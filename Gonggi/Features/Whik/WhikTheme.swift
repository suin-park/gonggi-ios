import SwiftUI

/// WHIK: 3D Scanner look (design: WHIK 3D 스캐너 앱 3화면 시안). Deep teal background, mint accent, white logo.
enum WhikColors {
    static let background = Color(red: 0x0C / 255, green: 0x1D / 255, blue: 0x23 / 255)   // #0C1D23 (brand)
    static let surface = Color(red: 0x13 / 255, green: 0x29 / 255, blue: 0x2C / 255)      // cards, tab bar
    static let surfaceRaised = Color(red: 0x1A / 255, green: 0x33 / 255, blue: 0x37 / 255)
    static let border = Color.white.opacity(0.10)
    static let mint = Color(red: 0xB2 / 255, green: 0xEE / 255, blue: 0xE0 / 255)          // #B2EEE0
    static let onMint = Color(red: 0x06 / 255, green: 0x16 / 255, blue: 0x1A / 255)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.68)
    static let textTertiary = Color.white.opacity(0.45)
    static let danger = Color(red: 1.0, green: 0.48, blue: 0.45)
}

enum WhikFont {
    static func largeTitle() -> Font { .system(size: 34, weight: .bold) }
    static func cardTitle() -> Font { .system(size: 21, weight: .bold) }
    static func title(_ size: CGFloat = 26) -> Font { .system(size: size, weight: .bold) }
    static func body(_ weight: Font.Weight = .regular) -> Font { .system(.body, design: .default).weight(weight) }
    static func subheadline() -> Font { .subheadline }
    static func caption() -> Font { .footnote }
}

/// Vector logo from the brand kit (`WhikLogoWhite`, preserved vector PDF). Width only: the PDF keeps its ratio.
struct WhikLogo: View {
    var width: CGFloat = 150

    var body: some View {
        Image("WhikLogoWhite")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: width)
            .accessibilityLabel("WHIK 3D Scanner")
    }
}

/// Circular outline icon button used on the photo headers (profile, arrow).
struct WhikCircleButton: View {
    let systemImage: String
    var size: CGFloat = 44
    var label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(WhikColors.textPrimary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.black.opacity(0.18)))
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Mint pill segmented control (Spaces / Objects, All / Spaces / Objects).
struct WhikSegmented<Value: Hashable>: View {
    let items: [(Value, String)]
    @Binding var selection: Value
    var stretch = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let selected = item.0 == selection
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = item.0 }
                } label: {
                    Text(item.1)
                        .font(.system(.subheadline, design: .default).weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? WhikColors.onMint : WhikColors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 40)
                        .frame(maxWidth: stretch ? .infinity : nil)
                        .background(Capsule().fill(selected ? WhikColors.mint : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(Capsule().fill(WhikColors.background.opacity(0.78)))
        .overlay(Capsule().stroke(WhikColors.border, lineWidth: 1))
    }
}

/// Separate-chip filter row (Library: All / Spaces / Objects).
struct WhikChips<Value: Hashable>: View {
    let items: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let selected = item.0 == selection
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = item.0 }
                } label: {
                    Text(item.1)
                        .font(.system(.subheadline).weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? WhikColors.onMint : WhikColors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(selected ? WhikColors.mint : WhikColors.surface))
                        .overlay(Capsule().stroke(selected ? Color.clear : WhikColors.border, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// Bottom-weighted dark gradient so white text stays readable over photos.
struct WhikPhotoScrim: View {
    var top: Double = 0.0
    var bottom: Double = 0.78

    var body: some View {
        LinearGradient(
            colors: [Color.black.opacity(top), Color.black.opacity(0), Color.black.opacity(bottom)],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}
