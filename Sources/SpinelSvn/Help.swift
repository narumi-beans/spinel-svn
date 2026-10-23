import SwiftUI

// MARK: - Content model

struct HelpTopic: Identifiable, Hashable {
    let id: String
    let symbol: String
    let title: String
    let blocks: [HelpBlock]

    /// Plain text used by the help search.
    var searchableText: String {
        ([title] + blocks.map(\.text)).joined(separator: "\n").lowercased()
    }
}

enum HelpBlock: Hashable {
    case text(String)
    case heading(String)
    case steps([String])
    case keys([KeyRow])
    case note(String)

    var text: String {
        switch self {
        case let .text(s), let .heading(s), let .note(s): return s
        case let .steps(items): return items.joined(separator: "\n")
        case let .keys(rows): return rows.map { $0.keys + " " + $0.action }.joined(separator: "\n")
        }
    }
}

struct KeyRow: Hashable {
    let keys: String
    let action: String
}

/// Help is written as whole topics per language rather than string by string.
enum HelpContent {
    static var topics: [HelpTopic] { Localization.language == "ja" ? japanese : english }

    static let japanese: [HelpTopic] = [
        HelpTopic(id: "start", symbol: "sparkles", title: "はじめに", blocks: [
            .text("SpinelSvn は Subversion（SVN）の作業コピーを扱う Mac 用のクライアントです。操作は内部で svn コマンドを実行して行います。"),
            .heading("必要なもの"),
            .text("svn コマンドラインクライアントが必要です。Homebrew を使っている場合は、ターミナルで brew install subversion を実行してください。"),
            .heading("プロジェクトを開く"),
            .steps([
                "起動すると表示されるようこそ画面で、左側のボタンから始め方を選びます。",
                "「チェックアウト…」はリポジトリの URL から作業コピーを作ります。",
                "「作業コピーを開く…」は、すでに手元にある作業コピーのフォルダを選びます。",
                "「リポジトリへインポート…」は手元のフォルダをリポジトリに登録します。",
                "「ローカルリポジトリを作成…」は、このMac の中にリポジトリと作業コピーを作ります。",
                "一度開いたプロジェクトは右側の「最近のプロジェクト」に並びます。ダブルクリックか「開く」で開きます。右クリックで一覧から外せます。",
            ]),
        ]),
        HelpTopic(id: "window", symbol: "rectangle.split.3x1", title: "メイン画面", blocks: [
            .heading("サイドバー"),
            .text("「ローカルの変更」は作業コピー全体の変更だけを、「すべてのファイル」は変更のないファイルも含めて表示します。右の数字はコミットできる変更の数です。"),
            .text("「フォルダ」ではフォルダごとに表示します。⌘クリックや ⇧クリックで複数のフォルダを選ぶと、まとめて表示されます。オレンジの点は、その中に変更があることを示します。"),
            .heading("ファイル一覧"),
            .text("状態は色付きのラベルで表示されます（変更・追加・削除・競合・未バージョン管理など）。列の見出しを右クリックすると、表示する列を選べます。ツールバーの検索欄でファイル名を絞り込めます。"),
            .text("未バージョン管理・無視・変更のないファイルを表示するかどうかは「表示」メニューで切り替えます。"),
            .heading("差分ビューの位置"),
            .text("差分ビューはファイル一覧の右か下に置けます。「表示」メニューの「差分ビューの位置」、または差分の右上にある表示オプションのメニューで切り替えます。"),
            .heading("インスペクタ"),
            .text("ツールバー右端のボタンで、最近のコミットとアクティビティ（SpinelSvn が実行した svn コマンドとその結果）を表示するパネルを開閉します。"),
            .heading("ツールバー"),
            .text("ツールバーを右クリックするか「編集」メニューの「ツールバーをカスタマイズ…」で、ボタンの追加・削除・並べ替えができます。"),
        ]),
        HelpTopic(id: "diff", symbol: "rectangle.split.2x1", title: "変更を確認する", blocks: [
            .text("ファイル一覧でファイルを1つ選ぶと、差分ビューにベース（最後に更新した時点）と作業コピーの違いが表示されます。"),
            .text("差分ビュー右上のボタンで、ユニファイド表示と左右に並べる表示を切り替えます。表示オプションでは、コンパクト表示、空白の無視、改行コードの無視を切り替えられます。改行コード CR は ␍ として表示されます。"),
            .text("変更のあるファイルをダブルクリックすると、別ウインドウで大きく比較できます。「照会」メニューからは HEAD や前のリビジョンとの比較、注釈（行ごとの最終変更者）も開けます。"),
        ]),
        HelpTopic(id: "commit", symbol: "arrow.up.circle", title: "コミットする", blocks: [
            .heading("コミットの対象"),
            .steps([
                "ファイル一覧でファイルを選んでいる場合は、そのファイルだけが対象です。フォルダを選んでいれば、その中の変更も含まれます。",
                "ファイルを選ばず、サイドバーでフォルダを選んでいる場合は、そのフォルダ以下の変更が対象です。",
                "何も選んでいない場合は、作業コピー全体の変更が対象です。",
            ]),
            .text("コミット画面には対象の変更だけが並びます。チェックを外したファイルはコミットされません。未バージョン管理のファイルは、自分で選んだ場合だけ最初からチェックが付きます。"),
            .text("メッセージを書いて「コミット」を押すか ⌘Return でコミットします。「最近のメッセージ」から過去のメッセージを再利用できます。新しく作ったフォルダは中身ごと追加されます。"),
            .note("「SpinelSvn で非表示」にしたファイルは、コミット画面にも出ず、コミットされません。"),
        ]),
        HelpTopic(id: "update", symbol: "arrow.down.circle", title: "更新・スイッチ・マージ", blocks: [
            .text("「更新」（⌘U）でリポジトリの最新の状態を取り込みます。ボタン横の矢印からリビジョンを指定した更新やスイッチもできます。"),
            .text("「変更操作」メニューには、スイッチ（別のブランチやタグへの切り替え）、リロケート（サーバーのアドレス変更）、マージ（リビジョン範囲、2つのソース、ドライラン）、パッチの適用があります。パッチの作成は「照会」メニューにあります。"),
        ]),
        HelpTopic(id: "conflict", symbol: "exclamationmark.triangle", title: "競合を解決する", blocks: [
            .text("更新で他の人の変更とぶつかると、ファイルの状態が「競合」になります。そのファイルをダブルクリックするか、ツールバーの「競合ソルバー」を押します。"),
            .steps([
                "競合しない変更は自動で採用されます。",
                "競合ごとに、自分・相手・自分→相手の順・相手→自分の順・ベースのどれを採用するか選びます。",
                "下の「結果」は直接編集もできます。",
                "「保存して解決済みにする」（⌘S）で保存し、解決済みにします。ファイルの改行コードは元のまま保たれます。",
            ]),
            .note("ツリー競合とプロパティ競合は、ファイル一覧の右クリックメニューの「解決済みにする…」で処理します。"),
        ]),
        HelpTopic(id: "history", symbol: "clock.arrow.circlepath", title: "履歴を見る", blocks: [
            .text("「ログ」（⌘L）で、選んだファイルやフォルダの履歴を開きます。左の一覧でリビジョンを選ぶと、メッセージと変更されたパスが表示され、パスを選ぶとその差分が表示されます。検索欄で、メッセージ・作成者・パス・リビジョンを絞り込めます。"),
            .text("「ログキャッシュを使用」がオンのときは、リポジトリの履歴を手元に保存し、次からは新しい分だけを取得します。キャッシュは「プロジェクト」メニューの「ログキャッシュを管理…」で削除できます。"),
            .text("「リビジョングラフ」（⌥⌘G）は、trunk・ブランチ・タグの関係を図で表示します。ノードを選ぶと詳細が表示されます。インスペクタの最近のコミットをダブルクリックすると、そのリビジョンのログが開きます。"),
        ]),
        HelpTopic(id: "review", symbol: "checklist", title: "レビュー", blocks: [
            .text("ツールバーの切り替え、または ⌥⌘2 でレビュー画面に切り替えます（⌥⌘1 でメイン画面に戻ります）。"),
            .steps([
                "左の一覧から変更を1つずつ選び、右の差分を確認します。",
                "⌥Return で「レビュー済みにして次へ」、⌥↑ / ⌥↓ で前後のファイルに移動します。",
                "メッセージを書いて「レビュー済みの○個のファイルをコミット」を押すと、レビュー済みのものだけがコミットされます。",
            ]),
            .note("レビュー済みにした後でファイルが変更されると、次の再読み込みで印が外れます。"),
        ]),
        HelpTopic(id: "hidden", symbol: "eye.slash", title: "ファイルを非表示にする", blocks: [
            .text("プロジェクトごとに、SpinelSvn に表示しないファイルやフォルダを設定できます。設定は SpinelSvn の中だけに保存され、リポジトリには何も書き込みません（svn:ignore とは別の機能です）。"),
            .text("非表示にしたファイルは、ファイル一覧・フォルダ・変更の数・コミット画面・レビューに出なくなり、コミットもされません。"),
            .heading("設定のしかた"),
            .steps([
                "ファイルやフォルダを右クリックし「SpinelSvn で非表示にする」を選びます。",
                "まとめて設定するときは「プロジェクト」メニューの「非表示のファイル…」を開き、1行に1つパターンを書きます。",
            ]),
            .heading("パターンの書き方"),
            .steps([
                "*.log … どの階層でも、名前が一致するファイルやフォルダ。",
                "build/ … どの階層でも、その名前のフォルダと中身。",
                "/app/tmp/ や app/tmp/*.txt … 作業コピーのルートからのパス。",
                "# で始まる行はコメントです。",
            ]),
            .note("フォルダ全体を更新したり元に戻したりすると、svn はフォルダ単位で処理するため、非表示のファイルも対象になります。"),
        ]),
        HelpTopic(id: "files", symbol: "doc.on.doc", title: "ファイル操作", blocks: [
            .text("ファイル一覧の右クリックメニューか「変更操作」メニューから操作します。"),
            .steps([
                "追加 … 未バージョン管理のファイルをバージョン管理に加えます。",
                "除去… … バージョン管理から外します。未バージョン管理のファイルはゴミ箱に移ります。",
                "元に戻す… … ローカルの変更を取り消します。確認画面で Return を押すとキャンセルになります。",
                "無視… … svn:ignore に登録します（リポジトリに記録されます）。",
                "物理削除… … ファイルをゴミ箱に移します。",
                "名前を変更・移動・コピー … 履歴を保ったまま svn で操作します。",
            ]),
            .text("変更セット、ロック、プロパティの編集もそれぞれのメニューにあります。"),
        ]),
        HelpTopic(id: "branches", symbol: "arrow.triangle.branch", title: "ブランチとタグ", blocks: [
            .text("「タグ+ブランチ」メニューの「タグを作成…」「ブランチを作成…」で作ります。作成先はプロジェクトの構成から自動で決まり、たとえば proj/trunk の作業コピーなら proj/tags や proj/branches に作られます。作成先は画面で確認できます。"),
        ]),
        HelpTopic(id: "settings", symbol: "gearshape", title: "認証と設定", blocks: [
            .text("サーバーが認証を求めると、ユーザー名とパスワードを入力する画面が出ます。入力した内容はリポジトリごとに記憶され、ログやグラフなどの別ウインドウでも使われます。パスワードはコマンドラインに含めず、安全な方法で svn に渡します。"),
            .text("設定（⌘,）では、svn コマンドの場所と表示言語を変更できます。言語の変更はアプリの再起動後に反映されます。"),
        ]),
        HelpTopic(id: "keys", symbol: "keyboard", title: "キーボードショートカット", blocks: [
            .keys([
                KeyRow(keys: "⌘N", action: "新規プロジェクトウインドウ"),
                KeyRow(keys: "⌘O", action: "プロジェクトを開く/管理"),
                KeyRow(keys: "⌘R", action: "再読み込み"),
                KeyRow(keys: "⌥⌘R", action: "リモート状態を更新"),
                KeyRow(keys: "⌘U", action: "更新"),
                KeyRow(keys: "⌘K", action: "コミット"),
                KeyRow(keys: "⌘Return", action: "コミット画面でコミット"),
                KeyRow(keys: "⌥⌘+", action: "追加"),
                KeyRow(keys: "⇧⌘R", action: "名前を変更"),
                KeyRow(keys: "⌥⌘Z", action: "元に戻す"),
                KeyRow(keys: "⌘D", action: "変更を表示"),
                KeyRow(keys: "⌘L", action: "ログ"),
                KeyRow(keys: "⌥⌘G", action: "リビジョングラフ"),
                KeyRow(keys: "⌥⌘1 / ⌥⌘2", action: "メイン / レビュー画面"),
                KeyRow(keys: "⌥↑ / ⌥↓", action: "レビューで前 / 次のファイル"),
                KeyRow(keys: "⌥Return", action: "レビュー済みにして次へ"),
                KeyRow(keys: "⌘S", action: "競合ソルバーで保存して解決済みにする"),
                KeyRow(keys: "⌘?", action: "このヘルプ"),
            ]),
        ]),
        HelpTopic(id: "trouble", symbol: "questionmark.circle", title: "困ったとき", blocks: [
            .steps([
                "svn が見つからない … 設定（⌘,）で svn コマンドの場所を指定してください。",
                "認証エラーになる … 認証画面でユーザー名とパスワードを入れ直してください。",
                "作業コピーがロックされている … 「変更操作」メニューの「クリーンアップ…」を実行してください。",
                "ファイルが一覧に出ない … 「表示」メニューの設定、検索欄、「非表示のファイル…」の設定を確認してください。",
                "何が起きたか知りたい … インスペクタの「アクティビティ」に、実行した svn コマンドと結果が残っています。",
            ]),
        ]),
    ]

