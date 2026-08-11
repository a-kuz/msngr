import SwiftUI
import MsngrCore

/// Инпут-бар: растущее поле, morph кнопки (микрофон↔отправить), запись голосового
/// с slide-to-cancel и lock, плашки reply/edit.
struct InputBar: View {
    @ObservedObject var model: ChatViewModel
    @Binding var text: String
    var onAttach: () -> Void
    var onSendVoice: (URL, TimeInterval, [Int]) -> Void

    @StateObject private var recorder = VoiceRecorder()
    @State private var recordingLocked = false
    @State private var dragOffset: CGFloat = 0
    @GestureState private var pressing = false

    var body: some View {
        VStack(spacing: 0) {
            replyEditBanner
            HStack(alignment: .bottom, spacing: 8) {
                if recorder.isRecording {
                    recordingView
                } else {
                    Button(action: onAttach) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                    }
                    GrowingTextView(text: $text) { model.textChanged($0) }
                        .frame(minHeight: 36)
                }
                actionButton
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var replyEditBanner: some View {
        if let target = model.editing ?? model.replyingTo {
            HStack(spacing: 8) {
                Image(systemName: model.editing != nil ? "pencil" : "arrowshape.turn.up.left")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.editing != nil ? "Редактирование"
                         : (model.members.first { $0.id == target.fromUserId }?.displayName ?? ""))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Text(ChatViewModel.previewText(target))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    withAnimation(Theme.springFast) {
                        model.replyingTo = nil
                        if model.editing != nil {
                            model.editing = nil
                            text = ""
                        }
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                if let e = model.editing { text = e.text ?? "" }
            }
        }
    }

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var actionButton: some View {
        if hasText {
            Button {
                let t = text
                text = ""
                withAnimation(Theme.springFast) { model.send(text: t) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.accent)
            }
            .transition(.scale.combined(with: .opacity))
        } else if recordingLocked {
            Button {
                finishRecording()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.accent)
            }
        } else {
            micButton
        }
    }

    private var micButton: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 22))
            .foregroundStyle(recorder.isRecording ? .red : .secondary)
            .frame(width: 36, height: 36)
            .scaleEffect(recorder.isRecording ? 1.6 : 1)
            .animation(recorder.isRecording
                       ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                       : Theme.springFast, value: recorder.isRecording)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !recorder.isRecording {
                            Haptics.medium()
                            try? recorder.start()
                        }
                        dragOffset = value.translation.width
                        // свайп вверх → lock
                        if value.translation.height < -70 && !recordingLocked {
                            recordingLocked = true
                            Haptics.success()
                        }
                        // свайп влево → отмена
                        if value.translation.width < -110 {
                            recorder.cancel()
                            recordingLocked = false
                            Haptics.rigid()
                        }
                    }
                    .onEnded { _ in
                        dragOffset = 0
                        guard recorder.isRecording, !recordingLocked else { return }
                        finishRecording()
                    }
            )
    }

    private var recordingView: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 10, height: 10)
                .opacity(0.5 + 0.5 * sin(recorder.duration * 4))
            Text(String(format: "%d:%02d,%01d", Int(recorder.duration) / 60,
                        Int(recorder.duration) % 60,
                        Int(recorder.duration * 10) % 10))
                .font(.system(size: 16, design: .monospaced))
            LiveWaveView(amplitudes: recorder.liveAmplitudes)
                .frame(height: 26)
            Spacer()
            if recordingLocked {
                Button("Отмена", role: .destructive) {
                    recorder.cancel()
                    recordingLocked = false
                }
                .font(.callout)
            } else {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                    Text("Отмена")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .opacity(max(0.2, 1 + Double(dragOffset) / 110))
                .offset(x: min(0, dragOffset / 3))
            }
        }
        .frame(minHeight: 36)
        .transition(.opacity)
    }

    private func finishRecording() {
        recordingLocked = false
        guard let result = recorder.stop() else { return }
        Haptics.light()
        onSendVoice(result.url, result.duration, result.waveform)
    }
}

/// Живая волна при записи.
struct LiveWaveView: View {
    let amplitudes: [Float]

    var body: some View {
        Canvas { ctx, size in
            let barW: CGFloat = 2.5
            let gap: CGFloat = 1.5
            let count = min(amplitudes.count, Int(size.width / (barW + gap)))
            guard count > 0 else { return }
            let recent = amplitudes.suffix(count)
            for (i, amp) in recent.enumerated() {
                let h = max(3, CGFloat(amp) * size.height)
                let x = CGFloat(i) * (barW + gap)
                let rect = CGRect(x: x, y: size.height / 2 - h / 2, width: barW, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2), with: .color(.red))
            }
        }
    }
}

/// Растущее текстовое поле (до 6 строк), как в TG.
struct GrowingTextView: UIViewRepresentable {
    @Binding var text: String
    var onChange: (String) -> Void

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.font = .systemFont(ofSize: 17)
        tv.backgroundColor = UIColor.systemGray6
        tv.layer.cornerRadius = 18
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        tv.delegate = context.coordinator
        tv.isScrollEnabled = false
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text { tv.text = text }
        let maxHeight: CGFloat = 6 * 22 + 16
        let fit = tv.sizeThatFits(CGSize(width: tv.bounds.width, height: .infinity)).height
        tv.isScrollEnabled = fit > maxHeight
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: GrowingTextView
        init(_ p: GrowingTextView) { parent = p }
        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            parent.onChange(tv.text)
            tv.invalidateIntrinsicContentSize()
        }
    }
}
