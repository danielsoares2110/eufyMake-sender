import Foundation
import AppKit

// Orchestrates everything: login → device list → MQTT monitoring → PPPP camera/upload.

enum PrintEvent: Int {
    case idle = 0, printing = 1, paused = 2, stopped = 3, completed = 4, leveling = 5,
         downloading = 6, levelHeating = 7, printHeating = 8, preheating = 9,
         printDownloading = 10, calibration = 11, calibrationHeating = 12,
         extrusionPreheating = 13, feedAndReturnMaterial = 14, slicing = 15,
         loadMaterial = 16, unloadMaterial = 17
    var label: String {
        switch self {
        case .idle: return "Idle"
        case .printing: return "Printing"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .completed: return "Completed"
        case .leveling: return "Leveling"
        case .downloading: return "Downloading"
        case .levelHeating: return "Level heating"
        case .printHeating: return "Heating"
        case .preheating: return "Pre-heating"
        default: return "Busy (\(rawValue))"
        }
    }
}

struct DeviceStatus {
    var nozzleCurrent: Int = 0
    var nozzleTarget: Int = 0
    var bedCurrent: Int = 0
    var bedTarget: Int = 0
    var event: PrintEvent? = nil
    var jobName: String = ""
    var progress: Double = -1        // 0..100, -1 = unknown
    var timeLeft: Int = -1           // seconds
    var elapsed: Int = 0
    var totalLayer: Int = 0
    var currentLayer: Int = 0
}

enum MqttState: String { case offline, connecting, connected }
enum TransferState: Equatable {
    case idle
    case connecting
    case uploading(Double)
    case succeeded
    case failed(String)
}


@MainActor
final class PrinterHub: ObservableObject {
    static let shared = PrinterHub()

    let api = AnkerAPI()
    private(set) var login = LoginState()

    @Published var loginEmail: String = ""
    @Published var devices: [AnkerDevice] = []
    @Published var selectedDevice: AnkerDevice?
    @Published var status = DeviceStatus()
    @Published var mqttState: MqttState = .offline
    @Published var cameraRunning = false
    @Published var cameraConnecting = false
    @Published var gcodeFile: URL?
    @Published var gcodeSize: Int = 0
    @Published var transfer: TransferState = .idle
    @Published var logs: [String] = []

    private var mqtt = AnkerMqttClient()
    private var cameraThread: Thread?
    private var cameraStop = Atomic(false)
    private var cameraLastFrame = Atomic(Date.distantPast)
    var cameraFrameHandler: ((CGImage) -> Void)?
    private var uploadSessionActive = Atomic(false)
    var loginController: LoginWindowController?

    init() {
        login = api.loadLogin()
        loginEmail = login.email
        AppLog.onLine { [weak self] line in
            DispatchQueue.main.async {
                self?.logs.insert(line, at: 0)
                if self?.logs.count ?? 0 > 200 { self?.logs.removeLast() }
            }
        }
        if login.isLogined {
            Task { await refreshDevicesAndRestartMonitor() }
        }
    }

    // MARK: - Login

    func adoptionLoginCompleted(_ newLogin: LoginState) {
        login = newLogin
        loginEmail = newLogin.email
        api.saveLogin(newLogin)
        Task { await refreshDevicesAndRestartMonitor() }
    }

    func signOut() {
        mqtt.disconnect()
        login = LoginState()
        loginEmail = ""
        devices = []
        selectedDevice = nil
        try? FileManager.default.removeItem(atPath: AnkerAPI.loginCachePath())
        mqttState = .offline
    }

    // MARK: - Device list + MQTT monitor

    func refreshDevices() async {
        guard login.isLogined else { return }
        do {
            let devs = try await api.queryDeviceList(login)
            devices = devs
            if selectedDevice == nil || !devs.contains(where: { $0.sn == selectedDevice?.sn }) {
                selectedDevice = devs.first
            }
            AppLog.api("fetched \(devs.count) device(s)")
        } catch {
            AppLog.api("device list failed: \(error)")
        }
    }

    func restartMonitor() async {
        guard login.isLogined, !devices.isEmpty else { return }
        mqtt.disconnect()
        mqttState = .connecting
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let fresh = AnkerMqttClient()
            mqtt = fresh
            fresh.onStateChange = { [weak self] ok in
                DispatchQueue.main.async {
                    self?.mqttState = ok ? .connected : .offline
                }
            }
            fresh.onMessage = { [weak self] topic, payload in
                DispatchQueue.main.async {
                    self?.handleMqttMessage(topic: topic, payload: payload)
                }
            }
            fresh.connect(host: login.mqttHost, port: 8789,
                          username: "eufy_" + login.user_id,
                          password: login.email,
                          clientId: "eufypc_\(String(login.user_id.prefix(8)))_\(Int.random(in: 0..<999999))") { ok, err in
                if !ok { AppLog.mqtt("connect failed: \(err ?? "?")") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { cont.resume() }
            }
        }
        guard mqtt.isConnected else { mqttState = .offline; return }

        for d in devices {
            mqtt.subscribe("/phone/maker/\(d.sn)/notice")
            mqtt.subscribe("/phone/maker/\(d.sn)/command/reply")
            mqtt.subscribe("/phone/maker/\(d.sn)/query/reply")
        }
        // Ask every device for a full status snapshot (commandType 1027).
        for d in devices {
            publishFramed(device: d, json: "{\"commandType\":1027}", topicSuffix: "/query")
        }
    }

