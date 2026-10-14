#if DEBUG
  import DatabaseKit
  import Foundation

  /// Drives the UI from launch arguments in development builds, for screenshots and manual checks:
  ///   --select "Shop/shop/public/orders"   connect and open a table (path of sidebar titles)
  ///   --inspector / --no-inspector         show or hide the inspector
  ///   --query-editor                       show the Query Editor strip
  ///   --view cards|json                    pick the list view
  ///   --filter "status:equals:shipped"     add a filter
  ///   --mode aggregate [--full-builder]    open Aggregate mode
  ///   --stage-edit "field=value"           stage an edit on the first row and open Review
  ///   --new-connection [link]              open the New Connection sheet (optionally paste a link)
  ///   --edit-connection "Shop"             open Edit Connection
  ///   --ssh-configuration "Work"           also open that SSH configuration in the connection sheet
  ///   --new-query "SELECT 1" [--run]       open a query tab
  ///   --select-row N                       select the Nth row (0-based)
  ///   --hide-sidebar                       start with the sidebar hidden
  @MainActor
  enum DebugDriver {
    static func run(_ window: WindowModel) async {
      let app = window.app
      if let link = LaunchOptions.value("--new-connection") ?? (LaunchOptions.flag("--new-connection") ? "" : nil) {
        window.showsNewConnection = true
        if !link.isEmpty && !link.hasPrefix("--") { pendingLink = link }
      }
      if let name = LaunchOptions.value("--edit-connection"), let profile = app.profiles.first(where: { $0.name == name }) {
        window.editingProfileID = profile.id
      }
      guard let path = LaunchOptions.value("--select") else { return }
      let parts = path.split(separator: "/").map(String.init)
      guard let first = parts.first, let profile = app.profiles.first(where: { $0.name == first }) else { return }
      window.selection = .connection(profile.id)
      let connection = app.connection(for: profile.id)
      await connection.connect()
      var parent: TreeNode?
      var target: TreeNode?
      for title in parts.dropFirst() {
        await connection.loadChildren(of: parent)
        guard let node = connection.children[connection.key(parent)]?.first(where: { $0.title == title }) else { break }
        connection.expanded.insert(connection.key(parent))
        if node.hasChildren {
          connection.expanded.insert(node.id)
          parent = node
        } else {
          target = node
        }
      }
      if let target {
        window.selection = .node(profile.id, target)
      }
      if LaunchOptions.flag("--no-inspector") { window.showsInspector = false }
      if let text = LaunchOptions.value("--new-query") {
        window.newQuery()
        if let tab = connection.queries.selected { tab.text = text }
        if LaunchOptions.flag("--run") { await connection.queries.runSelected() }
        return
      }
      guard let browser = window.browser else { return }
      await browser.load()
      if let view = LaunchOptions.value("--view") {
        browser.viewMode = BrowserModel.ViewMode.allCases.first { $0.rawValue.lowercased() == view } ?? browser.viewMode
      }
      if let filter = LaunchOptions.value("--filter") {
        let pieces = filter.split(separator: ":", maxSplits: 2).map(String.init)
        if pieces.count == 3, let op = FilterOp(rawValue: pieces[1]) {
          await browser.addFilter(Filter(field: pieces[0], op: op, value: pieces[2]))
        }
      }
      if let search = LaunchOptions.value("--search") {
        browser.request.search = search
        await browser.reload()
      }
      if let key = LaunchOptions.value("--select-key") {
        browser.selection = ["key:" + key]
      }
      if let row = LaunchOptions.value("--select-row").flatMap(Int.init), browser.records.indices.contains(row) {
        browser.selection = [browser.records[row].id]
      }
      if LaunchOptions.flag("--query-editor") { browser.showsQueryEditor = true }
      if LaunchOptions.value("--mode") == "aggregate" {
        await browser.switchMode(.aggregate)
        browser.pipeline.showsFullBuilder = LaunchOptions.flag("--full-builder")
        if LaunchOptions.flag("--demo-pipeline") { demoPipeline(browser.pipeline) }
      }
      if let edit = LaunchOptions.value("--stage-edit"), let record = browser.selectedRecord ?? browser.records.first {
        for assignment in edit.split(separator: ";") {
          let pair = assignment.split(separator: "=", maxSplits: 1).map(String.init)
          guard pair.count == 2, let field = browser.fields.first(where: { $0.name == pair[0] }),
            let value = try? browser.session?.parseInput(pair[1], isNull: false, for: field)
          else { continue }
          browser.stage(
            RecordEdit(
              ref: browser.ref, key: record.key,
              kind: .update([FieldChange(field: field.name, old: record[field.name] ?? .null, new: value)]),
              title: browser.title(for: record)))
        }
        if LaunchOptions.flag("--stage-delete"), browser.records.count > 2 { browser.stageDelete([browser.records[2]]) }
        browser.showsReview = true
      }
    }

    static var pendingLink: String?

    /// The design's "Review trends" pipeline.
    static func demoPipeline(_ pipeline: PipelineModel) {
      pipeline.steps = []
      pipeline.add(.match)
      pipeline.update(pipeline.steps[0].id) {
        $0.form = .filter([StepCondition(field: "createdAt", op: .inLastDays, value: "365")])
      }
      pipeline.add(.lookup)
      pipeline.update(pipeline.steps[1].id) {
        $0.form = .lookup(from: "products", localField: "product_id", foreignField: "_id", as: "product")
      }
      pipeline.add(.unwind)
      pipeline.update(pipeline.steps[2].id) { $0.form = .unwind(path: "product", keepEmpty: false) }
      pipeline.add(.set)
      pipeline.update(pipeline.steps[3].id) {
        $0.form = .addFields([
          FieldFormula(name: "month", kind: .roundDate, field: "createdAt", unit: "month", timezone: "Europe/Lisbon"),
          FieldFormula(name: "positive", kind: .condition, field: "rating", compare: .greaterOrEqual, compareValue: "4"),
        ])
      }
      pipeline.add(.facet)
      pipeline.update(pipeline.steps[4].id) {
        $0.text =
          "{ byMonth: [{ $group: { _id: \"$month\", avgRating: { $avg: \"$rating\" } } }, { $sort: { _id: 1 } }], byCategory: [{ $group: { _id: \"$product.category\", share: { $avg: \"$positive\" } } }, { $sort: { share: -1 } }] }"
      }
      pipeline.add(.merge)
      pipeline.select(pipeline.steps[3].id)
    }
  }
#endif
