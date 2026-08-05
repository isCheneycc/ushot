import Foundation

public enum CaptureSessionState: Equatable, Sendable {
    case idle
    case checkingPermission(CaptureMode)
    case preparingContent(CaptureMode)
    case selecting(CaptureMode)
    case capturing(CaptureMode)
    case presentingPinnedShot
    case quickEditing
    case canvasEditing
    case exporting
}

public enum CaptureAdmission: Equatable, Sendable {
    case accepted
    case rejected(activeState: CaptureSessionState)
}

public actor CaptureStateMachine {
    public private(set) var state: CaptureSessionState = .idle

    public init() {}

    public func admit(mode: CaptureMode) -> CaptureAdmission {
        guard state == .idle else {
            return .rejected(activeState: state)
        }
        state = .checkingPermission(mode)
        return .accepted
    }

    public func begin(mode: CaptureMode) throws {
        guard admit(mode: mode) == .accepted else {
            throw ScreenshotAppError.captureFailed(description: "A capture session is already active.")
        }
    }

    public func permissionGranted() throws {
        guard case .checkingPermission(let mode) = state else { throw invalidTransition() }
        state = .preparingContent(mode)
    }

    public func contentPrepared(requiresSelection: Bool) throws {
        guard case .preparingContent(let mode) = state else { throw invalidTransition() }
        state = requiresSelection ? .selecting(mode) : .capturing(mode)
    }

    public func selectionCompleted() throws {
        guard case .selecting(let mode) = state else { throw invalidTransition() }
        state = .capturing(mode)
    }

    public func imageCaptured() throws {
        guard case .capturing = state else { throw invalidTransition() }
        state = .presentingPinnedShot
    }

    public func beginQuickEditing() throws {
        guard state == .presentingPinnedShot else { throw invalidTransition() }
        state = .quickEditing
    }

    public func beginCanvasEditing() throws {
        guard state == .presentingPinnedShot || state == .quickEditing else { throw invalidTransition() }
        state = .canvasEditing
    }

    public func beginExporting() throws {
        switch state {
        case .presentingPinnedShot, .quickEditing, .canvasEditing:
            state = .exporting
        default:
            throw invalidTransition()
        }
    }

    public func finish() {
        state = .idle
    }

    public func cancel() {
        state = .idle
    }

    public func fail(_ error: Error) {
        AppLog.capture.error("Capture state reset after error: \(error.localizedDescription, privacy: .public)")
        state = .idle
    }

    private func invalidTransition() -> ScreenshotAppError {
        .captureFailed(description: "Invalid transition from \(String(describing: state)).")
    }
}
