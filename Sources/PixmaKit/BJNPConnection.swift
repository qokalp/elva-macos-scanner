import Foundation
import Darwin

/// Canon BJNP network transport (UDP + TCP on port 8612).
///
/// BJNP is Canon's proprietary protocol for PIXMA printers/scanners on a network. Every packet
/// starts with a 16-byte header:
///
///     "BJNP" | devType(1) | cmd(1) | 0(2) | seq(be16) | session(be16) | payloadLen(be32)
///
/// Control messages (discover, identity, job details, close) travel over UDP. Scanner commands
/// are wrapped in TCP "send" packets (0x21) and responses are pulled with TCP "request" packets
/// (0x20). The scanner never answers a request when it has nothing to send, so callers must only
/// ask for data they know is coming.
public final class BJNPConnection {
    public static let scanPort: UInt16 = 8612

    enum Command: UInt8 {
        case discover = 0x01
        case jobDetails = 0x10
        case close = 0x11
        case tcpRequest = 0x20
        case tcpSend = 0x21
        case getID = 0x30
    }

    static let headerSize = 16
    private static let devTypeScanner: UInt8 = 0x02

    public let host: String
    public let port: UInt16
    /// Timeout for individual network operations, in seconds.
    public var timeout: TimeInterval

    private var address: sockaddr_storage
    private var addressLength: socklen_t
    private var tcpSocket: Int32 = -1
    private var serial: UInt16 = 0xFFFF   // incremented before every command; first one is 0
    private var sessionID: UInt16 = 0
    private var lastCommand: UInt8 = 0

    public init(host: String, port: UInt16 = BJNPConnection.scanPort, timeout: TimeInterval = 20) throws {
        self.host = host
        self.port = port
        self.timeout = timeout
        (address, addressLength) = try Self.resolve(host: host, port: port)
    }

    deinit { closeTCP(sendClose: false) }

    public var isOpen: Bool { tcpSocket >= 0 }

    // MARK: - Address resolution

