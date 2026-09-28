import AppKit
import Foundation

/// L3 — hotkey global : appui court = toggle, maintien = push-to-talk.
///
/// `NSEvent.addGlobalMonitorForEvents` (permission « Surveillance de
/// l'entrée ») : documenté dans `docs/shell-permissions.md`, vérifié par
/// l'écran d'onboarding (bouton de test + ouverture des Réglages Système).
/// Tap-vs-hold est une logique pure (`TapHoldDetector`, testée) ; ce
/// manager ne fait que le câblage NSEvent → callbacks.
public struct HotkeyConfig: Sendable, Equatable {
    /// Keycode suivi (défaut F13 = 105). Échap = 53 (toujours : annulation).
    public var keyCode: Int
    /// Seuil tap/hold en secondes.
    public var holdThreshold: Double

    public init(keyCode: Int = 105, holdThreshold: Double = 0.4) {
        self.keyCode = keyCode
        self.holdThreshold = holdThreshold
    }
}

public enum HotkeyGesture: Sendable, Equatable {
    case tap
    case holdBegan
    case holdEnded(duration: Double)
}

public enum TapHoldDetector {
    public enum Phase: Sendable, Equatable {
        case idle
        case down(since: Date)
    }

    /// Transition pure : keyDown → (immédiat : holdBegan potentiel), keyUp →
    /// tap ou holdEnded selon la durée. Le hold est notifié au keyDown
    /// (l'app commence à écouter tout de suite) puis confirmé au keyUp.
    public static func keyDown(phase: Phase) -> (Phase, HotkeyGesture?) {
        switch phase {
        case .idle:
            return (.down(since: Date()), .holdBegan)
        case .down:
            return (phase, nil)
        }
    }

    public static func keyUp(phase: Phase, now: Date = Date(), threshold: Double) -> (Phase, HotkeyGesture?) {
        switch phase {
        case .idle:
            return (phase, nil)
        case .down(let since):
            let duration = now.timeIntervalSince(since)
            if duration < threshold {
                return (.idle, .tap)
            }
            return (.idle, .holdEnded(duration: duration))
        }
    }
}

public final class HotkeyManager {
    private let config: HotkeyConfig
    private let onGesture: @Sendable (HotkeyGesture) -> Void
    private let onEscape: @Sendable () -> Void
    private let state = HotkeyTapState()
    private var monitors: [Any] = []
    private let lock = NSLock()

    public init(
        config: HotkeyConfig,
        onGesture: @Sendable @escaping (HotkeyGesture) -> Void,
        onEscape: @Sendable @escaping () -> Void
    ) {
        self.config = config
        self.onGesture = onGesture
        self.onEscape = onEscape
    }

    public func start() {
        stop()
        let keyCode = config.keyCode
        let threshold = config.holdThreshold
        let onGesture = onGesture
        let onEscape = onEscape
        let state = state
        let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            if event.keyCode == 53, event.type == .keyDown {
                onEscape()
                return
            }
            guard event.keyCode == UInt16(keyCode) else { return }
            if event.type == .keyDown, !event.isARepeat {
                state.withLock { $0 = .down(since: Date()) }
                onGesture(.holdBegan)
            } else if event.type == .keyUp {
                let since = state.withLock { phase -> Date? in
                    if case .down(let s) = phase { return s }
                    return nil
                }
                state.withLock { $0 = .idle }
                if let since {
                    let duration = Date().timeIntervalSince(since)
                    onGesture(duration < threshold ? .tap : .holdEnded(duration: duration))
                }
            }
        }
        lock.withLock {
            if let keyMonitor { monitors.append(keyMonitor) }
        }
    }

    public func stop() {
        lock.withLock {
            for m in monitors { NSEvent.removeMonitor(m) }
            monitors.removeAll()
        }
    }

    /// Surveillance de l'entrée probablement accordée ? Le seul test fiable
    /// est empirique (le moniteur reçoit des événements) — l'onboarding
    /// propose un bouton de test + l'ouverture directe du panneau.
    public static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// `@unchecked` justifié : la phase n'est lue/écrite que sous `NSLock`.
final class HotkeyTapState: @unchecked Sendable {
    private var phase = TapHoldDetector.Phase.idle
    private let lock = NSLock()

    func withLock<T>(_ body: (TapHoldDetector.Phase) -> T) -> T {
        lock.withLock { body(phase) }
    }

    func withLock(_ body: (inout TapHoldDetector.Phase) -> Void) {
        lock.withLock { body(&phase) }
    }
}
