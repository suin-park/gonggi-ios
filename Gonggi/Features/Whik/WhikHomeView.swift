import SwiftUI
import UIKit

enum WhikLayout {
    /// Space kept free above the floating tab bar.
    static let tabBarClearance: CGFloat = 104
    static let sideInset: CGFloat = 20
}

/// Home: photo-led sample browser. Open without signing in.
struct WhikHomeView: View {
    let onProfile: () -> Void
    @State private var category: WhikSample.Category = .spaces
    @State private var page: [WhikSample.Category: String] = [:]
    @State private var openedPanorama = false
    @State private var openedPhoto: WhikSample?

    private var items: [WhikSample] { WhikSample.items(category) }

    private var selection: Binding<String> {
        Binding(
            get: { page[category] ?? items.first?.id ?? "" },
            set: { page[category] = $0 }
        )
    }

    var body: some View {
        GeometryReader { outer in
        ZStack {
            WhikColors.background.ignoresSafeArea()
            TabView(selection: selection) {
                ForEach(items) { sample in
                    // The pager ignores the safe area (full-bleed photo); pass the real bottom inset down.
                    WhikSamplePage(sample: sample, bottomInset: outer.safeAreaInsets.bottom) { open(sample) }
                        .tag(sample.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .id(category)

            VStack(spacing: 18) {
                HStack(alignment: .top) {
                    WhikLogo(width: 150)
                    Spacer(minLength: 12)
                    WhikCircleButton(systemImage: "person", label: "Profile", action: onProfile)
                }
                WhikSegmented(items: [(.spaces, "Spaces"), (.objects, "Objects")], selection: $category)
                    .frame(maxWidth: 300)
                Spacer()
            }
            .padding(.horizontal, WhikLayout.sideInset)
            .padding(.top, 8)
        }
        }
        .fullScreenCover(isPresented: $openedPanorama) {
            if let url = WelcomePanoramaSampleAsset.bundleURL {
                Panorama360ViewerView(imageURL: url)
            }
        }
        .fullScreenCover(item: $openedPhoto) { sample in
            WhikPhotoPreview(sample: sample) { openedPhoto = nil }
        }
    }

    private func open(_ sample: WhikSample) {
        GonggiHaptics.light()
        switch sample.kind {
        case .panorama360: openedPanorama = true
        case .photo: openedPhoto = sample
        }
    }
}

/// One full-bleed sample page: photo, title, label and an arrow that opens what the sample really is.
private struct WhikSamplePage: View {
    let sample: WhikSample
    let bottomInset: CGFloat
    let onOpen: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                WhikSampleImage(sample: sample)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                WhikPhotoScrim(top: 0.45, bottom: 0.85)
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .bottom, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sample.title)
                                .font(WhikFont.title(28))
                                .foregroundStyle(WhikColors.textPrimary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                            Text(sample.subtitle)
                                .font(.system(.body))
                                .foregroundStyle(WhikColors.textSecondary)
                        }
                        Spacer(minLength: 8)
                        WhikCircleButton(
                            systemImage: sample.opensViewer ? "arrow.right" : "photo",
                            size: 54,
                            label: sample.opensViewer ? "Open \(sample.title)" : "View photo",
                            action: onOpen
                        )
                    }
                    HStack(spacing: 12) {
                        Rectangle().fill(WhikColors.textTertiary).frame(width: 48, height: 1)
                        Text("Swipe to explore")
                            .font(.system(.footnote))
                            .foregroundStyle(WhikColors.textSecondary)
                        Rectangle().fill(WhikColors.textTertiary).frame(width: 48, height: 1)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                }
                .padding(.horizontal, WhikLayout.sideInset + 6)
                .padding(.bottom, bottomInset + WhikLayout.tabBarClearance)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
        }
        .accessibilityElement(children: .contain)
    }
}

struct WhikSampleImage: View {
    let sample: WhikSample

    var body: some View {
        switch sample.kind {
        case .photo(let assetName):
            Image(assetName).resizable().scaledToFill()
        case .panorama360:
            if let image = WhikPanoramaThumbnail.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                WhikColors.surface
            }
        }
    }
}

/// Centre crop of the bundled equirect sample, so the cover shows the room rather than a stretched strip.
enum WhikPanoramaThumbnail {
    static let image: UIImage? = {
        guard let full = WelcomePanoramaSampleAsset.loadUIImage(), let cg = full.cgImage else { return nil }
        let h = CGFloat(cg.height)
        let w = min(CGFloat(cg.width), h * 0.62)
        let x = CGFloat(cg.width) * (0.5 + Double(WelcomePanoramaSampleAsset.initialYawDegrees) / 360) - w / 2
        let rect = CGRect(x: max(0, min(CGFloat(cg.width) - w, x)), y: 0, width: w, height: h).integral
        guard let crop = cg.cropping(to: rect) else { return full }
        return UIImage(cgImage: crop)
    }()
}

/// Full-screen design photo. Clearly a photo: no 3D controls.
struct WhikPhotoPreview: View {
    let sample: WhikSample
    let onClose: () -> Void
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if case .photo(let name) = sample.kind {
                Image(name)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale = min(4, max(1, $0)) }
                            .onEnded { _ in withAnimation(.easeOut(duration: 0.2)) { scale = 1 } }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(sample.title)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sample.title).font(.headline).foregroundStyle(.white)
                    Text("Photo preview").font(.footnote).foregroundStyle(WhikColors.textSecondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, WhikLayout.sideInset)
            .padding(.top, 8)
        }
    }
}
