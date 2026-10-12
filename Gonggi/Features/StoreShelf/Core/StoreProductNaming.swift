import Foundation

// Product name from the text read on the package (Korean, English or mixed). Pure Swift: the OCR itself runs on the
// device (Vision); everything here works on plain text lines and is tested on Linux.
//
// Rules: text must be read in more than one sharp observation before it becomes a name; nutrition facts, dates,
// storage notes, legal text and advertising phrases are never a name; an unreadable name is left empty (the product
// keeps its placeholder and is flagged), never invented.

struct ShelfTextLine: Codable, Equatable, Sendable {
    var text: String
    var confidence: Float
    /// Height of the text box as a fraction of the crop height (0...1).
    var heightFraction: Float
    /// Vertical centre as a fraction of the crop, 0 = top.
    var centerY: Float
}

struct ShelfExtractedName: Codable, Equatable, Sendable {
    var displayName: String
    var brand: String?
    var variant: String?
    var volume: String?
    var confidence: Float
    /// In how many distinct observations the strongest line was read.
    var support: Int
    var hasHangul: Bool
    var hasLatin: Bool
    /// True when the name is shown first but the manager should look at it (weak support or confidence).
    var needsConfirmation: Bool
    /// Every kept line (normalised search tokens), used for name search and for matching text seen by the camera.
    var tokens: [String]
}

enum ShelfProductNameExtractor {
    struct Config: Sendable {
        var minLineConfidence: Float = 0.4
        var minSupport = 2
        /// A line read only once is accepted when it is large and confidently read, but flagged for confirmation.
        var singleReadConfidence: Float = 0.85
        var singleReadHeight: Float = 0.12
        var maxLines = 3
        var confirmBelow: Float = 0.6
    }

    // MARK: Character classes

