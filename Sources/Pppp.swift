import Foundation
import CryptoKit

// Port of AnkerStudio's AnkerPppp.{hpp,cpp} (LAN path) — the direct UDP protocol to
// AnkerMake M5 printers, as documented in AnkerNetModule/PROTOCOL.md §3:
//   - every packet: 0xF1 | type(1) | len(u16 BIG-endian) | payload
//   - discovery: LAN_SEARCH broadcast to UDP 32108 every 500ms until we lock the printer
//   - handshake: PUNCH_PKT -> reply CLOSE + P2P_RDY; P2P_RDY -> reply P2P_RDY_ACK
//   - reliable writes: DRW packets (<=1024B, retransmit every 500ms until acked)
//   - file upload: XZYH announce (chan 0) + AABB BEGIN/DATA(32KB)/END frames (chan 1)
//   - camera: XZYH JSON commandType 1000 (start) / 1001 (stop); H.264 chunks on chan 1
//
// Like the C++ original this class is *always driven from one thread*: connect(),
// uploadFile() and recvVideoChunk() each pump the socket while they block. Run each
// PpppClient on its own background thread/queue (the caller's).

final class PpppClient {
    static let LAN_PORT: UInt16 = 32108

    private enum PType: UInt8 {
        case hello = 0x00, helloAck = 0x01
        case lanSearch = 0x30
        case punchPkt = 0x41
        case p2pRdy = 0x42, p2pRdyAck = 0x43
        case drw = 0xd0, drwAck = 0xd1
        case alive = 0xe0, aliveAck = 0xe1
        case close = 0xf0
    }

    // AABB frametypes
    private let ftBegin: UInt8 = 0x00
    private let ftData: UInt8 = 0x01
    private let ftEnd: UInt8 = 0x02

    private let p2pSendFile: UInt16 = 0x3a98
    private let p2pJsonCmd: UInt16 = 0x06a4

    final class Channel {
        var txCtr: UInt16 = 0
        var rxCtr: UInt16 = 0
        var tx: [UInt16: (data: Data, deadline: TimeInterval)] = [:]
        var rxBuf: [UInt16: Data] = [:]
        var rxBytes = Data()
    }

    private var fd: Int32 = -1
    private var duid = Data()
    private var peer: (octets: [UInt8], port: UInt16) = ([255, 255, 255, 255], 32108)
    private var peerLocked = false
    private(set) var connected = false
    private var closed = false
    private var chanReleased = false
    private var chans: [Channel] = (0..<8).map { _ in Channel() }
    private let lock = NSLock()
    private let txLock = NSLock()  // guards tx maps + txCtr

    deinit { close() }

    var isConnected: Bool { connected && !closed }

    // MARK: - Connection

