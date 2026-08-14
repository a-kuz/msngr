import SwiftUI
import UIKit

/// Режим выделения текста сообщения: системный выбор с лупой, маркерами и
/// меню «Скопировать». Текст открыт целиком, выделен по умолчанию.
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

/// UITextView только для чтения: редактирование выключено, выделение и меню — нет.
private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true
        tv.backgroundColor = .clear
        tv.font = .systemFont(ofSize: 17)
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.dataDetectorTypes = [.link, .phoneNumber]
        tv.accessibilityIdentifier = "chat.textSelection"
        tv.text = text
        // весь текст выделен сразу: длинное нажатие для старта выбора не нужно
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
