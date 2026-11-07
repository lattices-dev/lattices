import AppKit

// Private API: get CGWindowID from an AXUIElement (already declared in WindowTiler.swift)
// We reuse the same _AXUIElementGetWindow binding.

struct AXTextResult {
    let wid: UInt32
    let texts: [String]
    let fullText: String
}

final class AccessibilityTextExtractor {
    static let timeoutSeconds: TimeInterval = 0.2
    static let maxDepth: Int = 4
    static let maxChildrenPerNode: Int = 30

    typealias AttributeReader = (AXUIElement, CFString) -> (AXError, CFTypeRef?)
    private let readAttribute: AttributeReader

    init(readAttribute: @escaping AttributeReader = { element, name in
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        return (error, value)
    }) {
        self.readAttribute = readAttribute
    }

    /// Extract text from a window's AX element tree.
    /// Returns nil if AX fails or yields fewer than `minChars` characters.
    func extract(pid: Int32, wid: UInt32, minChars: Int = 12) -> AXTextResult? {
        let appRef = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appRef, Float(Self.timeoutSeconds))

        // Find the AXUIElement matching this wid
        let (err, windowsRef) = readAttribute(appRef, kAXWindowsAttribute as CFString)
        guard err == .success, let axWindows = windowsRef as? [AXUIElement] else { return nil }

        var targetWindow: AXUIElement?
        for axWin in axWindows {
            var winID: CGWindowID = 0
            if _AXUIElementGetWindow(axWin, &winID) == .success, winID == CGWindowID(wid) {
                targetWindow = axWin
                break
            }
        }

        guard let window = targetWindow else { return nil }

        return extract(window: window, wid: wid, minChars: minChars)
    }

    /// A successful empty result is distinct from an unavailable AX tree. The
    /// index uses minChars=0 so blank/secure content can replace stale live text.
    func extract(window: AXUIElement, wid: UInt32, minChars: Int = 12) -> AXTextResult? {
        let deadline = Date().addingTimeInterval(Self.timeoutSeconds)
        var collected: [String] = []
        var failed = false

        walkChildren(element: window, depth: 0, deadline: deadline, collected: &collected, failed: &failed)

        let fullText = collected.joined(separator: "\n")
        guard !failed, fullText.count >= minChars else { return nil }

        return AXTextResult(wid: wid, texts: collected, fullText: fullText)
    }

    // MARK: - Tree Walker

    private func walkChildren(
        element: AXUIElement,
        depth: Int,
        deadline: Date,
        collected: inout [String],
        failed: inout Bool
    ) {
        guard depth < Self.maxDepth else { return }
        guard Date() < deadline else { failed = true; return }

        let (_, subrole) = attribute(element, kAXSubroleAttribute, failed: &failed)
        let (_, hidden) = attribute(element, kAXHiddenAttribute, failed: &failed)
        guard !failed else { return }
        guard ScreenTextPolicy.allowsAccessibilityNode(
            subrole: subrole as? String, hidden: (hidden as? Bool) == true
        ) else { return }

        // Extract text attributes from this element
        extractText(from: element, into: &collected, failed: &failed)
        guard !failed else { return }

        // Get children — prefer visible children, fall back to all children
        var gotChildren = false

        let (visErr, childrenRef) = attribute(element, kAXVisibleChildrenAttribute, failed: &failed)
        guard !failed else { return }
        if visErr == .success {
            gotChildren = true
            // A supplied malformed list must not fall back to every child.
            guard let children = childrenRef as? [AXUIElement] else { return }
            let capped = children.prefix(Self.maxChildrenPerNode)
            for child in capped {
                walkChildren(element: child, depth: depth + 1, deadline: deadline, collected: &collected, failed: &failed)
                guard !failed else { return }
            }
        }

        if !gotChildren {
            let (childErr, childrenRef) = attribute(element, kAXChildrenAttribute, failed: &failed)
            guard !failed else { return }
            if childErr == .success, let children = childrenRef as? [AXUIElement] {
                let capped = children.prefix(Self.maxChildrenPerNode)
                for child in capped {
                    walkChildren(element: child, depth: depth + 1, deadline: deadline, collected: &collected, failed: &failed)
                    guard !failed else { return }
                }
            }
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String, failed: inout Bool) -> (AXError, CFTypeRef?) {
        let response = readAttribute(element, name as CFString)
        switch response.0 {
        case .success, .attributeUnsupported, .noValue: break
        default: failed = true
        }
        return response
    }

    private func extractText(from element: AXUIElement, into collected: inout [String], failed: inout Bool) {
        // kAXValueAttribute — text field contents, labels, etc.
        let (valueError, valueRef) = attribute(element, kAXValueAttribute, failed: &failed)
        if valueError == .success,
           let str = valueRef as? String, !str.isEmpty, str.count > 1 {
            var visibleRange: NSRange?
            let (rangeError, visibleRangeRef) = attribute(element, kAXVisibleCharacterRangeAttribute, failed: &failed)
            if rangeError == .success {
                // A supplied but malformed range must not become an unrestricted value.
                visibleRange = NSRange(location: NSNotFound, length: 0)
                if let visibleRangeRef, CFGetTypeID(visibleRangeRef) == AXValueGetTypeID() {
                    let value = unsafeBitCast(visibleRangeRef, to: AXValue.self)
                    var range = CFRange()
                    if AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length >= 0 {
                        visibleRange = NSRange(location: range.location, length: range.length)
                    }
                }
            }
            let visible = ScreenTextPolicy.visibleText(str, range: visibleRange)
            if !visible.isEmpty { collected.append(visible) }
        }

        // kAXTitleAttribute — window/button titles
        let (titleError, titleRef) = attribute(element, kAXTitleAttribute, failed: &failed)
        if titleError == .success,
           let str = titleRef as? String, !str.isEmpty, str.count > 1 {
            collected.append(str)
        }

        // kAXDescriptionAttribute — accessible descriptions
        let (descriptionError, descRef) = attribute(element, kAXDescriptionAttribute, failed: &failed)
        if descriptionError == .success,
           let str = descRef as? String, !str.isEmpty, str.count > 1 {
            collected.append(str)
        }
    }
}
