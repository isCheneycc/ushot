public enum PointerIdleOutputAttempt<Output> {
    case admitted(Output)
    case rejected(pressedMouseButtons: UInt)
}

/// Samples the global mouse-button state exactly once and starts an output
/// operation only when no button is pressed.
public struct PointerIdleOutputGate {
    private let pressedMouseButtonsProvider: () -> UInt

    public init(pressedMouseButtonsProvider: @escaping () -> UInt) {
        self.pressedMouseButtonsProvider = pressedMouseButtonsProvider
    }

    public func performIfIdle<Output>(
        _ operation: () -> Output
    ) -> PointerIdleOutputAttempt<Output> {
        let pressedMouseButtons = pressedMouseButtonsProvider()
        guard pressedMouseButtons == 0 else {
            return .rejected(pressedMouseButtons: pressedMouseButtons)
        }
        return .admitted(operation())
    }
}
