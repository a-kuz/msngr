import SwiftUI
import MsngrCore

/// Input bar: a growing field, a button that morphs between microphone and send, voice
/// recording with slide-to-cancel and lock, and the reply and edit strips.
struct InputBar: View {
    @ObservedObject var model: ChatViewModel
    @Binding var text: String
    var onAttachPhoto: () -> Void
    var onAttachFile: () -> Void
    var onSendVoice: (URL, TimeInterval, [Int]) -> Void
    var onSendImages: ([UIImage], String) -> Void

    @StateObject private var recorder = VoiceRecorder()
    @ObservedObject private var theme = ThemeStore.shared
    @State private var inputHeight: CGFloat = GrowingTextView.minHeight
    @State private var recordingLocked = false
    @State private var dragOffset: CGFloat = 0
    /// images from the clipboard waiting to be sent
    @State private var pendingImages: [UIImage] = []
    @State private var pasteboardHasImage = MessageClipboard.hasImages
    /// микрофон запрещён в системе: единственное, что здесь ещё можно сделать —
    /// открыть настройки, поэтому кнопка ведёт туда
    @State private var micDenied = false
    /// запрос доступа уже в полёте: повторные касания микрофона его не множат
    @State private var startingRecording = false
    @GestureState private var pressing = false

    var body: some View {
        if model.peer?.isBlocked == true {
            blockedBar
        } else {
            composer
        }
    }

    /// You do not write to someone you blocked: the composer gives way to a strip that unblocks them.
    private var blockedBar: some View {
        VStack(spacing: 6) {
            Text("Вы заблокировали пользователя.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Разблокировать") {
                guard let peerId = model.peer?.id else { return }
                Task { try? await AppState.shared.engine.setBlocked(userId: peerId, blocked: false) }
            }
            .font(.callout.weight(.semibold))
            .accessibilityIdentifier("chat.unblock")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.bar)
        .accessibilityIdentifier("chat.blockedBar")
    }

    private var composer: some View {
        VStack(spacing: 0) {
            replyEditBanner
            pendingImagesBar
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
                        if pasteboardHasImage && text.isEmpty {
                            Button { pasteImages() } label: {
                                Label("Вставить", systemImage: "doc.on.clipboard")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(Theme.glyph(22, max: 34))
                            .foregroundStyle(.secondary)
                            .frame(width: TypeScale.scaled(36, max: 48), height: TypeScale.scaled(36, max: 48))
                    }
                    .accessibilityIdentifier("chat.attach")
                    GrowingTextView(text: $text, height: $inputHeight,
                                    onChange: { model.textChanged($0) },
                                    onPasteImages: { addPending($0) })
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
        // the «Вставить» item appears when the clipboard really holds an image: a copy made
        // here raises changedNotification, one made elsewhere shows up on return to the app
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            pasteboardHasImage = MessageClipboard.hasImages
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            pasteboardHasImage = MessageClipboard.hasImages
        }
        .alert("Микрофон выключен", isPresented: $micDenied) {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Настройки") { UIApplication.shared.open(url) }
            }
            Button("Понятно", role: .cancel) { }
        } message: {
            Text("Голосовые сообщения записываются с микрофона.")
        }
        // the hint about how recording works floats above the bar until recording is locked
        .overlay(alignment: .top) {
            if recorder.isRecording && !recordingLocked {
                recordingHint
                    .offset(y: -40)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(Theme.springFast, value: recorder.isRecording)
        .animation(Theme.springFast, value: recordingLocked)
    }

    /// «влево — отмена, вверх — замок»: shown as soon as recording starts.
    private var recordingHint: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                Text("влево — отмена")
            }
            HStack(spacing: 3) {
                Image(systemName: "lock.fill")
                Text("вверх — замок")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        .allowsHitTesting(false)
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

    /// Previews of the pasted images: tapping the cross drops an attachment.
    @ViewBuilder
    private var pendingImagesBar: some View {
        if !pendingImages.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(pendingImages.enumerated()), id: \.offset) { pair in
                        PendingImageThumb(image: pair.element) {
                            withAnimation(Theme.springFast) {
                                _ = pendingImages.remove(at: pair.offset)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(height: 68)
            .accessibilityIdentifier("chat.pendingAttachments")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func pasteImages() {
        addPending(MessageClipboard.pastedImages())
    }

    private func addPending(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        Haptics.light()
        withAnimation(Theme.springFast) { pendingImages.append(contentsOf: images) }
    }

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var actionButton: some View {
        if hasText || !pendingImages.isEmpty {
            Button {
                let t = text
                let images = pendingImages
                text = ""
                withAnimation(Theme.springFast) { pendingImages = [] }
                guard !images.isEmpty else {
                    withAnimation(Theme.springFast) { model.send(text: t) }
                    return
                }
                model.textChanged("")
                onSendImages(images, t.trimmingCharacters(in: .whitespacesAndNewlines))
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Theme.glyph(32, max: 44))
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityIdentifier("chat.send")
            .transition(.scale.combined(with: .opacity))
        } else if recordingLocked {
            Button {
                finishRecording()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Theme.glyph(32, max: 44))
                    .foregroundStyle(Theme.accent)
            }
        } else {
            micButton
        }
    }

    private var micButton: some View {
        Image(systemName: "mic.fill")
            .font(Theme.glyph(22, max: 34))
            .foregroundStyle(recorder.isRecording ? .red : .secondary)
            .frame(width: TypeScale.scaled(36, max: 48), height: TypeScale.scaled(36, max: 48))
            .scaleEffect(recorder.isRecording ? 1.6 : 1)
            .animation(recorder.isRecording
                       ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                       : Theme.springFast, value: recorder.isRecording)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !recorder.isRecording { beginRecording() }
                        dragOffset = value.translation.width
                        // swipe up locks the recording
                        if value.translation.height < -70 && !recordingLocked {
                            recordingLocked = true
                            Haptics.success()
                        }
                        // swipe left cancels it
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

    /// Первое нажатие на микрофон спрашивает доступ и записи не начинает:
    /// системный диалог перекрывает экран, и этот дубль был бы тишиной.
    /// Пользователь нажимает второй раз, уже с разрешением.
    private func beginRecording() {
        guard !startingRecording else { return }
        startingRecording = true
        Task {
            let granted = await VoiceRecorder.requestPermission()
            await MainActor.run {
                startingRecording = false
                guard granted else {
                    micDenied = true
                    return
                }
                Haptics.medium()
                do {
                    try recorder.start()
                } catch {
                    MsngrLog.outbox.error("не удалось начать запись: \(error)")
                    model.sendFailure = "Голосовое не записано: микрофон занят другим приложением"
                }
            }
        }
    }

    private var recordingView: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 10, height: 10)
                .opacity(0.5 + 0.5 * sin(recorder.duration * 4))
            Text(String(format: "%d:%02d,%01d", Int(recorder.duration) / 60,
                        Int(recorder.duration) % 60,
                        Int(recorder.duration * 10) % 10))
                .textRole(Theme.Text.recordTimer)
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
        .frame(minHeight: TypeScale.scaled(36, max: 48))
        .transition(.opacity)
    }

    private func finishRecording() {
        recordingLocked = false
        guard let result = recorder.stop() else {
            // a recording shorter than a second is dropped: a short hard haptic instead of a message
            Haptics.rigid()
            return
        }
        Haptics.light()
        onSendVoice(result.url, result.duration, result.waveform)
    }
}

/// Attachment thumbnail in the input bar, with a cross to remove it.
struct PendingImageThumb: View {
    let image: UIImage
    let onRemove: () -> Void

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.glyph(16, max: 24))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.black.opacity(0.55))
                }
                .padding(2)
            }
    }
}

