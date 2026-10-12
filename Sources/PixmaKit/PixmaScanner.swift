import Foundation

/// Drives a Canon PIXMA (generation 4/5, e.g. MG7150) flatbed over BJNP.
///
/// Command framing (inside BJNP TCP packets):
///
///     command: be16 cmd | 0[10] | be16 length | data… | checksum
///     result : be16 status | 0[6] | data… | checksum        (status 0x0606 OK, 0x1414 busy, 0x1515 failed)
///
/// The checksum byte makes the data section sum to zero (mod 256). The command set and the scan
/// sequence were reverse-engineered by the SANE project's `pixma` backend; this is an independent
/// Swift implementation of that documented protocol.
///
/// The class is synchronous and must be used from one thread at a time. Call `cancel()` from any
/// thread to stop a running scan.
public final class PixmaScanner: @unchecked Sendable {
    enum Cmd: UInt16 {
        case startSession = 0xDB20
        case gamma = 0xEE20
        case abortSession = 0xEF20
        case errorInfo = 0xFF20
        case readImage = 0xD420
        case scanParam3 = 0xD820
        case scanStart3 = 0xD920
        case status3 = 0xDA20
    }

    enum Status: UInt16 {
        case ok = 0x0606
        case busy = 0x1414
        case failed = 0x1515
    }

    private static let xmlStartJob = """
        <?xml version="1.0" encoding="utf-8" ?><cmd xmlns:ivec="http://www.canon.com/ns/cmd/2008/07/common/"><ivec:contents><ivec:operation>StartJob</ivec:operation><ivec:param_set servicetype="scan"><ivec:jobID>00000001</ivec:jobID><ivec:bidi>1</ivec:bidi></ivec:param_set></ivec:contents></cmd>
        """
    private static let xmlModeShift = """
        <?xml version="1.0" encoding="utf-8" ?><cmd xmlns:ivec="http://www.canon.com/ns/cmd/2008/07/common/" xmlns:vcn="http://www.canon.com/ns/cmd/2008/07/canon/"><ivec:contents><ivec:operation>VendorCmd</ivec:operation><ivec:param_set servicetype="scan"><ivec:jobID>00000001</ivec:jobID><vcn:ijoperation>ModeShift</vcn:ijoperation><vcn:ijmode>1</vcn:ijmode></ivec:param_set></ivec:contents></cmd>
        """
    private static let xmlEndJob = """
        <?xml version="1.0" encoding="utf-8" ?><cmd xmlns:ivec="http://www.canon.com/ns/cmd/2008/07/common/"><ivec:contents><ivec:operation>EndJob</ivec:operation><ivec:param_set servicetype="scan"><ivec:jobID>00000001</ivec:jobID></ivec:param_set></ivec:contents></cmd>
        """

    private static let imageBlockSize = 512 * 1024

    public let connection: BJNPConnection
    public private(set) var model: PixmaModel
    public private(set) var identity: String = ""

    private let cancelLock = NSLock()
    private var _cancelled = false
    private var isCancelled: Bool { cancelLock.withLock { _cancelled } }

    /// Logs protocol steps; handy for diagnostics.
    public var log: (String) -> Void = { _ in }

    public init(host: String, model: PixmaModel? = nil) throws {
        connection = try BJNPConnection(host: host)
        self.model = model ?? .generic(named: "Canon PIXMA")
    }

    /// Reads the device ID over UDP and picks the matching model profile.
    @discardableResult
    public func identify() throws -> String {
        identity = try connection.identity()
        let mdl = IEEE1284.fields(identity)["MDL"].map { "Canon \($0)" } ?? "Canon PIXMA"
        model = PixmaModel.forIdentity(identity) ?? .generic(named: mdl)
        log("Identity: \(identity)")
        return identity
    }

    public func cancel() { cancelLock.withLock { _cancelled = true } }

    // MARK: - Command plumbing

