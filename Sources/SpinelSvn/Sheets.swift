import SwiftUI

/// Standard dialog chrome: title, description, content, Cancel/OK.
struct DialogFrame<Content: View>: View {
    var title: String
    var message: String?
    var okTitle: String = L("OK")
    var okDisabled = false
    var destructive = false
    var width: CGFloat = 480
    var onOK: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            if let message { Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            content
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .keyboardShortcut(destructive ? .defaultAction : .cancelAction)
                // Return must not confirm a destructive action; it cancels instead.
                Button(okTitle, role: destructive ? .destructive : nil) {
                    onOK()
                    dismiss()
                }
                .keyboardShortcut(destructive ? nil : .defaultAction)
                .disabled(okDisabled)
            }
        }
        .padding(20)
        .frame(width: width)
    }
}

struct ProjectSheetView: View {
    @ObservedObject var wc: WorkingCopyModel
    let sheet: ProjectSheet

    var body: some View {
        switch sheet {
        case let .commit(paths, picked): CommitSheet(wc: wc, initialPaths: Set(paths), pickedFiles: picked)
        case let .input(r): InputSheet(request: r)
        case let .confirm(r): ConfirmSheet(request: r)
        case let .properties(p): PropertiesSheet(wc: wc, path: p)
        case .updateToRevision: UpdateToRevisionSheet(wc: wc)
        case .switchTo: SwitchSheet(wc: wc)
        case .relocate: RelocateSheet(wc: wc)
        case .merge: MergeSheet(wc: wc)
        case let .tagBranch(isTag): TagBranchSheet(wc: wc, isTag: isTag)
        case .credentials: CredentialsSheet(wc: wc)
        }
    }
}

// MARK: - Commit

struct CommitSheet: View {
    @ObservedObject var wc: WorkingCopyModel
    @State private var checked: Set<String>
    @State private var message = ""
    @State private var keepChangelists = false
    @State private var showUnversioned = true
    @State private var focused: String?
    @FocusState private var messageFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(wc: WorkingCopyModel, initialPaths: Set<String>, pickedFiles: Bool) {
        self.wc = wc
        // Unversioned files are offered but not pre-checked unless the user picked them.
        _checked = State(initialValue: initialPaths.filter { pickedFiles || wc.entries[$0]?.item != .unversioned })
    }

    private var candidates: [StatusEntry] {
        wc.committable.filter { showUnversioned || $0.item != .unversioned }
    }

