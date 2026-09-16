import SwiftUI
import AppKit
import JarvisCore

struct AutoResizingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let maxHeight: CGFloat
    let font: NSFont
    var onSend: (() -> Void)?

    init(text: Binding<String>, height: Binding<CGFloat>, maxHeight: CGFloat = 120, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize), onSend: (() -> Void)? = nil) {
        self._text = text
        self._height = height
        self.maxHeight = maxHeight
        self.font = font
        self.onSend = onSend
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = AutoSizingScrollView()

        let textView = NSTextView()
        textView.font = font
        textView.string = text
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainer?.containerSize = NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        applyTextColor(textView)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        computeHeight(textView: textView, notify: false)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        syncContainerWidth(scrollView: nsView, textView: textView)

        // BUG CORRIGÉ : quand on tape vite, SwiftUI peut déclencher updateNSView avec une valeur
        // du binding EN RETARD sur le contenu réel du NSTextView (le textDidChange d'une frappe
        // suivante n'a pas encore été propagé). Réécrire textView.string dans ce cas effaçait les
        // derniers caractères tapés et faisait sauter le curseur — d'où l'impression que la saisie
        // "bugue". Le flag isEditing marque les changements initiés par la saisie elle-même :
        // on ne réécrit alors jamais le texte depuis SwiftUI.
        if context.coordinator.isEditing {
            return
        }

        if textView.string != text {
            let selection = textView.selectedRanges
            let scrollPoint = textView.visibleRect.origin
            textView.string = text
            applyTextColor(textView)
            // Restaure curseur et position de scroll : un remplacement externe (clear après envoi,
            // pré-remplissage) ne doit pas téléporter le curseur en fin de texte.
            if !selection.isEmpty {
                textView.selectedRanges = selection
            }
            textView.scroll(scrollPoint)
            computeHeight(textView: textView, notify: false)
        }
    }

    /// Le textContainer garde sinon sa largeur initiale (200pt) : le texte wrappe avant le bord
    /// réel du champ et cliquer à droite ne place pas le curseur. On cale la largeur du conteneur
    /// sur celle effective de la vue.
    private func syncContainerWidth(scrollView: NSScrollView, textView: NSTextView) {
        guard let container = textView.textContainer else { return }
        let width = max(scrollView.contentSize.width - container.lineFragmentPadding * 2, 40)
        if abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    private func applyTextColor(_ textView: NSTextView) {
        let color = JarvisTheme.nsTextPrimary
        textView.textColor = color
        textView.insertionPointColor = color
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: color
        ]
        if !textView.string.isEmpty {
            textView.setTextColor(color, range: NSRange(location: 0, length: textView.string.utf16.count))
        }
    }

    private func computeHeight(textView: NSTextView, notify: Bool) {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let usedHeight = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
        let newHeight = min(max(usedHeight + 8, 34), maxHeight)
        if notify || abs(height - newHeight) > 0.5 {
            height = newHeight
        }
        textView.isVerticallyResizable = usedHeight > maxHeight - 8
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AutoResizingTextView
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        /// Vrai entre un textDidChange (saisie utilisateur) et la réconciliation SwiftUI qui suit :
        /// empêche updateNSView de réécrire textView.string avec une valeur obsolète du binding.
        var isEditing = false

        init(_ parent: AutoResizingTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else { return }
            isEditing = true
            parent.text = textView.string
            parent.computeHeight(textView: textView, notify: true)
            // La réconciliation SwiftUI consomme le flag ; si elle n'arrive pas (pas de re-render),
            // on le retire au prochain tour de runloop pour ne pas bloquer les mises à jour externes.
            DispatchQueue.main.async { [weak self] in self?.isEditing = false }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.command) {
                    return false
                }
                parent.onSend?()
                return true
            }
            return false
        }
    }
}

private class AutoSizingScrollView: NSScrollView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncTextContainerWidth()
    }

    override func tile() {
        super.tile()
        syncTextContainerWidth()
    }

    private func syncTextContainerWidth() {
        guard let tv = documentView as? NSTextView, let tc = tv.textContainer else { return }
        let width = max(contentSize.width - tc.lineFragmentPadding * 2, 40)
        if abs(tc.containerSize.width - width) > 0.5 {
            tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if let textView = documentView as? NSTextView,
           let layoutManager = textView.layoutManager,
           let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            let usedHeight = layoutManager.usedRect(for: container).height
            if usedHeight <= frame.height {
                nextResponder?.scrollWheel(with: event)
                return
            }
        }
        super.scrollWheel(with: event)
    }
}
