import AppKit
import SwiftUI

enum CommandCenterPalette {
    static let window = Color(red: 0.05, green: 0.045, blue: 0.035)
    static let surface = Color(red: 0.075, green: 0.07, blue: 0.055)
    static let panel = Color(red: 0.10, green: 0.09, blue: 0.075)
    static let panelRaised = Color(red: 0.125, green: 0.11, blue: 0.09)
    static let border = Color(red: 0.18, green: 0.16, blue: 0.13)
    static let primary = Color(red: 0.34, green: 0.88, blue: 0.68)
    static let primaryForeground = Color(red: 0.03, green: 0.12, blue: 0.09)
    static let primaryDim = Color(red: 0.02, green: 0.38, blue: 0.34)
    static let cyan = Color(red: 0.39, green: 0.82, blue: 0.83)
    static let warning = Color(red: 0.96, green: 0.70, blue: 0.25)
    static let danger = Color(red: 0.94, green: 0.38, blue: 0.38)
    static let purple = Color(red: 0.76, green: 0.55, blue: 0.90)
    static let text = Color(red: 0.92, green: 0.89, blue: 0.84)
    static let secondaryText = Color(red: 0.68, green: 0.64, blue: 0.58)
    static let mutedText = Color(red: 0.45, green: 0.42, blue: 0.36)
}

enum CommandCenterTypography {
    static let eyebrow = Font.system(size: 12, weight: .bold, design: .monospaced)
    static let mono = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let chip = Font.system(size: 12, weight: .semibold, design: .monospaced)
    static let button = Font.system(size: 13, weight: .semibold)
    static let title = Font.system(size: 17, weight: .semibold)
    static let body = Font.system(size: 16, weight: .regular)
    static let transcript = Font.system(size: 17, weight: .regular)
    static let secondaryBody = Font.system(size: 15, weight: .regular)
    static let caption = Font.system(size: 12, weight: .regular)
    static let sectionTitle = Font.system(size: 13, weight: .bold)
}

enum CommandCenterNativeAppearance {
    static func apply() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.windows.forEach { window in
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView?.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

private struct CommandCenterAppTheme: ViewModifier {
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(.dark)
            .environment(\.colorScheme, .dark)
            .foregroundStyle(CommandCenterPalette.text)
            .tint(CommandCenterPalette.primary)
            .background(CommandCenterPalette.window)
            .onAppear {
                CommandCenterNativeAppearance.apply()
            }
    }
}

extension View {
    func commandCenterAppTheme() -> some View {
        modifier(CommandCenterAppTheme())
    }

    func commandCenterScrollableSurface(_ background: Color = CommandCenterPalette.window) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(background)
            .environment(\.colorScheme, .dark)
            .foregroundStyle(CommandCenterPalette.text)
            .tint(CommandCenterPalette.primary)
    }
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

struct CommandCenterPageHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(CommandCenterTypography.title)
                .foregroundStyle(CommandCenterPalette.text)
            if let subtitle {
                Text(subtitle)
                    .font(CommandCenterTypography.caption)
                    .foregroundStyle(CommandCenterPalette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(CommandCenterPalette.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CommandCenterPalette.border)
                .frame(height: 1)
        }
    }
}

struct CommandCenterScrollView<Content: View>: View {
    private let axes: Axis.Set
    private let showsIndicators: Bool
    private let background: Color
    private let content: Content

    init(
        _ axes: Axis.Set = .vertical,
        showsIndicators: Bool = true,
        background: Color = CommandCenterPalette.window,
        @ViewBuilder content: () -> Content
    ) {
        self.axes = axes
        self.showsIndicators = showsIndicators
        self.background = background
        self.content = content()
    }

    var body: some View {
        ScrollView(axes, showsIndicators: showsIndicators) {
            content
        }
        .commandCenterScrollableSurface(background)
    }
}

struct CommandCenterTextEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(CommandCenterTypography.secondaryBody)
            .foregroundStyle(CommandCenterPalette.text)
            .commandCenterScrollableSurface(CommandCenterPalette.panelRaised)
            .frame(width: 420, height: 130)
            .padding(8)
            .background(CommandCenterPalette.panelRaised)
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
            .font(CommandCenterTypography.chip)
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
            .font(CommandCenterTypography.button)
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
            return CommandCenterPalette.primaryForeground
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

struct CommandCenterIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CommandCenterTypography.button)
            .foregroundStyle(CommandCenterPalette.secondaryText)
            .frame(width: 28, height: 28)
            .background(CommandCenterPalette.panelRaised.opacity(configuration.isPressed ? 0.65 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(CommandCenterPalette.border, lineWidth: 1)
            )
    }
}

extension Text {
    func commandCenterEyebrow() -> some View {
        self
            .font(CommandCenterTypography.eyebrow)
            .tracking(1.6)
            .foregroundStyle(CommandCenterPalette.primary)
            .textCase(.uppercase)
    }

    func commandCenterMono() -> some View {
        self
            .font(CommandCenterTypography.mono)
            .foregroundStyle(CommandCenterPalette.mutedText)
    }

    func commandCenterBody() -> some View {
        self
            .font(CommandCenterTypography.body)
            .foregroundStyle(CommandCenterPalette.text)
    }

    func commandCenterCaption(_ color: Color = CommandCenterPalette.secondaryText) -> some View {
        self
            .font(CommandCenterTypography.caption)
            .foregroundStyle(color)
    }

    func commandCenterTitle() -> some View {
        self
            .font(CommandCenterTypography.title)
            .foregroundStyle(CommandCenterPalette.text)
    }

    func commandCenterTranscript(_ color: Color = CommandCenterPalette.text) -> some View {
        self
            .font(CommandCenterTypography.transcript)
            .foregroundStyle(color)
    }
}