    func refreshDevicesAndRestartMonitor() async {
        await refreshDevices()
        await restartMonitor()
    }

    // MARK: - MQTT publishing

    private func myGuid() -> String { UUID().uuidString }

    private func publishFramed(device: AnkerDevice, json: String, topicSuffix: String) {
        guard let frame = MaFrame.encode(json, keyHex: device.secretKey, guid: myGuid()) else {
            AppLog.mqtt("frame encode failed for \(device.sn)")
            return
        }
        mqtt.publish(topic: "/device/maker/\(device.sn)\(topicSuffix)", payload: frame)
    }

    /// QoS-0 commands can be silently dropped (observed); send 3x over ~800ms for the
    /// important ones, exactly like the reference implementation.
    func sendCommandReliably(device: AnkerDevice, json: String) {
        let dev = device
        publishFramed(device: dev, json: json, topicSuffix: "/command")
        DispatchQueue.global(qos: .utility).async {
            for _ in 0..<2 {
                Thread.sleep(forTimeInterval: 0.4)
                DispatchQueue.main.async {
                    self.publishFramed(device: dev, json: json, topicSuffix: "/command")
                }
            }
        }
    }

    func pausePrint() { printControl(2) }
    func resumePrint() { printControl(3) }
    func stopPrint() { printControl(4) }

    private func printControl(_ value: Int) {
        guard let dev = selectedDevice else { return }
        let json = "{\"commandType\":1008,\"value\":\(value),\"printMode\":1," +
            "\"userName\":\"\(login.nick_name)\",\"filePath\":\"\",\"userId\":\"\(login.user_id)\"}"
        sendCommandReliably(device: dev, json: json)
        AppLog.mqtt("print control \(value)")
    }

    func sendRawGcode(_ line: String) {
        guard let dev = selectedDevice else { return }
        let escaped = line.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
        let json = "{\"commandType\":1043,\"cmdLen\":\(escaped.count),\"cmdData\":\"\(escaped)\"}"
        sendCommandReliably(device: dev, json: json)
    }

    func preheat(_ nozzleTarget: Int, _ bedTarget: Int) {
        guard let dev = selectedDevice else { return }
        // The 1003/1004 commands take a plain "value" in 1/100 °C; the heater only
        // actually engages when the matching M104/M140 gcode is sent too (1043),
        // per the reference client.
        publishFramed(device: dev, json: "{\"commandType\":1003,\"value\":\(nozzleTarget * 100)}", topicSuffix: "/command")
        publishFramed(device: dev, json: "{\"commandType\":1004,\"value\":\(bedTarget * 100)}", topicSuffix: "/command")
        sendRawGcode("M104 S\(nozzleTarget)")
        sendRawGcode("M140 S\(bedTarget)")
    }

    // MARK: - MQTT receive / status update

    private func handleMqttMessage(topic: String, payload: Data) {
        // topic: /phone/maker/<sn>/<kind>
        guard let range = topic.range(of: "/maker/") else { return }
        let rest = topic[range.upperBound...]
        let sn = rest.prefix { $0 != "/" }
        guard let device = devices.first(where: { $0.sn == sn }) else { return }
        guard let json = MaFrame.decode(payload, keyHex: device.secretKey),
              let obj = try? JSONSerialization.jsonObject(with: json) else {
            AppLog.mqtt("MA decode failed sn=\(sn) topic=\(topic)")
            return
        }
        var objs: [[String: Any]] = []
        if let single = obj as? [String: Any] {
            objs = [single]
        } else if let arr = obj as? [[String: Any]] {
            objs = arr
        }
        for o in objs { applyStatus(o) }
    }

    private func applyStatus(_ o: [String: Any]) {
        let cmd = o["commandType"] as? Int ?? -1
        switch cmd {
        case 1003, 1004: // temps are x100
            let cur = o["currentTemp"] as? Int ?? 0
            let tgt = o["targetTemp"] as? Int ?? 0
            if cmd == 1003 { status.nozzleCurrent = cur / 100; status.nozzleTarget = tgt / 100 }
            else { status.bedCurrent = cur / 100; status.bedTarget = tgt / 100 }
        case 1000:
            if o["subType"] as? Int == 1, let v = o["value"] as? Int, let ev = PrintEvent(rawValue: v) {
                status.event = ev
            }
        case 1001:
            if let p = o["progress"] as? Int, p >= 0 { status.progress = Double(p) / 100.0 }
            if let name = o["name"] as? String { status.jobName = name }
            status.timeLeft = o["time"] as? Int ?? -1
            status.elapsed = o["totalTime"] as? Int ?? 0
        case 1052:
            status.totalLayer = o["total_layer"] as? Int ?? 0
            status.currentLayer = o["real_print_layer"] as? Int ?? 0
        default:
            break
        }
    }

