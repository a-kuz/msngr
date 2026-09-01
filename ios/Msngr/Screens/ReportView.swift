import SwiftUI
import MsngrCore

/// A report of a chat or a single message. The conversation is E2EE, so the
/// server sees nothing by itself: the report carries only what the reporter
/// chooses to attach here. Blocking is offered in the same step.
struct ReportView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let chatId: String?
    /// the person the report is about; blocking is offered when it is known
    let targetUserId: String?
    /// prefilled from the reported message when the report starts on one
    let message: Message?

    @State private var reason = "spam"
    @State private var comment = ""
    @State private var attachMessage = true
    @State private var sending = false
    @State private var failed = false

    private static let reasons: [(String, LocalizedStringKey)] = [
        ("spam", "Spam"),
        ("violence", "Violence"),
        ("scam", "Scam"),
        ("other", "Other"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Self.reasons, id: \.0) { value, title in
                        Button {
                            reason = value
                        } label: {
                            HStack {
                                Text(title).foregroundStyle(.primary)
                                Spacer()
                                if reason == value {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Reason")
                }
                Section {
                    TextField(String(localized: "Details (optional)"), text: $comment, axis: .vertical)
                        .lineLimit(3...6)
                }
                if message != nil {
                    Section {
                        Toggle(String(localized: "Attach the message"), isOn: $attachMessage)
                    } footer: {
                        Text("Chats are end-to-end encrypted: the report carries only what you attach here.")
                    }
                } else {
                    Section {
                    } footer: {
                        Text("Chats are end-to-end encrypted: the report carries only what you attach here.")
                    }
                }
                Section {
                    Button {
                        Task { await send(block: false) }
                    } label: {
                        if sending { ProgressView() } else { Text("Report") }
                    }
                    .disabled(sending)
                    .accessibilityIdentifier("report.send")
                    if targetUserId != nil {
                        Button(role: .destructive) {
                            Task { await send(block: true) }
                        } label: {
                            Text("Report and block")
                        }
                        .disabled(sending)
                        .accessibilityIdentifier("report.sendAndBlock")
                    }
                }
                if failed {
                    Section {
                        Text("Not sent").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "Report"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
    }

    private func send(block: Bool) async {
        sending = true
        failed = false
        var attached: [APIClient.ReportedMessage] = []
        if attachMessage, let message {
            attached.append(.init(seq: message.seq.map(Int64.init), senderId: message.fromUserId,
                                  text: message.text?.isEmpty == false ? message.text : nil))
        }
        do {
            try await app.api.report(chatId: chatId, targetUserId: targetUserId,
                                     reason: reason,
                                     comment: comment.isEmpty ? nil : comment,
                                     attached: attached)
            if block, let targetUserId {
                try? await app.api.setBlocked(targetUserId, blocked: true)
                await app.engine?.refreshBlocked()
            }
            Haptics.success()
            dismiss()
        } catch {
            failed = true
        }
        sending = false
    }
}
