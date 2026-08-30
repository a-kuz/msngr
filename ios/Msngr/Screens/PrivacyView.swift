import SwiftUI
import MsngrCore

/// Who sees "was online" and the presence dot. The server enforces this: hiding it drops
/// the presence frame at the source (ConversationDO) and also blinds the viewer to
/// everyone else's, the same reciprocity Telegram has.
enum LastSeenVisibility: String, CaseIterable, Identifiable {
    case everyone, contacts, nobody
    var id: String { rawValue }

    var label: String {
        switch self {
        case .everyone: String(localized: "Everyone")
        case .contacts: String(localized: "My contacts")
        case .nobody: String(localized: "Nobody")
        }
    }
}

/// The privacy screen: three settings, each applied on the server, not only hidden in
/// the interface. Loads the current values and saves each change as it is made.
struct PrivacyView: View {
    @EnvironmentObject var app: AppState
    @State private var lastSeen = LastSeenVisibility.everyone
    @State private var readReceipts = true
    @State private var typing = true
    @State private var loaded = false
    /// Local, this device only: whether the composer fetches a typed link's
    /// page to build the card. Off means no page is ever requested.
    @AppStorage(LinkPreviewSetting.key) private var linkPreviews = true

    var body: some View {
        List {
            Section {
                Picker(selection: $lastSeen) {
                    ForEach(LastSeenVisibility.allCases) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    Label("Last seen", systemImage: "clock")
                }
                .accessibilityIdentifier("privacy.lastSeen")
            } footer: {
                Text("Hiding your last seen also hides everyone else's from you.")
            }

            Section {
                Toggle(isOn: $readReceipts) {
                    Label("Read receipts", systemImage: "checkmark.circle")
                }
                .accessibilityIdentifier("privacy.readReceipts")
            } footer: {
                Text("Turning this off also hides read receipts from people who turned theirs off.")
            }

            Section {
                Toggle(isOn: $typing) {
                    Label("Typing", systemImage: "ellipsis.bubble")
                }
                .accessibilityIdentifier("privacy.typing")
            } footer: {
                Text("Whether people see when you're typing, and you see when they are.")
            }

            Section {
                Toggle(isOn: $linkPreviews) {
                    Label("Link previews", systemImage: "link")
                }
                .accessibilityIdentifier("privacy.linkPreviews")
            } footer: {
                Text("To build a preview card this device fetches the page of a link you type. Turned off, no page is ever requested.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!loaded)
        .task { await load() }
        .onChange(of: lastSeen) { old, new in
            guard loaded else { return }
            Task {
                guard let api = app.api else { return }
                if (try? await api.setPrivacy(lastSeen: new.rawValue)) == nil { lastSeen = old }
            }
        }
        .onChange(of: readReceipts) { old, new in
            guard loaded else { return }
            Task {
                guard let api = app.api else { return }
                if (try? await api.setPrivacy(readReceipts: new)) == nil { readReceipts = old }
            }
        }
        .onChange(of: typing) { old, new in
            guard loaded else { return }
            Task {
                guard let api = app.api else { return }
                if (try? await api.setPrivacy(typing: new)) == nil { typing = old }
            }
        }
    }

    private func load() async {
        guard let api = app.api, let p = try? await api.privacy() else { loaded = true; return }
        lastSeen = LastSeenVisibility(rawValue: p.lastSeen) ?? .everyone
        readReceipts = p.readReceipts
        typing = p.typing
        loaded = true
    }
}
