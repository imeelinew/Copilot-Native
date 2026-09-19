import AppKit
import SwiftUI

struct PaddedTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> EditorContainerView {
        let view = EditorContainerView()
        view.textView.delegate = context.coordinator
        view.textView.font = font
        view.textView.setAccessibilityLabel(accessibilityLabel)
        view.placeholderLabel.font = font
        view.placeholderLabel.stringValue = placeholder
        view.textView.string = text
        view.placeholderLabel.isHidden = !text.isEmpty
        return view
    }

    func updateNSView(_ view: EditorContainerView, context: Context) {
        context.coordinator.text = $text
        if view.textView.string != text {
            view.textView.string = text
        }
        view.textView.font = font
        view.placeholderLabel.font = font
        view.placeholderLabel.stringValue = placeholder
        view.placeholderLabel.isHidden = !text.isEmpty
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            (textView.enclosingScrollView?.superview as? EditorContainerView)?
                .placeholderLabel.isHidden = !textView.string.isEmpty
        }
    }
}

final class EditorContainerView: NSView {
    let scrollView = NSScrollView()
    let textView = NSTextView()
    let placeholderLabel = ClickThroughLabel(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView

        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        scrollView.contentView.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: 14),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.contentView.trailingAnchor, constant: -14),
            placeholderLabel.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let contentSize = scrollView.contentSize
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if textView.frame.width != contentSize.width {
            textView.setFrameSize(NSSize(width: contentSize.width, height: max(textView.frame.height, contentSize.height)))
        }
    }
}

final class ClickThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
