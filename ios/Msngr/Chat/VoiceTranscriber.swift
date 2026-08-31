import Foundation
import UIKit
import AVFoundation
import Combine
import Speech
import MsngrCore

/// On-device recognition of a finished voice file. The language of a take is
/// not the language of the interface: the candidates are every language the
/// user lives in (system languages plus keyboard languages), and with more
/// than one the take is recognized in each and the confident one wins — a
/// Russian take on a phone that also speaks English must come out Russian.
/// SpeechAnalyzer serves a language its on-device models cover;
/// SFSpeechRecognizer pinned to on-device recognition serves the rest
/// (Russian among them). Either way nothing leaves the device.
enum VoiceTranscriber {
    enum Failure: Error {
        case unavailable
        case denied
        case emptyResult
    }

    /// The languages a take may be spoken in, most likely first: the system
    /// languages, then the keyboard languages (a Russian speaker on an
    /// English phone still has the Russian keyboard).
    @MainActor
    static func candidateLanguages() -> [Locale.Language] {
        var seen: Set<String> = []
        var out: [Locale.Language] = []
        let ids = Locale.preferredLanguages
            + UITextInputMode.activeInputModes.compactMap(\.primaryLanguage)
        for id in ids {
            let language = Locale(identifier: id).language
            guard let code = language.languageCode?.identifier, code != "emoji",
                  seen.insert(code).inserted else { continue }
            out.append(language)
        }
        return out
    }

    /// Whether recognition is possible for any of the user's languages — what
    /// decides if the bubble shows the transcript button.
    static func availability() async -> Bool {
        let candidates = await candidateLanguages()
        for language in candidates {
            if legacyRecognizer(for: language) != nil { return true }
            if await analyzerLocale(for: language) != nil { return true }
        }
        return false
    }

    /// Recognizes the file whole. The spans carry the word timings the playback
    /// highlight walks along; concatenating their text yields the returned
    /// transcript exactly.
    static func transcribe(url: URL) async throws -> (text: String, spans: [TranscriptSpan]) {
        let candidates = await candidateLanguages()
        guard !candidates.isEmpty else { throw Failure.unavailable }

        // one language: the better engine that knows it
        if candidates.count == 1 {
            if let locale = await analyzerLocale(for: candidates[0]) {
                return try await analyzerTranscribe(url: url, locale: locale)
            }
            guard let recognizer = legacyRecognizer(for: candidates[0]) else { throw Failure.unavailable }
            let take = try await legacyTranscribe(url: url, recognizer: recognizer)
            return try finish(spans: take.spans)
        }

        // several languages: recognize in each on the device and keep the
        // confident one; SFSpeechRecognizer is the engine that reports
        // confidence, so it does the judging and provides the winning text
        var best: (score: Double, spans: [TranscriptSpan])?
        var attempted = false
        for language in candidates {
            guard let recognizer = legacyRecognizer(for: language) else { continue }
            attempted = true
            guard let take = try? await legacyTranscribe(url: url, recognizer: recognizer) else { continue }
            MsngrLog.transcript.info("candidate \(language.minimalIdentifier) scored \(take.score)")
            if take.score > (best?.score ?? -1) { best = (take.score, take.spans) }
        }
        if let best { return try finish(spans: best.spans) }
        if attempted { throw Failure.emptyResult }
        // no candidate has a legacy on-device model: the first one the new
        // engine covers
        for language in candidates {
            if let locale = await analyzerLocale(for: language) {
                return try await analyzerTranscribe(url: url, locale: locale)
            }
        }
        throw Failure.unavailable
    }

    // MARK: - SpeechAnalyzer (the languages it ships models for)

    private static func analyzerLocale(for language: Locale.Language) async -> Locale? {
        await SpeechTranscriber.supportedLocales
            .first { $0.language.languageCode == language.languageCode }
    }

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

    private static func legacyRecognizer(for language: Locale.Language) -> SFSpeechRecognizer? {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: language.maximalIdentifier)),
              r.supportsOnDeviceRecognition else { return nil }
        return r
    }

    private static func legacyTranscribe(url: URL, recognizer: SFSpeechRecognizer) async throws
        -> (spans: [TranscriptSpan], score: Double) {
        let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard auth == .authorized else { throw Failure.denied }
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
        // the language that actually matches the speech is confident about
        // most of its words; a wrong one guesses. Weighted by word length so
        // one confident short word does not carry a long take
        let weight = segments.reduce(0.0) { $0 + Double($1.substring.count) }
        let score = weight > 0
            ? segments.reduce(0.0) { $0 + Double($1.confidence) * Double($1.substring.count) } / weight
            : 0
        return (spans, score)
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
