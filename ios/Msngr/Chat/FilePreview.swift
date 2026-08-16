import UIKit
import QuickLook
import UniformTypeIdentifiers
import MsngrCore

/// File name for the preview: QuickLook decides the type from the extension, while in the
/// media cache the file lives under its mediaId with an extension from the mime type,
/// which for documents is ".bin".
enum FilePreviewName {
    static func previewFileName(name: String?, mime: String?, mediaId: String) -> String {
        let cleaned = (name ?? "")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? (mediaId.isEmpty ? "file" : mediaId) : cleaned
        guard (base as NSString).pathExtension.isEmpty else { return base }
        guard let ext = mime.flatMap({ UTType(mimeType: $0)?.preferredFilenameExtension }) else { return base }
        return base + "." + ext
    }
}

/// The screen the system previewer is presented over.
@MainActor
enum TopViewController {
    static func current() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = (scene.windows.first { $0.isKeyWindow } ?? scene.windows.first)?.rootViewController
        else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

/// Preview of a file message: the decrypted file from the cache opens in a
/// QLPreviewController, and types it cannot read go to the system share sheet.
@MainActor
enum FilePreviewPresenter {
    private static var source: PreviewItemSource?

    static func present(message: Message) {
        guard let media = message.media, let mm = AppState.shared.media else { return }
        Task {
            guard let url = try? await mm.fetch(media) else { return }
            let name = FilePreviewName.previewFileName(name: media.name, mime: media.mime,
                                                       mediaId: media.mediaId)
            show(named(url, as: name))
        }
    }

    /// A copy under the original name, made as a hard link so the bytes are not duplicated on disk.
    private static func named(_ url: URL, as name: String) -> URL {
        guard url.lastPathComponent != name else { return url }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("preview", isDirectory: true)
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true)
        let dst = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: dst.path) { return dst }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try fm.linkItem(at: url, to: dst)
        } catch {
            guard (try? fm.copyItem(at: url, to: dst)) != nil else { return url }
        }
        return dst
    }

    private static func show(_ url: URL) {
        guard let top = TopViewController.current() else { return }
        guard QLPreviewController.canPreview(url as QLPreviewItem) else {
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = top.view
            share.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX,
                                                                     y: top.view.bounds.midY,
                                                                     width: 1, height: 1)
            top.present(share, animated: true)
            return
        }
        let ds = PreviewItemSource(url: url)
        source = ds
        let ql = QLPreviewController()
        ql.dataSource = ds
        ql.delegate = ds
        top.present(ql, animated: true)
    }

    /// Keeps the URL alive while the previewer is on screen.
    private final class PreviewItemSource: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }

        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            FilePreviewPresenter.source = nil
        }
    }
}
