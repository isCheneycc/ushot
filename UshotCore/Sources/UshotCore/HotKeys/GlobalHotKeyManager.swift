import Carbon
import Foundation

@MainActor
public protocol GlobalHotKeyManaging: AnyObject {
    var onAction: ((HotKeyAction) -> Void)? { get set }
    var assignments: [HotKeyAction: HotKeyShortcut] { get }

    func register(_ assignments: [HotKeyAction: HotKeyShortcut]) throws
    func update(action: HotKeyAction, to shortcut: HotKeyShortcut) throws
    func unregisterAll() throws
}

@MainActor
protocol HotKeySystemRegistering: AnyObject {
    var onAction: ((HotKeyAction) -> Void)? { get set }

    func register(action: HotKeyAction, shortcut: HotKeyShortcut) throws -> UInt32
    func unregister(token: UInt32) throws
}

@MainActor
public final class CarbonGlobalHotKeyManager: GlobalHotKeyManaging {
    public var onAction: ((HotKeyAction) -> Void)?
    public private(set) var assignments: [HotKeyAction: HotKeyShortcut] = [:]

    private let backend: any HotKeySystemRegistering
    private var tokens: [HotKeyAction: UInt32] = [:]

    public convenience init() throws {
        try self.init(backend: CarbonHotKeyBackend())
    }

    init(backend: any HotKeySystemRegistering) throws {
        self.backend = backend
        self.backend.onAction = { [weak self] action in
            self?.onAction?(action)
        }
    }

    public func register(_ assignments: [HotKeyAction: HotKeyShortcut]) throws {
        _ = try ShortcutSettings(assignments: assignments).validatingUniqueAssignments()

        let oldAssignments = self.assignments
        let oldTokens = tokens

        do {
            try unregister(tokens: oldTokens)
        } catch {
            throw ScreenshotAppError.shortcutRollbackFailed(
                description: "Existing registrations could not be removed: \(error.localizedDescription)"
            )
        }

        do {
            let newTokens = try registerWithBackend(assignments)
            self.assignments = assignments
            self.tokens = newTokens
        } catch {
            let originalError = error
            do {
                try unregister(tokens: tokens)
                let restoredTokens = try registerWithBackend(oldAssignments)
                self.assignments = oldAssignments
                self.tokens = restoredTokens
            } catch {
                AppLog.hotKeys.fault("Hot-key rollback failed: \(error.localizedDescription, privacy: .public)")
                throw ScreenshotAppError.shortcutRollbackFailed(description: error.localizedDescription)
            }

            if let appError = originalError as? ScreenshotAppError {
                throw appError
            }
            throw originalError
        }
    }

    public func update(action: HotKeyAction, to shortcut: HotKeyShortcut) throws {
        var candidate = assignments
        candidate[action] = shortcut
        try register(candidate)
    }

    public func unregisterAll() throws {
        try unregister(tokens: tokens)
        assignments.removeAll()
        tokens.removeAll()
    }

    private func registerWithBackend(
        _ assignments: [HotKeyAction: HotKeyShortcut]
    ) throws -> [HotKeyAction: UInt32] {
        var registered: [HotKeyAction: UInt32] = [:]

        do {
            for action in HotKeyAction.allCases {
                guard let shortcut = assignments[action] else { continue }
                registered[action] = try backend.register(action: action, shortcut: shortcut)
            }
            tokens = registered
            return registered
        } catch let error as CarbonHotKeyError {
            try cleanupFailedRegistrations(registered, registrationError: error)
            throw ScreenshotAppError.shortcutConflict(action: error.action, status: error.status)
        } catch {
            try cleanupFailedRegistrations(registered, registrationError: error)
            throw error
        }
    }

    private func cleanupFailedRegistrations(
        _ registered: [HotKeyAction: UInt32],
        registrationError: Error
    ) throws {
        var cleanupFailures: [String] = []
        for token in registered.values {
            do {
                try backend.unregister(token: token)
            } catch {
                cleanupFailures.append(error.localizedDescription)
            }
        }
        if cleanupFailures.isEmpty {
            tokens.removeAll()
            return
        }
        tokens = registered
        let detail = cleanupFailures.joined(separator: "; ")
        AppLog.hotKeys.fault(
            "Partial hot-key cleanup failed after \(registrationError.localizedDescription, privacy: .public): \(detail, privacy: .public)"
        )
        throw ScreenshotAppError.shortcutRollbackFailed(
            description: "Registration failed (\(registrationError.localizedDescription)); cleanup also failed (\(detail))."
        )
    }

    private func unregister(tokens: [HotKeyAction: UInt32]) throws {
        for action in HotKeyAction.allCases {
            guard let token = tokens[action] else { continue }
            try backend.unregister(token: token)
        }
    }
}

private struct CarbonHotKeyError: LocalizedError {
    let action: HotKeyAction
    let status: Int32

    var errorDescription: String? {
        "RegisterEventHotKey failed for \(action.title) with OSStatus \(status)."
    }
}

@MainActor
private final class CarbonHotKeyBackend: HotKeySystemRegistering {
    var onAction: ((HotKeyAction) -> Void)?

    private var handler: EventHandlerRef?
    private var references: [UInt32: EventHotKeyRef] = [:]

    init() throws {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyEventHandler,
            1,
            &eventType,
            context,
            &handler
        )
        guard status == noErr else {
            throw ScreenshotAppError.shortcutRollbackFailed(
                description: "InstallEventHandler returned OSStatus \(status)."
            )
        }
    }

    func register(action: HotKeyAction, shortcut: HotKeyShortcut) throws -> UInt32 {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x5553_4854, id: action.rawValue)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &reference
        )

        guard status == noErr, let reference else {
            throw CarbonHotKeyError(action: action, status: status)
        }
        references[action.rawValue] = reference
        return action.rawValue
    }

    func unregister(token: UInt32) throws {
        guard let reference = references[token] else { return }
        let status = UnregisterEventHotKey(reference)
        guard status == noErr else {
            throw ScreenshotAppError.shortcutRollbackFailed(
                description: "UnregisterEventHotKey returned OSStatus \(status)."
            )
        }
        references[token] = nil
    }

    func dispatch(identifier: UInt32) {
        guard let action = HotKeyAction(rawValue: identifier) else {
            AppLog.hotKeys.error("Received unknown hot-key identifier \(identifier)")
            return
        }
        onAction?(action)
    }
}

private func carbonHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr else { return status }

    let backend = Unmanaged<CarbonHotKeyBackend>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        backend.dispatch(identifier: identifier.id)
    }
    return noErr
}

private extension HotKeyModifiers {
    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if contains(.command) { value |= UInt32(cmdKey) }
        if contains(.option) { value |= UInt32(optionKey) }
        if contains(.control) { value |= UInt32(controlKey) }
        if contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
}
