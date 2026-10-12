import Foundation
import AppKit

/// Looks for a newer release on GitHub. Updating stays manual: download the new DMG and replace
/// the app. Automatic checks run at most once a day and only show something when an update exists.
@MainActor
final class UpdateChecker: ObservableObject {
    static let repository = "qokalp/elva-macos-scanner"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!

    struct Result: Identifiable {
        enum Kind { case available(version: String, page: URL), upToDate, failed }
        let id = UUID()
        let kind: Kind
    }

    @Published var result: Result?
    @Published var isChecking = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private let lastCheckKey = "LastUpdateCheck"

    func checkAutomaticallyIfDue(enabled: Bool) {
        guard enabled, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {   // nothing published yet
                if userInitiated { result = Result(kind: .upToDate) }
                return
            }
            guard status == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { throw URLError(.badServerResponse) }
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? Self.releasesPage
            if Self.isVersion(latest, newerThan: currentVersion) {
                result = Result(kind: .available(version: latest, page: page))
            } else if userInitiated {
                result = Result(kind: .upToDate)
            }
        } catch {
            if userInitiated { result = Result(kind: .failed) }
        }
    }

    /// Compares dotted version numbers ("1.10.0" > "1.9.2").
    nonisolated static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
