import SwiftUI

/// Date and time picker for a scheduled send, reused for the initial pick
/// (long press on the send button) and for moving an already-scheduled
/// message to a new time.
struct SchedulePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    let onConfirm: (Date) -> Void

    init(initial: Date = Date().addingTimeInterval(60), onConfirm: @escaping (Date) -> Void) {
        _date = State(initialValue: initial)
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            DatePicker("", selection: $date, in: Date()...,
                      displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.wheel)
                .labelsHidden()
                .padding()
                .navigationTitle(String(localized: "Schedule Send"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) {
                            onConfirm(date)
                            dismiss()
                        }
                        .accessibilityIdentifier("chat.schedule.confirm")
                    }
                }
        }
        .presentationDetents([.medium])
    }
}
