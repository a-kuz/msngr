import AVFoundation
import Foundation
import MsngrCrypto

/// A format 2 blob read while it plays: the player asks for a byte range, the
/// stream asks the server for the blocks that range falls in, checks and opens
/// each of them and answers with plaintext. Nothing waits for the whole file,
/// so playback starts on the first blocks and a seek forward fetches only the
/// blocks it lands on.
///
/// What has been opened is kept in a partial file at the plaintext's own
/// offsets, and a background pass fills whatever playback did not ask for.
/// When every block is there the file moves into the media cache under the name
/// `fetch` would have given it, so the viewer, «Вложения» and the cache ceiling
/// see the same plaintext file as after an ordinary download.
public final class MediaStream: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    public enum StreamError: Error { case unsupportedFormat, badFile }

    /// One slice of the blob from wherever it lives; in the app this is a Range
    /// request to the server.
    public typealias RangeFetch = @Sendable (_ offset: Int, _ length: Int) async throws -> Data

    private let media: MediaInfo
    private let fetchRange: RangeFetch
    private let partialURL: URL
    private let finalURL: URL
    private let size: Int
    private let key: Data
    private let root: Data
    private let onComplete: (@Sendable (URL) -> Void)?

    private let lock = NSLock()
    private var handle: FileHandle?
    private var present: [Bool]
    private var hashes: [Data]?
    private var inflight: [Int: Task<Void, Error>] = [:]
    private var manifestTask: Task<[Data], Error>?
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var fill: Task<Void, Never>?
    private var firstBlockLogged = false
    private var finished = false

    /// One HTTP request covers at most this many blocks: a request per block
    /// would spend the whole transfer waiting for round trips.
    private static let runBlocks = 16

    public init(media: MediaInfo, fetchRange: @escaping RangeFetch,
                partialURL: URL, finalURL: URL,
                onComplete: (@Sendable (URL) -> Void)? = nil) throws {
        guard media.v == 2, media.size > 0,
              let key = Data(base64Encoded: media.key),
              let root = Data(base64Encoded: media.hash) else {
            throw StreamError.unsupportedFormat
        }
        self.media = media
        self.fetchRange = fetchRange
        self.partialURL = partialURL
        self.finalURL = finalURL
        self.size = media.size
        self.key = key
        self.root = root
        self.onComplete = onComplete
        self.present = Array(repeating: false, count: MediaCrypto.blockCount(plaintextSize: media.size))
        super.init()
    }

    /// The URL the player is given: a scheme of ours, so AVFoundation routes
    /// every read through this delegate instead of going to the network itself.
    public var playbackURL: URL {
        var comps = URLComponents()
        comps.scheme = "msngr-media"
        comps.host = "blob"
        comps.path = "/" + media.mediaId + "." + MediaManager.fileExtension(forMime: media.mime)
        return comps.url!
    }

    public func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: playbackURL)
        asset.resourceLoader.setDelegate(self, queue: DispatchQueue(label: "msngr.media.stream"))
        return asset
    }

    /// Fills the blocks playback did not ask for, so the file lands in the
    /// cache complete. Runs behind the player's own requests.
    public func startBackgroundFill() {
        lock.lock()
        let already = fill != nil
        if !already { fill = Task.detached(priority: .utility) { [weak self] in await self?.fillLoop() } }
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        let tasks = requests.values
        requests.removeAll()
        fill?.cancel()
        let running = inflight.values
        lock.unlock()
        tasks.forEach { $0.cancel() }
        running.forEach { $0.cancel() }
    }

    // MARK: - Blocks

    /// The file the blocks live in: the partial file while the download is
    /// running, the cache file once every block is in — a read that arrives
    /// after the move must not bring the partial file back as an empty one.
    private func openFile() throws -> FileHandle {
        lock.lock(); defer { lock.unlock() }
        if let handle { return handle }
        let fm = FileManager.default
        if finished {
            guard let h = try? FileHandle(forReadingFrom: finalURL) else { throw StreamError.badFile }
            handle = h
            return h
        }
        if !fm.fileExists(atPath: partialURL.path) {
            fm.createFile(atPath: partialURL.path, contents: nil)
        }
        guard let h = try? FileHandle(forUpdating: partialURL) else { throw StreamError.badFile }
        try h.truncate(atOffset: UInt64(size))
        handle = h
        return h
    }

    private func manifest() async throws -> [Data] {
        lock.lock()
        if let hashes { lock.unlock(); return hashes }
        if let task = manifestTask { lock.unlock(); return try await task.value }
        let range = MediaCrypto.manifestRange(plaintextSize: size)
        let task = Task<[Data], Error> { [fetchRange, root, size] in
            let raw = try await fetchRange(range.lowerBound, range.count)
            return try MediaCrypto.parseManifest(raw, plaintextSize: size, expectedRoot: root)
        }
        manifestTask = task
        lock.unlock()
        let hashes = try await task.value
        lock.lock(); self.hashes = hashes; lock.unlock()
        return hashes
    }

    /// Makes sure every block of `blocks` is in the partial file, asking the
    /// server for the missing ones in runs.
    private func ensure(blocks: Range<Int>) async throws {
        var index = blocks.lowerBound
        while index < blocks.upperBound {
            if isPresent(index) { index += 1; continue }
            var end = index + 1
            while end < blocks.upperBound, end - index < Self.runBlocks, !isPresent(end) { end += 1 }
            try await run(index..<end)
            index = end
        }
    }

    private func isPresent(_ index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return index < present.count && present[index]
    }

    private func run(_ blocks: Range<Int>) async throws {
        lock.lock()
        if let existing = inflight[blocks.lowerBound] {
            lock.unlock()
            try await existing.value
            return
        }
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.download(blocks)
        }
        for i in blocks { inflight[i] = task }
        lock.unlock()
        defer {
            lock.lock()
            for i in blocks where inflight[i] == task { inflight[i] = nil }
            lock.unlock()
        }
        try await task.value
    }

    private func download(_ blocks: Range<Int>) async throws {
        let hashes = try await manifest()
        let first = MediaCrypto.blockRange(index: blocks.lowerBound, plaintextSize: size)
        let last = MediaCrypto.blockRange(index: blocks.upperBound - 1, plaintextSize: size)
        MsngrLog.media.debug("stream \(self.media.mediaId, privacy: .public): blocks \(blocks.lowerBound, privacy: .public)…\(blocks.upperBound - 1, privacy: .public) over range \(first.lowerBound, privacy: .public)+\(last.upperBound - first.lowerBound, privacy: .public)")
        let bytes = try await fetchRange(first.lowerBound, last.upperBound - first.lowerBound)
        guard bytes.count == last.upperBound - first.lowerBound else { throw StreamError.badFile }
        let handle = try openFile()
        for i in blocks {
            let r = MediaCrypto.blockRange(index: i, plaintextSize: size)
            let slice = bytes.subdata(in: (r.lowerBound - first.lowerBound)..<(r.upperBound - first.lowerBound))
            let plain = try MediaCrypto.openBlock(slice, index: i, key: key, expectedHash: hashes[i])
            lock.lock()
            try handle.seek(toOffset: UInt64(i * MediaCrypto.blockSize))
            try handle.write(contentsOf: plain)
            present[i] = true
            let firstOne = !firstBlockLogged
            firstBlockLogged = true
            let done = !present.contains(false)
            lock.unlock()
            if firstOne {
                MsngrLog.media.info("stream \(self.media.mediaId, privacy: .public): first block ready")
            }
            if done { completeFile() }
        }
    }

    /// Every block is in: the partial file becomes the cache file.
    private func completeFile() {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        lock.unlock()
        let fm = FileManager.default
        try? fm.removeItem(at: finalURL)
        do {
            try fm.moveItem(at: partialURL, to: finalURL)
        } catch {
            MsngrLog.media.error("stream \(self.media.mediaId, privacy: .public): cache move failed \(error.localizedDescription, privacy: .public)")
            return
        }
        MsngrLog.media.info("stream \(self.media.mediaId, privacy: .public): download complete, \(self.size, privacy: .public) bytes in cache")
        onComplete?(finalURL)
    }

    private func fillLoop() async {
        while !Task.isCancelled {
            lock.lock()
            let next = present.firstIndex(of: false)
            lock.unlock()
            guard let next else { return }
            let end = min(next + Self.runBlocks, present.count)
            do { try await ensure(blocks: next..<end) } catch {
                if Task.isCancelled { return }
                MsngrLog.media.error("stream \(self.media.mediaId, privacy: .public): fill failed \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Plaintext bytes of the file, fetching and opening whatever blocks the
    /// range falls in and nothing else. This is what the player's range
    /// requests are answered from.
    public func plaintext(offset: Int, length: Int) async throws -> Data {
        let end = min(offset + length, size)
        guard offset < end else { return Data() }
        let firstBlock = offset / MediaCrypto.blockSize
        let lastBlock = (end - 1) / MediaCrypto.blockSize
        try await ensure(blocks: firstBlock..<(lastBlock + 1))
        let handle = try openFile()
        lock.lock(); defer { lock.unlock() }
        try handle.seek(toOffset: UInt64(offset))
        return (try handle.read(upToCount: end - offset)) ?? Data()
    }

    // MARK: - AVAssetResourceLoaderDelegate

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = Self.contentType(forMime: media.mime)
            info.contentLength = Int64(size)
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }
        let id = ObjectIdentifier(request)
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.requests[id] = nil
                self.lock.unlock()
            }
            do {
                var offset = Int(dataRequest.currentOffset)
                let upper = dataRequest.requestsAllDataToEndOfResource
                    ? self.size
                    : Int(dataRequest.requestedOffset) + dataRequest.requestedLength
                while offset < min(upper, self.size) {
                    if Task.isCancelled { return }
                    let piece = min(MediaCrypto.blockSize * 4, min(upper, self.size) - offset)
                    let data = try await self.plaintext(offset: offset, length: piece)
                    if data.isEmpty { break }
                    dataRequest.respond(with: data)
                    offset += data.count
                }
                request.finishLoading()
            } catch {
                if Task.isCancelled { return }
                MsngrLog.media.error("stream \(self.media.mediaId, privacy: .public): range failed \(error.localizedDescription, privacy: .public)")
                request.finishLoading(with: error)
            }
        }
        lock.lock(); requests[id] = task; lock.unlock()
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               didCancel request: AVAssetResourceLoadingRequest) {
        let id = ObjectIdentifier(request)
        lock.lock()
        let task = requests.removeValue(forKey: id)
        lock.unlock()
        task?.cancel()
    }

    /// AVFoundation picks the parser from this, and a wrong one leaves the
    /// player with a file it will not open.
    private static func contentType(forMime mime: String) -> String {
        switch mime.lowercased() {
        case "video/quicktime": return AVFileType.mov.rawValue
        case "audio/m4a", "audio/x-m4a", "audio/mp4": return AVFileType.m4a.rawValue
        default: return AVFileType.mp4.rawValue
        }
    }
}
