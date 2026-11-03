import Foundation

/// What a search finds in the part of a connection's tree that's loaded. Nothing here asks the server anything, so it
/// can run on every keystroke.
public struct TreeSearch: Sendable {
  public let query: String
  /// The nodes whose title matches, and those holding one further down.
  public let matching: Set<String>
  /// The branches never opened: their children aren't loaded, so the search doesn't see them.
  public let unopened: [TreeNode]

  public var hasMatches: Bool { !matching.isEmpty }

  public init(query: String, children: [String: [TreeNode]], root: String) {
    var matching: Set<String> = []
    var unopened: [TreeNode] = []
    func visit(_ nodes: [TreeNode]) -> Bool {
      var found = false
      for node in nodes {
        var holds = node.title.localizedCaseInsensitiveContains(query)
        if let below = children[node.id] {
          if visit(below) { holds = true }
        } else if node.hasChildren {
          unopened.append(node)
        }
        if holds {
          matching.insert(node.id)
          found = true
        }
      }
      return found
    }
    _ = visit(children[root] ?? [])
    self.query = query
    self.matching = matching
    self.unopened = unopened
  }
}

/// A connection's open tree as one flat list of lines, for a lazy list of rows.
public struct TreeOutline: Sendable {
  public struct Line: Identifiable, Sendable {
    public enum Content: Sendable {
      /// `isRevealed`: open because the search found something in it, whether or not the user opened it.
      case node(TreeNode, isRevealed: Bool)
      case empty(parent: TreeNode?)
      case failed(String)
      /// A branch not loaded yet; its row loads it on coming to the screen.
      case loading(parent: TreeNode?)
    }

    public var id: String
    public var content: Content
    public var level: Int
  }

  public var children: [String: [TreeNode]]
  public var errors: [String: String]
  public var expanded: Set<String>
  public var root: String

  public init(children: [String: [TreeNode]], errors: [String: String], expanded: Set<String>, root: String) {
    self.children = children
    self.errors = errors
    self.expanded = expanded
    self.root = root
  }

  /// The lines from the top. With a `search` it keeps the matches and what leads to them, open; a match with no match
  /// below it opens and closes as usual and shows all its children.
  public func lines(level: Int, search: TreeSearch? = nil) -> [Line] {
    if let search, !search.hasMatches { return [] }
    var lines: [Line] = []
    func add(_ parent: TreeNode?, level: Int, narrowed: Bool) {
      let key = parent?.id ?? root
      if let nodes = children[key] {
        if nodes.isEmpty { lines.append(Line(id: "note:" + key, content: .empty(parent: parent), level: level)) }
        for node in nodes where !narrowed || search?.matching.contains(node.id) == true {
          let revealed = narrowed && children[node.id]?.contains { search?.matching.contains($0.id) == true } == true
          lines.append(Line(id: node.id, content: .node(node, isRevealed: revealed), level: level))
          if node.hasChildren, revealed || expanded.contains(node.id) { add(node, level: level + 1, narrowed: revealed) }
        }
      } else if let error = errors[key] {
        lines.append(Line(id: "note:" + key, content: .failed(error), level: level))
      } else {
        lines.append(Line(id: "note:" + key, content: .loading(parent: parent), level: level))
      }
    }
    add(nil, level: level, narrowed: search != nil)
    return lines
  }
}
