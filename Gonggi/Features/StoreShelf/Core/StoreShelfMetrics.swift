import Foundation

// Measurements of a real trial (registration time, manual corrections, recognition accuracy, restore success, time from
// search to guidance). Recorded on the device; nothing here is computed from mock data.

struct StoreRegistrationMetric: Codable, Equatable, Sendable {
    var id: String
    var storeId: String
    var shelfId: String
    var startedAt: Date
    var finishedAt: Date
    var productsSaved: Int
    var placementsSaved: Int
    var rejectedBlurry: Int
    var rejectedFewObservations: Int
    var unplaceableDetections: Int
    /// Manual edits in the review screen (rename, delete, merge, confirm look-alike, ...).
    var manualCorrections: Int
    var correctionKinds: [String: Int]
    /// Detection / tracking / naming counters of this pass (nil on records saved before they existed).
    var diagnostics: StoreRecordingDiagnostics? = nil

    var durationSeconds: Double { finishedAt.timeIntervalSince(startedAt) }
}

struct StoreSearchMetric: Codable, Equatable, Sendable {
    var id: String
    var storeId: String
    var startedAt: Date
    var alignedAt: Date?
    var recognizedAt: Date?
    var guidanceStartedAt: Date?
    /// matched / uncertain / unregistered / noGallery
    var outcome: String
    var matchedProductId: String?
    /// Entered by the tester: "correct", "wrong", or nil when not judged.
    var testerVerdict: String?
    var alignmentMethod: String?
    var guidanceKind: String?

    var secondsToRecognition: Double? { recognizedAt.map { $0.timeIntervalSince(startedAt) } }
    var secondsToGuidance: Double? { guidanceStartedAt.map { $0.timeIntervalSince(startedAt) } }
}

struct StoreMetricsFile: Codable, Equatable, Sendable {
    var registrations: [StoreRegistrationMetric] = []
    var searches: [StoreSearchMetric] = []
}

struct StoreMetricsSummary: Equatable, Sendable {
    var registrationCount = 0
    var meanRegistrationSeconds: Double?
    var meanManualCorrectionsPerProduct: Double?
    var searchCount = 0
    /// Of the searches the tester judged: correct / (correct + wrong). nil when none was judged.
    var recognitionAccuracy: Double?
    var judgedSearches = 0
    var meanSecondsToGuidance: Double?
    var restoreAttempts = 0
    var restoreSuccessRate: Double?

    static func summarize(_ m: StoreMetricsFile, restoreAttempts: [StoreRestoreAttempt]) -> StoreMetricsSummary {
        var s = StoreMetricsSummary()
        s.registrationCount = m.registrations.count
        if !m.registrations.isEmpty {
            s.meanRegistrationSeconds = m.registrations.map(\.durationSeconds).reduce(0, +) / Double(m.registrations.count)
            let products = m.registrations.map(\.productsSaved).reduce(0, +)
            if products > 0 {
                s.meanManualCorrectionsPerProduct = Double(m.registrations.map(\.manualCorrections).reduce(0, +)) / Double(products)
            }
        }
        s.searchCount = m.searches.count
        let judged = m.searches.filter { $0.testerVerdict == "correct" || $0.testerVerdict == "wrong" }
        s.judgedSearches = judged.count
        if !judged.isEmpty {
            s.recognitionAccuracy = Double(judged.filter { $0.testerVerdict == "correct" }.count) / Double(judged.count)
        }
        let guided = m.searches.compactMap(\.secondsToGuidance)
        if !guided.isEmpty { s.meanSecondsToGuidance = guided.reduce(0, +) / Double(guided.count) }
        s.restoreAttempts = restoreAttempts.count
        if !restoreAttempts.isEmpty {
            s.restoreSuccessRate = Double(restoreAttempts.filter { $0.outcome == "restored" }.count) / Double(restoreAttempts.count)
        }
        return s
    }
}

/// Human wording for "last confirmed" (a location record, never current stock).
enum StoreShelfTimeText {
    static func lastConfirmed(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60: return "방금 확인"
        case ..<3600: return "\(Int(s / 60))분 전 확인"
        case ..<86_400: return "\(Int(s / 3600))시간 전 확인"
        default: return "\(Int(s / 86_400))일 전 확인"
        }
    }
}