/// Live waveform while recording.
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

/// A growing text field (up to 6 lines), the way TG has it.
/// The height is computed from the content and handed back out: without that SwiftUI
/// stretches the UITextView over all the free space and the field eats half the screen.
struct GrowingTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var onChange: (String) -> Void
    var onPasteImages: ([UIImage]) -> Void = { _ in }
    /// Reading the size is what brings `updateUIView` back when the reader
    /// changes it: the field then re-fonts itself and re-measures its height.
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The field grows with the text: one line at the floor, six at the ceiling, past
    /// which the field starts scrolling.
    static var minHeight: CGFloat { max(36, ceil(Theme.Text.input.uiFont.lineHeight) + 18) }
    static var maxHeight: CGFloat { 6 * ceil(Theme.Text.input.uiFont.lineHeight) + 16 }

    func makeUIView(context: Context) -> UITextView {
        let tv = PasteAwareTextView()
        tv.onPasteImages = onPasteImages
        tv.font = Theme.Text.input.uiFont
        tv.backgroundColor = UIColor.systemGray6
        tv.layer.cornerRadius = 18
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        tv.textContainer.lineFragmentPadding = 2
        tv.delegate = context.coordinator
        tv.isScrollEnabled = false
        tv.accessibilityIdentifier = "chat.input"
        tv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        // a long unbroken string inflates the UITextView's intrinsic width and the field
        // pushes the buttons off the screen
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let placeholder = UILabel()
        placeholder.tag = 777
        placeholder.text = "Сообщение"
        placeholder.font = Theme.Text.input.uiFont
        placeholder.textColor = .placeholderText
        tv.addSubview(placeholder)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text { tv.text = text }
        let font = Theme.Text.input.uiFont
        if tv.font != font { tv.font = font }
        if let placeholder = tv.viewWithTag(777) as? UILabel {
            placeholder.isHidden = !text.isEmpty
            placeholder.font = font
            placeholder.frame = CGRect(x: 14, y: 8, width: tv.bounds.width - 20,
                                       height: ceil(font.lineHeight))
        }
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

    /// A pasted image leaves as an attachment: a plain field ignores that kind of clipboard
    /// altogether and does not even offer «Вставить».
    final class PasteAwareTextView: UITextView {
        var onPasteImages: ([UIImage]) -> Void = { _ in }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_ sender: Any?) {
            let images = UIPasteboard.general.hasImages ? (UIPasteboard.general.images ?? []) : []
            guard !images.isEmpty else {
                super.paste(sender)
                return
            }
            onPasteImages(images)
        }
    }

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
