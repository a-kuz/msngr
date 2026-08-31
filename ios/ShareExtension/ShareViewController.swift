import UIKit
import UniformTypeIdentifiers
import GRDB
import MsngrCore

/// The share sheet's window into the messenger: a list of chats, and the
/// shared items land in the tapped one. The extension only writes the
/// database of the app group — the app's own worker uploads and sends.
final class ShareViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var chats: [ShareComposer.ChatRow] = []
    private var session: (db: DatabaseQueueBox, ownUserId: String, location: StorageLocation)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Share to")
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelled))
        table.dataSource = self
        table.delegate = self
        table.frame = view.bounds
        table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(table)
        loadChats()
    }

    private func loadChats() {
        struct StoredSession: Decodable { let userId: String }
        guard let location = AppContainer.groupLocation(),
              FileManager.default.fileExists(atPath: location.databaseURL.path),
              let db = try? AppDatabase.open(at: location.databaseURL),
              let data = try? Data(contentsOf: location.sessionURL),
              let stored = try? JSONDecoder().decode(StoredSession.self, from: data)
        else {
            showEmpty(String(localized: "Open Msngr and sign in first."))
            return
        }
        session = (DatabaseQueueBox(db), stored.userId, location)
        chats = (try? db.read { try ShareComposer.chats($0, ownUserId: stored.userId) }) ?? []
        if chats.isEmpty { showEmpty(String(localized: "No chats yet.")) }
        table.reloadData()
    }

    private func showEmpty(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        table.backgroundView = label
    }

    @objc private func cancelled() {
        extensionContext?.cancelRequest(withError: NSError(
            domain: "msngr.share", code: 0))
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        chats.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chat")
            ?? UITableViewCell(style: .default, reuseIdentifier: "chat")
        let chat = chats[indexPath.row]
        cell.textLabel?.text = chat.title
        cell.imageView?.image = UIImage(systemName: chat.isGroup ? "person.2.circle" : "person.circle")
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let session else { return }
        let chatId = chats[indexPath.row].id
        view.isUserInteractionEnabled = false
        Task {
            await self.deliver(to: chatId, session: session)
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    // MARK: - Turning the shared items into messages

    private func deliver(to chatId: String,
                         session: (db: DatabaseQueueBox, ownUserId: String, location: StorageLocation)) async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []
        let media = MediaManager(api: APIClient(baseURL: URL(string: "http://localhost:1")!),
                                 cacheDir: session.location.root.appendingPathComponent("share-cache"),
                                 pendingDir: session.location.pendingMediaDir)
        var payloads: [ContentPayload] = []
        var texts: [String] = []

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let data = await loadFileData(provider, type: .image) {
                var info = MediaInfo(type: "photo", mediaId: "", key: "", hash: "",
                                     size: data.bytes.count, mime: data.mime ?? "image/jpeg")
                info.localPath = try? media.stash(data.bytes, mime: data.mime ?? "image/jpeg")
                guard info.localPath != nil else { continue }
                var c = ContentPayload(kind: "photo")
                c.media = info
                payloads.append(c)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
                      let data = await loadFileData(provider, type: .movie) {
                var info = MediaInfo(type: "video", mediaId: "", key: "", hash: "",
                                     size: data.bytes.count, mime: data.mime ?? "video/mp4")
                info.localPath = try? media.stash(data.bytes, mime: data.mime ?? "video/mp4")
                guard info.localPath != nil else { continue }
                var c = ContentPayload(kind: "video")
                c.media = info
                payloads.append(c)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                      let data = await loadFileData(provider, type: .fileURL) {
                var info = MediaInfo(type: "file", mediaId: "", key: "", hash: "",
                                     size: data.bytes.count, mime: "application/octet-stream")
                info.localPath = try? media.stash(data.bytes)
                guard info.localPath != nil else { continue }
                info.name = data.name
                var c = ContentPayload(kind: "file")
                c.media = info
                payloads.append(c)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = await loadItem(provider, type: .url) as? URL {
                texts.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = await loadItem(provider, type: .plainText) as? String {
                texts.append(text)
            }
        }
        if !texts.isEmpty {
            var c = ContentPayload(kind: "text")
            c.text = texts.joined(separator: "\n")
            payloads.append(c)
        }
        guard !payloads.isEmpty else { return }
        try? await session.db.queue.write { dbc in
            for payload in payloads {
                try ShareComposer.enqueue(dbc, content: payload, chatId: chatId,
                                          ownUserId: session.ownUserId)
            }
        }
    }

    private struct LoadedFile { let bytes: Data; let mime: String?; let name: String? }

    private func loadFileData(_ provider: NSItemProvider, type: UTType) async -> LoadedFile? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                switch item {
                case let url as URL:
                    let secured = url.startAccessingSecurityScopedResource()
                    defer { if secured { url.stopAccessingSecurityScopedResource() } }
                    guard let bytes = try? Data(contentsOf: url), bytes.count < 100_000_000 else {
                        cont.resume(returning: nil); return
                    }
                    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    cont.resume(returning: LoadedFile(bytes: bytes, mime: mime,
                                                      name: url.lastPathComponent))
                case let data as Data:
                    cont.resume(returning: LoadedFile(bytes: data, mime: nil, name: nil))
                case let image as UIImage:
                    cont.resume(returning: image.jpegData(compressionQuality: 0.9)
                        .map { LoadedFile(bytes: $0, mime: "image/jpeg", name: nil) })
                default:
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func loadItem(_ provider: NSItemProvider, type: UTType) async -> NSSecureCoding? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                cont.resume(returning: item)
            }
        }
    }
}

/// The extension's entry point: the picker inside a navigation bar.
final class ShareNavigationController: UINavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()
        setViewControllers([ShareViewController()], animated: false)
    }
}

/// A reference wrapper so the tuple stays Sendable-friendly across the task.
final class DatabaseQueueBox {
    let queue: GRDB.DatabaseQueue
    init(_ queue: GRDB.DatabaseQueue) { self.queue = queue }
}
