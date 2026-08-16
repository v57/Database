import SwiftUI
import MongoDB

/// Detail column: full JSON of the selected document, or a placeholder.
struct DocumentDetailView: View {
    @Environment(DatabaseModel.self) private var model

    var body: some View {
        Group {
            if let doc = model.selectedDocument {
                ScrollView {
                    Text(BSONSupport.json(doc))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                ContentUnavailableView(
                    "Select a Document",
                    systemImage: "doc.text",
                    description: Text("Click a document to view its full JSON.")
                )
            }
        }
        .navigationSubtitle(model.selectedDocument.map { BSONSupport.json($0).prefix(80).description } ?? "")
    }
}
