import SwiftUI

enum CommandCenterPalette {
    static let window = Color(red: 0.05, green: 0.045, blue: 0.035)
    static let surface = Color(red: 0.075, green: 0.07, blue: 0.055)
    static let panel = Color(red: 0.10, green: 0.09, blue: 0.075)
    static let panelRaised = Color(red: 0.125, green: 0.11, blue: 0.09)
    static let border = Color(red: 0.18, green: 0.16, blue: 0.13)
    static let primary = Color(red: 0.34, green: 0.88, blue: 0.68)
    static let primaryDim = Color(red: 0.02, green: 0.38, blue: 0.34)
    static let cyan = Color(red: 0.39, green: 0.82, blue: 0.83)
    static let warning = Color(red: 0.96, green: 0.70, blue: 0.25)
    static let danger = Color(red: 0.94, green: 0.38, blue: 0.38)
    static let purple = Color(red: 0.76, green: 0.55, blue: 0.90)
    static let text = Color(red: 0.92, green: 0.89, blue: 0.84)
    static let secondaryText = Color(red: 0.68, green: 0.64, blue: 0.58)
    static let mutedText = Color(red: 0.45, green: 0.42, blue: 0.36)
}

struct CommandCenterPanel<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(CommandCenterPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(CommandCenterPalette.border, lineWidth: 1)
            )
    }
}

struct SettingsCommandCenterPanel<Content: View>: View {
    let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        CommandCenterPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).commandCenterEyebrow()
                content
            }
        }
    }
}

struct CommandCenterChip: View {
    let title: String
    var tint: Color = CommandCenterPalette.secondaryText
    var filled: Bool = false

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(filled ? tint.opacity(0.16) : CommandCenterPalette.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(0.45), lineWidth: 1)
            )
    }
}

struct CommandCenterActionButtonStyle: ButtonStyle {
    enum Variant {
        case primary
        case secondary
        case danger
    }

    var variant: Variant = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: 34)
            .background(backgroundColor.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
    }

    private var foregroundColor: Color {
        switch variant {
        case .primary:
            return Color(red: 0.03, green: 0.12, blue: 0.09)
        case .secondary:
            return CommandCenterPalette.text
        case .danger:
            return CommandCenterPalette.danger
        }
    }

    private var backgroundColor: Color {
        switch variant {
        case .primary:
            return CommandCenterPalette.primary
        case .secondary:
            return CommandCenterPalette.panelRaised
        case .danger:
            return CommandCenterPalette.danger.opacity(0.12)
        }
    }

    private var borderColor: Color {
        switch variant {
        case .primary:
            return CommandCenterPalette.primary
        case .secondary:
            return CommandCenterPalette.border
        case .danger:
            return CommandCenterPalette.danger.opacity(0.5)
        }
    }
}

extension Text {
    func commandCenterEyebrow() -> some View {
        self
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(CommandCenterPalette.primary)
            .textCase(.uppercase)
    }

    func commandCenterMono() -> some View {
        self
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(CommandCenterPalette.mutedText)
    }

    func commandCenterBody() -> some View {
        self
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(CommandCenterPalette.text)
    }
}
