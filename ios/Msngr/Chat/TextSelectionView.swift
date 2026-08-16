import SwiftUI
import UIKit

/// Text selection mode for a message: the system selection with its loupe, its handles
/// and the «Скопировать» menu. The whole text is shown and selected by default.
struct TextSelectionView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableText(text: text)
                .padding(.horizontal, 16)
                .navigationTitle("Выделение текста")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { dismiss() }
                    }
                }
        }
        .presentationDragIndicator(.visible)
    }
}

/// A read-only UITextView: editing is off while selection and its menu stay on.
private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true
        tv.backgroundColor = .clear
        tv.font = Theme.Text.bubble.uiFont
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.dataDetectorTypes = [.link, .phoneNumber]
        tv.accessibilityIdentifier = "chat.textSelection"
        tv.text = text
        // the whole text is selected right away, so no long press is needed to start
        DispatchQueue.main.async {
            tv.becomeFirstResponder()
            tv.selectAll(nil)
        }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text { tv.text = text }
    }
}
