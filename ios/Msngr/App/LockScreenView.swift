import SwiftUI

/// Passcode screen: dots, keypad, Face ID, shake on a wrong code.
struct LockScreenView: View {
    @EnvironmentObject var app: AppState
    @State private var entered = ""
    @State private var shake = 0

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Enter the passcode")
                    .font(.headline)
                HStack(spacing: 18) {
                    ForEach(0..<4, id: \.self) { i in
                        Circle()
                            .strokeBorder(.secondary, lineWidth: 1.2)
                            .background(Circle().fill(i < entered.count ? Color.primary : .clear))
                            .frame(width: 14, height: 14)
                    }
                }
                .modifier(ShakeEffect(shakes: CGFloat(shake)))
                .animation(.linear(duration: 0.4), value: shake)

                PinPad { key in
                    handle(key)
                }
            }
        }
        .onAppear { app.tryBiometrics() }
    }

    private func handle(_ key: PinKey) {
        switch key {
        case .digit(let d):
            guard entered.count < 4 else { return }
            entered.append(d)
            Haptics.light()
            if entered.count == 4 {
                if PinStore.verify(entered) {
                    Haptics.success()
                    app.unlock()
                } else {
                    shake += 1
                    Haptics.rigid()
                    entered = ""
                }
            }
        case .delete:
            if !entered.isEmpty { entered.removeLast() }
        case .biometrics:
            app.tryBiometrics()
        }
    }
}

enum PinKey {
    case digit(String), delete, biometrics
}

struct PinPad: View {
    let action: (PinKey) -> Void
    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["face", "0", "del"]]

    var body: some View {
        VStack(spacing: 16) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(row, id: \.self) { key in
                        Button {
                            switch key {
                            case "del": action(.delete)
                            case "face": action(.biometrics)
                            default: action(.digit(key))
                            }
                        } label: {
                            Group {
                                switch key {
                                case "del": Image(systemName: "delete.left")
                                case "face":
                                    if PinStore.biometricsEnabled() {
                                        Image(systemName: "faceid")
                                    } else {
                                        Color.clear
                                    }
                                default: Text(key).textRole(Theme.Text.largeControl)
                                }
                            }
                            .frame(width: TypeScale.scaled(74, relativeTo: .title2, max: 88),
                                   height: TypeScale.scaled(74, relativeTo: .title2, max: 88))
                            .background(key == "face" || key == "del" ? Color.clear : Color.primary.opacity(0.06))
                            .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(shakes * .pi * 4), y: 0))
    }
}

/// Blurs the content in the app switcher.
struct PrivacyShieldView: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .ignoresSafeArea()
            .overlay(Image(systemName: "message.fill").font(.system(size: 44))
                .foregroundStyle(.secondary).accessibilityHidden(true))
    }
}
