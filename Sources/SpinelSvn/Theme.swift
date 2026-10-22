import SwiftUI

/// App palette, taken from the app icon.
enum Theme {
    /// The brand colours appear only on the welcome window; everywhere else controls follow
    /// the system accent colour.
    static let spinel = Color(red: 0xD9 / 255, green: 0x24 / 255, blue: 0x3A / 255)
    static let garnet = Color(red: 0x7A / 255, green: 0x10 / 255, blue: 0x22 / 255)
    static let plum = Color(red: 0x1B / 255, green: 0x14 / 255, blue: 0x24 / 255)
}

extension ItemState {
    /// Semantic system colours so states read the same in light and dark mode.
    var tint: Color {
        switch self {
        case .modified, .merged: return .orange
        case .added: return .green
        case .replaced: return .teal
        case .deleted, .missing, .obstructed, .incomplete: return .red
        case .conflicted: return .purple
        case .external: return .indigo
        case .unversioned, .ignored, .normal, .none: return .secondary
        }
    }
}

/// Compact state label used in lists, headers and the commit sheet.
struct StatePill: View {
    let entry: StatusEntry

    var body: some View {
        let state = entry.effectiveState
        Text(entry.localStateLabel)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(state == .normal ? Color.secondary : state.tint)
            .background(Capsule().fill(state.tint.opacity(state == .normal ? 0.08 : 0.15)))
    }
}

/// File-type symbol for list rows.
func fileSymbol(_ entry: StatusEntry) -> String {
    if entry.isDirectory { return "folder.fill" }
    switch (entry.name as NSString).pathExtension.lowercased() {
    case "swift", "rb", "py", "js", "ts", "php", "c", "h", "m", "java", "kt", "go", "rs", "css", "scss", "erb", "html", "sh":
        return "chevron.left.forwardslash.chevron.right"
    case "png", "jpg", "jpeg", "gif", "svg", "webp", "icns": return "photo"
    case "md", "txt", "rtf": return "doc.text"
    case "json", "yml", "yaml", "xml", "plist", "toml", "ini", "conf": return "gearshape"
    default: return "doc"
    }
}