    static func resolve(host: String, port: UInt16) throws -> (sockaddr_storage, socklen_t) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &result)
        guard rc == 0, let first = result else {
            throw PixmaError.network("Cannot resolve \(host): \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(result) }
        // Prefer IPv4: some PIXMA firmwares only answer BJNP on IPv4.
        var chosen = first
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cursor {
            if ai.pointee.ai_family == AF_INET { chosen = ai; break }
            cursor = ai.pointee.ai_next
        }
        var storage = sockaddr_storage()
        memcpy(&storage, chosen.pointee.ai_addr, Int(chosen.pointee.ai_addrlen))
        return (storage, chosen.pointee.ai_addrlen)
    }

    public var resolvedAddress: String {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var addr = address
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, addressLength, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return rc == 0 ? String(cString: buf) : host
    }

    // MARK: - Header

    private func makeHeader(_ cmd: Command, payloadLength: Int) -> [UInt8] {
        serial &+= 1
        lastCommand = cmd.rawValue
        var h = [UInt8](repeating: 0, count: Self.headerSize)
        h[0] = 0x42; h[1] = 0x4A; h[2] = 0x4E; h[3] = 0x50   // "BJNP"
        h[4] = Self.devTypeScanner
        h[5] = cmd.rawValue
        h.putBE16(serial, at: 8)
        h.putBE16(sessionID, at: 10)
        h.putBE32(UInt32(payloadLength), at: 12)
        return h
    }

    // MARK: - UDP

    /// Sends a UDP command and returns the full response datagram.
    func udpCommand(_ cmd: Command, payload: [UInt8] = [], retries: Int = 3) throws -> [UInt8] {
        let packet = makeHeader(cmd, payloadLength: payload.count) + payload
        let expectedSerial = serial
        let fd = socket(Int32(address.ss_family), SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw PixmaError.network("UDP socket: \(errnoString())") }
        defer { close(fd) }
        var addr = address
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, addressLength) }
        }
        guard rc == 0 else { throw PixmaError.network("UDP connect to \(host): \(errnoString())") }
        setReceiveTimeout(fd, seconds: 2)

        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<retries {
            let sent = packet.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            guard sent == packet.count else { continue }
            // Skip late answers to earlier commands (wrong sequence number).
            while true {
                let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if n < Self.headerSize { break }
                let response = Array(buffer[0..<n])
                if response.be16(at: 8) == expectedSerial { return response }
            }
        }
        throw PixmaError.timeout("No UDP response from \(host) to BJNP command 0x\(String(cmd.rawValue, radix: 16))")
    }

    /// BJNP discover: returns the MAC address the scanner reports.
    public func discover() throws -> String {
        let r = try udpCommand(.discover)
        guard r.count >= Self.headerSize + 12 else { throw PixmaError.protocolError("Short discover response") }
        let macLen = Int(r[Self.headerSize + 4])
        let start = Self.headerSize + 6
        guard macLen > 0, r.count >= start + macLen else { return "" }
        return r[start..<start + macLen].map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// BJNP identity: the IEEE-1284 device ID, e.g. `MFG:Canon;CMD:MultiPass 2.1,IVEC;MDL:MG7100 series;...`
    public func identity() throws -> String {
        let r = try udpCommand(.getID)
        guard r.count > Self.headerSize + 2 else { throw PixmaError.protocolError("Short identity response") }
        let idLen = Int(r.be16(at: Self.headerSize))
        let start = Self.headerSize + 2
        let end = min(r.count, start + max(0, idLen - 2))
        return String(decoding: r[start..<end], as: UTF8.self)
    }

    /// Sends the job-owner details. The scanner answers with the session ID used for TCP traffic,
    /// and shows the host name on its panel while the scan job runs.
    ///
    /// Header bytes 6–7 carry a status: 0 = accepted. 0x85 0x02 means a scan session is still
    /// open (e.g. left behind by an interrupted job); while that is the case the scanner keeps its
    /// TCP port closed. A BJNP close releases it, so we close and retry once.
    func sendJobDetails(hostname: String, user: String, title: String) throws {
        var payload = [UInt8](repeating: 0, count: 8)
        payload += Self.utf16BE(hostname, bytes: 64)
        payload += Self.utf16BE(user, bytes: 64)
        payload += Self.utf16BE(title, bytes: 256)
        var r = try udpCommand(.jobDetails, payload: payload)
        if r.be16(at: 6) != 0 {
            _ = try? udpCommand(.close, retries: 1)
            Thread.sleep(forTimeInterval: 0.5)
            r = try udpCommand(.jobDetails, payload: payload)
        }
        let status = r.be16(at: 6)
        guard status == 0 else {
            throw PixmaError.scannerRejected(String(format: "the scanner is reserved by another job (BJNP status 0x%04X). Wait for it to finish, or power-cycle the printer.", status))
        }
        sessionID = r.be16(at: 10)
    }

    static func utf16BE(_ s: String, bytes: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bytes)
        // Last character slot stays zero as a terminator.
        for (i, scalar) in s.unicodeScalars.prefix(bytes / 2 - 1).enumerated() {
            let v = scalar.isASCII ? UInt8(scalar.value) : UInt8(ascii: "?")
            out[2 * i + 1] = v
        }
        return out
    }

    // MARK: - TCP session

    public func openTCP(jobTitle: String = "Elva Scanner") throws {
        guard tcpSocket < 0 else { return }
        let hostName = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "Mac"
        try sendJobDetails(hostname: hostName, user: NSUserName(), title: jobTitle)

        var lastError = ""
        for _ in 0..<20 {   // the scanner may refuse briefly right after the previous session
            let fd = socket(Int32(address.ss_family), SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { throw PixmaError.network("TCP socket: \(errnoString())") }
            var one: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setReceiveTimeout(fd, seconds: timeout)
            setSendTimeout(fd, seconds: timeout)
            var addr = address
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, addressLength) }
            }
            if rc == 0 { tcpSocket = fd; return }
            lastError = errnoString()
            close(fd)
            usleep(100_000)
        }
        throw PixmaError.network("Cannot connect to \(host):\(port) – \(lastError)")
    }

    public func closeTCP(sendClose: Bool = true) {
        guard tcpSocket >= 0 else { return }
        if sendClose { _ = try? udpCommand(.close, retries: 1) }
        close(tcpSocket)
        tcpSocket = -1
    }

    /// Sends one scanner command over TCP and checks the scanner's byte-count confirmation.
    public func write(_ data: [UInt8]) throws {
        guard tcpSocket >= 0 else { throw PixmaError.network("Not connected") }
        let packet = makeHeader(.tcpSend, payloadLength: data.count) + data
        try sendAll(packet)
        let payloadLength = try receiveHeader()
        guard payloadLength == 4 else {
            throw PixmaError.protocolError("Unexpected write confirmation length \(payloadLength)")
        }
        let confirm = try receiveExactly(4)
        let confirmed = Int(confirm.be32(at: 0))
        guard confirmed == data.count else {
            throw PixmaError.protocolError("Scanner confirmed \(confirmed) of \(data.count) bytes")
        }
    }

    /// Asks the scanner for its next block of response data and returns all of it.
    public func readBlock() throws -> [UInt8] {
        guard tcpSocket >= 0 else { throw PixmaError.network("Not connected") }
        try sendAll(makeHeader(.tcpRequest, payloadLength: 0))
        let payloadLength = try receiveHeader()
        return try receiveExactly(payloadLength)
    }

    private func receiveHeader() throws -> Int {
        let h = try receiveExactly(Self.headerSize)
        guard h[0] == 0x42, h[1] == 0x4A, h[2] == 0x4E, h[3] == 0x50 else {
            throw PixmaError.protocolError("Bad BJNP header")
        }
        guard h[5] == lastCommand else {
            throw PixmaError.protocolError("Response to command \(h[5]) while waiting for \(lastCommand)")
        }
        guard h.be16(at: 8) == serial else {
            throw PixmaError.protocolError("Response sequence \(h.be16(at: 8)) ≠ \(serial)")
        }
        return Int(h.be32(at: 12))
    }

    private func sendAll(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { send(tcpSocket, $0.baseAddress! + offset, $0.count - offset, 0) }
            if n < 0 {
                if errno == EINTR { continue }
                throw PixmaError.network("Send failed: \(errnoString())")
            }
            offset += n
        }
    }

    private func receiveExactly(_ count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = out.withUnsafeMutableBytes { recv(tcpSocket, $0.baseAddress! + got, count - got, 0) }
            if n == 0 { throw PixmaError.network("Scanner closed the connection") }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw PixmaError.timeout("Scanner did not respond within \(Int(timeout)) s")
                }
                throw PixmaError.network("Receive failed: \(errnoString())")
            }
            got += n
        }
        return out
    }

    private func setReceiveTimeout(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func setSendTimeout(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}

func errnoString() -> String { String(cString: strerror(errno)) }

extension Array where Element == UInt8 {
    mutating func putBE16(_ v: UInt16, at i: Int) {
        self[i] = UInt8(v >> 8); self[i + 1] = UInt8(v & 0xFF)
    }
    mutating func putBE32(_ v: UInt32, at i: Int) {
        self[i] = UInt8(v >> 24); self[i + 1] = UInt8((v >> 16) & 0xFF)
        self[i + 2] = UInt8((v >> 8) & 0xFF); self[i + 3] = UInt8(v & 0xFF)
    }
    func be16(at i: Int) -> UInt16 { UInt16(self[i]) << 8 | UInt16(self[i + 1]) }
    func be32(at i: Int) -> UInt32 {
        UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}
