import SwiftUI
import MsngrCore

/// The bots this account owns: making one, its token, and the commands it
/// offers. A bot has no keys of its own, so everything it takes part in is
/// readable on the server — the screen says that before the first one is made.
struct BotsView: View {
    @EnvironmentObject var app: AppState
    @State private var bots: [APIClient.BotDTO] = []
    @State private var loaded = false
    @State private var creating = false
    /// The token of the bot just made, or the one just reissued: shown once,
    /// because the server keeps only its hash.
    @State private var freshToken: (name: String, token: String)?

    var body: some View {
        List {
            if let freshToken {
                Section {
                    Text(freshToken.token)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("bots.token")
                    Button {
                        UIPasteboard.general.string = freshToken.token
                    } label: {
                        Label("Copy token", systemImage: "doc.on.doc")
                    }
                } header: {
                    Text(freshToken.name)
                } footer: {
                    Text("The token is the bot's whole authentication and is shown once. Ask for a new one if it leaks.")
                }
            }
            Section {
                ForEach(bots) { bot in
                    NavigationLink {
                        BotDetailView(bot: bot, onToken: { token in
                            freshToken = (bot.display_name, token)
                        })
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bot.display_name)
                            Text("@\(bot.username)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    creating = true
                } label: {
                    Label("New bot", systemImage: "plus")
                }
                .accessibilityIdentifier("bots.new")
            } footer: {
                Text("A bot has no keys, so a chat with it is not encrypted: the server reads what is written there.")
            }
        }
        .navigationTitle("My bots")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loaded && bots.isEmpty && freshToken == nil {
                ContentUnavailableView {
                    Label("No bots yet", systemImage: "cpu")
                } description: {
                    Text("A bot answers over its token, the way an app would.")
                }
                .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $creating) {
            NewBotView { created, name in
                freshToken = (name, created.token)
                Task { await load() }
            }
        }
        .task { await load() }
    }

    private func load() async {
        bots = (try? await app.api.bots()) ?? []
        loaded = true
    }
}

/// Making one: a username the same shape as a person's, a name, and the
/// commands the input will offer after «/».
private struct NewBotView: View {
    var onCreated: (APIClient.BotCreated, String) -> Void
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var displayName = ""
    @State private var commands = ""
    @State private var failed = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username (a-z, 0-9, _)", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("bots.username")
                    TextField("Name", text: $displayName)
                        .accessibilityIdentifier("bots.name")
                }
                Section {
                    TextField("start — begins the conversation", text: $commands, axis: .vertical)
                        .lineLimit(3...8)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("bots.commands")
                } header: {
                    Text("Commands")
                } footer: {
                    Text("One per line: the word, a dash, what it does.")
                }
                if failed {
                    Text("Not created")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") { Task { await create() } }
                        .disabled(working || username.isEmpty || displayName.isEmpty)
                }
            }
        }
    }

    private func create() async {
        working = true
        defer { working = false }
        do {
            let created = try await app.api.createBot(username: username, displayName: displayName,
                                                      commands: BotCommandText.parse(commands))
            onCreated(created, displayName)
            dismiss()
        } catch {
            failed = true
        }
    }
}

/// One bot: its commands and a fresh token.
private struct BotDetailView: View {
    let bot: APIClient.BotDTO
    var onToken: (String) -> Void
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var commands: String = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                TextField("start — begins the conversation", text: $commands, axis: .vertical)
                    .lineLimit(3...10)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("bot.commands")
                Button(saved ? "Saved" : "Save commands") {
                    Task {
                        _ = try? await app.api.updateBot(bot.id,
                                                         commands: BotCommandText.parse(commands))
                        saved = true
                    }
                }
                .accessibilityIdentifier("bot.saveCommands")
            } header: {
                Text("Commands")
            }
            Section {
                Button {
                    Task {
                        if let token = try? await app.api.updateBot(bot.id, newToken: true) ?? nil {
                            onToken(token)
                            dismiss()
                        }
                    }
                } label: {
                    Label("New token", systemImage: "key")
                }
                .accessibilityIdentifier("bot.newToken")
            } footer: {
                Text("The old token stops working the moment a new one is issued.")
            }
        }
        .navigationTitle(bot.display_name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { commands = BotCommandText.render(bot.commands) }
        .onChange(of: commands) { _, _ in saved = false }
    }
}

/// The command list as it is typed and as it is shown: one per line, the word,
/// a dash, what it does.
enum BotCommandText {
    static func parse(_ text: String) -> [BotCommand] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "—", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let word = parts.first?
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                .lowercased() ?? ""
            guard !word.isEmpty else { return nil }
            return BotCommand(command: word, description: parts.count > 1 ? parts[1] : "")
        }
    }

    static func render(_ commands: [BotCommand]) -> String {
        commands.map { $0.description.isEmpty ? $0.command : "\($0.command) — \($0.description)" }
            .joined(separator: "\n")
    }
}
