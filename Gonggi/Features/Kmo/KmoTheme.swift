import SwiftUI

// 커모 화면 공통 색과 부품. 짙은 청회색 바탕, 한 단계 밝은 카드, 차분한 청록 버튼.
// 글씨는 시스템 고딕 계열의 동적 글꼴만 쓴다(시스템 글자 크기 설정을 따른다).

enum KmoColors {
    static let background = Color(red: 0.055, green: 0.115, blue: 0.140)
    static let card = Color(red: 0.090, green: 0.165, blue: 0.190)
    static let field = Color(red: 0.070, green: 0.135, blue: 0.160)
    static let stroke = Color.white.opacity(0.10)
    static let textPrimary = Color(red: 0.93, green: 0.95, blue: 0.95)
    static let textSecondary = Color(red: 0.70, green: 0.77, blue: 0.79)
    static let accent = Color(red: 0.49, green: 0.84, blue: 0.77)
    static let onAccent = Color(red: 0.04, green: 0.13, blue: 0.14)
    static let warning = Color(red: 0.96, green: 0.65, blue: 0.40)
}

struct KmoBackground: View {
    var body: some View {
        KmoColors.background.ignoresSafeArea()
    }
}

extension View {
    func kmoCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KmoColors.card)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KmoColors.stroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 큰 청록 버튼. 최소 높이 56, 글씨가 커지면 함께 늘어난다.
struct KmoPrimaryButton: View {
    let title: String
    var isBusy = false
    let action: () -> Void

    init(title: String, isBusy: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isBusy = isBusy
        self.action = action
    }

    /// 기존 화면의 호출 형태. 장식 아이콘은 쓰지 않는다.
    init(title: String, icon: String, action: @escaping () -> Void) {
        self.init(title: title, isBusy: false, action: action)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isBusy { ProgressView().tint(KmoColors.onAccent) }
                Text(title)
                    .font(.headline.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(KmoColors.onAccent)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 12)
            .background(KmoColors.accent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }
}

/// 보조 버튼: 카드 바탕, 글씨만.
struct KmoSecondaryButton: View {
    let title: String
    let action: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    init(title: String, icon: String, action: @escaping () -> Void) {
        self.init(title: title, action: action)
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(KmoColors.textPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 52)
                .padding(.horizontal, 12)
                .background(KmoColors.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KmoColors.stroke, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct KmoSectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.title3.weight(.bold))
            .foregroundStyle(KmoColors.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 실제 제품 사진. 사진이 없거나 못 불러오면 단색 기본 상태.
struct KmoRemoteImage: View {
    let urlString: String?
    var size: CGSize
    var fit = true

    var body: some View {
        Group {
            if let urlString, let url = URL(string: urlString), url.scheme == "https" {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        if fit { image.resizable().scaledToFit() } else { image.resizable().scaledToFill() }
                    default:
                        KmoColors.field
                    }
                }
            } else {
                KmoColors.field
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// 카드 윗부분을 채우는 사진. 폭은 카드에 맞추고, 사진이 없으면 단색.
struct KmoBannerImage: View {
    let urlString: String?

    var body: some View {
        ZStack {
            KmoColors.field
            if let urlString, let url = URL(string: urlString), url.scheme == "https" {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .clipped()
        .accessibilityHidden(true)
    }
}
