import Foundation

/// Capture summary copy — shared by UI and XCTest (generation policy unchanged; UI labels only).
enum CaptureSummaryPresentation {
    static func heroTitle(
        completionState: CaptureCompletionState,
        terminalContinuityOK: Bool,
        candidateSafetyCapReached: Bool = false
    ) -> String {
        if completionState == .ready && terminalContinuityOK {
            return "촬영이 완료되었어요"
        }
        if candidateSafetyCapReached {
            // Partial package under enqueue safety cap — not "enough for 3DGS".
            return "촬영 데이터가 부분 저장되었어요"
        }
        return "촬영 데이터가 저장되었어요"
    }

    /// Clarifies enqueue-cap stop without claiming a durable JPEG count.
    static func heroSubtitle(
        completionState: CaptureCompletionState,
        terminalContinuityOK: Bool,
        candidateSafetyCapReached: Bool
    ) -> String? {
        guard candidateSafetyCapReached else { return nil }
        if completionState == .ready && terminalContinuityOK {
            return "사진 저장 한도에 도달했어요. 이미 저장된 데이터로 이어갈 수 있어요."
        }
        return "사진 저장 한도에 도달해 더 이상 새 사진이 저장되지 않았어요. 이미 저장된 데이터는 유지됩니다."
    }

    static func createButtonTitle(weakTerminal: Bool) -> String {
        weakTerminal ? "현재 데이터로 생성" : "이대로 공간 생성"
    }

    static func continueButtonTitle(weakTerminal: Bool) -> String {
        weakTerminal ? "연결 보강 촬영" : "추가 촬영"
    }

    /// Same-session append is not supported; starting again is a new capture.
    /// After enqueue cap, do not offer a control that looks like saves will resume.
    static func shouldOfferContinueCapture(candidateSafetyCapReached: Bool) -> Bool {
        !candidateSafetyCapReached
    }

    static let remainingHeader = "더 담을 수 있었던 곳"
    static let remainingFootnote = "완료와 공간 생성에는 영향이 없어요. 다음 촬영 때 참고해 주세요."

    /// Summary rows for the open items. An item is never shown as enough: 남음 = not asked yet, 미해결 = asked and
    /// still missing, 사진 한도 = the photo limit was reached first.
    static func remainingRows(_ items: [CaptureRemainingItem]) -> [(status: String, name: String, detail: String)] {
        items.map { ($0.statusLabel, $0.name, $0.statusDetail) }
    }

    static func earlyFinishDialogTitle(candidateSafetyCapReached: Bool) -> String {
        if candidateSafetyCapReached {
            return "새 사진이 더 이상 저장되지 않습니다. 현재까지 저장된 데이터로 종료할까요?"
        }
        return "조금 더 촬영하면 3D 공간 품질이 좋아질 수 있어요."
    }
}
