# DatabaseUI

DatabaseUI is Database's whole interface as a library: the connection list and tree, the table, collection and Redis
key browsers, the inspector, editing with review and undo, query tabs, aggregation pipelines, the connection and SSH
sheets, the Settings panes and the Data menu. Database's app is a thin scene around it, and Shell shows the same
interface for the database connections in its sidebar.

It runs on [DatabaseKit](DatabaseKit.md), draws with ComponentKit (the [Component](https://github.com/v57/Component)
repository), highlights queries with Code's `CodeHighlighting`, and keeps its saved connections in the shared vault
(the [Vault](https://github.com/v57/Vault) repository's `VaultKit`), so every v57 app sees the same connections, SSH
servers and passwords. What the interface does for people is in the [user guide](README.md); this page covers
hosting it in an app.

It is not a set of separate widgets for building another database interface. Embed it whole, and change its behaviour
through the hooks below.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Database.git", branch: "main"),
  .package(url: "https://github.com/v57/Component.git", branch: "main"),
  .package(url: "https://github.com/v57/Vault.git", branch: "main"),
],
targets: [
  .target(
    name: "MyApp",
    dependencies: [
      .product(name: "DatabaseUI", package: "Database"),
      .product(name: "DatabaseKit", package: "Database"),
      .product(name: "ComponentKit", package: "Component"),
      .product(name: "VaultUI", package: "Vault"),
    ]),
]
```

In the v57 checkout, `Database-Local.xcworkspace` builds against the sibling repositories instead of GitHub's, and
SwiftPM does the same with `V57_LOCAL=1`.

A window with the sidebar, the detail pane, the connection sheets and the menu commands:

```swift
import ComponentKit
import DatabaseUI
import SwiftUI
import VaultUI

@main
struct MyApp: App {
  @State private var model = DatabaseModel.live()

  var body: some Scene {
    WindowGroup {
      DatabaseWindow()
        .environment(model)
        .kitToasts()
        .vaultHostKeyRequests()
        .componentKit(accent: .databaseAccent)
    }
    .commands { DatabaseCommands() }
  }
}

struct DatabaseWindow: View {
  @Environment(DatabaseModel.self) private var model
  @State private var window: WindowModel?
  @State private var columns = NavigationSplitViewVisibility.all

  var body: some View {
    if let window {
      NavigationSplitView(columnVisibility: $columns) {
        SidebarView(window: window, columnVisibility: $columns)
      } detail: {
        DetailView(window: window)
      }
      .focusedSceneValue(\.databaseWindow, window)
      .databaseSheets(window)
    } else {
      Color.clear.onAppear { window = WindowModel(app: model) }
    }
  }
}
```

`DatabaseModel.live()` opens the shared vault and starts its iCloud sync; use `DatabaseModel(folder:vault:)` to pass
a vault and a data folder of your own. `vaultHostKeyRequests()` shows the question when an SSH server's key isn't
known yet.

## Main API

### Models

- `DatabaseModel` (`@Observable`, main actor): the saved connections (`profiles`), the open ones (`live`,
  `connection(for:)`), and `save(_:password:sshPassword:sshHostID:)`, `delete(_:)`, `rename(_:to:)`,
  `duplicate(_:)`, `move(from:to:)`, `addFile(_:)` (a database file opened from Finder or a drop),
  `disconnect(_:)`, `disconnectAll()`, `credentials(for:password:sshPassword:)`. `vault` is the account's vault;
  `model(for:)` gives each vault account a model of its own, shared by that account's windows.
- `WindowModel`: one window's navigation: `selection` (a `SidebarItem`), `route`, `currentConnection`,
  `showsInspector`, and `connect(_:)`, `newConnection(through:)`, `newQuery()`, `refresh()`, `run()`,
  `leave(_:)`.
- `LiveConnection`: one open or opening connection: `profile`, `status` (`idle`, `connecting`, `connected`,
  `failed`), `connect()`, `reconnect()`, `close()`, `refreshTree()`, `expanded`, `onTunnelClosed(_:)`,
  `liveTile(size:)`.
- `SidebarItem`: what a sidebar row points at: a connection, a tree node, a saved query or a query tab.

### Views and scenes

- `SidebarView(window:columnVisibility:)`: the whole sidebar (account picker, the open connection, every saved
  connection).
- `ConnectionContents(connection:window:level:)`: one connection's tree and queries, for an app that lists
  connections in its own sidebar.
- `ConnectionMenu(connection:window:onDelete:extra:)`: a connection's actions, with room for the app's own.
- `DetailView(window:)`: the welcome, a connection's overview, a browser or the query tabs, by the window's route.
- `View.databaseSheets(_:)`: the New and Edit Connection sheets.
- `DatabaseCommands(includesFileItems:)`: New Connection and New Query, Undo Last Save, and the Data menu, acting on
  the focused window (`FocusedValues.databaseWindow`).
- `SettingsView()`: the Settings panes (Mac and Linux).

### Hooks for host apps

- `DatabaseModel.opener` (`DatabaseOpener`): opens a connection's session your way and returns an `OpenedSession`
  with what to close along with it. Shell logs in to the SSH server on its own connection and hands DatabaseKit a
  dialer for its channels. Nil uses DatabaseKit's `Connector`.
- `DatabaseModel.onDisconnect`: called after a connection closed (Disconnect, a changed or deleted connection).
- `WindowModel.onSelect`: called when the selection changes, including from inside the interface (a new query tab, a
  foreign key's table), so an app's own sidebar can follow.
- `EnvironmentValues.databaseSidebarTag` (`DatabaseSidebarTag`): what tree rows give the sidebar as their selection
  value, for an app whose sidebar selects its own type.
- `DatabaseCommands(includesFileItems: false)`: for an app with its own New and Refresh commands. New Query and
  Refresh move to the Data menu, on ⌥⌘T and ⌥⌘R.
- `DatabaseUI.accent` (and `Color.databaseAccent`): the accent of the interface's sheets. Database's blue unless the
  app sets its own.

### Development runs

`LaunchOptions` reads launch arguments. In Debug builds, `--data-dir <folder>` keeps connections, secrets and DuckDB
in a scratch folder instead of the vault and the Keychain, and `DebugDriver.run(_:)` opens the screen other arguments
describe (`--select "Shop/shop/public/orders"`, `--new-query "SELECT 1" --run`, and others listed in
`Sources/DatabaseUI/App/DebugDriver.swift`), for screenshots and manual checks.

## Platform notes

- **macOS:** everything, including DuckDB files and the Settings window.
- **iOS, iPadOS:** the same interface without DuckDB and without a Settings screen. On iPhone, tables show as a list
  and an item opens on its own page; on iPad the inspector floats over the grid where it doesn't fit beside it.
- **Linux:** builds and runs on v57/SwiftUI's GTK backend, with the Settings window. Less tested than the Mac.
- **Windows:** builds and runs on v57/SwiftUI's WinUI backend; no Settings window. Less tested than the Mac.
- **Android:** not yet.

There is no iCloud sync off Apple platforms; the vault stays on the device.

## Testing

DatabaseUI has no test target. The engine-neutral behaviour under it is tested in DatabaseKit (see
[DatabaseKit](DatabaseKit.md#testing) and [Engines](Engines.md#test-servers)). Build the interface with the app:

```bash
xcodebuild -project Database.xcodeproj -scheme Database -destination 'platform=macOS' build
xcodebuild -workspace Database-Local.xcworkspace -scheme Database -destination 'platform=macOS' build  # sibling checkouts
cd App && V57_LOCAL=1 swift build --product Database   # Linux
```

Shell embeds this library, so build Shell after changing the hooks above.
