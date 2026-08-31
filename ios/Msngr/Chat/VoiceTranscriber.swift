import Foundation
import AVFoundation
import Combine
import Speech
import MsngrCore

/// On-device recognition of a finished voice file. SpeechAnalyzer carries the
/// languages it ships models for; a language it does not know (Russian among
/// them) goes through SFSpeechRecognizer pinned to on-device recognition.
/// Either way nothing leaves the device.
enum VoiceTranscriber {
    enum Failure: Error {
        case unavailable
        case denied
        case emptyResult
    }

    /// Whether recognition is possible for the user's language at all — what
    /// decides if the bubble shows the transcript button.
    static func availability() async -> Bool {
        if await pickLocale() != nil { return true }
        return legacyRecognizer() != nil
    }

    /// The locale SpeechAnalyzer runs in: the first of the user's preferred
    /// languages the on-device model supports.
    static func pickLocale() async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        for id in Locale.preferredLanguages {
            let language = Locale(identifier: id).language
            if let match = supported.first(where: { $0.language.languageCode == language.languageCode }) {
                return match
            }
        }
        return nil
    }

    /// Recognizes the file whole. The spans carry the word timings the playback
    /// highlight walks along; concatenating their text yields the returned
    /// transcript exactly.
    static func transcribe(url: URL) async throws -> (text: String, spans: [TranscriptSpan]) {
        if let locale = await pickLocale() {
            return try await analyzerTranscribe(url: url, locale: locale)
        }
        return try await legacyTranscribe(url: url)
    }

    // MARK: - SpeechAnalyzer (the languages it ships models for)

    private static func analyzerTranscribe(url: URL, locale: Locale) async throws -> (String, [TranscriptSpan]) {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        // the results stream is read alongside the analysis: the transcriber
        // holds its output until someone consumes it
        async let collected: [TranscriptSpan] = {
            var spans: [TranscriptSpan] = []
            for try await result in transcriber.results where result.isFinal {
                for run in result.text.runs {
                    let piece = String(result.text[run.range].characters)
                    if let time = run.audioTimeRange {
                        spans.append(TranscriptSpan(text: piece,
                                                    start: time.start.seconds,
                                                    end: time.end.seconds))
                    } else if spans.isEmpty {
                        spans.append(TranscriptSpan(text: piece, start: 0, end: 0))
                    } else {
                        // untimed glue (spaces, punctuation) joins the word before it
                        spans[spans.count - 1].text += piece
                    }
                }
            }
            return spans
        }()
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try finish(spans: await collected)
    }

    // MARK: - SFSpeechRecognizer pinned to the device

    private static func legacyRecognizer() -> SFSpeechRecognizer? {
        for id in Locale.preferredLanguages {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)),
               r.supportsOnDeviceRecognition {
                return r
            }
        }
        return nil
    }

    private static func legacyTranscribe(url: URL) async throws -> (String, [TranscriptSpan]) {
        let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard auth == .authorized else { throw Failure.denied }
        guard let recognizer = legacyRecognizer() else { throw Failure.unavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        let result: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { c in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                if done { return }
                if let error { done = true; c.resume(throwing: error); return }
                if let result, result.isFinal { done = true; c.resume(returning: result) }
            }
        }
        // segments are bare words; the joining spaces become part of the word
        // before them so the spans still concatenate into the text exactly
        let segments = result.bestTranscription.segments
        let spans = segments.enumerated().map { i, s in
            TranscriptSpan(text: s.substring + (i == segments.count - 1 ? "" : " "),
                           start: s.timestamp, end: s.timestamp + s.duration)
        }
        return try finish(spans: spans)
    }

    /// Trims the edges (the layout trims nothing) and rejects an empty take.
    private static func finish(spans: [TranscriptSpan]) throws -> (String, [TranscriptSpan]) {
        var spans = spans
        if var first = spans.first {
            first.text = String(first.text.drop(while: { $0.isWhitespace }))
            spans[0] = first
        }
        if var last = spans.last {
            last.text = String(last.text.reversed().drop(while: { $0.isWhitespace }).reversed())
            spans[spans.count - 1] = last
        }
        spans.removeAll { $0.text.isEmpty }
        let text = spans.map(\.text).joined()
        guard !text.isEmpty else { throw Failure.emptyResult }
        return (text, spans)
    }
}

/// The voice messages being recognized right now, and whether recognition is
/// possible on this device at all: what the button follows. One per app, like
/// the player, so a cell reused mid-recognition still shows the work.
@MainActor
final class TranscriptWork: ObservableObject {
    static let shared = TranscriptWork()
    @Published private(set) var inFlight: Set<String> = []
    /// nil until the probe answers; the probe runs once per launch
    @Published private(set) var available: Bool?
    private var probing = false

    func begin(_ msgId: String) { inFlight.insert(msgId) }
    func end(_ msgId: String) { inFlight.remove(msgId) }

    func probeIfNeeded() {
        guard available == nil, !probing else { return }
        probing = true
        Task { available = await VoiceTranscriber.availability() }
    }
}
