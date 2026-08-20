import SwiftUI
import MsngrCore

/// Every text an edited message has shown, newest first, each with the time it
/// was authored. Opened from the context menu of an edited message.
struct EditHistorySheet: View {
    let message: Message

    /// Newest first: the current text on top, then the superseded ones.
    var versions: [EditVersion] {
        var all = message.editHistory
        all.append(EditVersion(text: message.text ?? "",
                               ts: message.editedAt ?? message.sentAt))
        return all.reversed()
    }

    var body: some View {
        List {
            Section {
                ForEach(Array(versions.enumerated()), id: \.offset) { index, version in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(version.text)
                        Text(Date(timeIntervalSince1970: version.ts),
                             format: .dateTime.day().month().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("chat.editHistory.version")
                }
            } header: {
                Text("Edit history")
            }
        }
        .listStyle(.insetGrouped)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
