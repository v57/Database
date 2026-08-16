import SwiftUI
import MongoDB

/// Middle column: database picker, collection search field, and the
/// collection list — all wired straight into the shared DatabaseModel.
struct CollectionsView: View {
    @Environment(DatabaseModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.session == nil {
                ContentUnavailableView(
                    "No connection selected",
                    systemImage: "cable.connector",
                    description: Text("Pick a saved connection in the sidebar.")
                )
            } else {
                VStack(spacing: 0) {
                    Picker("Database", selection: $model.selectedDatabase) {
                        if model.databases.isEmpty {
                            Text("No databases").tag(String?.none)
                        } else {
                            ForEach(model.databases, id: \.self) { db in
                                Text(db).tag(Optional(db))
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .onChange(of: model.selectedDatabase) { _, newValue in
                        guard let newValue else { return }
                        Task { await model.select(database: newValue) }
                    }

                    TextField("Filter collections…", text: $model.collectionSearch)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                        .onSubmit {
                            Task { await model.refreshCollections() }
                        }
                        .onChange(of: model.collectionSearch) { _, _ in
                            Task { await model.refreshCollections() }
                        }

                    List(model.collections, id: \.self, selection: $model.selectedCollection) { coll in
                        Label(coll, systemImage: "shippingbox")
                    }
                    .onChange(of: model.selectedCollection) { _, newValue in
                        guard let newValue else { return }
                        Task { await model.select(collection: newValue) }
                    }

                    if !model.statusMessage.isEmpty {
                        Text(model.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(.bar)
                    }
                }
            }
        }
    }
}