import Foundation

/// Home samples. Only `panorama360` is a real, viewable capture (the bundled LatLong sample that the old
/// Welcome screen used). Every other item is a design photo and is labelled and opened as a photo — never
/// as a 3D result.
struct WhikSample: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Bundled equirect JPEG (`WelcomePanoramaSampleAsset`) → `Panorama360ViewerView`.
        case panorama360
        /// Asset-catalog photo → full-screen photo preview.
        case photo(assetName: String)
    }

    enum Category: Hashable { case spaces, objects }

    let id: String
    let title: String
    let kind: Kind
    let category: Category

    var subtitle: String {
        switch kind {
        case .panorama360: return "Sample 360° space"
        case .photo: return "Photo preview"
        }
    }

    /// Only real captures can be opened in a 3D/360 viewer.
    var opensViewer: Bool { kind == .panorama360 }

    static let spaces: [WhikSample] = [
        WhikSample(id: "sample-360", title: "Look around", kind: .panorama360, category: .spaces),
        WhikSample(id: "photo-sunday", title: "Sunday at home", kind: .photo(assetName: "WhikPhotoLivingSunday"), category: .spaces),
        WhikSample(id: "photo-autumn", title: "Autumn light", kind: .photo(assetName: "WhikPhotoLivingAutumn"), category: .spaces),
        WhikSample(id: "photo-cafe", title: "Corner café", kind: .photo(assetName: "WhikPhotoCafe"), category: .spaces),
        WhikSample(id: "photo-studio", title: "Home studio", kind: .photo(assetName: "WhikPhotoStudio"), category: .spaces),
    ]

    static let objects: [WhikSample] = [
        WhikSample(id: "photo-chair-walnut", title: "Lounge chair", kind: .photo(assetName: "WhikPhotoChairWalnut"), category: .objects),
        WhikSample(id: "photo-chair-charcoal", title: "Bouclé chair", kind: .photo(assetName: "WhikPhotoChairCharcoal"), category: .objects),
    ]

    static func items(_ category: Category) -> [WhikSample] {
        category == .spaces ? spaces : objects
    }
}