    static func isHangul(_ s: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7A3).contains(s.value) || (0x1100...0x11FF).contains(s.value) || (0x3130...0x318F).contains(s.value)
    }

    static func isLatinLetter(_ s: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(s.value) || (0x61...0x7A).contains(s.value) || (0xC0...0x24F).contains(s.value)
    }

    static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.filter { isHangul($0) || isLatinLetter($0) }.count
    }

    // MARK: Normalisation

    /// Lower-case, canonical composition, letters and digits only (so "COCA-COLA" == "coca cola" == "cocacola").
    static func key(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping.lowercased()
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            isHangul($0) || isLatinLetter($0) || (0x30...0x39).contains($0.value)
        }))
    }

    static func clean(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|_~`^*#<>[]{}\\/\"'.,:;-"))
        return collapsed.trimmingCharacters(in: trimSet)
    }

    // MARK: Lines that are never a name

    /// Korean fragments (two or more syllables) of nutrition, date, storage, legal and advertising text.
    private static let blockedKorean: [String] = [
        "영양", "나트륨", "탄수화물", "단백질", "당류", "트랜스지방", "포화지방", "콜레스테롤", "칼로리", "1회제공", "제공량", "총내용량",
        "유통기한", "소비기한", "제조일", "제조년월", "품질유지", "개봉후", "냉장보관", "냉동보관", "직사광선", "서늘한곳", "보관방법", "보관상",
        "원재료", "원산지", "제조원", "판매원", "수입원", "식품유형", "식품의", "품목보고", "알레르기", "알레르겐", "함유", "주의사항", "고객센터",
        "소비자상담", "부정불량", "분리배출", "재활용", "포장재질", "바코드",
        "할인", "특가", "행사", "이벤트", "증정", "사은품", "신제품", "쿠폰", "적립", "포인트",
    ]

    /// Words that are only advertising when they stand alone ("저지방" is a product attribute, "지방" a nutrition row).
    private static let blockedKoreanExact: Set<String> = [
        "지방", "포화", "무료", "한정", "특별", "추천", "인기", "신상", "교환", "반품", "전화", "상담", "덤",
    ]

    /// Latin phrases (compared on the letters-and-digits key).
    private static let blockedEnglishPhrases: [String] = [
        "nutritionfacts", "nutritioninformation", "servingsize", "calories", "saturatedfat", "cholesterol", "totalfat", "bestbefore",
        "expirydate", "storeinacool", "keeprefrigerated", "madein", "ingredients", "allergen", "manufacturedby", "distributedby",
    ]

    /// Whole words that are never a product name by themselves.
    private static let blockedEnglishWords: Set<String> = [
        "kcal", "sodium", "protein", "exp", "mfg", "tel", "www", "sale", "event", "free", "new", "best", "serving", "nutrition",
    ]

    /// Number-heavy or symbol-only lines: dates, prices, codes, percentages.
    static func isNoise(_ text: String) -> Bool {
        let t = clean(text)
        guard t.count >= 2 else { return true }
        let letters = letterCount(t)
        if letters == 0 { return true }
        let digits = t.unicodeScalars.filter { (0x30...0x39).contains($0.value) }.count
        if digits > 0, Double(digits) / Double(t.unicodeScalars.count) > 0.4 { return true }
        let k = key(t)
        if k.count < 2 { return true }
        for b in blockedKorean where k.contains(b) { return true }
        if blockedKoreanExact.contains(k) { return true }
        for b in blockedEnglishPhrases where k.contains(b) { return true }
        let words = t.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        if !words.isEmpty, words.allSatisfy({ blockedEnglishWords.contains($0) }) { return true }
        let lower = t.lowercased()
        if lower.contains("http") || lower.contains("www.") || lower.contains(".com") || lower.contains("@") { return true }
        if lower.contains("1+1") || lower.contains("2+1") { return true }
        if t.contains("%") || t.contains("₩") { return true }
        // price: digits followed by 원
        if t.range(of: "[0-9,]+\\s*원", options: .regularExpression) != nil { return true }
        // date-like
        if t.range(of: "\\d{2,4}[.\\-/]\\d{1,2}([.\\-/]\\d{1,2})?", options: .regularExpression) != nil { return true }
        return false
    }

    /// "500ml", "1.5L", "350 g", "6입", "12개입", "2 x 190ml".
    static func volumeText(in text: String) -> String? {
        let pattern = "(\\d+([.,]\\d+)?\\s*(ml|mL|ML|l|L|g|G|kg|KG|oz|OZ|cl|CL)\\b)|(\\d+\\s*(입|개입|개|팩|병|캔|매|봉)\\b)"
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespaces)
    }

    private static let variantWords = [
        "맛", "향", "제로", "zero", "오리지널", "original", "라이트", "light", "플러스", "plus", "딸기", "포도", "사과", "복숭아", "레몬", "라임",
        "오렌지", "초코", "초콜릿", "바닐라", "커피", "라떼", "녹차", "블루베리", "망고", "자몽", "매운", "순한", "고소한", "달콤", "무가당", "저지방",
        "chocolate", "vanilla", "strawberry", "lemon", "lime", "orange", "mango", "grape", "peach", "apple", "coffee", "latte", "diet", "sugarfree",
    ]

    static func isVariantLike(_ text: String) -> Bool {
        let k = key(text)
        return variantWords.contains { k.contains($0) }
    }

    // MARK: Edit distance for tolerant grouping of OCR variants

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    static func sameLine(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let ca = Array(a), cb = Array(b)
        guard min(ca.count, cb.count) >= 3 else { return false }
        if a.contains(b) || b.contains(a) { return min(ca.count, cb.count) * 3 >= max(ca.count, cb.count) * 2 }
        let allowed = max(ca.count, cb.count) >= 8 ? 2 : 1
        return editDistance(ca, cb) <= allowed
    }

    /// Two product NAMES are the same: spelling variants of OCR only (no containment: "코카콜라" is not "코카콜라 제로").
    static func sameName(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let ca = Array(a), cb = Array(b)
        guard min(ca.count, cb.count) >= 3 else { return false }
        let allowed = max(ca.count, cb.count) >= 8 ? 2 : 1
        return editDistance(ca, cb) <= allowed
    }

    // MARK: Extraction

    private struct Group {
        var display: String
        var key: String
        var observations = Set<Int>()
        var confidenceSum: Float = 0
        var reads = 0
        var heightSum: Float = 0
        var centerYSum: Float = 0
        var bestConfidence: Float = 0

        var meanConfidence: Float { reads > 0 ? confidenceSum / Float(reads) : 0 }
        var meanHeight: Float { reads > 0 ? heightSum / Float(reads) : 0 }
        var meanCenterY: Float { reads > 0 ? centerYSum / Float(reads) : 0.5 }
        var support: Int { observations.count }
    }

    /// `observations[i]` are the lines read in sharp observation i of ONE physical product.
    static func extract(observations: [[ShelfTextLine]], config: Config = Config()) -> ShelfExtractedName? {
        var groups: [Group] = []
        var volumeVotes: [String: Int] = [:]
        for (oi, lines) in observations.enumerated() {
            for line in lines where line.confidence >= config.minLineConfidence {
                let text = clean(line.text)
                if let v = volumeText(in: text) { volumeVotes[v.replacingOccurrences(of: " ", with: ""), default: 0] += 1 }
                if isNoise(text) { continue }
                let k = key(text)
                if let gi = groups.firstIndex(where: { sameLine($0.key, k) }) {
                    groups[gi].observations.insert(oi)
                    groups[gi].confidenceSum += line.confidence
                    groups[gi].reads += 1
                    groups[gi].heightSum += line.heightFraction
                    groups[gi].centerYSum += line.centerY
                    // the spelling read with the highest confidence is the one shown
                    if line.confidence > groups[gi].bestConfidence {
                        groups[gi].bestConfidence = line.confidence
                        groups[gi].display = text
                        groups[gi].key = k
                    }
                } else {
                    var g = Group(display: text, key: k)
                    g.observations.insert(oi)
                    g.confidenceSum = line.confidence
                    g.reads = 1
                    g.heightSum = line.heightFraction
                    g.centerYSum = line.centerY
                    g.bestConfidence = line.confidence
                    groups.append(g)
                }
            }
        }
        var accepted = groups.filter { g in
            g.support >= config.minSupport
                || (g.meanConfidence >= config.singleReadConfidence && g.meanHeight >= config.singleReadHeight)
        }
        guard !accepted.isEmpty else { return nil }
        // Strongest first: more observations, then larger text, then confidence.
        accepted.sort { a, b in
            if a.support != b.support { return a.support > b.support }
            if a.meanHeight != b.meanHeight { return a.meanHeight > b.meanHeight }
            return a.meanConfidence > b.meanConfidence
        }
        let chosen = Array(accepted.prefix(config.maxLines))
        // Display order: as printed, top to bottom.
        let ordered = chosen.sorted { $0.meanCenterY < $1.meanCenterY }
        let displayLines = ordered.map(\.display)
        let display = displayLines.joined(separator: " ")
        guard letterCount(display) >= 2 else { return nil }

        let strongest = chosen[0]
        let brand = chosen.count >= 2 ? strongest.display : nil
        let variantLine = ordered.first { isVariantLike($0.display) && $0.display != brand }?.display
        let volume = volumeVotes.max { $0.value < $1.value }?.key
        let scalars = display.unicodeScalars
        let support = strongest.support
        let meanConf = chosen.map(\.meanConfidence).reduce(0, +) / Float(chosen.count)
        let confidence = min(1, meanConf * min(1, Float(support) / 3))
        let weak = support < config.minSupport || confidence < config.confirmBelow
        return ShelfExtractedName(
            displayName: String(display.prefix(60)), brand: brand, variant: variantLine, volume: volume, confidence: confidence,
            support: support, hasHangul: scalars.contains { isHangul($0) }, hasLatin: scalars.contains { isLatinLetter($0) },
            needsConfirmation: weak, tokens: accepted.map(\.key))
    }

    /// Generic placeholder names created when no text could be read ("제품 3").
    static func isPlaceholder(_ name: String) -> Bool {
        name.range(of: "^제품\\s*\\d+$", options: .regularExpression) != nil
    }
}

/// Which stored product do text lines read from the camera point to? Used to settle an UNCERTAIN image match only: it
/// never creates a match on its own and never overrides a clear image result.
enum ShelfTextResolver {
    /// `names`: product id -> normalised tokens/name keys. Returns the single candidate whose name equals what the
    /// camera read. A partial read ("코카콜라" for "코카콜라 제로") decides nothing when another candidate's name contains it.
    static func resolve(candidates: [String], names: [String: [String]], readLines: [String]) -> String? {
        let read = readLines.map { ShelfProductNameExtractor.key($0) }.filter { $0.count >= 3 }
        guard !read.isEmpty else { return nil }
        var hits: [String] = []
        var partialOfOther = false
        for id in candidates {
            let tokens = (names[id] ?? []).map { ShelfProductNameExtractor.key($0) }.filter { $0.count >= 3 }
            if tokens.contains(where: { t in read.contains { ShelfProductNameExtractor.sameName($0, t) } }) {
                hits.append(id)
            } else if tokens.contains(where: { t in read.contains { r in t != r && t.contains(r) } }) {
                partialOfOther = true
            }
        }
        return hits.count == 1 && !partialOfOther ? hits[0] : nil
    }
}
