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

    static func earlyFinishDialogTitle(candidateSafetyCapReached: Bool) -> String {
        if candidateSafetyCapReached {
            return "새 사진이 더 이상 저장되지 않습니다. 현재까지 저장된 데이터로 종료할까요?"
        }
        return "조금 더 촬영하면 3D 공간 품질이 좋아질 수 있어요."
    }
}