    static let english: [HelpTopic] = [
        HelpTopic(id: "start", symbol: "sparkles", title: "Getting Started", blocks: [
            .text("SpinelSvn is a Mac client for Subversion (SVN) working copies. It runs the svn command-line client for every operation."),
            .heading("Requirements"),
            .text("Install the svn command-line client, for example with Homebrew: brew install subversion."),
            .heading("Opening a project"),
            .steps([
                "The welcome window lists the ways to start on the left.",
                "Check Out… creates a working copy from a repository URL.",
                "Open Working Copy… opens a working copy that is already on this Mac.",
                "Import Into Repository… adds a local folder to a repository.",
                "Set Up Local Repository… creates a repository and a working copy on this Mac.",
                "Projects you open appear under Recent Projects. Double-click or choose Open; right-click to remove one from the list.",
            ]),
        ]),
        HelpTopic(id: "window", symbol: "rectangle.split.3x1", title: "Main Window", blocks: [
            .heading("Sidebar"),
            .text("Local Changes lists only changed files; All Files includes unchanged ones. The number is how many changes can be committed."),
            .text("Under Folders, choose a folder to list its files. ⌘-click or ⇧-click to select several folders at once. An orange dot means the folder contains changes."),
            .heading("File list"),
            .text("Each file shows its state as a coloured label. Right-click the column headers to choose columns, and use the search field in the toolbar to filter by name. The View menu shows or hides unversioned, ignored and unchanged files."),
            .heading("Changes view position"),
            .text("The changes view can sit to the right of or below the file list. Choose View ▸ Changes View Position, or use the display options menu at the top right of the changes view."),
            .heading("Inspector"),
            .text("The button at the right end of the toolbar shows recent commits and the activity log (the svn commands SpinelSvn ran and their output)."),
            .heading("Toolbar"),
            .text("Right-click the toolbar or choose Edit ▸ Configure Toolbar… to add, remove or rearrange buttons."),
        ]),
        HelpTopic(id: "diff", symbol: "rectangle.split.2x1", title: "Reviewing Changes", blocks: [
            .text("Select one file to see the difference between its base (last update) and your working copy."),
            .text("Switch between unified and side-by-side layouts at the top right. Display options turn on compact view and ignore whitespace or line-ending changes; carriage returns show as ␍."),
            .text("Double-click a changed file to compare it in its own window. The Query menu also compares with HEAD or the previous revision and opens Annotate."),
        ]),
        HelpTopic(id: "commit", symbol: "arrow.up.circle", title: "Committing", blocks: [
            .heading("What gets committed"),
            .steps([
                "If files are selected in the file list, only those files (a selected folder brings its contents).",
                "Otherwise, if folders are selected in the sidebar, the changes inside those folders.",
                "Otherwise, every change in the working copy.",
            ]),
            .text("The commit sheet lists only those changes; unchecked files are not committed. Unversioned files start checked only when you picked them yourself."),
            .text("Write a message and choose Commit or press ⌘Return. Recent messages can be reused. New folders are added with their contents."),
            .note("Files hidden from SpinelSvn never appear in the commit sheet and are never committed."),
        ]),
        HelpTopic(id: "update", symbol: "arrow.down.circle", title: "Update, Switch and Merge", blocks: [
            .text("Update (⌘U) brings in the latest changes. The arrow next to the button updates to a specific revision or switches."),
            .text("The Modify menu has Switch, Relocate (when the server address changed), Merge (revision ranges, two sources, dry run) and Apply Patch. Create Patch is in the Query menu."),
        ]),
        HelpTopic(id: "conflict", symbol: "exclamationmark.triangle", title: "Resolving Conflicts", blocks: [
            .text("When an update collides with someone else's change, the file is marked Conflict. Double-click it or choose Conflict Solver in the toolbar."),
            .steps([
                "Changes that don't collide are taken automatically.",
                "For each conflict choose mine, theirs, both in either order, or the base.",
                "You can edit the result directly.",
                "Save and Mark Resolved (⌘S) writes the file and marks it resolved, keeping its line endings.",
            ]),
            .note("Tree and property conflicts are resolved with Mark Resolved… in the file list's context menu."),
        ]),
        HelpTopic(id: "history", symbol: "clock.arrow.circlepath", title: "History", blocks: [
            .text("Log (⌘L) shows the history of the selected file or folder. Pick a revision to see its message and changed paths, and a path to see its diff. Search filters by message, author, path or revision."),
            .text("With Use log cache on, SpinelSvn keeps the repository history locally and fetches only new revisions. Delete caches with Project ▸ Manage Log Caches…."),
            .text("Revision Graph (⌥⌘G) draws trunk, branches and tags. Double-click a recent commit in the inspector to open the log at that revision."),
        ]),
        HelpTopic(id: "review", symbol: "checklist", title: "Review", blocks: [
            .text("Switch to the review perspective with the toolbar control or ⌥⌘2 (⌥⌘1 returns to the main window)."),
            .steps([
                "Go through the changes one by one on the left and read the diff on the right.",
                "⌥Return marks a file reviewed and moves on; ⌥↑ / ⌥↓ move between files.",
                "Write a message and commit the reviewed files only.",
            ]),
            .note("If a reviewed file changes again, its mark is cleared on the next refresh."),
        ]),
        HelpTopic(id: "hidden", symbol: "eye.slash", title: "Hiding Files", blocks: [
            .text("Each project can hide files and folders from SpinelSvn. The setting stays in SpinelSvn; nothing is written to the repository (unlike svn:ignore)."),
            .text("Hidden files disappear from the file list, folders, change counts, the commit sheet and review, and are never committed."),
            .heading("How to hide files"),
            .steps([
                "Right-click a file or folder and choose Hide from SpinelSvn.",
                "To edit several patterns, choose Project ▸ Hidden Files… and write one pattern per line.",
            ]),
            .heading("Patterns"),
            .steps([
                "*.log hides matching names at any depth.",
                "build/ hides every folder with that name, and its contents.",
                "/app/tmp/ or app/tmp/*.txt match a path from the working-copy root.",
                "Lines starting with # are comments.",
            ]),
            .note("Updating or reverting a whole folder still affects hidden files, because svn works on the folder."),
        ]),
        HelpTopic(id: "files", symbol: "doc.on.doc", title: "File Operations", blocks: [
            .text("Use the file list's context menu or the Modify menu."),
            .steps([
                "Add puts unversioned files under version control.",
                "Remove… takes files out of version control; unversioned files go to the Trash.",
                "Revert… discards local changes. Return cancels the confirmation.",
                "Ignore… adds names to svn:ignore (recorded in the repository).",
                "Delete Physically… moves files to the Trash.",
                "Rename, Move and Copy keep the history.",
            ]),
            .text("Change sets, locks and properties have their own menus."),
        ]),
        HelpTopic(id: "branches", symbol: "arrow.triangle.branch", title: "Branches and Tags", blocks: [
            .text("Use Tag+Branch ▸ Add Tag… or Add Branch…. The location follows the project layout: a working copy of proj/trunk creates them under proj/tags or proj/branches. The dialog shows where."),
        ]),
        HelpTopic(id: "settings", symbol: "gearshape", title: "Sign-in and Settings", blocks: [
            .text("When a server asks for credentials, SpinelSvn asks for a user name and password, remembers them per repository and uses them in every window. The password is never put on the command line."),
            .text("Settings (⌘,) set the location of the svn command and the language; a language change applies after a restart."),
        ]),
        HelpTopic(id: "keys", symbol: "keyboard", title: "Keyboard Shortcuts", blocks: [
            .keys([
                KeyRow(keys: "⌘N", action: "New project window"),
                KeyRow(keys: "⌘O", action: "Open or manage projects"),
                KeyRow(keys: "⌘R", action: "Refresh"),
                KeyRow(keys: "⌥⌘R", action: "Refresh remote state"),
                KeyRow(keys: "⌘U", action: "Update"),
                KeyRow(keys: "⌘K", action: "Commit"),
                KeyRow(keys: "⌘Return", action: "Commit in the commit sheet"),
                KeyRow(keys: "⌥⌘+", action: "Add"),
                KeyRow(keys: "⇧⌘R", action: "Rename"),
                KeyRow(keys: "⌥⌘Z", action: "Revert"),
                KeyRow(keys: "⌘D", action: "Show changes"),
                KeyRow(keys: "⌘L", action: "Log"),
                KeyRow(keys: "⌥⌘G", action: "Revision graph"),
                KeyRow(keys: "⌥⌘1 / ⌥⌘2", action: "Main / review perspective"),
                KeyRow(keys: "⌥↑ / ⌥↓", action: "Previous / next file in review"),
                KeyRow(keys: "⌥Return", action: "Mark reviewed and go to next"),
                KeyRow(keys: "⌘S", action: "Save and mark resolved in the conflict solver"),
                KeyRow(keys: "⌘?", action: "This help"),
            ]),
        ]),
        HelpTopic(id: "trouble", symbol: "questionmark.circle", title: "Troubleshooting", blocks: [
            .steps([
                "svn not found: set the location of the svn command in Settings (⌘,).",
                "Authentication errors: enter the user name and password again when asked.",
                "Working copy locked: run Modify ▸ Clean Up….",
                "A file is missing from the list: check the View menu, the search field and Project ▸ Hidden Files….",
                "What happened? The inspector's Activity tab lists every svn command and its output.",
            ]),
        ]),
    ]
}

