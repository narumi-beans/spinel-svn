import SwiftUI

struct WelcomeView: View {
    var onOpen: (String) -> Void
    @EnvironmentObject var app: AppState
    @ObservedObject private var router = WelcomeRouter.shared

    enum Choice: Hashable { case checkout, open, importProject, localRepo }
    @State private var selectedProject: String?
    @State private var dialog: Choice?
    @State private var error: String?

    var body: some View {
        HStack(spacing: 0) {
            brandPanel
                .frame(width: 300)
            recentProjects
                .frame(minWidth: 380)
        }
        .frame(minWidth: 700, minHeight: 440)
        .ignoresSafeArea()
        .background(WindowAccessor { window in
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbar?.isVisible = false
            window.isMovableByWindowBackground = true
            window.styleMask.insert(.fullSizeContentView)
            if window.frame.width > 900 {
                window.setContentSize(NSSize(width: 760, height: 460))
                window.center()
            }
        })
        .onAppear { WelcomeRouter.shared.openWelcomeWindows += 1 }
        .onDisappear { WelcomeRouter.shared.openWelcomeWindows -= 1 }
        .task {
            if selectedProject == nil { selectedProject = app.projects.first?.path }
            consumeRouter()
        }
        .onChange(of: router.request) { consumeRouter() }
        .sheet(item: $dialog) { d in
            switch d {
            case .checkout: CheckoutSheet { open($0) }
            case .importProject: ImportSheet { open($0) }
            case .localRepo: LocalRepoSheet { open($0) }
            case .open: EmptyView()
            }
        }
    }

    // The one branded surface: the icon's garnet-to-plum backdrop, the gem, and the four ways in.
    private var brandPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 28)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            Text("SpinelSvn")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 14)
            Text(L("Subversion client for Mac"))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
            Text(String(format: L("Version %@"), Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 2)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 4) {
                action(L("Check Out…"), "arrow.down.doc") { dialog = .checkout }
                action(L("Open Working Copy…"), "folder") { openWorkingCopy() }
                action(L("Import Into Repository…"), "square.and.arrow.up") { dialog = .importProject }
                action(L("Set Up Local Repository…"), "externaldrive.badge.plus") { dialog = .localRepo }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.white).padding(.top, 8)
            }
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Theme.garnet, Theme.plum], startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .dark)
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(WelcomeActionStyle())
    }

    private var recentProjects: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Recent Projects"))
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 38)
                .padding(.bottom, 8)
            List(app.projects, selection: $selectedProject) { p in
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.spinel.gradient)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.body.weight(.medium))
                        Text(abbreviate(p.path)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(.vertical, 3)
                .tag(p.path)
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: String.self) { ids in
                Button(L("Remove from List")) { ids.forEach(app.remove(path:)) }
            } primaryAction: { ids in
                if let p = ids.first { open(p) }
            }
            .overlay {
                if app.projects.isEmpty {
                    ContentUnavailableView(L("No projects yet"), systemImage: "tray",
                                           description: Text(L("Check out a project or open a working copy to get started.")))
                }
            }
            HStack {
                Spacer()
                Button(L("Close")) { NSApp.keyWindow?.close() }
                Button(L("Open")) { if let p = selectedProject { open(p) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedProject == nil)
            }
            .padding(14)
        }
        .background(.background)
    }

    private func consumeRouter() {
        guard let r = router.request else { return }
        router.request = nil
        switch r {
        case .checkout: dialog = .checkout
        case .open: openWorkingCopy()
        case .importProject: dialog = .importProject
        case .localRepo: dialog = .localRepo
        }
    }

    private func openWorkingCopy() {
        error = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = L("Choose the root directory of a working copy")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let root = AppState.workingCopyRoot(for: url.path) {
            open(root)
        } else {
            error = L("The selected directory is not a Subversion working copy.")
        }
    }

    private func open(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            error = String(format: L("Directory not found: %@"), path)
            return
        }
        onOpen(path)
    }

    private func abbreviate(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

extension WelcomeView.Choice: Identifiable {
    var id: Self { self }
}

/// Quiet translucent rows on the brand panel that brighten on hover and press.
private struct WelcomeActionStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(configuration.isPressed ? 0.22 : hovering ? 0.12 : 0)))
            .onHover { hovering = $0 }
    }
}

// MARK: - Checkout / import / local repository

private struct RunState {
    var running = false
    var log = ""
}

private func chooseDirectory(_ message: String, create: Bool = true) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = create
    panel.message = message
    return panel.runModal() == .OK ? panel.url?.path : nil
}

