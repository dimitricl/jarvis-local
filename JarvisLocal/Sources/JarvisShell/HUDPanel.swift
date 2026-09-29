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
///
/// Focus saisie (`showForInput`) — cause réelle et correctif :
/// l'app est `LSUIElement` (politique `.accessory`, pas de Dock) et, sur
/// macOS récent, `NSApp.activate()` seul n'arrache pas le focus à l'app
/// frontale précédente : le log constatait
/// `hud input: key=false active=false` malgré
/// `activate() + makeKeyAndOrderFront`. Le correctif bascule temporairement
/// la politique d'activation à `.regular` puis force l'activation via
/// `activate(ignoringOtherApps: true)` (étape 2 : la bascule seule s'est
/// montrée insuffisante en réel, `key=false active=false` persistait),
/// puis `hide()` la restaure à `.accessory` (un seul point de fermeture du panel, via
/// `ShellCoordinator.applyAction` → `hide()`, audité : aucun autre
/// `orderOut` hors de ce fichier). Second étage (panel) : le panel est
/// `borderless`, donc `NSWindow.canBecomeKey` de base retourne `false` et
/// `makeKeyAndOrderFront` est ignoré silencieusement (`active=true` mais
/// `key=false` persistant) — d'où la sous-classe `HUDFocusPanel`.
/// Le comportement `NSApp`/`NSPanel` réel
/// reste non testable en headless ; seule la logique pure de bascule
/// (`HUDFocusPolicy`) est couverte par test.
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

/// Logique pure de bascule de politique d'activation pour le focus HUD.
///
/// - `input` (`.regular`) : appliquée par `showForInput()` avant
///   `activate() + makeKeyAndOrderFront` — seule façon fiable d'arracher le
///   focus à l'app frontale pour une app `LSUIElement` sur macOS récent.
/// - `idle` (`.accessory`) : restaurée par `hide()`, unique point de
///   fermeture du panel — préserve la contrainte « pas de Dock ».
///
/// Extraite pour être testable : le comportement `NSApp`/`NSPanel` réel
/// reste non testable en headless (coquille `HUDPanelController`).
public enum HUDFocusPolicy {
    public static var input: NSApplication.ActivationPolicy { .regular }
    public static var idle: NSApplication.ActivationPolicy { .accessory }
}

/// Le panel est `borderless` (sans barre de titre ni resize) : l'implémentation
/// de base de `NSWindow.canBecomeKey` retourne alors `false`, et
/// `makeKeyAndOrderFront` est ignoré silencieusement — constaté en réel :
/// `active=true` mais `key=false` persistant malgré l'activation différée et
/// son rejeu. La sous-classe autorise le statut key pour la saisie ; les
/// affichages agent restent non-activants via `show()` + `.nonactivatingPanel`.
@MainActor
private final class HUDFocusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
public final class HUDPanelController {
    private let panel: HUDFocusPanel
    private var keyMonitor: Any?
    private var lastEscape = Date.distantPast
    private let log = Logger(subsystem: "com.dimitriclaverie.JarvisLocal", category: "hud")

    public var onConfirmKey: ((Bool) -> Void)?
    public var onEscapeKey: (() -> Void)?
    public var onSubmitKey: (() -> Void)?

    public init() {
        let panel = HUDFocusPanel(
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
        fitToContent()
    }

    /// Le panel a une taille fixe à la création : sans réajustement, tout
    /// contenu dépassant est clippé hors fenêtre (constaté en réel : la
    /// réponse `.done` rendue mais invisible, seul « ✓ terminé » affiché —
    /// les logs `hud show` gardaient une hauteur de 69/71 pt). On ajuste la
    /// hauteur au contenu, plafonnée pour rester un HUD.
    private func fitToContent() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        let height = min(max(fitting.height, 69), 480)
        var frame = panel.frame
        let delta = height - frame.height
        guard delta != 0 else { return }
        // Ancre le bord haut : le HUD grandit vers le bas.
        frame.origin.y -= delta
        frame.size.height = height
        panel.setFrame(frame, display: false)
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
        // Restaure la politique `LSUIElement` : sans ce reset l'app garderait
        // une icône Dock en permanence (contrainte « pas de Dock »).
        NSApp.setActivationPolicy(HUDFocusPolicy.idle)
    }

    public var isVisible: Bool { panel.isVisible }

    private func orderFront() {
        panel.orderFrontRegardless()
        installKeyMonitor()
    }

    /// Ouverture explicite pour saisie (menu, hotkey) : le panneau devient
    /// `key` pour que le champ prenne le focus. Les affichages pilotés par
    /// l'agent (`show()`) restent non-activants et non-intrusifs.
    /// App `LSUIElement` (`.accessory`) : `activate()` seul ne suffit pas à
    /// arracher le focus sur macOS récent (`key=false active=false`
    /// constaté en réel) — on bascule temporairement en `.regular`,
    /// restaurée par `hide()`. Étapes 1 (bascule seule) et 2 (`ignoringOtherApps`
    /// dans le même tour) montrées insuffisantes en réel, d'où l'activation
    /// en réel, d'où l'activation différée d'un tour ci-dessous puis le
    /// `makeKey` rejoué une fois l'app active (`active=true` mais `key=false`
    /// constaté) — voir les commentaires avant tout nettoyage de lint.
    public func showForInput() {
        show()
        panel.styleMask.remove(.nonactivatingPanel)
        let policyBefore = NSApp.activationPolicy()
        let policyOK = NSApp.setActivationPolicy(HUDFocusPolicy.input)
        // La bascule de politique doit être traitée par le runloop avant que
        // l'activation puisse aboutir : activer dans le même tour échoue
        // silencieusement (constaté en réel : `key=false active=false` malgré
        // `.regular` + `ignoringOtherApps`). D'où l'activation différée d'un
        // tour. Le log `policyBefore/setOK/policy` permet de distinguer un
        // refus de bascule d'un échec d'activation à politique égale.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
            let policy = NSApp.activationPolicy().rawValue
            self.log.info("hud input: policyBefore=\(policyBefore.rawValue) setOK=\(policyOK) policy=\(policy)")
            // L'activation est asynchrone : on constate après un délai.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                // `makeKey` émis alors que l'app n'était pas encore active est
                // refusé silencieusement (constaté en réel : `active=true` mais
                // `key=false`). Si l'app est active et le panel pas key, on
                // rejoue `makeKey` maintenant que l'activation a abouti.
                if NSApp.isActive, !self.panel.isKeyWindow {
                    self.panel.makeKeyAndOrderFront(nil)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self else { return }
                    let key = self.panel.isKeyWindow
                    let active = NSApp.isActive
                    self.log.info("hud input: key=\(key) active=\(active)")
                }
            }
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
            // Entrée (36) / pavé (76) : autoriser ou envoyer, une seule fois.
            if event.keyCode == 36 || event.keyCode == 76 {
                if self.onConfirmKey != nil {
                    self.onConfirmKey?(true)
                    return nil
                }
                // On avale l'événement : sinon `TextField.onCommit` le
                // resoumet (constaté en réel : 3 runs concurrents pour un seul
                // Entrée, qui s'annulent et pilonnent le serveur).
                self.onSubmitKey?()
                return nil
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