// MARK: - Window

struct HelpWindow: View {
    @State private var selection: String? = HelpContent.topics.first?.id
    @State private var query = ""

    private var topics: [HelpTopic] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? HelpContent.topics : HelpContent.topics.filter { $0.searchableText.contains(q) }
    }

    var body: some View {
        NavigationSplitView {
            List(topics, selection: $selection) { t in
                Label(t.title, systemImage: t.symbol).tag(t.id)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .overlay {
                if topics.isEmpty { ContentUnavailableView.search(text: query) }
            }
        } detail: {
            if let topic = HelpContent.topics.first(where: { $0.id == selection }) {
                ScrollView {
                    HelpTopicView(topic: topic)
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(L("Choose a topic"), systemImage: "book")
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: Text(L("Search Help")))
        .onChange(of: query) { if !topics.contains(where: { $0.id == selection }) { selection = topics.first?.id } }
        .navigationTitle(L("SpinelSvn Help"))
    }
}

private struct HelpTopicView: View {
    let topic: HelpTopic

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(topic.title, systemImage: topic.symbol)
                .font(.largeTitle.weight(.semibold))
                .padding(.bottom, 4)
            ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .text(s):
                    Text(s).fixedSize(horizontal: false, vertical: true)
                case let .heading(s):
                    Text(s).font(.title3.weight(.semibold)).padding(.top, 6)
                case let .steps(items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(.secondary).frame(width: 5, height: 5)
                                Text(item).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case let .keys(rows):
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                        ForEach(rows, id: \.self) { row in
                            GridRow {
                                Text(row.keys)
                                    .font(.system(.body, design: .rounded).weight(.medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
                                Text(row.action)
                            }
                        }
                    }
                case let .note(s):
                    Label(s, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                }
            }
        }
        .textSelection(.enabled)
    }
}
