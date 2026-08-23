import SwiftUI
import SwiftData
import MongoDB

/// ONE form for creating AND editing a saved connection (house pattern):
/// optional prefill via a custom init using underscore property-wrapper state.
/// Secrets rule: the stored password is NEVER read back into the form — the
/// field starts empty on edit and the stored secret is kept unless retyped.
/// Saving persists (insert-or-mutate + save) and then connects.
struct ConnectionFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(DatabaseModel.self) private var model

    private let config: ConnectionConfig?
    private let record: ConnectionRecord?

    @State private var name: String
    @State private var host: String
    @State private var port: Int
    @State private var username: String
    @State private var password: String
    @State private var authSource: String
    @State private var defaultDatabase: String
    @State private var directConnection: Bool
    @State private var errorMessage: String?

    init(config: ConnectionConfig? = nil, record: ConnectionRecord? = nil) {
        self.config = config
        self.record = record
        let c = config ?? record?.toConfig()
        _name = State(initialValue: c?.name ?? "")
        _host = State(initialValue: c?.host ?? "localhost")
        _port = State(initialValue: c.map { Int($0.port) } ?? 27017)
        _username = State(initialValue: c?.username ?? "")
        // Secrets rule: prefill EMPTY so the stored secret is never read back.
        _password = State(initialValue: "")
        _authSource = State(initialValue: c?.authSource ?? "")
        _defaultDatabase = State(initialValue: c?.defaultDatabase ?? "")
        _directConnection = State(initialValue: c?.directConnection ?? false)
    }

    private var isEditing: Bool { record != nil }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65535).contains(port)
    }

    var body: some View {
        Form {
            Text(isEditing ? "Edit Connection" : "Add Connection")
                .font(.headline)
            Section("Connection") {
                TextField("Name", text: $name)
                TextField("Host", text: $host)
                TextField("Port", value: $port, format: .number.grouping(.never))
            }
            Section("Authentication (optional)") {
                TextField("Username", text: $username)
                SecureField("Password (kept on edit unless retyped)", text: $password)
                TextField("Auth Source", text: $authSource)
            }
            Section("Startup") {
                TextField("Default Database", text: $defaultDatabase)
                Toggle("Direct connect", isOn: $directConnection)
                    .help("Connect directly to this server, bypassing topology discovery.")
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            Section {
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420)
        .padding()
    }

    private func save() {
        let newConfig = ConnectionConfig(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: UInt16(port),
            username: emptyToNil(username),
            password: emptyToNil(password),
            authSource: emptyToNil(authSource),
            defaultDatabase: emptyToNil(defaultDatabase),
            directConnection: directConnection
        )

        let saved: ConnectionRecord
        do {
            if let record {
                // Edit: mutate the existing record in place so the sidebar row
                // and any running session keep their identity.
                saved = record
                saved.name = newConfig.name
                saved.host = newConfig.host
                saved.port = Int(newConfig.port)
                saved.username = newConfig.username
                if !password.isEmpty {
                    // Only a retyped password replaces the stored secret.
                    saved.password = password
                }
                saved.authSource = newConfig.authSource
                saved.defaultDatabase = newConfig.defaultDatabase
                saved.directConnection = newConfig.directConnection
            } else {
                // Create: new @Model objects are NOT registered by init —
                // insert is required or save() silently persists nothing.
                saved = ConnectionRecord.from(config: newConfig)
                modelContext.insert(saved)
            }
            try modelContext.save()
            // Connect with the record's final config, which keeps the stored
            // password when it was not retyped.
            Task { await model.connect(saved.toConfig()) }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func emptyToNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}