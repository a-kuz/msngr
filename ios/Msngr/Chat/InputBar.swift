import SwiftUI
import AVFoundation
import GameController
import MsngrCore

/// Input bar: a growing field, a button that morphs between microphone and send, voice
/// recording with slide-to-cancel and lock, and the reply and edit strips.
struct InputBar: View {
    @ObservedObject var model: ChatViewModel
    @Binding var text: String
    var onAttachPhoto: () -> Void
    var onAttachFile: () -> Void
    var onAttachShader: () -> Void
    var onAttachSticker: () -> Void
    var onAttachBubbleShader: () -> Void
    var onSendVoice: (URL, TimeInterval, [Int]) -> Void
    var onSendImages: ([UIImage], String) -> Void
    /// ↑/↓ from the hardware keyboard over an empty composer (true is up):
    /// the chat screen walks the feed with it.
    var onArrowKey: (Bool) -> Bool = { _ in false }
    /// Return over an empty composer: the chat screen may act on the walked
    /// message (a reply); false leaves the keystroke a no-op.
    var onEmptyReturn: () -> Bool = { false }

    @StateObject private var recorder = VoiceRecorder()
    @ObservedObject private var surfaces = ShaderSurfaces.shared
    @ObservedObject private var theme = ThemeStore.shared
    /// where the take is in its life: asked for, running, locked, dropped
    @State private var gesture = RecordingGesture()
    @State private var dragOffset: CGFloat = 0
    /// images from the clipboard waiting to be sent
    @State private var pendingImages: [UIImage] = []
    @State private var pasteboardHasImage = MessageClipboard.hasImages
    /// the microphone is denied in the system: the only thing left to do from here is
    /// open Settings, so that is where the button leads
    @State private var micDenied = false

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
            Text("You blocked this user.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Unblock") {
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
            bubbleShaderStrip
            mentionBar
            pendingImagesBar
            HStack(alignment: .bottom, spacing: 8) {
                if recorder.isRecording {
                    recordingView
                } else {
                    Menu {
                        Button { onAttachPhoto() } label: {
                            Label("Photo or video", systemImage: "photo.on.rectangle")
                        }
                        .accessibilityIdentifier("chat.attach.photo")
                        Button { onAttachFile() } label: {
                            Label("File", systemImage: "doc")
                        }
                        // the shader composer is the owner's debugging tool:
                        // its entries appear only when switched on in Settings
                        if surfaces.composerEnabled {
                            Button { onAttachShader() } label: {
                                Label("Shader", systemImage: "sparkles")
                            }
                            .accessibilityIdentifier("chat.attach.shader")
                        }
                        Button { onAttachSticker() } label: {
                            Label("Sticker", systemImage: "sparkles.rectangle.stack")
                        }
                        .accessibilityIdentifier("chat.attach.sticker")
                        if surfaces.composerEnabled {
                            Button { onAttachBubbleShader() } label: {
                                Label("Bubble shader", systemImage: "bubble.left.fill")
                            }
                            .accessibilityIdentifier("chat.attach.bubbleShader")
                        }
                        if pasteboardHasImage && text.isEmpty {
                            Button { pasteImages() } label: {
                                Label("Paste", systemImage: "doc.on.clipboard")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(Theme.glyph(22, max: 34))
                            .foregroundStyle(.secondary)
                            .frame(width: TypeScale.scaled(36, max: 48), height: TypeScale.scaled(36, max: 48))
                    }
                    .accessibilityIdentifier("chat.attach")
                    GrowingTextView(text: $text,
                                    onChange: { model.textChanged($0) },
                                    onPasteImages: { addPending($0) },
                                    onReturn: {
                                        guard hasText || !pendingImages.isEmpty else {
                                            _ = onEmptyReturn()
                                            return true
                                        }
                                        sendCurrent()
                                        return true
                                    },
                                    onArrow: onArrowKey)
                        .frame(maxWidth: .infinity)
                }
                actionButton
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
        // the paste item appears when the clipboard really holds an image: a copy made
        // here raises changedNotification, one made elsewhere shows up on return to the app
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            pasteboardHasImage = MessageClipboard.hasImages
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            pasteboardHasImage = MessageClipboard.hasImages
        }
        .alert(String(localized: "Microphone disabled"), isPresented: $micDenied) {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Button(String(localized: "Settings")) { UIApplication.shared.open(url) }
            }
            Button(String(localized: "Got it"), role: .cancel) { }
        } message: {
            Text(String(localized: "Voice messages are recorded from the microphone."))
        }
        // the hint about how recording works floats above the bar until recording is locked
        .overlay(alignment: .top) {
            if recorder.isRecording && !gesture.isLocked {
                recordingHint
                    .offset(y: -40)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        // a take is held by this screen and by nothing else: leaving the chat, leaving
        // the app or a call taking the microphone away drops it whole, so that no stump
        // of one goes out unnoticed
        .onDisappear { handle(gesture.interrupted()) }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willResignActiveNotification)) { _ in
            handle(gesture.interrupted())
        }
        .onReceive(NotificationCenter.default.publisher(
            for: AVAudioSession.interruptionNotification)) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            guard AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            handle(gesture.interrupted())
        }
        .animation(Theme.springFast, value: recorder.isRecording)
        .animation(Theme.springFast, value: gesture.isLocked)
    }

