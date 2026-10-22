import ComponentKit
import DatabaseKit
import SwiftUI

/// What an app hosting the interface sets once, before showing it.
public enum DatabaseUI {
  /// The accent of the interface's sheets, which the kit sets up as scenes of their own: Database's blue (#0066cc),
  /// or the hosting app's.
  public static var accent = Color(.sRGB, red: 0, green: 0.4, blue: 0.8)
}

extension Color {
  /// The interface's accent (`DatabaseUI.accent`).
  public static var databaseAccent: Color { DatabaseUI.accent }
}

extension EnvironmentValues {
  /// What the tree's rows give the sidebar as their selection value. Database's sidebar selects `SidebarItem`s;
  /// an app showing the tree in its own sidebar wraps them in its selection type.
  @Entry public var databaseSidebarTag: @MainActor @Sendable (SidebarItem) -> AnyHashable = { AnyHashable($0) }
}

extension FocusedValues {
  /// The key window's navigation, for the menu commands.
  @Entry public var databaseWindow: WindowModel?
}

extension View {
  /// The New and Edit Connection sheets of `window`; a saved connection opens.
  public func databaseSheets(_ window: WindowModel) -> some View {
    modifier(ConnectionSheets(window: window))
  }
}

private struct ConnectionSheets: ViewModifier {
  @Bindable var window: WindowModel
  @Environment(DatabaseModel.self) private var app

  /// The edited connection's id, as a sheet item.
  private struct Editing: Identifiable {
    let id: UUID
  }

  private var editing: Binding<Editing?> {
    Binding(get: { window.editingProfileID.map(Editing.init) }, set: { window.editingProfileID = $0?.id })
  }

  func body(content: Content) -> some View {
    content
      .kitSheet(isPresented: $window.showsNewConnection, onDismiss: { window.newConnectionHost = nil }) {
        ConnectionSheet(profile: nil, through: window.newConnectionHost) { saved in
          window.connect(saved.id)
        }
        .componentKit(accent: .databaseAccent)
      }
      .kitSheet(item: editing) { item in
        ConnectionSheet(profile: app.profile(item.id)) { saved in
          window.connect(saved.id)
        }
        .componentKit(accent: .databaseAccent)
      }
  }
}

/// The menu commands, acting on the key window's model (`databaseWindow`; nil disables them). An app with its own
/// New and Refresh commands leaves out the file items: New Query and Refresh move to the Data menu, on ⌥⌘T and ⌥⌘R.
public struct DatabaseCommands: Commands {
  @FocusedValue(\.databaseWindow) private var window
  private let includesFileItems: Bool

  public init(includesFileItems: Bool = true) {
    self.includesFileItems = includesFileItems
  }

  public var body: some Commands {
    if includesFileItems {
      CommandGroup(replacing: .newItem) {
        Button("New Connection…") { window?.newConnection() }
          .keyboardShortcut("n")
          .disabled(window == nil)
        Button("New Query") { window?.newQuery() }
          .keyboardShortcut("t")
          .disabled(window?.currentConnectionID == nil)
      }
    }
    CommandGroup(after: .undoRedo) {
      Button("Undo Last Save") { Task { await window?.browser?.undo() } }
        .keyboardShortcut("z", modifiers: [.command, .shift, .option])
        .disabled(window?.browser?.canUndo != true)
    }
    CommandMenu("Data") {
      if !includesFileItems {
        Button("New Query") { window?.newQuery() }
          .keyboardShortcut("t", modifiers: [.command, .option])
          .disabled(window?.currentConnectionID == nil)
      }
      Button("Refresh") { Task { await window?.refresh() } }
        .keyboardShortcut("r", modifiers: includesFileItems ? .command : [.command, .option])
        .disabled(window == nil)
      Button("Run") { Task { await window?.run() } }
        .keyboardShortcut(.return)
        .disabled(window == nil)
      Divider()
      Button(window?.browser?.showsQueryEditor == true ? "Hide Query Editor" : "Show Query Editor") {
        window?.browser?.showsQueryEditor.toggle()
      }
      .keyboardShortcut("e", modifiers: [.command, .shift])
      .disabled(window?.browser == nil)
      Button("Review Changes…") { window?.browser?.showsReview = true }
        .keyboardShortcut("s")
        .disabled(window?.browser?.pending.isEmpty != false)
      Divider()
      Button("Show Inspector") { window?.showsInspector.toggle() }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(window == nil)
    }
  }
}
