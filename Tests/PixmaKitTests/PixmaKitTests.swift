import XCTest
@testable import PixmaKit

final class PixmaKitTests: XCTestCase {
    func testModelLookupFromIEEE1284() {
        let id = "MFG:Canon;CMD:MultiPass 2.1,IVEC;MDL:MG7100 series;CLS:IMAGE;DES:Canon MG7100 series;SOJ:BJNP2,BJNPe;"
        let model = PixmaModel.forIdentity(id)
        XCTAssertEqual(model?.match, "MG7100")
        XCTAssertEqual(model?.supportedDPIs, [75, 150, 300, 600, 1200, 2400])
        XCTAssertEqual(IEEE1284.fields(id)["MDL"], "MG7100 series")
    }

    func testBedSizeIsA4Plus() {
        let m = PixmaModel.mg7100
        XCTAssertEqual(m.bedWidthInches, 8.5067, accuracy: 0.001)
        XCTAssertEqual(m.bedHeightInches, 11.6933, accuracy: 0.001)
    }

    func testGeometryAlignsRawWidthTo32AndKeepsCropOffset() throws {
        let s = try PixmaScanner(host: "127.0.0.1", model: .mg7100)
        let g = try s.geometry(for: PixmaScanRequest(dpi: 150, mode: .gray, x: 1.53, y: 1.1, width: 2.71, height: 3.3))
        XCTAssertEqual(g.x, 230)
        XCTAssertEqual(g.xShift, 230 % 32)
        XCTAssertEqual(g.w, 407)
        XCTAssertEqual(g.rawWidth % 32, 0)
        XCTAssertGreaterThanOrEqual(g.rawWidth, g.w + g.xShift)
        XCTAssertEqual(g.channels, 1)
    }

    func testGeometryClampsToGlass() throws {
        let s = try PixmaScanner(host: "127.0.0.1", model: .mg7100)
        let g = try s.geometry(for: PixmaScanRequest(dpi: 75, x: 8, y: 11, width: 5, height: 5))
        XCTAssertLessThanOrEqual(g.x + g.w, 638)
        XCTAssertLessThanOrEqual(g.y + g.h, 877)
    }

    func testRejectsUnsupportedResolution() throws {
        let s = try PixmaScanner(host: "127.0.0.1", model: .mg7100)
        XCTAssertThrowsError(try s.geometry(for: PixmaScanRequest(dpi: 200)))
        XCTAssertThrowsError(try s.geometry(for: PixmaScanRequest(dpi: 4800)))
    }

    func testUTF16BigEndianJobField() {
        let f = BJNPConnection.utf16BE("Mac", bytes: 8)
        XCTAssertEqual(f, [0, 0x4D, 0, 0x61, 0, 0x63, 0, 0])
    }

    func testBigEndianHelpers() {
        var b = [UInt8](repeating: 0, count: 6)
        b.putBE16(0xDB20, at: 0)
        b.putBE32(0x0102_0304, at: 2)
        XCTAssertEqual(b, [0xDB, 0x20, 1, 2, 3, 4])
        XCTAssertEqual(b.be16(at: 0), 0xDB20)
        XCTAssertEqual(b.be32(at: 2), 0x0102_0304)
    }

    func testUnknownModelGetsGenericExperimentalProfile() {
        let id = "MFG:Canon;CMD:MultiPass 2.1,IVEC;MDL:ZZ9000 series;CLS:IMAGE;"
        XCTAssertNil(PixmaModel.forIdentity(id))
        let g = PixmaModel.generic(named: "Canon ZZ9000 series")
        XCTAssertTrue(g.isGeneric)
        XCTAssertFalse(g.verified)
        XCTAssertEqual(g.supportedDPIs.max(), 1200)
        XCTAssertFalse(PixmaModel.mg7100.isGeneric)
        XCTAssertFalse(PixmaModel.known.contains { $0.isGeneric })
    }

    func testModelTableMatchesExactTokens() {
        XCTAssertGreaterThan(PixmaModel.known.count, 150)
        XCTAssertEqual(PixmaModel.forIdentity("Canon MG7100 series")?.match, "MG7100")
        XCTAssertEqual(PixmaModel.forIdentity("Canon PIXMA MG7100 Series")?.match, "MG7100")
        XCTAssertEqual(PixmaModel.forIdentity("MFG:Canon;MDL:MX920 series;")?.match, "MX920")
        XCTAssertEqual(PixmaModel.forIdentity("MFG:Canon;MDL:E400 series;")?.match, "E400")
        XCTAssertNotEqual(PixmaModel.forIdentity("MFG:Canon;MDL:E4000 series;")?.match, "E400")
        XCTAssertTrue(PixmaModel.mg7100.verified)
        XCTAssertFalse(PixmaModel.forIdentity("Canon MX920 series")!.verified)
        // Generation 3 model with interleaved high-resolution lines.
        let mp610 = PixmaModel.forIdentity("Canon MP610 series")!
        XCTAssertEqual(mp610.generation, 3)
        XCTAssertEqual(mp610.interleaveUnit, 600)
    }

    func testDeinterleaveMatchesSANEFormula() {
        // SANE reorder_pixels: linebuf[c*(n*(i%m) + i/m)] = src[c*i], m = w/n.
        let w = 12, c = 3, n = 3, m = w / n
        let src: [UInt8] = (0..<(w * c)).map { UInt8($0) }
        var expected = [UInt8](repeating: 0, count: w * c)
        for i in 0..<w { for k in 0..<c { expected[c * (n * (i % m) + i / m) + k] = src[c * i + k] } }
        var buf = [UInt8](repeating: 9, count: 5) + src      // line starts at an offset
        var scratch = [UInt8](repeating: 0, count: w * c)
        PixmaScanner.deinterleave(&buf, lineStart: 5, width: w, channels: c, subImages: n, scratch: &scratch)
        XCTAssertEqual(Array(buf[5...]), expected)
        XCTAssertEqual(Array(buf[0..<5]), [9, 9, 9, 9, 9])
    }
}
