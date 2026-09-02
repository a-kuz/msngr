import SwiftUI
import Combine
import GRDB
import MsngrCore

/// One call in the list: the row the feed shows, joined with who it was with.
struct CallsListItem: Identifiable, Equatable {
    let id: String
    let chatId: String
    let peer: User?
    let outgoing: Bool
    let log: CallLog?
    let at: Double
}

/// Every call this device knows of, newest first, across all chats.
/// A tap dials the person again.
struct CallsListView: View {
    @EnvironmentObject private var app: AppState
    @State private var items: [CallsListItem] = []
    @State private var observation: AnyCancellable?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var avatarSide: CGFloat { typeSize.scaled(54, relativeTo: .subheadline, max: 74) }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No calls yet", systemImage: "phone")
                } description: {
                    Text("Calls you make and receive will be listed here.")
                }
            } else {
                List(items) { item in
                    row(item)
                        .contentShape(Rectangle())
                        .onTapGesture { redial(item) }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Calls")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("calls.list")
        .onAppear { observe() }
    }

    private func row(_ item: CallsListItem) -> some View {
        let missedIncoming = !item.outgoing && item.log.map {
            $0.outcome == .missed || $0.outcome == .declined
        } ?? false
        // the same row metrics as the chat list, so the two lists read as one set
        return HStack(spacing: 10) {
            AvatarView(name: item.peer?.displayName ?? "", avatarId: item.peer?.avatarId)
                .frame(width: avatarSide, height: avatarSide)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.peer?.displayName ?? "…")
                    .textRole(Theme.Text.rowTitle)
                    .foregroundStyle(missedIncoming ? Color.red : Color.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: item.outgoing ? "phone.arrow.up.right" : "phone.arrow.down.left")
                        .font(Theme.glyph(11, max: 15))
                    Text(detail(item))
                        .lineLimit(1)
                }
                .textRole(Theme.Text.rowPreview)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(Self.when(item.at))
                .textRole(Theme.Text.rowTime)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func detail(_ item: CallsListItem) -> String {
        let title = CallMessageView.title(outgoing: item.outgoing, log: item.log)
        let extra = CallMessageView.detail(outgoing: item.outgoing, log: item.log)
        return extra.isEmpty ? title : "\(title) · \(extra)"
    }

    private func redial(_ item: CallsListItem) {
        guard let peerId = item.peer?.id else { return }
        Task { await app.callManager?.startCall(chatId: item.chatId, peerUserId: peerId) }
    }

    private static func when(_ ts: Double) -> String {
        let date = Date(timeIntervalSince1970: ts)
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.day().month())
    }

    /// The calls this device knows of, newest first. Ordered by the server's
    /// clock where there is one — the same value the row shows — so a peer
    /// whose own clock is wrong cannot stand at the top of the list for good,
    /// or push real calls out of the window it is cut to.
    static func calls(_ dbc: GRDB.Database) throws -> [Message] {
        try Message.fetchAll(dbc, sql: """
            SELECT * FROM message WHERE kind = 'call'
            ORDER BY COALESCE(serverTs, sentAt) DESC LIMIT 300
            """)
    }

    private func observe() {
        guard let db = app.db, let ownId = app.session?.userId else { return }
        observation = ValueObservation
            .tracking { dbc -> [CallsListItem] in
                let msgs = try CallsListView.calls(dbc)
                var peers: [String: User] = [:]
                for chatId in Set(msgs.map(\.chatId)) {
                    if let peerId = try String.fetchOne(
                        dbc, sql: "SELECT userId FROM member WHERE chatId = ? AND userId != ?",
                        arguments: [chatId, ownId]),
                       let peer = try User.fetchOne(dbc, key: peerId) {
                        peers[chatId] = try ContactBookName.applied(dbc, to: peer)
                    }
                }
                return msgs.map { msg in
                    CallsListItem(id: msg.id, chatId: msg.chatId, peer: peers[msg.chatId],
                                  outgoing: msg.isOutgoing, log: msg.callLog,
                                  at: msg.serverTs ?? msg.sentAt)
                }
            }
            .publisher(in: db, scheduling: .async(onQueue: .main))
            .sink(receiveCompletion: { _ in }, receiveValue: { items = $0 })
    }
}
