import Testing

@testable import DatabaseKit

private func database(_ name: String) -> TreeNode { TreeNode(id: name, title: name, kind: .database, hasChildren: true) }
private func collection(_ name: String, in parent: String) -> TreeNode {
  TreeNode(id: "\(parent)/\(name)", title: name, kind: .collection)
}

private let children: [String: [TreeNode]] = [
  "root": [database("shop"), database("logs"), database("archive")],
  "shop": [collection("orders", in: "shop"), collection("customers", in: "shop")],
  "logs": [collection("events", in: "logs"), collection("shop_events", in: "logs")],
]

private func titles(_ lines: [TreeOutline.Line]) -> [String] {
  lines.compactMap { if case .node(let node, _) = $0.content { node.title } else { nil } }
}

private func outline(expanded: Set<String> = []) -> TreeOutline {
  TreeOutline(children: children, errors: [:], expanded: expanded, root: "root")
}

@Test func outlineFollowsOpenBranches() {
  #expect(titles(outline().lines(level: 0)) == ["shop", "logs", "archive"])
  let open = outline(expanded: ["logs"]).lines(level: 1)
  #expect(titles(open) == ["shop", "logs", "events", "shop_events", "archive"])
  #expect(open[2].level == 2)
}

@Test func outlineMarksUnloadedBranches() {
  let lines = outline(expanded: ["archive"]).lines(level: 0)
  guard case .loading(let parent)? = lines.last?.content else {
    Issue.record("the open, unloaded branch has a loading line")
    return
  }
  #expect(parent?.id == "archive")
}

@Test func searchOpensBranchesToAMatch() {
  let search = TreeSearch(query: "ORD", children: children, root: "root")
  let lines = outline().lines(level: 0, search: search)
  #expect(titles(lines) == ["shop", "orders"])
  guard case .node(_, let isRevealed)? = lines.first?.content else { return }
  #expect(isRevealed)
}

@Test func searchKeepsOnlyMatchesBelowAMatchingBranch() {
  let search = TreeSearch(query: "shop", children: children, root: "root")
  // "logs" leads to shop_events; "shop" matches itself but holds no match, so it stays closed.
  #expect(titles(outline().lines(level: 0, search: search)) == ["shop", "logs", "shop_events"])
  // Opened by the user, a matching branch shows all it holds.
  #expect(titles(outline(expanded: ["shop"]).lines(level: 0, search: search)) == ["shop", "orders", "customers", "logs", "shop_events"])
}

@Test func searchSeesOnlyWhatIsLoaded() {
  let search = TreeSearch(query: "nothing", children: children, root: "root")
  #expect(!search.hasMatches)
  #expect(search.unopened.map(\.id) == ["archive"])
  #expect(outline().lines(level: 0, search: search).isEmpty)
}
