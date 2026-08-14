import SwiftUI
import MsngrCore

struct ChatRowView: View {
    let item: ChatListItem
    let ownUserId: String
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(name: item.title, avatarId: item.chat.kind == .direct ? item.peer?.avatarId : item.chat.avatarId,
                       online: item.peer?.online ?? false)
                .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    if item.chat.muted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    // галочки своего последнего сообщения
                    if let last = item.lastMessage, last.isOutgoing, !contentHidden {
                        TickView(status: last.status)
                            .font(.system(size: 12))
                    }
                    Text(Self.timeLabel(item.lastMessage.map { $0.serverTs ?? $0.sentAt } ?? item.chat.lastActivityAt))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 4) {
                    previewText
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if visibleUnread > 0 {
                        Text("\(visibleUnread)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .frame(minWidth: 21, minHeight: 21)
                            .background(item.chat.muted ? Color.gray : Theme.accent)
                            .clipShape(Capsule())
                            .transition(.scale.combined(with: .opacity))
                    } else if item.chat.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .animation(Theme.springFast, value: visibleUnread)
    }

    /// Заявка до принятия: ни превью, ни счётчика, ни галочек.
    private var contentHidden: Bool { ChatPrivacy.hidesContent(item.chat) }

    private var visibleUnread: Int {
        ChatPrivacy.visibleUnread(isRequest: item.chat.isRequest, iAccepted: item.chat.iAccepted,
                                  unreadCount: item.chat.unreadCount)
    }

    @ViewBuilder
    private var previewText: some View {
        if contentHidden {
            Text(ChatPrivacy.requestPlaceholder).foregroundStyle(Theme.accent)
        } else if let typing = item.typingText {
            Text(typing).foregroundStyle(Theme.accent).italic()
        } else if let draft = item.chat.draft,
                  !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            (Text("Черновик: ").foregroundStyle(.red) + Text(draft))
        } else if let last = item.lastMessage {
            if last.deletedForAll {
                Text("Сообщение удалено").italic()
            } else {
                switch last.kind {
                case .photo: Label("Фото", systemImage: "photo").labelStyle(PreviewLabelStyle())
                case .video: Label("Видео", systemImage: "video.fill").labelStyle(PreviewLabelStyle())
                case .voice: Label("Голосовое сообщение", systemImage: "mic.fill").labelStyle(PreviewLabelStyle())
                case .file: Label(last.media?.name ?? "Файл", systemImage: "doc.fill").labelStyle(PreviewLabelStyle())
                case .album: Label("Альбом", systemImage: "photo.on.rectangle").labelStyle(PreviewLabelStyle())
                default: Text(last.text ?? "")
                }
            }
        } else {
            Text(" ")
        }
    }

    static func timeLabel(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        let date = Date(timeIntervalSince1970: ts)
        let cal = Calendar.current
        let fmt = DateFormatter()
        if cal.isDateInToday(date) {
            fmt.dateFormat = "HH:mm"
        } else if cal.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            fmt.dateFormat = "E"
        } else {
            fmt.dateFormat = "dd.MM.yy"
        }
        return fmt.string(from: date)
    }
}

struct PreviewLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 12))
            configuration.title
        }
        .foregroundStyle(Theme.accent)
    }
}

/// Галочки статуса: часики → одна → две → две цветные.
struct TickView: View {
    let status: MessageStatus

    var body: some View {
        Group {
            switch status {
            case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            case .sending: Image(systemName: "clock").foregroundStyle(.secondary)
            case .sent: Image(systemName: "checkmark").foregroundStyle(.secondary)
            case .delivered: DoubleTick(color: .secondary)
            case .read: DoubleTick(color: Theme.readTick)
            }
        }
        .contentTransition(.symbolEffect(.replace))
    }
}

struct DoubleTick: View {
    let color: Color
    var body: some View {
        ZStack {
            Image(systemName: "checkmark")
            Image(systemName: "checkmark").offset(x: 4.5)
        }
        .foregroundStyle(color)
        .padding(.trailing, 4.5)
    }
}

/// Аватар: фото или инициалы на градиенте, точка online.
struct AvatarView: View {
    let name: String
    let avatarId: String?
    var online: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let avatarId, let api = AppState.shared.api {
                        AsyncImage(url: api.avatarURL(avatarId)) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                initialsView
                            }
                        }
                    } else {
                        initialsView
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipShape(Circle())

                if online {
                    Circle()
                        .fill(Color.green)
                        .frame(width: geo.size.width * 0.26, height: geo.size.width * 0.26)
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                        .transition(.scale)
                }
            }
        }
        .animation(Theme.springFast, value: online)
    }

    private var gradientColors: [Color] {
        let palettes: [[Color]] = [
            [.red, .orange], [.blue, .cyan], [.purple, .pink],
            [.green, .mint], [.orange, .yellow], [.indigo, .blue], [.pink, .red],
        ]
        return palettes[StableHash.index(name, modulo: palettes.count)]
    }

    private var initialsView: some View {
        LinearGradient(colors: gradientColors, startPoint: .top, endPoint: .bottom)
            .overlay(
                Text(initials)
                    .font(.system(size: 100, weight: .semibold))
                    .minimumScaleFactor(0.1)
                    .padding(8)
                    .foregroundStyle(.white)
            )
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }
}