    /// Autocomplete for a mention: appears while the field ends with an open
    /// "@prefix", a tap swaps the prefix for the picked handle.
    @ViewBuilder
    private var mentionBar: some View {
        let suggestions = model.mentionSuggestions(for: text)
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(suggestions, id: \.userId) { user in
                        Button {
                            insertMention(user)
                        } label: {
                            HStack(spacing: 6) {
                                AvatarView(name: user.displayName, avatarId: nil)
                                    .frame(width: 24, height: 24)
                                Text(user.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(.systemGray6), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.mention.\(user.username)")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// Replaces the open "@prefix" the field ends with by the picked handle.
    private func insertMention(_ user: MessageMarkdown.MentionCandidate) {
        guard let at = text.lastIndex(of: "@") else { return }
        text = String(text[..<at]) + "@\(user.username) "
        model.textChanged(text)
    }

    private var recordingHint: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                Text("left to cancel")
            }
            HStack(spacing: 3) {
                Image(systemName: "lock.fill")
                Text("up to lock")
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

    /// The shader waiting to go behind the next text message: a live thumbnail
    /// and a cross that lets it go.
    @ViewBuilder
    private var bubbleShaderStrip: some View {
        if let doc = model.pendingBubbleShader {
            HStack(spacing: 8) {
                ShaderCanvasView(document: doc, running: true, deviceInputs: true, priority: .focus)
                    .frame(width: 44, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bubble shader").font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                    Text(doc.name ?? String(localized: "Behind the next message"))
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    withAnimation(Theme.springFast) { model.pendingBubbleShader = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .accessibilityIdentifier("chat.strip.bubbleShader.cancel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("chat.strip.bubbleShader")
        }
    }

    @ViewBuilder
    private var replyEditBanner: some View {
        if let target = model.editing ?? model.replyingTo {
            HStack(spacing: 8) {
                Image(systemName: model.editing != nil ? "pencil" : "arrowshape.turn.up.left")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.editing != nil ? String(localized: "Editing")
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
                    // the strip carries one mode at a time, so the cross leaves the
                    // one it is showing: editing on top of a reply gives the reply back
                    withAnimation(Theme.springFast) {
                        if model.editing != nil {
                            model.editing = nil
                        } else {
                            model.replyingTo = nil
                        }
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .accessibilityIdentifier("chat.strip.cancel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier(model.editing != nil ? "chat.strip.edit" : "chat.strip.reply")
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

    /// One send for the button and the hardware Return alike.
    private func sendCurrent() {
        let t = text
        let images = pendingImages
        text = ""
        withAnimation(Theme.springFast) { pendingImages = [] }
        // emptying the field from code raises no delegate callback, so the
        // typing indicator on the other side is taken down by hand
        model.textChanged("")
        guard !images.isEmpty else {
            withAnimation(Theme.springFast) { model.send(text: t) }
            return
        }
        onSendImages(images, t.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @ViewBuilder
    private var actionButton: some View {
        if hasText || !pendingImages.isEmpty {
            Button {
                sendCurrent()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Theme.glyph(32, max: 44))
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityIdentifier("chat.send")
            .transition(.scale.combined(with: .opacity))
        } else if gesture.isLocked {
            Button {
                handle(gesture.send())
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Theme.glyph(32, max: 44))
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityIdentifier("chat.sendVoice")
        } else {
            micButton
        }
    }

    private var micButton: some View {
        Image(systemName: "mic.fill")
            .font(Theme.glyph(22, max: 34))
            .foregroundStyle(recorder.isRecording ? .red : .secondary)
            .frame(width: TypeScale.scaled(36, max: 48), height: TypeScale.scaled(36, max: 48))
            .accessibilityIdentifier("chat.mic")
            .scaleEffect(recorder.isRecording ? 1.6 : 1)
            .animation(recorder.isRecording
                       ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                       : Theme.springFast, value: recorder.isRecording)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handle(gesture.touchDown())
                        dragOffset = value.translation.width
                        handle(gesture.moved(value.translation))
                    }
                    .onEnded { _ in
                        dragOffset = 0
                        handle(gesture.touchUp())
                    }
            )
    }

    /// What the gesture decided, carried out. Access is asked for before the recorder
    /// runs: the system dialog covers the screen, and a take started under it would be
    /// silence, so the first touch on the microphone only asks.
    private func handle(_ action: RecordingGesture.Action) {
        switch action {
        case .none:
            break
        case .ask:
            Task {
                let granted = await VoiceRecorder.requestPermission()
                await MainActor.run {
                    if !granted { micDenied = true }
                    handle(gesture.permitted(granted))
                }
            }
        case .start:
            Haptics.medium()
            do {
                try recorder.start()
            } catch {
                MsngrLog.outbox.error("failed to start recording: \(error)")
                model.sendFailure = String(localized: "Voice not recorded: microphone is in use by another app")
                handle(gesture.interrupted())
            }
        case .lock:
            // the microphone gives way to the send button, so the drag ends without an
            // onEnded of its own and the offset has to be given back here
            dragOffset = 0
            Haptics.success()
        case .cancel:
            recorder.cancel()
            Haptics.rigid()
        case .finish:
            finishRecording()
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
            if gesture.isLocked {
                Button(String(localized: "Cancel"), role: .destructive) {
                    handle(gesture.discard())
                }
                .font(.callout)
                .accessibilityIdentifier("chat.cancelVoice")
            } else {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                    Text(String(localized: "Cancel"))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .opacity(max(0.2, 1 + Double(dragOffset) / 110))
                .offset(x: min(0, dragOffset / 3))
            }
        }
        .frame(minHeight: TypeScale.scaled(36, max: 48))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.recording")
        .transition(.opacity)
    }

    private func finishRecording() {
        guard let result = recorder.stop() else {
            // a take under 0.3 s is an accidental touch: a short hard haptic and nothing else
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
    var onChange: (String) -> Void
    var onPasteImages: ([UIImage]) -> Void = { _ in }
    /// Hardware Return; true means the keystroke was consumed (a send).
    var onReturn: () -> Bool = { false }
    /// ↑/↓ over an empty field (true is up): the feed walk.
    var onArrow: (Bool) -> Bool = { _ in false }
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
        tv.onReturn = onReturn
        tv.onArrow = onArrow
        tv.onEscape = { NotificationCenter.default.post(name: .chatEscapePressed, object: nil) }
        // with a hardware keyboard attached the composer takes focus as the
        // chat opens, so Enter works right away — a chat entered with the
        // keyboard should not need a tap before it
        if GCKeyboard.coalesced != nil {
            DispatchQueue.main.async { tv.becomeFirstResponder() }
        }
        tv.font = Theme.Text.input.uiFont
        tv.backgroundColor = UIColor.systemGray6
        tv.layer.cornerRadius = 18
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        tv.textContainer.lineFragmentPadding = 2
        tv.delegate = context.coordinator
        tv.isScrollEnabled = false
        tv.scrollsToTop = false
        tv.accessibilityIdentifier = "chat.input"
        tv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        // a long unbroken string inflates the UITextView's intrinsic width and the field
        // pushes the buttons off the screen
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let placeholder = UILabel()
        placeholder.tag = 777
        placeholder.text = String(localized: "Message")
        placeholder.font = Theme.Text.input.uiFont
        placeholder.textColor = .placeholderText
        tv.addSubview(placeholder)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // the closure captures view state (text, pending images) and goes
        // stale unless refreshed on every render
        (tv as? PasteAwareTextView)?.onReturn = onReturn
        (tv as? PasteAwareTextView)?.onArrow = onArrow
        // Text flows from the view into the binding while the user types; the
        // binding writes back only a value the view itself never held — a clear
        // after send, a restored draft. Writing on every render echoes a stale
        // binding under load: just-typed letters vanish and the caret lands
        // behind the text, because a programmatic write resets it. The guard is
        // the coordinator's record of what the view last reported.
        if text != context.coordinator.viewText {
            applyText(text, to: tv, coordinator: context.coordinator)
        }
        let font = Theme.Text.input.uiFont
        if tv.font != font { tv.font = font }
        if let placeholder = tv.viewWithTag(777) as? UILabel {
            placeholder.isHidden = !text.isEmpty
            placeholder.font = font
            placeholder.frame = CGRect(x: 14, y: 8, width: tv.bounds.width - 20,
                                       height: ceil(font.lineHeight))
        }
    }

    /// Brings the field to a value it does not hold yet. The caret keeps its
    /// distance from the end of the text rather than its absolute position: when
    /// the binding runs ahead of the view — the first character of a field the
    /// view still reports as empty — an absolute position put the caret in front
    /// of that character, and everything typed after it went in before it.
    func applyText(_ text: String, to tv: UITextView, coordinator: Coordinator) {
        let held = (tv.text ?? "") as NSString
        let tail = max(0, held.length - tv.selectedRange.location)
        tv.text = text
        coordinator.viewText = text
        tv.selectedRange = NSRange(location: max(0, (text as NSString).length - tail), length: 0)
        Self.fitScrolling(tv)
        tv.invalidateIntrinsicContentSize()
    }

    /// The height SwiftUI gives the field. Computed synchronously on request —
    /// no state hop, so the field resizes in the same frame as the keystroke.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView tv: UITextView,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? (tv.bounds.width > 0 ? tv.bounds.width
                                       : UIScreen.main.bounds.width - 100)
        let fit = tv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(max(fit, Self.minHeight), Self.maxHeight))
    }

    /// Past six lines the field scrolls instead of growing.
    fileprivate static func fitScrolling(_ tv: UITextView) {
        let width = tv.bounds.width > 0 ? tv.bounds.width : UIScreen.main.bounds.width - 100
        let fit = tv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        tv.isScrollEnabled = fit > Self.maxHeight
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// A pasted image leaves as an attachment: a plain field ignores that kind of clipboard
    /// altogether and does not even offer to paste.
    final class PasteAwareTextView: UITextView {
        var onPasteImages: ([UIImage]) -> Void = { _ in }
        /// Hardware Return: true means it was taken (a send); false falls back
        /// to a newline. Shift+Return always breaks the line, like everywhere.
        var onReturn: () -> Bool = { false }
        /// Esc pressed while the composer holds focus: the chat screen walks
        /// back out with it exactly as it does unfocused.
        var onEscape: () -> Void = {}
        /// ↑/↓ pressed while the composer is empty (true is up): the chat
        /// screen walks the feed with it. With text in the field the arrows
        /// never reach here and move the caret as in any text view.
        var onArrow: (Bool) -> Bool = { _ in false }

        override var keyCommands: [UIKeyCommand]? {
            let send = UIKeyCommand(input: "\r", modifierFlags: [],
                                    action: #selector(hardwareReturn))
            send.wantsPriorityOverSystemBehavior = true
            let newline = UIKeyCommand(input: "\r", modifierFlags: .shift,
                                       action: #selector(shiftReturn))
            newline.wantsPriorityOverSystemBehavior = true
            let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [],
                                      action: #selector(escapePressed))
            escape.wantsPriorityOverSystemBehavior = true
            // The composer holds focus for the whole chat, so Tab has nowhere
            // to move it — consumed, or the field fills with tab characters.
            let tab = UIKeyCommand(input: "\t", modifierFlags: [],
                                   action: #selector(tabPressed))
            tab.wantsPriorityOverSystemBehavior = true
            let nextChat = UIKeyCommand(input: "\t", modifierFlags: .control,
                                        action: #selector(switchChatForward))
            nextChat.wantsPriorityOverSystemBehavior = true
            let prevChat = UIKeyCommand(input: "\t", modifierFlags: [.control, .shift],
                                        action: #selector(switchChatBackward))
            prevChat.wantsPriorityOverSystemBehavior = true
            let nextBracket = UIKeyCommand(input: "]", modifierFlags: .command,
                                           action: #selector(switchChatForward))
            let prevBracket = UIKeyCommand(input: "[", modifierFlags: .command,
                                           action: #selector(switchChatBackward))
            let bold = UIKeyCommand(input: "b", modifierFlags: .command,
                                    action: #selector(makeBold))
            let italic = UIKeyCommand(input: "i", modifierFlags: .command,
                                      action: #selector(makeItalic))
            let link = UIKeyCommand(input: "k", modifierFlags: .command,
                                    action: #selector(makeLink))
            var commands = (super.keyCommands ?? []) + [send, newline, escape, tab,
                                                        nextChat, prevChat,
                                                        nextBracket, prevBracket,
                                                        bold, italic, link]
            if text.isEmpty {
                let up = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [],
                                      action: #selector(arrowUp))
                up.wantsPriorityOverSystemBehavior = true
                let down = UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [],
                                        action: #selector(arrowDown))
                down.wantsPriorityOverSystemBehavior = true
                commands += [up, down]
            }
            return commands
        }

        @objc private func escapePressed() {
            onEscape()
        }

        @objc private func hardwareReturn() {
            if !onReturn() { insertText("\n") }
        }

        @objc private func shiftReturn() {
            insertText("\n")
        }

        @objc private func tabPressed() {}

        @objc private func switchChatForward() {
            NotificationCenter.default.post(name: .chatSwitchRequested, object: nil,
                                            userInfo: ["forward": true])
        }

        @objc private func switchChatBackward() {
            NotificationCenter.default.post(name: .chatSwitchRequested, object: nil,
                                            userInfo: ["forward": false])
        }

        @objc private func arrowUp() { _ = onArrow(true) }
        @objc private func arrowDown() { _ = onArrow(false) }

        // MARK: - Formatting (the mini-markdown the feed draws)

        @objc private func makeBold() { toggleWrap("**") }
        @objc private func makeItalic() { toggleWrap("*") }

        /// Cmd+K: the selection becomes `[selection](url)`. A URL sitting on
        /// the clipboard fills the target; otherwise the caret lands between
        /// the parentheses to type it.
        @objc private func makeLink() {
            let range = selectedRange
            let selected = (text as NSString).substring(with: range)
            let clip = UIPasteboard.general.string?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url = clip.hasPrefix("http://") || clip.hasPrefix("https://") ? clip : ""
            replace(range, with: "[\(selected)](\(url))")
            if url.isEmpty {
                selectedRange = NSRange(location: range.location + selected.utf16.count + 3,
                                        length: 0)
            }
        }

        /// Wraps the selection in `marker`, or takes an existing wrap off; with
        /// nothing selected the pair is inserted and the caret goes inside.
        private func toggleWrap(_ marker: String) {
            let range = selectedRange
            let selected = (text as NSString).substring(with: range)
            if selected.hasPrefix(marker), selected.hasSuffix(marker),
               selected.count >= marker.count * 2 {
                let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
                replace(range, with: inner)
                selectedRange = NSRange(location: range.location, length: inner.utf16.count)
            } else if range.length > 0 {
                replace(range, with: marker + selected + marker)
                // the selection covers the markers too, so the same key
                // pressed again takes the wrap back off
                selectedRange = NSRange(location: range.location,
                                        length: range.length + 2 * marker.utf16.count)
            } else {
                replace(range, with: marker + marker)
                selectedRange = NSRange(location: range.location + marker.utf16.count, length: 0)
            }
        }

        /// Replacement through the text-input system, so the delegate fires
        /// and the SwiftUI binding follows.
        private func replace(_ range: NSRange, with string: String) {
            guard let start = position(from: beginningOfDocument, offset: range.location),
                  let end = position(from: start, offset: range.length),
                  let textRange = textRange(from: start, to: end) else { return }
            replace(textRange, withText: string)
        }

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
        /// What the view last reported: the one value the binding is allowed
        /// to differ from before it may write into the field.
        var viewText: String = ""
        init(_ p: GrowingTextView) { parent = p }
        func textViewDidChange(_ tv: UITextView) {
            viewText = tv.text
            parent.text = tv.text
            parent.onChange(tv.text)
            tv.viewWithTag(777)?.isHidden = !tv.text.isEmpty
            GrowingTextView.fitScrolling(tv)
            tv.invalidateIntrinsicContentSize()
        }
    }
}
