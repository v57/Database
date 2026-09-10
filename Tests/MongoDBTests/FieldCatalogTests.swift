import Foundation
import Testing

@testable import MongoDB

/// Pure unit tests for the field catalog that feeds the filter UI: which fields
/// exist in the loaded documents, their inferred kind, and the distinct sample
/// values offered as suggestions. No server.
@Suite struct FieldCatalogTests {
  private func sample() -> [Document] {
    [
      ["_id": .string("1"), "name": .string("ann"), "age": .int32(30), "ok": .bool(true)],
      ["_id": .string("2"), "name": .string("bob"), "age": .int32(17), "tag": .array([])],
      ["_id": .string("3"), "name": .string("ann"), "age": .double(42.5), "score": .null],
    ]
  }

  @Test func fieldsKeepFirstSeenOrder() {
    #expect(
      FieldCatalog.fields(in: sample()).map(\.name)
        == ["_id", "name", "age", "ok", "tag", "score"])
  }

  @Test func kindsAreInferredAndMixedFieldsAreFlagged() {
    let fields = FieldCatalog.fields(in: sample())
    func kind(_ name: String) -> FieldKind? { fields.first { $0.name == name }?.kind }
    #expect(kind("name") == .string)
    #expect(kind("age") == .number)  // int32 + double -> number
    #expect(kind("ok") == .boolean)
    #expect(kind("tag") == .container)
    #expect(kind("score") == .empty)  // the only sample is null
  }

  @Test func distinctValuesAreDedupedAndFrequencyOrdered() {
    let name = FieldCatalog.fields(in: sample()).first { $0.name == "name" }
    #expect(name?.values == [.string("ann"), .string("bob")])  // "ann" seen twice, first
  }

  @Test func containersAreNotOfferedAsSuggestions() {
    let tag = FieldCatalog.fields(in: sample()).first { $0.name == "tag" }
    #expect(tag?.values.isEmpty == true)
  }

  @Test func valueSuggestionsAreCapped() {
    let docs = (0..<80).map { Document(dictionaryLiteral: ("n", BSON.int32(Int32($0)))) }
    let field = FieldCatalog.fields(in: docs, valueLimit: 10).first { $0.name == "n" }
    #expect(field?.values.count == 10)
  }

  @Test func textFieldsFeedsSearchEverywhere() {
    // `_id` is string-typed in this sample, so it IS a text field; the number,
    // boolean, container and null-only fields are the ones that get dropped.
    #expect(FieldCatalog.textFields(in: sample()) == ["_id", "name"])
  }
}
