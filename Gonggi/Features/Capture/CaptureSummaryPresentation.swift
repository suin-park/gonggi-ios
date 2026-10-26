import Foundation

/// Capture summary copy — shared by UI and XCTest (generation policy unchanged; UI labels only).
enum CaptureSummaryPresentation {
    static func heroTitle(
        completionState: CaptureCompletionState,
        terminalContinuityOK: Bool,
        candidateSafetyCapReached: Bool = false
    ) -> String {
        if completionState == .ready && terminalContinuityOK {
            return L("Capture complete")
        }
        if candidateSafetyCapReached {
            // Partial package under enqueue safety cap — not "enough for 3DGS".
            return L("Part of the capture was saved")
        }
        return L("Capture saved")
    }

    /// Clarifies enqueue-cap stop without claiming a durable JPEG count.
    static func heroSubtitle(
        completionState: CaptureCompletionState,
        terminalContinuityOK: Bool,
        candidateSafetyCapReached: Bool
    ) -> String? {
        guard candidateSafetyCapReached else { return nil }
        if completionState == .ready && terminalContinuityOK {
            return L("The photo limit was reached. You can continue with what's already saved.")
        }
        return L("The photo limit was reached, so no more photos were saved. Saved data is kept.")
    }

    static func createButtonTitle(weakTerminal: Bool) -> String {
        weakTerminal ? L("Create with current data") : L("Create the space now")
    }

    static func continueButtonTitle(weakTerminal: Bool) -> String {
        weakTerminal ? L("Strengthen the connection") : L("Capture more")
    }

    /// Same-session append is not supported; starting again is a new capture.
    /// After enqueue cap, do not offer a control that looks like saves will resume.
    static func shouldOfferContinueCapture(candidateSafetyCapReached: Bool) -> Bool {
        !candidateSafetyCapReached
    }

    static var remainingHeader: String { L("Places you could have captured more") }
    static var remainingFootnote: String { L("This doesn't affect finishing or creating the space. Keep it in mind next time.") }

    /// Summary rows for the open items. An item is never shown as enough: 남음 = not asked yet, 미해결 = asked and
    /// still missing, 사진 한도 = the photo limit was reached first.
    static func remainingRows(_ items: [CaptureRemainingItem]) -> [(status: String, name: String, detail: String)] {
        items.map { ($0.statusLabel, $0.name, $0.statusDetail) }
    }

    static func earlyFinishDialogTitle(candidateSafetyCapReached: Bool) -> String {
        if candidateSafetyCapReached {
            return L("New photos are no longer being saved. Finish with the data saved so far?")
        }
        return L("Capturing a little more can improve the 3D Space quality.")
    }

    /// Ask before finishing when the capture isn't ready, or when it is ready but the photos are spread thin
    /// (CaptureDensityCheck). Before upload, so the user can still capture more.
    static func finishNeedsConfirm(quality q: CaptureQualityState) -> Bool {
        q.completionState != .ready || (!q.candidateSafetyCapReached && !CaptureDensityCheck.issues(for: q).isEmpty)
    }

    static func finishConfirmTitle(quality q: CaptureQualityState) -> String {
        if !q.candidateSafetyCapReached, !CaptureDensityCheck.issues(for: q).isEmpty {
            return CaptureDensityCheck.finishWarningTitle
        }
        return earlyFinishDialogTitle(candidateSafetyCapReached: q.candidateSafetyCapReached)
    }

    /// The main reason (first density issue), nil when there is no specific one.
    static func finishConfirmMessage(quality q: CaptureQualityState) -> String? {
        guard !q.candidateSafetyCapReached, let issue = CaptureDensityCheck.issues(for: q).first else { return nil }
        return CaptureDensityCheck.reason(issue)
    }
}
