import SwiftUI
import UIKit

// 사진 칸의 상태 구분: 없음, 불러오는 중(제한 시간 있음), 불러옴, 실패(다시 시도).
// 사진이 없으면 큰 빈 상자를 두지 않는다. 그 판단은 호출하는 화면이 `KmoImageSlot.none`으로 한다.

actor KmoImageLoader {
    static let shared = KmoImageLoader()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 60
        return c
    }()

    /// Signed links change on every request; the object path (without the query) identifies the picture.
    private func cacheKey(_ url: URL) -> NSString {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.query = nil
        return (c?.string ?? url.absoluteString) as NSString
    }

    func image(for urlString: String) async -> UIImage? {
        guard let url = URL(string: urlString), url.scheme == "https" else { return nil }
        let key = cacheKey(url)
        if let hit = cache.object(forKey: key) { return hit }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data) else { return nil }
            cache.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }
}

private struct KmoPhotoTaskKey: Hashable {
    var url: String?
    var attempt: Int
}

/// A real photo with its loading states. Shows nothing at all when there is no photo; the caller lays out the
/// small substitute.
struct KmoPhotoView: View {
    let urlString: String?
    var height: CGFloat = 120
    var cornerRadius: CGFloat = 12
    var fill = true

    @State private var slot: KmoImageSlot
    @State private var image: UIImage?
    @State private var attempt = 0

    init(urlString: String?, height: CGFloat = 120, cornerRadius: CGFloat = 12, fill: Bool = true) {
        self.urlString = urlString
        self.height = height
        self.cornerRadius = cornerRadius
        self.fill = fill
        _slot = State(initialValue: KmoImageSlot.initial(urlString: urlString))
    }

    var body: some View {
        Group {
            switch slot {
            case .none:
                EmptyView()
            case .loading:
                ZStack {
                    KmoColors.field
                    ProgressView().tint(KmoColors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
            case .loaded:
                if let image {
                    Group {
                        if fill {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipped()
                }
            case .failed:
                VStack(spacing: 6) {
                    Text("사진을 불러오지 못했어요")
                        .font(.footnote)
                        .foregroundStyle(KmoColors.textSecondary)
                    Button { attempt += 1 } label: {
                        Text("다시 시도")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(KmoColors.accent)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(KmoColors.field)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: KmoPhotoTaskKey(url: urlString, attempt: attempt)) {
            guard let urlString, KmoImageSlot.initial(urlString: urlString) != .none else {
                slot = .none
                image = nil
                return
            }
            slot = .loading
            if let loaded = await KmoImageLoader.shared.image(for: urlString) {
                image = loaded
                slot = .loaded
            } else if !Task.isCancelled {
                slot = .failed
            }
        }
    }
}

/// 제품 사진. 정사각 칸 안에 맞춰 넣고, 사진이 없을 때는 호출하는 쪽이 이 뷰를 쓰지 않는다.
struct KmoProductThumb: View {
    let urlString: String?
    var size: CGFloat = 64

    var body: some View {
        KmoPhotoView(urlString: urlString, height: size, cornerRadius: 10, fill: false)
            .frame(width: size)
            .background(KmoColors.field)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

enum KmoCoverImage {
    /// Scaled down (never up) and compressed until it fits the server limit; nil only when nothing fits.
    static func jpeg(from image: UIImage) -> Data? {
        let w = Double(image.size.width), h = Double(image.size.height)
        guard w > 0, h > 0 else { return nil }
        let target = KmoCoverPolicy.targetLongSide(width: w, height: h)
        let scale = target / max(w, h)
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        for q in KmoCoverPolicy.qualities {
            if let data = resized.jpegData(compressionQuality: q), data.count <= KmoCoverPolicy.maxBytes { return data }
        }
        return nil
    }
}

/// 카메라 촬영. 사진 선택은 PhotosPicker를 쓴다.
struct KmoCameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    let onCancel: () -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: KmoCameraPicker
        init(_ parent: KmoCameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) } else { parent.onCancel() }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}
