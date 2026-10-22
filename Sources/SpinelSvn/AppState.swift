import AppKit
import SwiftUI

enum Pref {
    static func bool(_ key: String, _ def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }

    static func set(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

struct SavedProject: Codable, Hashable, Identifiable {
    var name: String
    var path: String
    var id: String { path }
}

/// Global, app-wide state: known projects, settings and Finder-service hand-off.
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var projects: [SavedProject] = [] {
        didSet { save() }
    }
    @AppStorage("commitMessageHistory") private var historyData = Data()

    /// Actions requested from the Finder services, consumed by the project window once it loads.
    var pendingActions: [String: PendingAction] = [:]
    /// Set by the first window so non-view code (services) can open project windows.
    var openProject: ((String) -> Void)?

    enum PendingAction { case update, commit }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "projects"),
           let list = try? JSONDecoder().decode([SavedProject].self, from: data) {
            projects = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(projects) {
            UserDefaults.standard.set(data, forKey: "projects")
        }
    }

    func register(path: String) {
        guard !projects.contains(where: { $0.path == path }) else { return }
        projects.append(SavedProject(name: (path as NSString).lastPathComponent, path: path))
    }

    func remove(path: String) {
        projects.removeAll { $0.path == path }
    }

    var commitHistory: [String] {
        (try? JSONDecoder().decode([String].self, from: historyData)) ?? []
    }

    func remember(message: String) {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return }
        var h = commitHistory.filter { $0 != m }
        h.insert(m, at: 0)
        historyData = (try? JSONEncoder().encode(Array(h.prefix(30)))) ?? Data()
    }

    /// Finds the working-copy root that contains `path` (walks up while `.svn` is absent).
    static func workingCopyRoot(for path: String) -> String? {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            url.deleteLastPathComponent()
        }
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".svn").path) { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }

    func handleService(paths: [String], action: PendingAction?) {
        for p in paths {
            guard let root = AppState.workingCopyRoot(for: p) else { continue }
            register(path: root)
            if let action { pendingActions[root] = action }
            openProject?(root)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Provider for the Finder services declared in Info.plist (NSServices).
final class ServiceProvider: NSObject {
    private func paths(_ pboard: NSPasteboard) -> [String] {
        (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .map(\.path)
    }

    @objc func openInSpinelSvn(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        AppState.shared.handleService(paths: paths(pboard), action: nil)
    }

    @objc func updateFromSvn(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        AppState.shared.handleService(paths: paths(pboard), action: .update)
    }

    @objc func commitToSvn(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        AppState.shared.handleService(paths: paths(pboard), action: .commit)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppState.shared.handleService(paths: urls.map(\.path), action: nil)
    }
}
