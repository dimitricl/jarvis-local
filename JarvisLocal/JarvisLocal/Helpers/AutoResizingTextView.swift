import SwiftUI
import AppKit

struct AutoResizingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let maxHeight: CGFloat
    let font: NSFont

    init(text: Binding<String>, height: Binding<CGFloat>, maxHeight: CGFloat = 120, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)) {
        self._text = text
        self._height = height
        self.maxHeight = maxHeight
        self.font = font
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
        if textView.string != text {
            textView.string = text
            applyTextColor(textView)
            computeHeight(textView: textView, notify: false)
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

        init(_ parent: AutoResizingTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else { return }
            parent.text = textView.string
            parent.computeHeight(textView: textView, notify: true)
        }
    }
}

fileprivate class AutoSizingScrollView: NSScrollView {
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
