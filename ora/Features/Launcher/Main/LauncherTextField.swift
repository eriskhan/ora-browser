import SwiftUI

struct LauncherTextField: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    let onTab: () -> Void
    let onSubmit: () -> Void
    let onDelete: () -> Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    var cursorColor: Color
    var textColor: Color?
    var placeholder: String

    class CustomTextField: NSTextField {
        var cursorColor: NSColor?

        private func configureEditorIfNeeded() {
            guard let textView = currentEditor() as? NSTextView else { return }
            if let color = cursorColor {
                textView.insertionPointColor = color
            }
            textView.isHorizontallyResizable = true
            textView.isVerticallyResizable = false
            textView.textContainerInset = .zero
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: .greatestFiniteMagnitude,
                height: bounds.height
            )
            textView.textContainer?.lineBreakMode = .byClipping
            textView.textContainer?.maximumNumberOfLines = 1
        }

        override func becomeFirstResponder() -> Bool {
            let didBecome = super.becomeFirstResponder()
            if didBecome {
                configureEditorIfNeeded()
            }
            return didBecome
        }

        override func textDidBeginEditing(_ notification: Notification) {
            super.textDidBeginEditing(notification)
            configureEditorIfNeeded()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CustomTextField {
        let textField = CustomTextField()
        textField.delegate = context.coordinator
        textField.font = font
        textField.bezelStyle = .roundedBezel
        textField.isBordered = false
        textField.focusRingType = .none
        textField.drawsBackground = false
        textField.placeholderString = placeholder
        textField.lineBreakMode = .byClipping
        textField.maximumNumberOfLines = 1
        textField.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        if let textColor {
            textField.textColor = NSColor(textColor)
        }
        return textField
    }

    func updateNSView(_ nsView: CustomTextField, context: Context) {
        if nsView.stringValue != text {
            // Prevent the AppKit delegate callback from bouncing this write
            // straight back into SwiftUI during the same update pass.
            context.coordinator.isProgrammaticUpdate = true
            nsView.stringValue = text
            context.coordinator.isProgrammaticUpdate = false
        }
        nsView.cursorColor = NSColor(cursorColor)
        nsView.placeholderString = placeholder
        if let textColor {
            nsView.textColor = NSColor(textColor)
        }
        if let textView = nsView.currentEditor() as? NSTextView {
            textView.insertionPointColor = nsView.cursorColor
            textView.isHorizontallyResizable = true
            textView.isVerticallyResizable = false
            textView.textContainerInset = .zero
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: .greatestFiniteMagnitude,
                height: nsView.bounds.height
            )
            textView.textContainer?.lineBreakMode = .byClipping
            textView.textContainer?.maximumNumberOfLines = 1
        }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LauncherTextField
        var isProgrammaticUpdate = false

        init(_ parent: LauncherTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !isProgrammaticUpdate else { return }
            if let textField = obj.object as? NSTextField, parent.text != textField.stringValue {
                parent.text = textField.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)) {
                parent.onTab()
                return true
            } else if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            } else if selector == #selector(NSResponder.deleteBackward(_:)) {
                return parent.onDelete()
            } else if selector == #selector(NSResponder.moveUp(_:)) || selector ==
                #selector(NSResponder.moveToBeginningOfParagraph(_:))
            {
                parent.onMoveUp()
                return true
            } else if selector == #selector(NSResponder.moveDown(_:)) || selector ==
                #selector(NSResponder.moveToEndOfParagraph(_:))
            {
                parent.onMoveDown()
                return true
            }

            return false
        }
    }
}
