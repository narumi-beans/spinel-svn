import SwiftUI

struct WelcomeView: View {
    var onOpen: (String) -> Void
    @EnvironmentObject var app: AppState
    @ObservedObject private var router = WelcomeRouter.shared

    enum Choice: Hashable { case checkout, open, importProject, localRepo, existing }
    @State private var choice: Choice = .existing
    @State private var selectedProject: String?
    @State private var dialog: Choice?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("What do you want to do?")).font(.title2)
                Text(L("Check out a project from a repository, open an existing working copy, import a project into a repository or open a known project."))
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $choice) {
                    Text(L("Check out project from repository")).tag(Choice.checkout)
                    Text(L("Open existing working copy")).tag(Choice.open)
                    Text(L("Import project into repository")).tag(Choice.importProject)
                    Text(L("Set up local repository")).tag(Choice.localRepo)
                    Text(L("Open existing project(s):")).tag(Choice.existing)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                List(app.projects, selection: $selectedProject) { p in
                    HStack {
                        Image(systemName: "folder")
                        Text(p.name).bold()
                        Text("(\(abbreviate(p.path)))").foregroundStyle(.secondary)
                    }
                    .tag(p.path)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button(L("Remove from List")) { ids.forEach(app.remove(path:)) }
                } primaryAction: { ids in
                    if let p = ids.first { open(p) }
                }
                .disabled(choice != .existing)
                .opacity(choice == .existing ? 1 : 0.5)
                .overlay {
                    if app.projects.isEmpty { Text(L("No projects yet")).foregroundStyle(.secondary) }
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            .padding(20)
            Divider()
            HStack {
                Spacer()
                Button(L("Close")) { NSApp.keyWindow?.close() }
                Button(L("OK")) { proceed() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice == .existing && selectedProject == nil)
            }
            .padding(16)
        }
        .task {
            if selectedProject == nil { selectedProject = app.projects.first?.path }
            if app.projects.isEmpty { choice = .checkout }
            consumeRouter()
        }
        .onChange(of: selectedProject) { if selectedProject != nil { choice = .existing } }
        .onChange(of: router.request) { consumeRouter() }
        .sheet(item: $dialog) { d in
            switch d {
            case .checkout: CheckoutSheet { open($0) }
            case .importProject: ImportSheet { open($0) }
            case .localRepo: LocalRepoSheet { open($0) }
            default: EmptyView()
            }
        }
    }

    private func consumeRouter() {
        guard let r = router.request else { return }
        router.request = nil
        switch r {
        case .checkout: choice = .checkout
        case .open: choice = .open
        case .importProject: choice = .importProject
        case .localRepo: choice = .localRepo
        }
        proceed()
    }

    private func proceed() {
        error = nil
        switch choice {
        case .existing:
            if let p = selectedProject { open(p) }
        case .open:
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
        default:
            dialog = choice
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
                TextField(L("Repository URL"), text: $url, prompt: Text("https://svn.example.com/repo/trunk"))
                TextField(L("Revision (empty = HEAD)"), text: $revision)
                HStack {
                    TextField(L("Local directory"), text: $dir)
                    Button(L("Choose…")) { if let d = chooseDirectory(L("Choose the parent directory")) { dir = (d as NSString).appendingPathComponent(lastSegment) } }
                }
                TextField(L("User name (optional)"), text: $user)
                SecureField(L("Password (optional)"), text: $password)
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
                    TextField(L("Local directory"), text: $dir)
                    Button(L("Choose…")) { if let d = chooseDirectory(L("Choose the directory to import"), create: false) { dir = d } }
                }
                TextField(L("Repository URL"), text: $url)
                TextField(L("Commit message"), text: $message)
                Toggle(L("Turn the directory into a working copy after import"), isOn: $checkoutAfter)
                TextField(L("User name (optional)"), text: $user)
                SecureField(L("Password (optional)"), text: $password)
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
                    TextField(L("Repository directory"), text: $repoDir)
                    Button(L("Choose…")) { if let d = chooseDirectory(L("Choose the parent directory")) { repoDir = (d as NSString).appendingPathComponent("repo") } }
                }
                HStack {
                    TextField(L("Working copy directory"), text: $wcDir)
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
