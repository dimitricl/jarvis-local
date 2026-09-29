import AppKit
import SwiftUI
import os
import JarvisKit

/// L3 — panneau HUD : `NSPanel` non activant, flottant, tous espaces +
/// plein écran, sans voler le focus.
///
/// - `styleMask`: non-activating + borderless + utility.
/// - `level`: `.floating` (au-dessus), `collectionBehavior` :
///   `.canJoinAllSpaces | .fullScreenAuxiliary` (visible partout, y compris
///   plein écran) + `.stationary` (ne suit pas les espaces).
/// - Position : près du curseur, rabattue à l'écran.
/// - Clavier : moniteur local actif quand visible — Entrée = autoriser /
///   envoyer, Échap = refuser / interrompre (×2 = interruption immédiate).
/// Fin et testé : le positionnement pur (`HUDPlacement`) ; le panneau lui
/// est une coquille fine (pas de test headless possible).
public enum HUDPlacement {
    /// Cadre rabattu dans l'écran contenant le curseur (coin haut-droit
    /// sous le curseur, à défaut coin de l'écran).
    public static func frame(
        panelSize: CGSize,
        mouseLocation: CGPoint,
        screenFrame: CGRect,
        margin: Double = 16
    ) -> CGRect {
        var x = mouseLocation.x + margin
        var y = mouseLocation.y - panelSize.height - margin
        if x + panelSize.width > screenFrame.maxX {
            x = screenFrame.maxX - panelSize.width - margin
        }
        if y < screenFrame.minY {
            y = mouseLocation.y + margin
        }
        if y + panelSize.height > screenFrame.maxY {
            y = screenFrame.maxY - panelSize.height - margin
        }
        return CGRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
    }
}

@MainActor
public final class HUDPanelController {
    private let panel: NSPanel
    private var keyMonitor: Any?
    private var lastEscape = Date.distantPast
    private let log = Logger(subsystem: "com.dimitriclaverie.JarvisLocal", category: "hud")

    public var onConfirmKey: ((Bool) -> Void)?
    public var onEscapeKey: (() -> Void)?
    public var onSubmitKey: (() -> Void)?

    public init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.nonactivatingPanel, .borderless, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        self.panel = panel
    }

    public func setContent<Content: View>(_ view: Content) {
        panel.contentView = NSHostingView(rootView: view)
    }

    public func show() {
        panel.styleMask.insert(.nonactivatingPanel)
        guard let screen = screenAtCursor() else {
            log.info("hud show: no screen at cursor, centering")
            panel.center()
            orderFront()
            return
        }
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        panel.setFrame(HUDPlacement.frame(
            panelSize: size, mouseLocation: mouse, screenFrame: screen.frame), display: true)
        let frameDesc = String(describing: panel.frame)
        log.info("hud show: frame=\(frameDesc, privacy: .public)")
        orderFront()
    }

    public func hide() {
        log.info("hud hide")
        panel.orderOut(nil)
        lastEscape = .distantPast
    }

    public var isVisible: Bool { panel.isVisible }

    private func orderFront() {
        panel.orderFrontRegardless()
        installKeyMonitor()
    }

    /// Ouverture explicite pour saisie (menu, hotkey) : le panneau devient
    /// `key` pour que le champ prenne le focus. Les affichages pilotés par
    /// l'agent (`show()`) restent non-activants et non-intrusifs.
    /// Constaté en réel : `activate + makeKey` ne prend pas sur un panneau
    /// `.nonactivatingPanel` (`key=false active=false`) — on retire le masque
    /// pour la saisie, `show()` le remet pour les màj agent.
    public func showForInput() {
        show()
        panel.styleMask.remove(.nonactivatingPanel)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // L'activation est asynchrone : on constate au prochain tour.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let key = self.panel.isKeyWindow
            let active = NSApp.isActive
            self.log.info("hud input: key=\(key) active=\(active)")
        }
    }

    private func screenAtCursor() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    private func installKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            // Entrée (36) / pavé (76) : autoriser ou envoyer.
            if event.keyCode == 36 || event.keyCode == 76 {
                if self.onConfirmKey != nil {
                    self.onConfirmKey?(true)
                    return nil
                }
                self.onSubmitKey?()
                return event
            }
            // Échap (53) : sur confirmation = refuser ; ×2 rapide = interrompre.
            if event.keyCode == 53 {
                let now = Date()
                if now.timeIntervalSince(self.lastEscape) < 0.6 {
                    self.lastEscape = .distantPast
                    self.onEscapeKey?()
                    return nil
                }
                self.lastEscape = now
                if self.onConfirmKey != nil {
                    self.onConfirmKey?(false)
                    return nil
                }
                return event
            }
            return event
        }
    }
}