    /// Builds and sends a command, then reads the result. Returns the result data (without the
    /// 8-byte status header and without the trailing checksum byte).
    @discardableResult
    private func exec(_ cmd: Cmd, data: [UInt8] = [], resultLength: Int = 0) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 16)
        buf.putBE16(cmd.rawValue, at: 0)
        buf.putBE16(UInt16(data.count + resultLength), at: 14)
        if !data.isEmpty {
            var payload = data
            let sum = payload.dropLast().reduce(UInt8(0)) { $0 &+ $1 }
            payload[payload.count - 1] = 0 &- sum
            buf += payload
        }
        try connection.write(buf)
        let r = try connection.readBlock()
        guard r.count >= 8 else { throw PixmaError.protocolError("Short reply to 0x\(String(cmd.rawValue, radix: 16))") }
        switch Status(rawValue: r.be16(at: 0)) {
        case .ok: break
        case .busy: throw PixmaError.busy
        case .failed: throw PixmaError.cancelled
        case nil: throw PixmaError.protocolError(String(format: "Unknown status 0x%04X for command 0x%04X", r.be16(at: 0), cmd.rawValue))
        }
        guard resultLength > 0 else { return [] }
        guard r.count == 8 + resultLength else {
            throw PixmaError.protocolError("Reply length \(r.count), expected \(8 + resultLength)")
        }
        let body = Array(r[8...])
        guard body.reduce(UInt8(0), { $0 &+ $1 }) == 0 else { throw PixmaError.protocolError("Bad checksum") }
        return Array(body.dropLast())
    }

    private func xmlDialog(_ xml: String) throws {
        try connection.write(Array(xml.utf8))
        let reply = String(decoding: try connection.readBlock(), as: UTF8.self)
        log("XML reply: \(reply)")
        guard reply.contains("<ivec:response>OK</ivec:response>") else {
            let detail = reply.range(of: "<ivec:response_detail>")
                .flatMap { start in reply.range(of: "</ivec:response_detail>").map { String(reply[start.upperBound..<$0.lowerBound]) } }
            // Transient: the previous job is still closing (head parking) or the device is waking up.
            if detail == "PCScanning" || detail == "DeviceBusy" { throw PixmaError.busy }
            throw PixmaError.scannerRejected(Self.describe(detail ?? "NG"))
        }
    }

    /// Runs `body`, retrying while the scanner reports it is busy.
    private func retryWhileBusy(seconds: Int, _ body: () throws -> Void) throws {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while true {
            do { try body(); return }
            catch PixmaError.busy where Date() < deadline {
                if isCancelled { throw PixmaError.cancelled }
                log("Scanner busy, retrying…")
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    static func describe(_ detail: String) -> String {
        switch detail {
        case "DeviceBusy": return "The device is busy or still initialising."
        case "ScannerCarriageLockError": return "The scanner carriage is locked."
        case "PCScanning": return "A previous scan did not finish. Power-cycle the printer if this persists."
        case "DeviceCheckError": return "The device reported a hardware fault."
        default: return detail
        }
    }

    private func statusBits() throws -> [UInt8] {
        try exec(.status3, resultLength: 8)
    }

    private func sendGamma(_ gamma: Double) throws {
        // 1024-entry, 16-bit little-endian LUT preceded by a 4-byte descriptor.
        var data = [UInt8](repeating: 0, count: 1024 * 2 + 8)
        data[0] = 0x10
        data.putBE16(0x0804, at: 2)
        let inv = 1.0 / max(gamma, 0.1)
        for i in 0..<1024 {
            let v = UInt16(min(65535, (65535.0 * pow(Double(i) / 1023.0, inv) + 0.5)))
            data[4 + 2 * i] = UInt8(v & 0xFF)
            data[5 + 2 * i] = UInt8(v >> 8)
        }
        try exec(.gamma, data: data)
    }

    // MARK: - Geometry

    struct Geometry {
        let dpi: Int
        let x: Int, y: Int          // origin in pixels
        let w: Int, h: Int          // output size in pixels
        let xShift: Int             // x mod 32, re-added to the raw line and cropped off again
        let rawWidth: Int           // w + xShift rounded up to a multiple of 32
        let channels: Int
        var rawLineBytes: Int { rawWidth * channels }
    }

    func geometry(for r: PixmaScanRequest) throws -> Geometry {
        guard model.supportedDPIs.contains(r.dpi) else {
            throw PixmaError.unsupported("\(r.dpi) dpi is not supported. Choose one of \(model.supportedDPIs.map(String.init).joined(separator: ", ")).")
        }
        let d = Double(r.dpi)
        let maxW = model.bedWidth75 * r.dpi / 75
        let maxH = model.bedHeight75 * r.dpi / 75
        var x = max(0, Int((r.x * d).rounded()))
        var y = max(0, Int((r.y * d).rounded()))
        var w = Int((r.width * d).rounded())
        var h = Int((r.height * d).rounded())
        // Minimum 16×16 pixels; keep the area inside the glass.
        w = min(max(w, 16), maxW); h = min(max(h, 16), maxH)
        x = min(x, maxW - w); y = min(y, maxH - h)
        let xShift = x % 32
        let rawWidth = (w + xShift + 31) / 32 * 32
        return Geometry(dpi: r.dpi, x: x, y: y, w: w, h: h, xShift: xShift, rawWidth: rawWidth,
                        channels: r.mode == .color ? 3 : 1)
    }

    private func sendScanParameters(_ g: Geometry, calibrate: Bool) throws {
        var data = [UInt8](repeating: 0, count: 0x38)
        data[0x00] = 0x01                       // flatbed
        data[0x01] = 0x01
        data[0x02] = 0x01
        data[0x05] = calibrate ? 0x01 : 0x00
        data.putBE16(UInt16(g.dpi) | 0x8000, at: 0x08)
        data.putBE16(UInt16(g.dpi) | 0x8000, at: 0x0A)
        data.putBE32(UInt32(g.x - g.xShift), at: 0x0C)
        data.putBE32(UInt32(g.y), at: 0x10)
        data.putBE32(UInt32(g.rawWidth), at: 0x14)
        data.putBE32(UInt32(g.h), at: 0x18)
        data[0x1C] = g.channels == 3 ? 0x08 : 0x04
        data[0x1D] = UInt8(8 * g.channels)      // bits per pixel
        data[0x1F] = 0x01
        data[0x20] = 0xFF
        data[0x21] = 0x81
        data[0x23] = 0x02
        data[0x24] = 0x01
        if model.match == "MG5300" {
            // The MG5300 series expects these ASCII digits (values copied from real traffic).
            data[0x26] = 0x32; data[0x27] = 0x31; data[0x28] = 0x34; data[0x29] = 0x35
        }
        data[0x30] = 0x01
        try exec(.scanParam3, data: data)
    }

    // MARK: - Scan

    /// Performs a complete scan. Blocks until finished; reports progress on the calling thread.
    public func scan(_ request: PixmaScanRequest,
                     progress: (PixmaScanPhase) -> Void = { _ in }) throws -> PixmaRawImage {
        cancelLock.withLock { _cancelled = false }
        let g = try geometry(for: request)
        log("Scan \(g.w)×\(g.h) px @ \(g.dpi) dpi, origin (\(g.x), \(g.y)), raw width \(g.rawWidth), \(g.channels) ch")

        progress(.connecting)
        try connection.openTCP(jobTitle: "Elva Scanner")
        var sessionStarted = false
        var xmlStarted = false
        defer {
            progress(.finishing)
            if sessionStarted { _ = try? exec(.abortSession) }
            if xmlStarted { try? xmlDialog(Self.xmlEndJob) }
            connection.closeTCP()
        }

        if model.generation >= 4 {
            try retryWhileBusy(seconds: 30) { try xmlDialog(Self.xmlStartJob) }
            xmlStarted = true
            try xmlDialog(Self.xmlModeShift)
        }

        // Start session; the scanner answers "busy" while the head is still parking.
        try retryWhileBusy(seconds: 15) { try exec(.startSession) }
        sessionStarted = true

        for _ in 0..<3 { try sendGamma(request.gamma) }
        try sendScanParameters(g, calibrate: request.calibrate)
        try exec(.scanStart3)

        // Wait for lamp warm-up / calibration.
        progress(.warmingUp)
        var ready = false
        for _ in 0..<120 {
            if isCancelled { throw PixmaError.cancelled }
            let s = try statusBits()
            if s[0] & 0x03 != 0 { ready = true; break }
            Thread.sleep(forTimeInterval: 1)
        }
        guard ready else { throw PixmaError.timeout("Scanner did not become ready") }
        Thread.sleep(forTimeInterval: 1)

        // Receive image data, crop each raw line and stream it to disk.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("elva-\(UUID().uuidString).raw")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }

        let outLineBytes = g.w * g.channels
        let cropOffset = g.xShift * g.channels
        // Older models send high-resolution lines as interleaved sub-images.
        let subImages = model.interleaveUnit > 0 ? g.dpi / model.interleaveUnit : 0
        var lineScratch = [UInt8](repeating: 0, count: subImages > 1 ? g.rawLineBytes : 0)
        var pending = [UInt8]()
        pending.reserveCapacity(Self.imageBlockSize + g.rawLineBytes)
        var lines = 0
        var lastBlock: UInt8 = 0
        progress(.scanning(fraction: 0))

        while lastBlock & 0x28 != 0x28 && lines < g.h {
            if isCancelled { throw PixmaError.cancelled }
            let (info, chunk) = try readImageBlock(small: lastBlock & 0x20 != 0)
            lastBlock = info & 0x38
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            pending += chunk
            let whole = pending.count / g.rawLineBytes
            if whole > 0 {
                var outBuf = [UInt8]()
                let take = min(whole, g.h - lines)
                outBuf.reserveCapacity(take * outLineBytes)
                for i in 0..<take {
                    if subImages > 1 {
                        let lineStart = i * g.rawLineBytes
                        Self.deinterleave(&pending, lineStart: lineStart, width: g.rawWidth, channels: g.channels,
                                          subImages: subImages, scratch: &lineScratch)
                    }
                    let start = i * g.rawLineBytes + cropOffset
                    outBuf += pending[start..<start + outLineBytes]
                }
                try out.write(contentsOf: outBuf)
                lines += take
                pending.removeFirst(whole * g.rawLineBytes)
                progress(.scanning(fraction: Double(lines) / Double(g.h)))
            }
        }
        log("Received \(lines) of \(g.h) lines")
        guard lines > 0 else { throw PixmaError.protocolError("No image data received") }
        return PixmaRawImage(fileURL: url, width: g.w, height: lines, channels: g.channels, dpi: g.dpi)
    }

    /// Restores pixel order for a line sent as `subImages` interleaved sub-images: pixel i of the
    /// raw line belongs at position subImages·(i mod m) + i / m, where m = width / subImages.
    static func deinterleave(_ buf: inout [UInt8], lineStart: Int, width: Int, channels c: Int,
                             subImages n: Int, scratch: inout [UInt8]) {
        let m = width / n
        guard m > 0 else { return }
        for i in 0..<width {
            let dst = c * (n * (i % m) + i / m)
            let src = lineStart + c * i
            guard dst + c <= scratch.count else { continue }
            for k in 0..<c { scratch[dst + k] = buf[src + k] }
        }
        buf.replaceSubrange(lineStart..<lineStart + width * c, with: scratch[0..<width * c])
    }

    /// Requests one block of image data. Returns the block-info flags and the pixel bytes.
    private func readImageBlock(small: Bool) throws -> (UInt8, [UInt8]) {
        var cmd = [UInt8](repeating: 0, count: 16)
        cmd.putBE16(Cmd.readImage.rawValue, at: 0)
        cmd.putBE32(UInt32(small ? 32 + 8 : Self.imageBlockSize + 8), at: 12)
        try connection.write(cmd)

        var reply = try connection.readBlock()
        guard reply.count >= 8 else { throw PixmaError.protocolError("Short image header") }
        switch Status(rawValue: reply.be16(at: 0)) {
        case .ok: break
        case .busy: throw PixmaError.busy
        case .failed:
            _ = try? exec(.errorInfo, resultLength: 16)
            throw PixmaError.cancelled
        case nil: throw PixmaError.protocolError(String(format: "Image status 0x%04X", reply.be16(at: 0)))
        }
        while reply.count < 16 { reply += try connection.readBlock() }
        let info = reply[8]
        let length = Int(reply.be32(at: 12))
        // Large blocks may arrive split across several BJNP responses.
        while reply.count < 16 + length {
            if isCancelled { throw PixmaError.cancelled }
            reply += try connection.readBlock()
        }
        return (info, Array(reply[16..<16 + length]))
    }
}
