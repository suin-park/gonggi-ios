import SwiftUI

/// Shared in-capture chrome for the three WHIK capture modes (360° Space, 3D Space, 3D Object): the same top bar,
/// one guide card, one progress ring with the photo count and one action button, always in the same places.
/// Each flow keeps its own capture logic and only maps its state onto these pieces.
enum WhikCaptureTone: Equatable {
    case normal
    case warning
    case done
}

struct WhikCaptureGuide: Equatable {
    var title: String
    var subtitle: String?
    var tone: WhikCaptureTone = .normal
}

enum WhikCaptureColors {
    static let warning = Color(red: 1.0, green: 0.78, blue: 0.36)
    static let done = Color(red: 0.47, green: 0.90, blue: 0.62)

    static func accent(_ tone: WhikCaptureTone) -> Color {
        switch tone {
        case .normal: return WhikColors.mint
        case .warning: return warning
        case .done: return done
        }
    }
}

/// Close on the left, the mode name (same as the Capture tab) in the middle, optional help on the right.
struct WhikCaptureTopBar: View {
    let title: String
    let onClose: () -> Void
    var onHelp: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center) {
            WhikCircleButton(systemImage: "xmark", size: 40, label: L("Close"), action: onClose)
            Spacer(minLength: 8)
            Text(title)
                .font(.headline)
                .foregroundStyle(WhikColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let onHelp {
                WhikCircleButton(systemImage: "questionmark", size: 40, label: L("Capture guide"), action: onHelp)
            } else {
                Color.clear.frame(width: 40, height: 40).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
    }
}

/// The one guidance card: a short instruction and an optional supporting line. The border shows the tone.
struct WhikCaptureGuideCard: View {
    let guide: WhikCaptureGuide

    var body: some View {
        VStack(spacing: 6) {
            Text(guide.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(WhikColors.textPrimary)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
            if let subtitle = guide.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.62)))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(WhikCaptureColors.accent(guide.tone).opacity(0.75), lineWidth: 1.5)
        )
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }
}

/// Progress ring (0...1) for the bottom panel.
struct WhikCaptureProgressRing: View {
    let fraction: Double
    var tone: WhikCaptureTone = .normal
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 5)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(WhikCaptureColors.accent(tone), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if tone == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.32, weight: .bold))
                    .foregroundStyle(WhikCaptureColors.done)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Count (e.g. "84 photos") over a short status line, next to the ring.
struct WhikCaptureCountLabel: View {
    let count: String
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(count)
                .font(.headline.monospacedDigit())
                .foregroundStyle(WhikColors.textPrimary)
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(WhikColors.textSecondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Start / end button. `prominent` is mint (start, or finish when the capture is ready).
struct WhikCaptureActionButton: View {
    let title: String
    var systemImage: String? = nil
    var prominent = true
    var fullWidth = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.headline)
            .foregroundStyle(prominent ? WhikColors.onMint : WhikColors.textPrimary)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(Capsule().fill(prominent ? WhikColors.mint : Color.white.opacity(0.16)))
            .overlay(Capsule().stroke(Color.white.opacity(prominent ? 0 : 0.35), lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Bottom panel container (same shape in every mode).
struct WhikCapturePanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content.whikCapturePanelStyle()
    }
}

extension View {
    func whikCapturePanelStyle() -> some View {
        padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(WhikColors.border, lineWidth: 1))
            .padding(.horizontal, 16)
    }
}

/// Keeps a warning on screen for a moment so a short-lived condition does not make the card flicker.
struct WhikCaptureGuideHold {
    static let holdSec: TimeInterval = 2.0
    private(set) var held: WhikCaptureGuide?
    private var until: Date = .distantPast

    mutating func resolve(_ next: WhikCaptureGuide, at now: Date = Date()) -> WhikCaptureGuide {
        if next.tone == .warning {
            held = next
            until = now.addingTimeInterval(Self.holdSec)
            return next
        }
        if let held, now < until { return held }
        held = nil
        return next
    }
}
