import SwiftUI
import UIKit

struct AppearanceView: View {
    @AppStorage(ThemeKey.appearance) private var appearance = AppearanceMode.system
    @AppStorage(ThemeKey.accent) private var accent = AccentChoice.blue
    @AppStorage(ThemeKey.cardNightMode) private var cardNight = CardNightMode.followTheme
    @AppStorage(ThemeKey.cardFontScale) private var fontScale = 1.0
    @AppStorage(ThemeKey.customCSS) private var customCSS = ""
    @AppStorage(ThemeKey.buttonStyle) private var buttonStyle = AnswerButtonStyle.tinted
    @AppStorage(ThemeKey.buttonSize) private var buttonSize = AnswerButtonSize.regular
    @AppStorage(ThemeKey.haptics) private var haptics = true
    @AppStorage(ThemeKey.tapToReveal) private var tapToReveal = false
    @AppStorage(ThemeKey.colorfulDeckCounts) private var colorfulCounts = true
    @State private var currentIcon = UIApplication.shared.alternateIconName

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Accent Colour")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                        ForEach(AccentChoice.allCases) { choice in
                            Button {
                                withAnimation(.snappy) { accent = choice }
                            } label: {
                                Circle()
                                    .fill(choice.color.gradient)
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        if accent == choice {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .overlay(Circle().strokeBorder(.primary.opacity(accent == choice ? 0.35 : 0), lineWidth: 2).padding(-4))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.title)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(AppIconChoice.all) { icon in
                            Button {
                                setIcon(icon)
                            } label: {
                                VStack(spacing: 6) {
                                    Image(icon.preview)
                                        .resizable()
                                        .frame(width: 64, height: 64)
                                        .clipShape(.rect(cornerRadius: 15))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 18)
                                                .strokeBorder(Color.accentColor, lineWidth: currentIcon == icon.name ? 3 : 0)
                                                .padding(-4)
                                        )
                                    Text(icon.title)
                                        .font(.caption)
                                        .foregroundStyle(currentIcon == icon.name ? .primary : .secondary)
                                }
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } header: {
                Text("App Icon")
            } footer: {
                Text("Classic also has dark and tinted versions for iOS home screen styles.")
            }

            Section {
                Picker("Card colours", selection: $cardNight) {
                    ForEach(CardNightMode.allCases) { Text($0.title).tag($0) }
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("Card text size")
                        Spacer()
                        Text("\(Int((fontScale * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $fontScale, in: 0.7...2.0, step: 0.05) {
                        Text("Card text size")
                    } minimumValueLabel: {
                        Image(systemName: "textformat.size.smaller")
                    } maximumValueLabel: {
                        Image(systemName: "textformat.size.larger")
                    }
                }
                Toggle("Tap card to show answer", isOn: $tapToReveal)
            } header: {
                Text("Cards")
            } footer: {
                Text("Card styling comes from each note type's CSS. These settings adjust it on this device only.")
            }

            Section {
                Picker("Style", selection: $buttonStyle) {
                    ForEach(AnswerButtonStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Size", selection: $buttonSize) {
                    ForEach(AnswerButtonSize.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Haptic feedback", isOn: $haptics)
                AnswerButtonsPreview(style: buttonStyle, size: buttonSize)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            } header: {
                Text("Answer Buttons")
            }

            Section("Deck List") {
                Toggle("Colour due counts", isOn: $colorfulCounts)
            }

            Section {
                TextEditor(text: $customCSS)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 140)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .overlay(alignment: .topLeading) {
                        if customCSS.isEmpty {
                            Text(".card { font-family: Georgia; }\n.cloze { color: orange; }")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("Custom Card CSS")
            } footer: {
                Text("Added after every note type's own CSS, on this device only. It isn't synced. Use .nightMode to target dark cards.")
            }

            Section {
                Button("Reset Appearance", role: .destructive) { reset() }
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setIcon(_ icon: AppIconChoice) {
        guard UIApplication.shared.supportsAlternateIcons, currentIcon != icon.name else { return }
        UIApplication.shared.setAlternateIconName(icon.name) { error in
            if error == nil { currentIcon = icon.name }
        }
    }

    private func reset() {
        appearance = .system
        accent = .blue
        cardNight = .followTheme
        fontScale = 1
        customCSS = ""
        buttonStyle = .tinted
        buttonSize = .regular
        haptics = true
        tapToReveal = false
        colorfulCounts = true
    }
}

/// Shows the answer buttons with the chosen style.
struct AnswerButtonsPreview: View {
    let style: AnswerButtonStyle
    let size: AnswerButtonSize

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Array(zip(["Again", "Hard", "Good", "Easy"], [Color.red, .orange, .green, .blue])), id: \.0) { title, color in
                    AnswerButtonLabel(title: title, interval: ["<1m", "6m", "10m", "4d"][["Again", "Hard", "Good", "Easy"].firstIndex(of: title)!],
                                      color: color, style: style, size: size, showInterval: true)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// One answer button's face, in the chosen style.
struct AnswerButtonLabel: View {
    let title: String
    let interval: String
    let color: Color
    let style: AnswerButtonStyle
    let size: AnswerButtonSize
    let showInterval: Bool

    var body: some View {
        VStack(spacing: 2) {
            if showInterval {
                Text(interval)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(style == .solid ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
            Text(title)
                .font(size == .large ? .title3.weight(.semibold) : .headline)
                .foregroundStyle(style == .solid ? .white : color)
        }
        .frame(maxWidth: .infinity)
        .frame(height: size.height)
        .contentShape(.rect(cornerRadius: 22))
        .glassEffect(glass, in: .rect(cornerRadius: 22))
    }

    private var glass: Glass {
        switch style {
        case .tinted: return .regular.tint(color.opacity(0.18)).interactive()
        case .clear: return .regular.interactive()
        case .solid: return .regular.tint(color).interactive()
        }
    }
}
