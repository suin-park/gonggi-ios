import Foundation
import SwiftUI

/// Validates catalog `hexCode` for color chips. Invalid values must not break UI.
enum CatalogColorHex {
    /// Returns normalized `#RRGGBB` (uppercase) or nil.
    static func normalized(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        if s.hasPrefix("#") {
            s.removeFirst()
        }
        guard s.count == 6 || s.count == 3,
              s.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) })
        else {
            return nil
        }
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        return "#\(s.uppercased())"
    }

    static func swiftUIColor(_ normalizedHex: String) -> Color? {
        var s = normalizedHex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}
