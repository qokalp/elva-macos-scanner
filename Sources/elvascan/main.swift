import Foundation
import ImageIO
import UniformTypeIdentifiers
import PixmaKit

let usage = """
elvascan – Elva Scanner command-line tool for Canon PIXMA network scanners (BJNP)

  elvascan discover          (Bonjour + subnet sweep)
  elvascan sweep             (subnet sweep only)
  elvascan info <host>
  elvascan scan <host> [--dpi 300] [--gray] [--area x,y,w,h (inches)] [--gamma 2.2]
                     [--no-calibrate] [--verbose] [-o scan.png]

"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

switch command {
case "sweep":
    print(ScannerDiscovery.sweepSubnets(timeout: 2))
case "discover":
    let sem = DispatchSemaphore(value: 0)
    Task {
        let found = await ScannerDiscovery().discover(timeout: 3)
        if found.isEmpty { print("No Canon network scanners found.") }
        for s in found { print("\(s.name)\t\(s.host)\t(\(s.source))") }
        sem.signal()
    }
    sem.wait()

case "info":
    guard let host = args.first else { fail(usage) }
    do {
        let conn = try BJNPConnection(host: host, timeout: 3)
        print("Address:  \(conn.resolvedAddress)")
        print("MAC:      \(try conn.discover())")
        let id = try conn.identity()
        print("IEEE1284: \(id)")
        if let m = PixmaModel.forIdentity(id) {
            print("Model:    \(m.name) – max \(m.maxDPI) dpi, bed \(String(format: "%.2f×%.2f", m.bedWidthInches, m.bedHeightInches)) in\(m.verified ? "" : " (untested)")")
        } else {
            print("Model:    not in the supported list")
        }
    } catch { fail(error.localizedDescription) }

case "scan":
    guard let host = args.first else { fail(usage) }
    var request = PixmaScanRequest(dpi: 300)
    var output = "scan.png"
    var verbose = false
    var areaGiven = false
    var i = 1
    func next() -> String { i += 1; guard i < args.count else { fail(usage) }; return args[i] }
    while i < args.count {
        switch args[i] {
        case "--dpi": request.dpi = Int(next()) ?? 300
        case "--gray": request.mode = .gray
        case "--gamma": request.gamma = Double(next()) ?? 2.2
        case "--no-calibrate": request.calibrate = false
        case "--verbose", "-v": verbose = true
        case "-o": output = next()
        case "--area":
            let v = next().split(separator: ",").compactMap { Double($0) }
            guard v.count == 4 else { fail("--area needs x,y,w,h") }
            (request.x, request.y, request.width, request.height) = (v[0], v[1], v[2], v[3])
            areaGiven = true
        default: fail("Unknown option \(args[i])\n\n\(usage)")
        }
        i += 1
    }
    do {
        let scanner = try PixmaScanner(host: host)
        if verbose { scanner.log = { print("  · \($0)") } }
        try scanner.identify()
        if !areaGiven {
            request.width = scanner.model.bedWidthInches
            request.height = scanner.model.bedHeightInches
        }
        signal(SIGINT) { _ in exit(130) }
        let start = Date()
        var lastPrinted = -1
        let raw = try scanner.scan(request) { phase in
            switch phase {
            case .connecting: print("Connecting…")
            case .warmingUp: print("Warming up…")
            case .scanning(let f):
                let pct = Int(f * 100)
                if pct / 10 != lastPrinted / 10 { print("Scanning \(pct)%"); lastPrinted = pct }
            case .finishing: print("Finishing…")
            }
        }
        defer { raw.removeFile() }
        let image = try raw.makeCGImage()
        let url = URL(fileURLWithPath: output)
        let type: UTType = UTType(filenameExtension: url.pathExtension) ?? .png
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            fail("Cannot write \(output)")
        }
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: raw.dpi, kCGImagePropertyDPIHeight: raw.dpi]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { fail("Cannot write \(output)") }
        print(String(format: "Saved %@ (%d×%d px, %d dpi) in %.1f s", output, raw.width, raw.height, raw.dpi, Date().timeIntervalSince(start)))
    } catch { fail(error.localizedDescription) }

default:
    print(usage)
}
