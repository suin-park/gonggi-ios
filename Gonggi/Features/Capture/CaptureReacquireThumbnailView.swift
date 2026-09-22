import SwiftUI
import UIKit

/// REACQUIRE reference card — continuityAnchor thumbnail (memory JPEG), not reconstruction/latest KF.
struct CaptureReacquireThumbnailView: View {
    let jpegData: Data
    let title: String
    let guidance: String
    let signedYawDeg: Double?
    let proximity: Double

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if let ui = UIImage(data: jpegData) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 96)
                        .clipped()
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(borderColor, lineWidth: 3)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if let yaw = signedYawDeg, abs(yaw) >= 4 {
                    Image(systemName: yaw > 0 ? "arrow.right.circle.fill" : "arrow.left.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(.white.opacity(0.85))
                Text(guidance)
                    .font(GonggiTypography.body(14))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.black.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(guidance)")
    }

    private var borderColor: Color {
        // Closer recovery → greener border.
        let p = min(1, max(0, proximity))
        return Color(
            red: 1 - 0.55 * p,
            green: 0.35 + 0.55 * p,
            blue: 0.25
        )
    }
}