    // MARK: - Camera

    func startCamera() {
        guard let device = selectedDevice, !cameraRunning, !cameraConnecting else { return }
        let duid = device.p2pDid
        guard !duid.isEmpty else {
            AppLog.pppp("no p2p_did for \(device.sn)")
            return
        }
        cameraRunning = false
        cameraConnecting = true
        cameraStop.v = false
        cameraLastFrame.v = .distantPast
        let stopFlag = cameraStop
        let frameHandler = cameraFrameHandler
        let lastFrame = cameraLastFrame

        let thread = Thread { [weak self] in
            guard let self else { return }
            let client = PpppClient()
            let ok = client.connectLan(duidString: duid, ip: device.ip.isEmpty ? nil : device.ip, timeout: 10)
            DispatchQueue.main.async {
                self.cameraConnecting = false
                if !ok {
                    AppLog.pppp("video PPPP connect failed")
                    return
                }
                self.cameraRunning = true
            }
            if ok {
                let decoder = H264Decoder()
                decoder.onFrame = { img in
                    lastFrame.v = Date()
                    if let frameHandler { frameHandler(img) }
                }
                client.startLive()
                while !stopFlag.v && client.isConnected {
                    if let chunk = client.recvVideoChunk(timeoutMs: 3000), !chunk.isEmpty {
                        decoder.feed(chunk)
                    }
                    if Date().timeIntervalSince(lastFrame.v) > 30 { break }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                client.stopLive()
                client.close()
            }
            DispatchQueue.main.async {
                self.cameraRunning = false
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
        cameraThread = thread
    }

    func stopCamera() {
        cameraStop.v = true
        cameraRunning = false
    }

    func shutdown() {
        stopCamera()
        mqtt.disconnect()
    }

    // MARK: - G-code transfer

    func importGcode() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        if panel.runModal() == .OK, let url = panel.url {
            setGcode(url)
        }
    }

    func setGcode(_ url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else { return }
        gcodeFile = url
        gcodeSize = size
        AppLog.net("imported \(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .binary)))")
    }

    func sendToPrinter() {
        guard let device = selectedDevice, let file = gcodeFile, case .idle = transfer else { return }
        transfer = .connecting

        // Pause the camera during the upload (the reference app enforces one P2P
        // transfer at a time; this keeps the DRW streams clean).
        let camWasRunning = cameraRunning
        if camWasRunning { stopCamera() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.doUpload(device: device, file: file, restartCamera: camWasRunning)
        }
    }

    private func doUpload(device: AnkerDevice, file: URL, restartCamera: Bool) {
        let duid = device.p2pDid
        guard !duid.isEmpty && !uploadSessionActive.v else {
            transfer = .failed(duid.isEmpty ? "device has no p2p id" : "transfer already running")
            return
        }
        uploadSessionActive.v = true
        let sessionFlag = uploadSessionActive
        let userName = login.nick_name.isEmpty ? "EufyMake Sender" : login.nick_name
        let userId = login.user_id

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer { sessionFlag.v = false }

            guard let data = try? Data(contentsOf: file) else {
                DispatchQueue.main.async { self.transfer = .failed("cannot read \(file.lastPathComponent)") }
                if restartCamera { self.restartCameraLater() }
                return
            }
            let client = PpppClient()
            let connected = client.connectLan(duidString: duid, ip: device.ip.isEmpty ? nil : device.ip, timeout: 12)
            guard connected else {
                DispatchQueue.main.async {
                    self.transfer = .failed("PPPP connect timed out — is the printer on the LAN?")
                }
                if restartCamera { self.restartCameraLater() }
                return
            }

            DispatchQueue.main.async {
                self.transfer = .uploading(0)
            }
            let ok = client.uploadFile(fileName: file.lastPathComponent, fileData: data,
                                       userName: userName,
                                       userId: userId,
                                       machineId: UUID().uuidString) { pct in
                DispatchQueue.main.async {
                    self.transfer = .uploading(pct)
                }
            }
            client.close()
            DispatchQueue.main.async {
                self.transfer = ok ? .succeeded : .failed("printer rejected the transfer (see log)")
                if restartCamera { self.restartCameraLater() }
            }
        }
    }

    private func restartCameraLater() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.startCamera()
        }
    }
}

// Tiny atomic wrapper for cross-thread flags.
final class Atomic<T> {
    private var value: T
    private let lock = NSLock()
    init(_ initial: T) { value = initial }
    var v: T {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}
