import Foundation

/// Capture summary copy — shared by UI and XCTest (generation policy unchanged; UI labels only).
enum CaptureSummaryPresentation {
    static func heroTitle(
        completionState: CaptureCompletionState,
        terminalContinuityOK: Bool
    ) -> String {
        if completionState == .ready && terminalContinuityOK {
            return "촬영이 완료되었어요"
        }
        return "촬영 데이터가 저장되었어요"
    }

    static func createButtonTitle(weakTerminal: Bool) -> String {
        weakTerminal ? "현재 데이터로 생성" : "이대로 공간 생성"
    }

    static func continueButtonTitle(weakTerminal: Bool) -> String {
        weakTerminal ? "연결 보강 촬영" : "추가 촬영"
    }
}
