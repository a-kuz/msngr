import SwiftUI
import MsngrCore

/// Named-people overrides of one privacy tier: whoever is listed under
/// «always» sees the setting whatever the tier says, whoever is under
/// «never» does not. Rows are removed with a swipe; adding goes through the
/// user search.
struct PrivacyExceptionsView: View {
    @EnvironmentObject var app: AppState
    /// The server name of the setting these exceptions belong to.
    let setting: String
    let title: LocalizedStringKey

    @State private var exceptions: [APIClient.PrivacyExceptionDTO] = []
    @State private var adding: Bool?   // the allow value the picker will write

    var body: some View {
        List {
            section(allow: true, header: "Always show", empty: "No one yet.")
            section(allow: false, header: "Never show", empty: "No one yet.")
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } })) {
            if let allow = adding {
                ExceptionUserPicker { user in
                    Task {
                        try? await app.api.setPrivacyException(setting: setting,
                                                               peerId: user.id, allow: allow)
                        await load()
                    }
                    adding = nil
                }
            }
        }
    }

    @ViewBuilder
    private func section(allow: Bool, header: LocalizedStringKey,
                         empty: LocalizedStringKey) -> some View {
        Section {
            ForEach(exceptions.filter { $0.allow == allow }) { row in
                HStack {
                    Text(row.displayName)
                    Spacer()
                    Text("@" + row.username).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        Task {
                            try? await app.api.setPrivacyException(setting: setting,
                                                                   peerId: row.peerId, allow: nil)
                            await load()
                        }
                    } label: { Label("Remove", systemImage: "trash") }
                }
            }
            Button {
                adding = allow
            } label: {
                Label("Add", systemImage: "plus")
            }
            .accessibilityIdentifier(allow ? "privacy.exceptions.addAllow"
                                           : "privacy.exceptions.addDeny")
        } header: {
            Text(header)
        }
    }

    private func load() async {
        guard let api = app.api else { return }
        exceptions = ((try? await api.privacyExceptions()) ?? [])
            .filter { $0.setting == setting }
    }
}

/// The person the exception is written for, found by handle or name.
private struct ExceptionUserPicker: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    var onPick: (APIClient.UserDTO) -> Void
    @State private var query = ""
    @State private var results: [APIClient.UserDTO] = []

    var body: some View {
        NavigationStack {
            List(results, id: \.id) { user in
                Button {
                    onPick(user)
                } label: {
                    VStack(alignment: .leading) {
                        Text(user.displayName)
                        Text("@" + user.username).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .onChange(of: query) { _, q in
                Task {
                    guard q.count >= 2, let api = app.api else { results = []; return }
                    results = (try? await api.searchUsers(q)) ?? []
                }
            }
            .navigationTitle(Text("Add exception"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
