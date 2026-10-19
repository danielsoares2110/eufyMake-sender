import Foundation
import Network
import CryptoKit

// Port of AnkerMqtt.{hpp,cpp} + the mqttframe codec in AnkerNetNative:
// TLS MQTT 3.1.1 to make-mqtt(.eu).ankermake.com:8789, username "eufy_<user_id>",
// password = plain email, certs NOT verified (broker presents its own self-signed
// cert; the C++ did SSL_VERIFY_NONE, see PROTOCOL.md §2). Every payload is an "MA"
// frame: 64-byte header + AES-CBC(device secret_key, IV "3DPrintAnkerMake", PKCS7)
// ciphertext + 1 XOR checksum byte.

@inline(__always)
func anAESCBC(_ encrypt: Bool, key: Data, iv: Data, input: Data) -> Data? {
    let keyLen = key.count
    guard keyLen == 16 || keyLen == 32 else { return nil }
    var out = Data(repeating: 0, count: input.count + 48)
    var outLen: Int = out.count
    var iv = iv
    var key = key
    var input = input
    var outP = out
    let rc = outP.withUnsafeMutableBytes { ob -> Int32 in
        key.withUnsafeBytes { kb -> Int32 in
            iv.withUnsafeBytes { ib -> Int32 in
                input.withUnsafeBytes { db -> Int32 in
                    ANCryptoAESCBC(encrypt ? 1 : 0,
                                   kb.baseAddress!.assumingMemoryBound(to: UInt8.self), keyLen,
                                   ib.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                   db.baseAddress!.assumingMemoryBound(to: UInt8.self), input.count,
                                   ob.baseAddress!.assumingMemoryBound(to: UInt8.self), &outLen)
                }
            }
        }
    }
    out = outP
    guard rc == 0, outLen >= 0 else { return nil }
    return out.prefix(outLen)
}

enum MaFrame {
    static let iv = Data("3DPrintAnkerMake".utf8)

    static func decode(_ frame: Data, keyHex: String) -> Data? {
        guard frame.count >= 65 else { return nil }
        var xorAll: UInt8 = 0
        for b in frame { xorAll ^= b }
        guard xorAll == 0 else { return nil }
        let body = frame.dropLast(1)
        guard body.count >= 64,
              body.first == UInt8(ascii: "M"), body.dropFirst().first == UInt8(ascii: "A"),
              body[body.startIndex + 6] == 2 else { return nil }
        guard let key = Data(hexString: keyHex) else { return nil }
        return anAESCBC(false, key: key, iv: iv, input: body.dropFirst(64))
    }

    static func encode(_ json: String, keyHex: String, guid: String) -> Data? {
        guard let key = Data(hexString: keyHex) else { return nil }
        guard let enc = anAESCBC(true, key: key, iv: iv, input: Data(json.utf8)) else { return nil }

        let size = UInt16(64 + enc.count + 1)
        var h = Data("MA".utf8)
        h.appendLE(size)
        h.append(contentsOf: [5, 1, 2, 5, UInt8(ascii: "F"), 0xC0])
        h.append(contentsOf: [0, 0])          // packet_num
        h.append(contentsOf: [0, 0, 0, 0])    // time
        var g = Data(guid.utf8)
        g = g.prefix(37)
        if g.count < 37 { g.append(Data(repeating: 0, count: 37 - g.count)) }
        h.append(g)
        h.append(Data(repeating: 0, count: 11))
        precondition(h.count == 64)

        var frame = h + enc
        var x: UInt8 = 0
        for b in frame { x ^= b }
        frame.append(x)
        return frame
    }
}

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
            i += 2
        }
        self = Data(bytes)
    }
}

// MARK: - Minimal MQTT 3.1.1 client (QoS 0) over NWConnection TLS

final class AnkerMqttClient {
    private(set) var isConnected = false

    private var connection: NWConnection?
    private var buffer = Data()
    private var packetId: UInt16 = 1
    private var pingTimer: DispatchSourceTimer?
    private let writeQueue = DispatchQueue(label: "m5.mqtt.writer")
    private let queue: DispatchQueue
    var onMessage: ((_ topic: String, _ payload: Data) -> Void)?
    var onStateChange: ((Bool) -> Void)?

    init() { queue = DispatchQueue(label: "m5.mqtt") }

