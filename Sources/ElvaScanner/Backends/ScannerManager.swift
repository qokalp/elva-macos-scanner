import Foundation
import ImageCaptureCore
import PixmaKit

/// Keeps the list of available scanners: Canon PIXMA devices found on the network (native driver),
/// manually added IP addresses, and Image Capture devices (AirScan/eSCL and installed drivers —
/// HP, Brother, Epson, newer Canon models, …).
@MainActor
final class ScannerManager: NSObject, ObservableObject, ICDeviceBrowserDelegate {
    @Published private(set) var scanners: [any ScannerBackend] = []
    @Published private(set) var isSearching = false
    /// True once the first network search has completed.
    @Published private(set) var didFinishInitialSearch = false

    private let browser = ICDeviceBrowser()
    private var icaBackends: [ObjectIdentifier: ICABackend] = [:]
    private var pixmaBackends: [String: PixmaBackend] = [:]   // keyed by host

    static let manualHostsKey = "ManualScannerHosts"

    var manualHosts: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.manualHostsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.manualHostsKey) }
    }

    override init() {
        super.init()
        browser.delegate = self
        let mask = ICDeviceTypeMask.scanner.rawValue
            | ICDeviceLocationTypeMask.local.rawValue
            | ICDeviceLocationTypeMask.shared.rawValue
            | ICDeviceLocationTypeMask.bonjour.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .scanner
        for host in manualHosts { addPixma(host: host, name: "Canon scanner (\(host))") }
    }

    func start() {
        browser.start()
        Task { await refresh() }
    }

    func refresh() async {
        guard !isSearching else { return }
        isSearching = true
        defer { isSearching = false; didFinishInitialSearch = true }
        let discovery = ScannerDiscovery()
        async let canon = discovery.discover(timeout: 3)
        async let airScan = discovery.airScanHosts(timeout: 3)
        let (found, airScanHosts) = await (canon, airScan)
        for s in found {
            // A Canon we have no profile for but that offers AirScan is better served by macOS's own
            // driverless scanning (listed through Image Capture), so don't add a native entry for it.
            if PixmaModel.forIdentity(s.name) == nil && airScanHosts.contains(s.host) { continue }
            addPixma(host: s.host, name: s.name)
        }
    }

    /// Adds a scanner by hostname/IP after checking that it answers BJNP. Returns its ID.
    @discardableResult
    func addManual(host: String) async throws -> String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        let id = try await Task.detached { () throws -> String in
            let c = try BJNPConnection(host: trimmed, timeout: 3)
            return try c.identity()
        }.value
        let mdl = IEEE1284.fields(id)["MDL"] ?? "scanner"
        if !manualHosts.contains(trimmed) { manualHosts.append(trimmed) }
        addPixma(host: trimmed, name: "Canon \(mdl)")
        return pixmaBackends[trimmed]!.id
    }

    func remove(_ backend: any ScannerBackend) {
        if let p = backend as? PixmaBackend {
            pixmaBackends[p.host] = nil
            manualHosts.removeAll { $0 == p.host }
        }
        scanners.removeAll { $0.id == backend.id }
    }

    private func addPixma(host: String, name: String) {
        guard pixmaBackends[host] == nil else { return }
        let b = PixmaBackend(host: host, name: name)
        pixmaBackends[host] = b
        scanners.append(b)
    }

    // MARK: ICDeviceBrowserDelegate

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        MainActor.assumeIsolated {
            let b = ICABackend(device: scanner)
            icaBackends[ObjectIdentifier(scanner)] = b
            scanners.append(b)
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        MainActor.assumeIsolated {
            if let b = icaBackends.removeValue(forKey: ObjectIdentifier(device)) {
                scanners.removeAll { $0.id == b.id }
            }
        }
    }
}