struct CheckoutSheet: View {
    var onDone: (String) -> Void
    @State private var url = ""
    @State private var revision = ""
    @State private var dir = ""
    @State private var user = ""
    @State private var password = ""
    @State private var state = RunState()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Check Out")).font(.title3.bold())
            Form {
                TextField(L("Repository URL"), text: $url, prompt: Text("https://svn.example.com/repo/trunk")).accessibilityLabel(L("Repository URL"))
                TextField(L("Revision (empty = HEAD)"), text: $revision).accessibilityLabel(L("Revision (empty = HEAD)"))
                HStack {
                    TextField(L("Local directory"), text: $dir).accessibilityLabel(L("Local directory"))
                    Button(L("Choose…")) { if let d = chooseDirectory(L("Choose the parent directory")) { dir = (d as NSString).appendingPathComponent(lastSegment) } }
                }
                TextField(L("User name (optional)"), text: $user).accessibilityLabel(L("User name (optional)"))
                SecureField(L("Password (optional)"), text: $password).accessibilityLabel(L("Password (optional)"))
            }
            if !state.log.isEmpty {
                ScrollView { Text(state.log).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(height: 120)
            }
            HStack {
                if state.running { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Check Out")) { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(url.isEmpty || dir.isEmpty || state.running)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private var lastSegment: String {
        let s = url.split(separator: "/").last.map(String.init) ?? "checkout"
        return s.removingPercentEncoding ?? s
    }

    private func run() async {
        state.running = true
        var args = ["checkout", url, dir]
        if !revision.isEmpty { args += ["-r", revision] }
        state.log = SVN.commandLine(args) + "\n"
        let creds = user.isEmpty ? nil : SVNCredentials(username: user, password: password)
        let r = await SVN.run(args, cwd: nil, credentials: creds)
        state.running = false
        state.log += r.text.lines.suffix(30).joined(separator: "\n") + "\n" + r.stderr
        if r.ok {
            if let creds { CredentialStore.shared.save(creds, repository: url) }
            AppState.shared.register(path: dir)
            dismiss()
            onDone(dir)
        }
    }
}

struct ImportSheet: View {
    var onDone: (String) -> Void
    @State private var dir = ""
    @State private var url = ""
    @State private var message = "Initial import"
    @State private var checkoutAfter = true
    @State private var user = ""
    @State private var password = ""
    @State private var state = RunState()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Import Into Repository")).font(.title3.bold())
            Form {
                HStack {
                    TextField(L("Local directory"), text: $dir).accessibilityLabel(L("Local directory"))
                    Button(L("Choose…")) { if let d = chooseDirectory(L("Choose the directory to import"), create: false) { dir = d } }
                }
                TextField(L("Repository URL"), text: $url).accessibilityLabel(L("Repository URL"))
                TextField(L("Commit message"), text: $message).accessibilityLabel(L("Commit message"))
                Toggle(L("Turn the directory into a working copy after import"), isOn: $checkoutAfter)
                TextField(L("User name (optional)"), text: $user).accessibilityLabel(L("User name (optional)"))
                SecureField(L("Password (optional)"), text: $password).accessibilityLabel(L("Password (optional)"))
            }
            if !state.log.isEmpty {
                ScrollView { Text(state.log).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 100)
            }
            HStack {
                if state.running { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Import")) { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(dir.isEmpty || url.isEmpty || state.running)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private func run() async {
        state.running = true
        let creds = user.isEmpty ? nil : SVNCredentials(username: user, password: password)
        let r = await SVN.run(["import", dir, url, "-m", message], cwd: nil, credentials: creds)
        state.log = r.text + r.stderr
        guard r.ok else { state.running = false; return }
        if let creds { CredentialStore.shared.save(creds, repository: url) }
        if checkoutAfter {
            // Check out over the imported directory so it becomes a working copy in place.
            let co = await SVN.run(["checkout", "--force", url, dir], cwd: nil, credentials: creds)
            state.log += co.text + co.stderr
            state.running = false
            if co.ok {
                AppState.shared.register(path: dir)
                dismiss()
                onDone(dir)
            }
        } else {
            state.running = false
            dismiss()
        }
    }
}

struct LocalRepoSheet: View {
    var onDone: (String) -> Void
    @State private var repoDir = ""
    @State private var wcDir = ""
    @State private var standardLayout = true
    @State private var state = RunState()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Set Up Local Repository")).font(.title3.bold())
            Text(L("Creates a file-based repository with svnadmin and checks out a working copy."))
                .foregroundStyle(.secondary)
            Form {
                HStack {
                    TextField(L("Repository directory"), text: $repoDir).accessibilityLabel(L("Repository directory"))
                    Button(L("Choose…")) { if let d = chooseDirectory(L("Choose the parent directory")) { repoDir = (d as NSString).appendingPathComponent("repo") } }
                }
                HStack {
                    TextField(L("Working copy directory"), text: $wcDir).accessibilityLabel(L("Working copy directory"))
                    Button(L("Choose…")) { if let d = chooseDirectory(L("Choose the parent directory")) { wcDir = (d as NSString).appendingPathComponent("work") } }
                }
                Toggle(L("Create trunk/branches/tags layout"), isOn: $standardLayout)
            }
            if !state.log.isEmpty {
                ScrollView { Text(state.log).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 100)
            }
            HStack {
                if state.running { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Create")) { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(repoDir.isEmpty || wcDir.isEmpty || state.running)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private func run() async {
        state.running = true
        defer { state.running = false }
        let c = await SVN.run(["create", repoDir], cwd: nil, tool: SVN.svnadmin)
        state.log = c.stderr
        guard c.ok else { return }
        let absPath = (repoDir as NSString).standardizingPath
        let repoURL = "file://" + (absPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? absPath)
        var checkoutURL = repoURL
        if standardLayout {
            let m = await SVN.run(["mkdir", "-m", "Create standard layout",
                                   repoURL + "/trunk", repoURL + "/branches", repoURL + "/tags"], cwd: nil)
            state.log += m.text + m.stderr
            guard m.ok else { return }
            checkoutURL += "/trunk"
        }
        let co = await SVN.run(["checkout", checkoutURL, wcDir], cwd: nil)
        state.log += co.text + co.stderr
        if co.ok {
            AppState.shared.register(path: wcDir)
            dismiss()
            onDone(wcDir)
        }
    }
}
