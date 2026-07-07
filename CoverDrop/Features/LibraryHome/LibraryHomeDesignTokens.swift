import SwiftUI

enum LibraryHomeDesignToken {
    static let bgPrimary = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    static let bgSecondary = Color(red: 37 / 255, green: 37 / 255, blue: 37 / 255)
    static let bgTertiary = Color(red: 45 / 255, green: 45 / 255, blue: 45 / 255)
    static let bgElevated = Color(red: 58 / 255, green: 58 / 255, blue: 58 / 255)

    static let textPrimary = Color.white
    static let textSecondary = Color(red: 160 / 255, green: 160 / 255, blue: 160 / 255)
    static let textTertiary = Color(red: 110 / 255, green: 110 / 255, blue: 115 / 255)

    static let accent = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
    static let accentBg = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255).opacity(0.12)
    static let success = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let successBg = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255).opacity(0.12)
    static let warning = Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255)
    static let warningBg = Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255).opacity(0.12)
    static let destructive = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)
    static let destructiveBg = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255).opacity(0.12)

    static let border = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.15)

    static let radiusSm: CGFloat = 6
    static let radiusMd: CGFloat = 8
    static let radiusLg: CGFloat = 12

    static let shadowCard = Color.black.opacity(0.3)
    static let shadowElevated = Color.black.opacity(0.5)
}

struct LibraryPanelButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case subtle
        case destructive
    }

    let kind: Kind
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(foregroundColor)
            .frame(minHeight: height)
            .padding(.horizontal, kind == .subtle ? 0 : 12)
            .background(background(configuration: configuration))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary:
            LibraryHomeDesignToken.textPrimary
        case .secondary:
            LibraryHomeDesignToken.textSecondary
        case .subtle:
            LibraryHomeDesignToken.textSecondary
        case .destructive:
            LibraryHomeDesignToken.destructive
        }
    }

    @ViewBuilder
    private func background(configuration: Configuration) -> some View {
        switch kind {
        case .primary:
            RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusMd)
                .fill(LibraryHomeDesignToken.accent)
        case .secondary:
            RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusMd)
                .fill(configuration.isPressed ? LibraryHomeDesignToken.bgElevated : LibraryHomeDesignToken.bgTertiary)
                .overlay {
                    RoundedRectangle(cornerRadius: LibraryHomeDesignToken.radiusMd)
                        .stroke(LibraryHomeDesignToken.borderStrong)
                }
        case .subtle, .destructive:
            Color.clear
        }
    }
}

extension ButtonStyle where Self == LibraryPanelButtonStyle {
    static func coverDropPrimary(height: CGFloat = 32) -> LibraryPanelButtonStyle {
        LibraryPanelButtonStyle(kind: .primary, height: height)
    }

    static func coverDropSecondary(height: CGFloat = 32) -> LibraryPanelButtonStyle {
        LibraryPanelButtonStyle(kind: .secondary, height: height)
    }

    static var coverDropSubtle: LibraryPanelButtonStyle {
        LibraryPanelButtonStyle(kind: .subtle)
    }

    static var coverDropDestructive: LibraryPanelButtonStyle {
        LibraryPanelButtonStyle(kind: .destructive)
    }
}

struct LibraryStatusPill: View {
    let title: String
    let systemImage: String?
    let foreground: Color
    let background: Color
    var border: Color = .clear

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(title)
                .lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(background, in: Capsule())
        .overlay {
            Capsule().stroke(border)
        }
    }
}

struct LibraryDividerLine: View {
    var body: some View {
        Rectangle()
            .fill(LibraryHomeDesignToken.border)
            .frame(height: 1)
    }
}
