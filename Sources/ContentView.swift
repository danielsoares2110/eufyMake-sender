import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Main window UI — macOS 26 "Liquid Glass" styling: rounded floating cards,
// translucent panels, big friendly status readouts, and a drop-anywhere G-code area.

struct ContentView: View {
    @ObservedObject var hub: PrinterHub
    @ObservedObject private var settings = AppSettings.shared
    @State private var dropTargeted = false
    @State private var showLogs = true

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 900 || geo.size.height < 600
            ZStack {
                backdrop
                if compact {
                    compactLayout
                } else {
                    regularLayout
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { if hub.selectedDevice == nil { hub.selectedDevice = hub.devices.first } }
        .animation(.smooth(duration: 0.25), value: hub.mqttState)
        .animation(.smooth(duration: 0.25), value: hub.status.progress)
        .animation(.smooth(duration: 0.25), value: hub.connectedCount)
    }

    // Soft backdrop so the glass panels have something to refract.
    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor),
                                    Color(nsColor: .underPageBackgroundColor)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            Circle()
                .fill(hub.tint.opacity(0.16))
                .frame(width: 620, height: 620)
                .blur(radius: 120)
                .offset(x: -380, y: -260)
                .ignoresSafeArea()
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 520, height: 520)
                .blur(radius: 130)
                .offset(x: 420, y: 300)
                .ignoresSafeArea()
        }
    }

    private var regularLayout: some View {
        VStack(spacing: 14) {
            HeaderBar(hub: hub)
            if hub.loginEmail.isEmpty {
                SignInBanner(hub: hub)
            }
            HStack(alignment: .top, spacing: 14) {
                StatusPanel(hub: hub)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 380)
                VStack(spacing: 14) {
                    CameraPanel(hub: hub)
                    TransferPanel(hub: hub, dropTargeted: $dropTargeted)
                }
            }
            .frame(maxHeight: .infinity)
            if settings.showActivity {
                LogPanel(hub: hub, expanded: $showLogs)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // Single scrolling column for small windows (limit disabled).
    private var compactLayout: some View {
        ScrollView {
            VStack(spacing: 12) {
                HeaderBar(hub: hub, compact: true)
                if hub.loginEmail.isEmpty {
                    SignInBanner(hub: hub)
                }
                StatusPanel(hub: hub)
                    .frame(height: 430)
                CameraPanel(hub: hub)
                    .frame(height: 300)
                TransferPanel(hub: hub, dropTargeted: $dropTargeted)
                if settings.showActivity {
                    LogPanel(hub: hub, expanded: $showLogs)
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @ObservedObject var hub: PrinterHub
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            appIcon(size: compact ? 34 : 42)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("EufyMake Sender")
                    .font(.system(size: compact ? 14 : 16, weight: .semibold))
                Text(compact ? shortSubtitle : deviceSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Menu {
                if hub.devices.isEmpty {
                    Text(hub.loginEmail.isEmpty ? "Sign in to list printers" : "No printers found")
                }
                ForEach(hub.devices) { d in
                    Button {
                        hub.selectedDevice = d
                    } label: {
                        Text(d.name.isEmpty ? d.sn : d.name)
                    }
                }
            } label: {
                Label(deviceLabel, systemImage: "printer.fill")
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()

            if !compact {
                AccountChip(hub: hub)

                if hub.loginEmail.isEmpty {
                    Button("Sign in") { hub.showLogin() }
                        .buttonStyle(.glassProminent)
                } else {
                    Button {
                        Task { await hub.refreshDevicesAndRestartMonitor() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .help("Refresh printers and reconnect the monitor")

                    Button("Sign out") { hub.signOut() }
                        .buttonStyle(.glass)
                }
            } else if hub.loginEmail.isEmpty {
                Button("Sign in") { hub.showLogin() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            }

            Button {
                SettingsWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.glass)
            .help("Settings")
        }
        .padding(compact ? 11 : 14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: compact ? 18 : 24, style: .continuous))
    }

    private var shortSubtitle: String {
        if let d = hub.selectedDevice {
            return d.name.isEmpty ? "Printer selected" : d.name
        }
        return hub.loginEmail.isEmpty ? "Not signed in" : "No printer selected"
    }

    private var deviceLabel: String {
        guard let d = hub.selectedDevice else { return "Select printer" }
        return d.name.isEmpty ? d.sn : d.name
    }
    private var deviceSubtitle: String {
        guard let d = hub.selectedDevice else { return "No printer selected" }
        let model = d.model.isEmpty ? "AnkerMake M5" : d.model
        let ip = d.ip.isEmpty ? "LAN discovery" : d.ip
        return "\(model) · \(ip)"
    }
}

private struct AccountChip: View {
    @ObservedObject var hub: PrinterHub

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: hub.loginEmail.isEmpty ? "person.crop.circle.badge.questionmark" : "person.crop.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(hub.loginEmail.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(hub.tint))
            Text(hub.loginEmail.isEmpty ? "Not signed in" : hub.loginEmail)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 190, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
    }
}

private struct SignInBanner: View {
    @ObservedObject var hub: PrinterHub

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(hub.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in to send prints").font(.subheadline.weight(.semibold))
                Text("Your AnkerMake account gives this app your printer list, live temperatures and the camera keys. The G-code transfer itself uses your local network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Sign in") { hub.showLogin() }
                .buttonStyle(.glassProminent)
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Status panel

private struct StatusPanel: View {
    @ObservedObject var hub: PrinterHub

    var body: some View {
        ScrollView {
            panelContent
        }
        .scrollIndicators(.never)
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(hub.mqttColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: hub.mqttColor.opacity(0.7), radius: 4)
                Text(hub.mqttLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if hub.mqttState == .offline, !hub.loginEmail.isEmpty {
                    Button("Reconnect") { Task { await hub.restartMonitor() } }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                TempGauge(title: "Nozzle", icon: "flame.fill",
                          current: Double(hub.status.nozzleCurrent),
                          target: Double(hub.status.nozzleTarget), maxTemp: 300,
                          tint: .orange)
                TempGauge(title: "Bed", icon: "square.stack.3d.up.fill",
                          current: Double(hub.status.bedCurrent),
                          target: Double(hub.status.bedTarget), maxTemp: 110,
                          tint: .pink)
            }

            Divider().opacity(0.4)

            HStack(spacing: 8) {
                StatePill(hub: hub)
                Spacer()
                if hub.status.progress >= 0 {
                    Text("\(Int(hub.status.progress))%")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }

            if hub.status.progress >= 0 {
                ProgressView(value: hub.status.progress, total: 100)
                    .progressViewStyle(.linear)
                    .tint(hub.tint)
            }

            if !hub.status.jobName.isEmpty {
                Label(hub.status.jobName, systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 14) {
                if hub.status.elapsed > 0 {
                    Label(fmt(hub.status.elapsed), systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if hub.status.timeLeft >= 0 {
                    Label(fmt(hub.status.timeLeft), systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if hub.status.totalLayer > 0 {
                    Label("\(hub.status.currentLayer)/\(hub.status.totalLayer)", systemImage: "square.3.layers.3d")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider().opacity(0.4)

            Text("CONTROLS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.8)

            HStack(spacing: 8) {
                Button { hub.pausePrint() } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.glass)
                .disabled(!hub.canControl)

                Button { hub.resumePrint() } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.glass)
                .disabled(!hub.canControl)

                Button { hub.stopPrint() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.glass)
                .tint(.red)
                .disabled(!hub.canControl)
            }
            .controlSize(.regular)

            HStack(spacing: 8) {
                Button { hub.preheat(210, 60) } label: {
                    Label("Preheat", systemImage: "thermometer.sun.fill")
                }
                .buttonStyle(.glass)
                .disabled(hub.mqttState != .connected)

                Button { hub.sendRawGcode("G28") } label: {
                    Label("Home", systemImage: "house.fill")
                }
                .buttonStyle(.glass)
                .disabled(hub.mqttState != .connected)
            }
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fmt(_ s: Int) -> String {
        let sec = max(0, s), m = sec / 60, h = m / 60
        return h > 0 ? String(format: "%dh %02dm", h, m % 60) : String(format: "%dm %02ds", m, sec % 60)
    }
}

private struct TempGauge: View {
    let title: String
    let icon: String
    let current: Double
    let target: Double
    let maxTemp: Double
    let tint: Color

    private var fraction: Double { Swift.min(Swift.max(current / maxTemp, 0), 1) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 9)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(AngularGradient(colors: [tint.opacity(0.55), tint],
                                            center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.5), value: fraction)
                VStack(spacing: 0) {
                    Text("\(Int(current))°")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(target > 0 ? "→ \(Int(target))°" : "off")
                        .font(.caption2)
                        .foregroundStyle(target > 0 ? tint : Color.secondary)
                }
            }
            .frame(width: 92, height: 92)

            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StatePill: View {
    @ObservedObject var hub: PrinterHub

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: hub.stateIcon)
            Text(hub.status.event?.label ?? "Idle")
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(hub.stateColor.opacity(0.18), in: Capsule())
        .foregroundStyle(hub.stateColor)
        .contentTransition(.opacity)
    }
}

// MARK: - Camera

private struct CameraPanel: View {
    @ObservedObject var hub: PrinterHub

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Camera", systemImage: "video.fill").font(.subheadline.weight(.semibold))
                Spacer()
                Text(hub.cameraStatusText).font(.caption).foregroundStyle(.secondary)
                if hub.cameraRunning || hub.cameraConnecting {
                    Button {
                        hub.stopCamera()
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.glass)
                } else {
                    Button {
                        hub.startCamera()
                    } label: {
                        Label("Start", systemImage: "play.circle.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(hub.selectedDevice == nil)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black)
                CameraDisplayView(hub: hub)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                if !hub.cameraRunning {
                    VStack(spacing: 10) {
                        Image(systemName: hub.cameraConnecting ? "hourglass" : "video.slash")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(hub.cameraConnecting ? "Connecting to the printer…" : "Camera is off")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 140)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        }
        .frame(maxHeight: .infinity)
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

// MARK: - G-code transfer

private struct TransferPanel: View {
    @ObservedObject var hub: PrinterHub
    @Binding var dropTargeted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("G-code", systemImage: "doc.badge.arrow.up").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Choose file…") { hub.importGcode() }
                    .buttonStyle(.glass)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(dropTargeted ? AnyShapeStyle(hub.tint.opacity(0.14)) : AnyShapeStyle(.quaternary.opacity(0.35)))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    .foregroundStyle(dropTargeted ? hub.tint : Color.secondary.opacity(0.5))

                HStack(spacing: 14) {
                    Image(systemName: hub.gcodeFile == nil ? "tray.and.arrow.down.fill" : "doc.text.fill")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(hub.gcodeFile == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(hub.tint))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hub.gcodeFile?.lastPathComponent ?? "Drop a .gcode file here")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(hub.gcodeFile == nil
                             ? "or use Choose file — the print starts as soon as the transfer finishes"
                             : hub.gcodeSizeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    transferAction
                }
                .padding(16)
            }
            .frame(minHeight: 96)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let u = item as? URL { url = u }
                    if let url { DispatchQueue.main.async { hub.setGcode(url) } }
                }
                return true
            }

            if case .failed(let why) = hub.transfer {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    private var transferAction: some View {
        switch hub.transfer {
        case .idle:
            Button {
                hub.sendToPrinter()
            } label: {
                Label("Send to printer", systemImage: "paperplane.fill")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(hub.gcodeFile == nil || hub.selectedDevice == nil)
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting…").font(.caption)
            }
        case .uploading(let p):
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView(value: p).frame(width: 150)
                Text("\(Int(p * 100))% sent").font(.caption).monospacedDigit()
            }
        case .succeeded:
            VStack(alignment: .trailing, spacing: 6) {
                Label("Print started", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Button("Done") { hub.transfer = .idle }.buttonStyle(.glass).controlSize(.small)
            }
        case .failed:
            Button("Dismiss") { hub.transfer = .idle }.buttonStyle(.glass)
        }
    }
}

// MARK: - Log

private struct LogPanel: View {
    @ObservedObject var hub: PrinterHub
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.smooth(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Label("Activity", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                Spacer()
                Text("\(hub.logs.count) lines").font(.caption).foregroundStyle(.secondary)
                Button("Clear") { hub.clearLogs() }.buttonStyle(.glass).controlSize(.small)
            }

            if expanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(hub.logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 116)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("[Pppp]") { return .blue }
        if line.hasPrefix("[MQTT]") { return .purple }
        if line.hasPrefix("[API]") { return .teal }
        if line.hasPrefix("[H264]") { return .orange }
        if line.hasPrefix("[Net]") { return .green }
        return .secondary
    }
}

// MARK: - Camera surface

/// NSView that shows CGImages pushed from the H.264 decoder.
final class CameraLayerView: NSView {
    private var imageLayer: CALayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let il = CALayer()
        il.contentsGravity = .resizeAspect
        il.frame = bounds
        il.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(il)
        imageLayer = il
    }

    required init?(coder: NSCoder) {
        imageLayer = nil
        super.init(coder: coder)
        wantsLayer = true
    }

    override var acceptsFirstResponder: Bool { false }

    func show(_ image: CGImage) {
        imageLayer?.contents = image
    }

    override func layout() {
        super.layout()
        imageLayer?.frame = bounds
    }
}

struct CameraDisplayView: NSViewRepresentable {
    @ObservedObject var hub: PrinterHub

    func makeNSView(context: Context) -> CameraLayerView {
        let v = CameraLayerView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        hub.cameraFrameHandler = { img in v.show(img) }
        return v
    }

    func updateNSView(_ nsView: CameraLayerView, context: Context) {}
}

// MARK: - Hub presentation helpers

extension PrinterHub {
    var cameraStatusText: String {
        if cameraConnecting { return "connecting…" }
        if cameraRunning { return "live · 720p · 25 fps" }
        return "offline"
    }

    var gcodeSizeLabel: String {
        gcodeSize > 0 ? ByteCountFormatter.string(fromByteCount: Int64(gcodeSize), countStyle: .file) : ""
    }

    var connectedCount: Int { devices.count }

    var canControl: Bool {
        mqttState == .connected &&
        (status.event == .printing || status.event == .paused || status.event == .printHeating ||
         status.event == .preheating)
    }

    var tint: Color {
        switch status.event {
        case .printing, .printHeating, .preheating: return .orange
        case .paused: return .yellow
        case .completed: return .green
        case .idle, .none: return .accentColor
        default: return .accentColor
        }
    }

    var stateColor: Color {
        switch status.event {
        case .printing, .printHeating, .preheating: return .orange
        case .paused: return .yellow
        case .completed: return .green
        case .stopped: return .red
        case .idle, .none: return .secondary
        default: return .accentColor
        }
    }

    var stateIcon: String {
        switch status.event {
        case .printing: return "printer.fill"
        case .printHeating, .preheating, .levelHeating: return "flame.fill"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .leveling: return "level.fill"
        case .downloading, .printDownloading: return "arrow.down.circle.fill"
        default: return "moon.zzz.fill"
        }
    }

    var mqttColor: Color {
        switch mqttState {
        case .connected: return .green
        case .connecting: return .yellow
        case .offline: return .red
        }
    }

    var mqttLabel: String {
        switch mqttState {
        case .connected: return "Monitor online — temperatures live"
        case .connecting: return "Connecting to the monitor…"
        case .offline: return loginEmail.isEmpty ? "Monitor offline — sign in" : "Monitor offline"
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    func showLogin() {
        let ctl = LoginWindowController { [weak self] state in
            DispatchQueue.main.async { self?.adoptionLoginCompleted(state) }
        }
        loginController = ctl
        ctl.show()
    }
}
