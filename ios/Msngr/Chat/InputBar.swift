import SwiftUI
import MsngrCore

/// Инпут-бар: растущее поле, morph кнопки (микрофон↔отправить), запись голосового
/// с slide-to-cancel и lock, плашки reply/edit.
struct InputBar: View {
    @ObservedObject var model: ChatViewModel
    @Binding var text: String
    var onAttachPhoto: () -> Void
    var onAttachFile: () -> Void
    var onSendVoice: (URL, TimeInterval, [Int]) -> Void

    @StateObject private var recorder = VoiceRecorder()
    @State private var inputHeight: CGFloat = GrowingTextView.minHeight
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
                    Menu {
                        Button { onAttachPhoto() } label: {
                            Label("Фото или видео", systemImage: "photo.on.rectangle")
                        }
                        Button { onAttachFile() } label: {
                            Label("Файл", systemImage: "doc")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityIdentifier("chat.attach")
                    GrowingTextView(text: $text, height: $inputHeight) { model.textChanged($0) }
                        .frame(maxWidth: .infinity)
                        .frame(height: inputHeight)
                        .animation(.easeOut(duration: 0.16), value: inputHeight)
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
            .accessibilityIdentifier("chat.send")
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
/// Высота считается по контенту и отдаётся наружу: без этого SwiftUI растягивает
/// UITextView на всё свободное место и поле занимает пол-экрана.
struct GrowingTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var onChange: (String) -> Void

    static let minHeight: CGFloat = 36
    static let maxHeight: CGFloat = 6 * 21 + 16

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.font = .systemFont(ofSize: 17)
        tv.backgroundColor = UIColor.systemGray6
        tv.layer.cornerRadius = 18
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        tv.textContainer.lineFragmentPadding = 2
        tv.delegate = context.coordinator
        tv.isScrollEnabled = false
        tv.accessibilityIdentifier = "chat.input"
        tv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        // длинная строка без пробелов раздувает intrinsic width UITextView
        // и поле выталкивает кнопки за экран
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let placeholder = UILabel()
        placeholder.tag = 777
        placeholder.text = "Сообщение"
        placeholder.font = .systemFont(ofSize: 17)
        placeholder.textColor = .placeholderText
        placeholder.frame = CGRect(x: 14, y: 8, width: 200, height: 21)
        tv.addSubview(placeholder)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text { tv.text = text }
        tv.viewWithTag(777)?.isHidden = !text.isEmpty
        recalcHeight(tv)
    }

    private func recalcHeight(_ tv: UITextView) {
        let width = tv.bounds.width > 0 ? tv.bounds.width : UIScreen.main.bounds.width - 100
        let fit = tv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let clamped = min(max(fit, Self.minHeight), Self.maxHeight)
        tv.isScrollEnabled = fit > Self.maxHeight
        if abs(height - clamped) > 0.5 {
            DispatchQueue.main.async { height = clamped }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: GrowingTextView
        init(_ p: GrowingTextView) { parent = p }
        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            parent.onChange(tv.text)
            tv.viewWithTag(777)?.isHidden = !tv.text.isEmpty
            parent.recalcHeight(tv)
        }
    }
}