    // Cert validation disabled to match the reference implementation. If you want the
    // pinned cert instead, load AnkerStudio/resources/crt/make-us.crt as a custom anchor.
    static func makeTLSParams() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, DispatchQueue.global())
        return NWParameters(tls: tls)
    }

    func connect(host: String, port: UInt16, username: String, password: String,
                 clientId: String, completion: @escaping (_ ok: Bool, _ error: String?) -> Void) {
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: Self.makeTLSParams())
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isConnected = true
                self.onStateChange?(true)
                self.sendConnect(username: username, password: password, clientId: clientId)
                self.drainIncoming()
                self.startPinging()
                completion(true, nil)
            case .failed(let error):
                self.isConnected = false
                self.onStateChange?(false)
                completion(false, error.localizedDescription)
            case .waiting(let e):
                AppLog.mqtt("waiting: \(e)")
            case .cancelled:
                self.isConnected = false
                self.onStateChange?(false)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    func disconnect() {
        pingTimer?.cancel()
        pingTimer = nil
        isConnected = false
        connection?.cancel()
        connection = nil
        onStateChange?(false)
    }

    // MARK: packet assembly

    private static func puts(_ s: String, into out: inout Data) {
        let d = Data(s.utf8)
        out.appendLE(UInt16(d.count))
        out.append(d)
    }

    private static func remainingLength(_ len: Int, into out: inout Data) {
        var l = len
        repeat {
            var b = UInt8(l % 128)
            l /= 128
            if l > 0 { b |= 0x80 }
            out.append(b)
        } while l > 0
    }

    static func connectPacket(username: String, password: String, clientId: String) -> Data {
        var vh = Data()
        puts("MQTT", into: &vh)
        vh.append(0x04)                       // protocol level 4 (3.1.1)
        vh.append(0xC2)                       // user+pass+clean session
        vh.append(0x00); vh.append(0x3C)      // keepalive 60s
        puts(clientId, into: &vh)
        puts(username, into: &vh)
        puts(password, into: &vh)

        var pkt = Data([0x10])
        remainingLength(vh.count, into: &pkt)
        pkt.append(vh)
        return pkt
    }

    private func subscribePacket(_ topic: String) -> Data {
        var vh = Data()
        vh.appendBE(nextPacketId())
        Self.puts(topic, into: &vh)
        vh.append(0x00)
        var pkt = Data([0x82])
        Self.remainingLength(vh.count, into: &pkt)
        pkt.append(vh)
        return pkt
    }

    private func publishPacket(_ topic: String, payload: Data) -> Data {
        var vh = Data()
        Self.puts(topic, into: &vh)
        vh.append(payload)
        var pkt = Data([0x30]) // QoS 0, no packet id
        Self.remainingLength(vh.count, into: &pkt)
        pkt.append(vh)
        return pkt
    }

    private func nextPacketId() -> UInt16 {
        packetId = packetId == 65000 ? 1 : packetId + 1
        return packetId
    }

    private var writeBuf = Data()

    private func writeRaw(_ data: Data) {
        guard let conn = connection, isConnected || writeBuf.isEmpty == false else { return }
        conn.send(content: data, completion: .contentProcessed { err in
            if let err { AppLog.mqtt("send error \(err)") }
        })
    }

    private func sendConnect(username: String, password: String, clientId: String) {
        writeRaw(Self.connectPacket(username: username, password: password, clientId: clientId))
    }

    func subscribe(_ topic: String) {
        guard isConnected else { return }
        writeRaw(subscribePacket(topic))
    }

    func publish(topic: String, payload: Data) {
        guard isConnected else { return }
        writeRaw(publishPacket(topic, payload: payload))
    }

    private func startPinging() {
        pingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in self?.writeRaw(Data([0xC0, 0x00])) }
        t.resume()
        pingTimer = t
    }

    // MARK: receive loop

    private func drainIncoming() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainPackets()
            }
            if done || err != nil {
                if let err { AppLog.mqtt("recv error \(err)") }
                self.isConnected = false
                self.onStateChange?(false)
                return
            }
            if (self.isConnected) { self.drainIncoming() }
        }
    }

    /// Parse + consume MQTT packets from the buffer.
    private func drainPackets() {
        while true {
            guard let first = buffer.first else { return }
            var remaining = 0
            var multiplier = 1
            var i = 1
            var ok = false
            while i <= 4 && i < buffer.count {
                let b = buffer[buffer.startIndex + i]
                remaining += Int(b & 0x7f) * multiplier
                multiplier *= 128
                i += 1
                if b & 0x80 == 0 { ok = true; break }
            }
            guard ok, buffer.count >= i + remaining else { return }

            let type = first & 0xF0
            let body = buffer.subdata(in: (buffer.startIndex + i)..<(buffer.startIndex + i + remaining))
            buffer.removeFirst(i + remaining)

            if type == 0x30 {
                if body.count >= 2 {
                    let tlen = (Int(body[body.startIndex]) << 8) | Int(body[body.startIndex + 1])
                    if 2 + tlen <= body.count {
                        let topic = String(data: body.subdata(in: (body.startIndex + 2)..<(body.startIndex + 2 + tlen)), encoding: .utf8) ?? ""
                        let payload = body.subdata(in: (body.startIndex + 2 + tlen)..<body.endIndex)
                        onMessage?(topic, payload)
                    }
                }
            }
        }
    }
}