    /// Only files the user can see in the list are counted and committed.
    private var toCommit: [String] {
        candidates.map(\.path).filter(checked.contains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Commit")).font(.title3.bold())
            Text(wc.info?.url ?? wc.rootPath).font(.caption).foregroundStyle(.secondary)

            HStack {
                Text(L("Files to commit")).font(.headline)
                Spacer()
                Toggle(L("Show unversioned files"), isOn: $showUnversioned).controlSize(.small)
                Button(L("All")) { checked = Set(candidates.map(\.path)) }.controlSize(.small)
                Button(L("None")) { checked.removeAll() }.controlSize(.small)
            }
            List(candidates, selection: $focused) { e in
                HStack {
                    Toggle("", isOn: Binding(
                        get: { checked.contains(e.path) },
                        set: { if $0 { checked.insert(e.path) } else { checked.remove(e.path) } }))
                        .labelsHidden()
                    Image(systemName: e.effectiveState.symbol).foregroundStyle(e.effectiveState.color)
                    Text(e.path.isEmpty ? "." : e.path)
                    Spacer()
                    Text(e.localStateLabel).foregroundStyle(.secondary).font(.caption)
                    if let cl = e.changelist { Text("[\(cl)]").font(.caption).foregroundStyle(.purple) }
                }
                .tag(e.path)
            }
            .frame(minHeight: 160)

            HStack {
                Text(L("Commit message")).font(.headline)
                Spacer()
                Menu(L("Recent messages")) {
                    ForEach(AppState.shared.commitHistory, id: \.self) { m in
                        Button(m.lines.first ?? m) { message = m }
                    }
                }
                .fixedSize()
                .disabled(AppState.shared.commitHistory.isEmpty)
            }
            TextEditor(text: $message)
                .font(.system(.body, design: .monospaced))
                .focused($messageFocused)
                .frame(minHeight: 110)
                .border(Color.secondary.opacity(0.3))
            Toggle(L("Keep change sets after commit"), isOn: $keepChangelists)

            HStack {
                Text(String(format: L("%d file(s) selected"), toCommit.count)).foregroundStyle(.secondary)
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Commit")) {
                    wc.runCommit(paths: toCommit, message: message, keepChangelists: keepChangelists)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(toCommit.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720, height: 600)
        .onAppear { messageFocused = true }
    }
}

// MARK: - Simple dialogs

struct InputSheet: View {
    let request: InputRequest
    @State private var text: String

    init(request: InputRequest) {
        self.request = request
        _text = State(initialValue: request.initial)
    }

    var body: some View {
        DialogFrame(title: request.title, message: request.message, onOK: { request.action(text) }) {
            TextField("", text: $text).textFieldStyle(.roundedBorder)
        }
    }
}

struct ConfirmSheet: View {
    let request: ConfirmRequest
    @State private var flags: [Bool]

    init(request: ConfirmRequest) {
        self.request = request
        _flags = State(initialValue: request.options.map { _ in false })
    }

    var body: some View {
        DialogFrame(title: request.title, message: request.message, destructive: request.destructive,
                    onOK: { request.action(flags) }) {
            ForEach(request.options.indices, id: \.self) { i in
                Toggle(request.options[i], isOn: $flags[i])
            }
        }
    }
}

struct UpdateToRevisionSheet: View {
    @ObservedObject var wc: WorkingCopyModel
    @State private var revision = "HEAD"
    @State private var depth = ""

    var body: some View {
        DialogFrame(title: L("Update to Revision"), message: L("Update the selection to a specific revision."),
                    okTitle: L("Update"), onOK: { wc.update(revision: revision, depth: depth.isEmpty ? nil : depth) }) {
            Form {
                TextField(L("Revision"), text: $revision).accessibilityLabel(L("Revision"))
                Picker(L("Depth"), selection: $depth) {
                    Text(L("Working copy")).tag("")
                    Text("infinity").tag("infinity")
                    Text("immediates").tag("immediates")
                    Text("files").tag("files")
                    Text("empty").tag("empty")
                    Text("exclude").tag("exclude")
                }
            }
        }
    }
}

struct SwitchSheet: View {
    @ObservedObject var wc: WorkingCopyModel
    @State private var url = ""
    @State private var revision = ""

    var body: some View {
        DialogFrame(title: L("Switch"), message: L("Switch the working copy to another URL (branch or tag)."),
                    okTitle: L("Switch"), okDisabled: url.isEmpty, width: 560, onOK: { wc.switchTo(url: url, revision: revision) }) {
            Form {
                TextField(L("URL"), text: $url).accessibilityLabel(L("URL"))
                TextField(L("Revision (empty = HEAD)"), text: $revision).accessibilityLabel(L("Revision (empty = HEAD)"))
            }
        }
        .onAppear { url = wc.info?.url ?? "" }
    }
}

struct RelocateSheet: View {
    @ObservedObject var wc: WorkingCopyModel
    @State private var url = ""

    var body: some View {
        DialogFrame(title: L("Relocate"), message: L("Use when the repository server address has changed."),
                    okTitle: L("Relocate"), okDisabled: url.isEmpty, width: 560, onOK: { wc.relocate(to: url) }) {
            Form {
                LabeledContent(L("Current root"), value: wc.info?.repositoryRoot ?? "")
                TextField(L("New root URL"), text: $url).accessibilityLabel(L("New root URL"))
            }
        }
        .onAppear { url = wc.info?.repositoryRoot ?? "" }
    }
}

struct MergeSheet: View {
    @ObservedObject var wc: WorkingCopyModel
    @State private var twoSources = false
    @State private var source = ""
    @State private var source2 = ""
    @State private var range = ""
    @State private var dryRun = false

    var body: some View {
        DialogFrame(title: L("Merge"), message: String(format: L("Merge into: %@"), wc.absolute(wc.selectedDir ?? "")),
                    okTitle: L("Merge"), okDisabled: source.isEmpty || (twoSources && source2.isEmpty), width: 600, onOK: {
                        if twoSources { wc.mergeTwoSources(from: source, to: source2) }
                        else { wc.merge(source: source, range: range, dryRun: dryRun) }
                    }) {
            Form {
                Picker("", selection: $twoSources) {
                    Text(L("Merge revisions")).tag(false)
                    Text(L("Merge from 2 Sources")).tag(true)
                }
                .pickerStyle(.segmented)
                TextField(twoSources ? L("From URL@REV") : L("Source URL"), text: $source).accessibilityLabel(twoSources ? L("From URL@REV") : L("Source URL"))
                if twoSources {
                    TextField(L("To URL@REV"), text: $source2).accessibilityLabel(L("To URL@REV"))
                } else {
                    TextField(L("Revision range (e.g. 10:20, empty = all eligible)"), text: $range).accessibilityLabel(L("Revision range (e.g. 10:20, empty = all eligible)"))
                    Toggle(L("Dry run (only show what would change)"), isOn: $dryRun)
                }
            }
        }
        .onAppear {
            if let i = wc.info { source = i.repositoryRoot + "/trunk" }
        }
    }
}

struct TagBranchSheet: View {
    @ObservedObject var wc: WorkingCopyModel
    let isTag: Bool
    @State private var name = ""
    @State private var message = ""
    @State private var fromWC = false

    var body: some View {
        DialogFrame(title: isTag ? L("Add Tag") : L("Add Branch"),
                    message: String(format: L("Creates %@/%@ by copying %@."),
                                    wc.tagBranchBase(isTag: isTag),
                                    name.isEmpty ? "…" : name,
                                    fromWC ? L("the working copy") : (wc.info?.url ?? "")),
                    okTitle: L("Create"), okDisabled: name.isEmpty, width: 600, onOK: {
                        wc.createTagOrBranch(isTag: isTag, name: name,
                                             message: message.isEmpty ? (isTag ? "Tag " : "Branch ") + name : message,
                                             fromWorkingCopy: fromWC)
                    }) {
            Form {
                TextField(L("Name"), text: $name).accessibilityLabel(L("Name"))
                TextField(L("Commit message"), text: $message).accessibilityLabel(L("Commit message"))
                Toggle(L("Copy from the working copy (includes local modifications and mixed revisions)"), isOn: $fromWC)
            }
        }
    }
}

struct CredentialsSheet: View {
    @ObservedObject var wc: WorkingCopyModel
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        DialogFrame(title: L("Authentication Required"),
                    message: String(format: L("Enter your credentials for %@."), wc.info?.repositoryRoot ?? L("the repository")),
                    okTitle: L("Log In"), okDisabled: user.isEmpty, onOK: {
                        wc.retryWithCredentials(SVNCredentials(username: user, password: password))
                    }) {
            Form {
                TextField(L("User name"), text: $user).accessibilityLabel(L("User name"))
                SecureField(L("Password"), text: $password).accessibilityLabel(L("Password"))
            }
        }
        .onAppear { user = wc.credentials?.username ?? NSUserName() }
    }
}

// MARK: - Properties

struct PropertiesSheet: View {
    @ObservedObject var wc: WorkingCopyModel
    let path: String
    @State private var props: [PropEntry] = []
    @State private var selected: String?
    @State private var name = ""
    @State private var value = ""
    @State private var recursive = false
    @Environment(\.dismiss) private var dismiss