    /// Connect over the LAN. `duidString` is the device's `p2p_did` from the cloud
    /// ("prefix-serial-check"). If `ip` is empty/stale we fall back to broadcast
    /// discovery, which is the reliable path. Blocks up to `timeout` seconds.
    func connectLan(duidString: String, ip: String?, timeout: TimeInterval) -> Bool {
        let packed = Self.packDuid(duidString)
        guard packed.count == 20 else { return false }
        duid = packed

        fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))

        connected = false
        closed = false
        peerLocked = false

        var directed = false
        if let ip, let addr = Self.ipv4Octets(ip) {
            directed = true
            peer = (addr, PpppClient.LAN_PORT)
            peerLocked = true
        } else {
            peer = ([255, 255, 255, 255], PpppClient.LAN_PORT)
        }

        let deadline = Date().addingTimeInterval(timeout)
        let switchToBroadcast = directed ? Date().addingTimeInterval(6) : .distantPast
        var nextSearch: TimeInterval = 0
        while !connected && !closed && Date() < deadline {
            if directed && Date() >= switchToBroadcast {
                // The cloud's ip_addr is often empty or stale — broadcast discovery.
                directed = false
                peerLocked = false
                peer = ([255, 255, 255, 255], PpppClient.LAN_PORT)
            }
            if Date().timeIntervalSince1970 >= nextSearch {
                sendPkt(.lanSearch, Data())
                nextSearch = Date().timeIntervalSince1970 + 0.5
            }
            pump(100)
        }
        return connected
    }

    func close() {
        guard !chanReleased else { return }
        chanReleased = true
        if fd >= 0 {
            if connected {
                sendPkt(.close, Data())
            }
            Darwin.close(fd)
            fd = -1
        }
        lock.lock(); defer { lock.unlock() }
        connected = false
        closed = true
    }

    // MARK: - File upload (StartP2pOperator / uploadFile port)

    /// Upload a gcode file and start the print. `machineId` is a 16-char client id.
    func uploadFile(fileName: String, fileData: Data, userName: String,
                    userId: String, machineId: String,
                    progress: ((Double) -> Void)? = nil) -> Bool {
        guard connected else { return false }

        // 1) XZYH announce on channel 0 (16-char id).
        let id16 = String((machineId + "0000000000000000").prefix(16))
        sendXzyh(cmd: p2pSendFile, data: Data(id16.utf8), chan: 0)
        guard waitDrained(chan: 0, timeout: 10) else { return false }

        // 2) BEGIN: "0,<filename>,<size>,<md5hex>,<user>,<userid>,<machine>" + NUL
        let md5hex = Insecure.MD5.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
        let csv = "0,\(fileName),\(fileData.count),\(md5hex),\(userName),\(userId),\(machineId)"
        let meta = Data(csv.utf8) + Data([0x00])
        guard aabbRequest(ftBegin, meta, pos: 0, timeout: 15) else {
            AppLog.pppp("BEGIN rejected")
            return false
        }

        // 3) DATA in 32KB chunks.
        let blocksize = 1024 * 32
        var pos = 0
        while pos < fileData.count {
            let n = min(blocksize, fileData.count - pos)
            let chunk = fileData.subdata(in: pos..<(pos + n))
            guard aabbRequest(ftData, chunk, pos: UInt32(pos), timeout: 20) else {
                AppLog.pppp("DATA rejected at pos \(pos)")
                return false
            }
            pos += n
            progress?(Double(pos) / Double(fileData.count))
        }

        // 4) END — required: starts the print. Without it the printer shows
        // "transfer failed" even though every frame was acked.
        guard aabbRequest(ftEnd, Data(), pos: 0, timeout: 20) else {
            AppLog.pppp("END rejected")
            return false
        }
        AppLog.pppp("upload complete + END (\(fileData.count) bytes)")
        return true
    }

    // MARK: - Camera

    func startLive() {
        let json = "{\"commandType\":1000,\"data\":{\"encryptkey\":\"x\",\"accountId\":\"y\"}}"
        sendXzyh(cmd: p2pJsonCmd, data: Data(json.utf8), chan: 0)
        waitDrained(chan: 0, timeout: 5)
    }

    func stopLive() {
        let json = "{\"commandType\":1001}"
        sendXzyh(cmd: p2pJsonCmd, data: Data(json.utf8), chan: 0)
        waitDrained(chan: 0, timeout: 3)
    }

    /// Blocks up to ~timeout ms for the next video chunk (raw Annex-B H.264).
    func recvVideoChunk(timeoutMs: Int) -> Data? {
        var out = Data()
        guard recvXzyh(chan: 1, into: &out, timeoutMs: timeoutMs) else { return nil }
        return out
    }

    // MARK: - XZYH / channel plumbing

    private func sendXzyh(cmd: UInt16, data: Data, chan: UInt8) {
        var body = Data("XZYH".utf8)
        body.appendLE(cmd)
        body.appendLE(UInt32(data.count))
        body.append(contentsOf: [0, 0, 0, 0, 0, 0])
        body.append(data)
        channelSend(chan, body)
    }

    private func recvXzyh(chan: UInt8, into out: inout Data, timeoutMs: Int) -> Bool {
        var hdr = Data()
        guard readN(chan, 16, into: &hdr, timeoutMs: timeoutMs) else { return false }
        guard hdr.count == 16,
              hdr[0] == UInt8(ascii: "X"), hdr[1] == UInt8(ascii: "Z"),
              hdr[2] == UInt8(ascii: "Y"), hdr[3] == UInt8(ascii: "H") else { return false }
        let len = Int(hdr.u32leLE(at: 6))
        return readN(chan, len, into: &out, timeoutMs: timeoutMs)
    }

    /// AABB request on channel 1: send frame (reliably), await REPLY (frametype|0x80,
    /// payload 0x00 == OK). CRC16/XMODEM over everything after the AA BB magic.
    private func aabbRequest(_ frametype: UInt8, _ data: Data, pos: UInt32, timeout: TimeInterval) -> Bool {
        var frame = Data([0xAA, 0xBB, frametype, 0x00])
        frame.appendLE(pos)
        frame.appendLE(UInt32(data.count))
        frame.append(data)
        let crc = Self.crc16Xmodem(frame.subdata(in: 2..<frame.count))
        frame.appendLE(crc)

        channelSend(1, frame)
        guard waitDrained(chan: 1, timeout: timeout) else { return false }

        var hdr = Data()
        guard readN(1, 12, into: &hdr, timeoutMs: min(Int(timeout * 1000), 20000)) else { return false }
        guard hdr.count == 12, hdr[0] == 0xAA, hdr[1] == 0xBB else { return false }
        let rlen = Int(hdr.u32leLE(at: 8))
        var rest = Data()
        guard readN(1, rlen + 2, into: &rest, timeoutMs: 3000) else { return false }
        guard !rest.isEmpty else { return false }
        if rest[0] != 0x00 {
            AppLog.pppp(String(format: "aabb reply frametype=0x%02x reply=0x%02x", hdr[2], rest[0]))
        }
        return rest[0] == 0x00
    }

    private func channelSend(_ chan: UInt8, _ data: Data) {
        txLock.lock()
        let ch = chans[Int(chan)]
        var off = 0
        while off < data.count {
            let n = min(1024, data.count - off)
            var body = Data([0xD1, chan])
            body.appendBE(ch.txCtr)
            body.append(data.subdata(in: off..<(off + n)))
            ch.tx[ch.txCtr] = (body, Date().timeIntervalSince1970)
            ch.txCtr &+= 1
            off += n
        }
        txLock.unlock()
        retransmit()
    }

    private func retransmit() {
        let now = Date().timeIntervalSince1970
        txLock.lock()
        for c in 0..<8 {
            var keys: [UInt16] = []
            for (k, v) in chans[c].tx where v.deadline <= now { keys.append(k) }
            for k in keys {
                sendPkt(.drw, chans[c].tx[k]!.data)
                chans[c].tx[k]!.deadline = now + 0.5
            }
        }
        txLock.unlock()
    }

    private func waitDrained(chan: UInt8, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            txLock.lock()
            let empty = chans[Int(chan)].tx.isEmpty
            txLock.unlock()
            if empty { return true }
            if closed { return false }
            pump(50)
        }
        return true
    }

    private func readN(_ chan: UInt8, _ n: Int, into out: inout Data, timeoutMs: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        lock.lock()
        let ch = chans[Int(chan)]
        while ch.rxBytes.count < n {
            lock.unlock()
            if closed || Date() > deadline { return false }
            pump(50)
            lock.lock()
        }
        out = ch.rxBytes.prefix(n)
        ch.rxBytes.removeFirst(n)
        lock.unlock()
        return true
    }

    // MARK: - Packet layer

    private func pump(_ timeoutMs: Int) {
        var buf = [UInt8](repeating: 0, count: 4096)
        var srcAddr = sockaddr_in()
        var slen = socklen_t(MemoryLayout<sockaddr_in>.size)

        var tv = timeval(tv_sec: Int(timeoutMs / 1000), tv_usec: Int32((timeoutMs % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let n = withUnsafeMutablePointer(to: &srcAddr) { sa in
            recvfrom(fd, &buf, buf.count, 0, unsafeBitCast(sa, to: UnsafeMutablePointer<sockaddr>.self), &slen)
        }
        guard n >= 4, buf[0] == 0xF1 else { retransmit(); return }

        let octets = withUnsafeBytes(of: srcAddr.sin_addr.s_addr) { [UInt8($0[0]), UInt8($0[1]), UInt8($0[2]), UInt8($0[3])] }
        let srcPort = UInt16(srcAddr.sin_port.bigEndian)
        let accept = !peerLocked || (octets == peer.octets)
        guard accept else { retransmit(); return }
        if peerLocked {
            peer = (octets, srcPort)
        }

        let type = buf[1]
        var len = (Int(buf[2]) << 8) | Int(buf[3])
        let avail = n - 4
        if len > avail { len = avail }
        let payload = Data(buf[4..<(4 + len)])
        dispatch(type: type, payload: payload, srcOctets: octets, srcPort: srcPort)
        retransmit()
    }

    private func dispatch(type: UInt8, payload p: Data,
                          srcOctets: [UInt8], srcPort: UInt16) {
        // Before we've locked a peer, only discovery replies are actionable (parity
        // with the C++ client; keeps stray LAN chatter from resetting us).
        if !peerLocked && type != PType.p2pRdy.rawValue && type != PType.punchPkt.rawValue {
            return
        }
        lock.lock()
        switch type {
        case PType.p2pRdy.rawValue:
            if !peerLocked {
                guard p.count >= 12, p.prefix(12) == duid.prefix(12) else { lock.unlock(); return }
                // Adopt the printer's actual source address/port (the discover reply
                // may come from a different port than 32108).
                peer = (srcOctets, srcPort)
                peerLocked = true
                AppLog.pppp("locked peer via P2P_RDY")
            }
            var ack = duid
            ack.append(hostFrom(peer.octets, peer.port))
            ack.append(contentsOf: [UInt8](repeating: 0, count: 8))
            lock.unlock()
            sendPkt(.p2pRdyAck, ack)
            connected = true

        case PType.punchPkt.rawValue:
            if !connected {
                if !peerLocked {
                    guard p.count >= 12, p.prefix(12) == duid.prefix(12) else { lock.unlock(); return }
                    peer = (srcOctets, srcPort)
                    peerLocked = true
                }
                lock.unlock()
                sendPkt(.close, Data())
                sendPkt(.p2pRdy, duid)
            } else {
                lock.unlock()
            }

        case PType.hello.rawValue:
            lock.unlock()
            sendPkt(.helloAck, hostFrom(peer.octets, peer.port))

        case PType.alive.rawValue:
            lock.unlock()
            sendPkt(.aliveAck, Data())

        case PType.close.rawValue:
            closed = true
            connected = false
            lock.unlock()

        case PType.drwAck.rawValue:
            if p.count >= 4 {
                let chan = Int(p[p.startIndex + 1])
                guard chan < 8 else { lock.unlock(); return }
                let count = (Int(p[p.startIndex + 2]) << 8) | Int(p[p.startIndex + 3])
                var i = 0
                while i < count && (4 + i * 2 + 1) < p.count {
                    let idx = (UInt16(p[p.startIndex + 4 + i * 2]) << 8) | UInt16(p[p.startIndex + 4 + i * 2 + 1])
                    txLock.lock()
                    chans[chan].tx.removeValue(forKey: idx)
                    txLock.unlock()
                    i += 1
                }
            }
            lock.unlock()

        case PType.drw.rawValue:
            defer { lock.unlock() }
            if p.count < 4 { break }
            let chan = Int(p[p.startIndex + 1])
            guard chan < 8 else { break }
            let index = (UInt16(p[p.startIndex + 2]) << 8) | UInt16(p[p.startIndex + 3])
            let data = p.subdata(in: p.startIndex + 4..<p.endIndex)

            var ack = Data([0xD1, UInt8(chan)])
            ack.appendBE(UInt16(1))
            ack.appendBE(index)
            sendPkt(.drwAck, ack)

            let ch = chans[chan]
            let diff = UInt16(index &- ch.rxCtr)
            if diff == 0 {
                ch.rxBytes.append(data)
                ch.rxCtr &+= 1
                while let d = ch.rxBuf[ch.rxCtr] {
                    ch.rxBytes.append(d)
                    ch.rxBuf.removeValue(forKey: ch.rxCtr)
                    ch.rxCtr &+= 1
                }
            } else if diff < 0x8000 {
                ch.rxBuf[index] = data
            }
        default:
            lock.unlock()
        }
    }

    private func sendPkt(_ type: PType, _ payload: Data) {
        var pkt = Data([0xF1, type.rawValue])
        pkt.appendBE(UInt16(payload.count))
        pkt.append(payload)
        sendUdp(pkt, to: peer.octets, port: peer.port)
    }

    private func sendUdp(_ data: Data, to octets: [UInt8], port: UInt16) {
        guard fd >= 0 else { return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        memset(&addr.sin_addr, 0, 4)
        withUnsafeMutableBytes(of: &addr.sin_addr) { raw in
            for i in 0..<4 { raw[i] = octets[i] }
        }
        let sent = data.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &addr) { p -> Int in
                Darwin.sendto(fd, raw.baseAddress, data.count, 0,
                              unsafeBitCast(p, to: UnsafePointer<sockaddr>.self),
                              socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        _ = sent
    }

    private func hostFrom(_ octets: [UInt8], _ port: UInt16) -> Data {
        var h = Data([0x00, 0x02])
        h.appendLE(port)
        h.append(contentsOf: octets)
        h.append(contentsOf: [UInt8](repeating: 0, count: 8))
        return h
    }

    // MARK: - Static protocol helpers

    static func packDuid(_ s: String) -> Data {
        // Same parsing as the reference: prefix = before first '-', serial = between
        // first and last '-', check = after last '-'.
        guard let d1 = s.firstIndex(of: "-"),
              let d2 = s.lastIndex(of: "-"), d1 != d2 else { return Data() }
        let prefix = String(s[s.startIndex..<d1])
        let serialStr = String(s[s.index(after: d1)..<d2])
        let check = String(s[s.index(after: d2)...])
        let serial = UInt32(serialStr.trimmingCharacters(in: .whitespaces)) ?? 0

        var out = Data(repeating: 0, count: 20)
        for (i, c) in prefix.utf8.enumerated() where i < 8 { out[i] = c }
        out[8] = UInt8((serial >> 24) & 0xff); out[9] = UInt8((serial >> 16) & 0xff)
        out[10] = UInt8((serial >> 8) & 0xff); out[11] = UInt8(serial & 0xff)
        for (i, c) in check.utf8.enumerated() where i < 6 { out[12 + i] = c }
        return out
    }

    static func crc16Xmodem(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0x0000
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : (crc << 1)
            }
        }
        return crc
    }

    static func ipv4Octets(_ ip: String) -> [UInt8]? {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : nil
    }
}

// MARK: - small Data extensions

extension Data {
    mutating func appendLE(_ v: UInt16) { append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8)]) }
    mutating func appendBE(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)]) }
    mutating func appendLE(_ v: UInt32) {
        append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }
    func u32leLE(at offset: Int) -> UInt32 {
        UInt32(self[startIndex + offset]) |
          (UInt32(self[startIndex + offset + 1]) << 8) |
          (UInt32(self[startIndex + offset + 2]) << 16) |
          (UInt32(self[startIndex + offset + 3]) << 24)
    }
}