    private let common = ["svn:ignore", "svn:global-ignores", "svn:externals", "svn:eol-style", "svn:mime-type",
                          "svn:keywords", "svn:executable", "svn:needs-lock", "bugtraq:url", "bugtraq:message"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Edit Properties")).font(.title3.bold())
            Text(path.isEmpty ? wc.rootPath : path).font(.caption).foregroundStyle(.secondary)
            HSplitView {
                List(props, selection: $selected) { p in
                    VStack(alignment: .leading) {
                        Text(p.name).bold()
                        Text(p.value.lines.first ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(p.name)
                }
                .frame(minWidth: 200)
                VStack(alignment: .leading) {
                    HStack {
                        TextField(L("Property name"), text: $name).accessibilityLabel(L("Property name"))
                        Menu("") {
                            ForEach(common, id: \.self) { n in Button(n) { name = n; value = props.first { $0.name == n }?.value ?? "" } }
                        }
                        .fixedSize()
                    }
                    TextEditor(text: $value)
                        .font(.system(.body, design: .monospaced))
                        .border(Color.secondary.opacity(0.3))
                    Toggle(L("Apply recursively"), isOn: $recursive)
                    HStack {
                        Button(L("Set")) {
                            wc.setProperty(name, value: value, on: [path], recursive: recursive) { Task { await load() } }
                        }
                        .disabled(name.isEmpty)
                        Button(L("Delete")) {
                            wc.setProperty(name, value: nil, on: [path], recursive: recursive) { Task { await load() } }
                        }
                        .disabled(name.isEmpty)
                    }
                }
                .padding(.leading, 8)
                .frame(minWidth: 300)
            }
            HStack {
                Spacer()
                Button(L("Close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 460)
        .task { await load() }
        .onChange(of: selected) { _, n in
            if let p = props.first(where: { $0.name == n }) {
                name = p.name
                value = p.value
            }
        }
    }

    private func load() async {
        let r = await SVN.run(["proplist", "-v", "--xml", wc.absolute(path)], cwd: wc.root, credentials: wc.credentials)
        props = SVNParse.props(r.stdout)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("svnPath") private var svnPath = ""
    @AppStorage("appLanguage") private var language = "system"

    var body: some View {
        Form {
            Section(L("Subversion")) {
                TextField(L("svn executable"), text: $svnPath, prompt: Text(SVN.executable)).accessibilityLabel(L("svn executable"))
                Text(L("Leave empty to detect automatically (Homebrew, /usr/local, /usr/bin)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Language")) {
                Picker(L("Language"), selection: $language) {
                    Text(L("System")).tag("system")
                    Text("日本語").tag("ja")
                    Text("English").tag("en")
                }
                Text(L("The language change applies after restarting the app."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 300)
    }
}
