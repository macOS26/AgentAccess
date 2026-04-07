import AgentAudit
import AXorcist
import Foundation
import AppKit

extension AccessibilityService {
    // MARK: - Perform Actions

    /// Perform an AX action on an element identified by role/title/value/appBundleId.
    /// Coordinate-based dispatch is intentionally absent — every action must go
    /// through AXorcist's element-finding so it can be reliably retargeted when
    /// the UI shifts. If you need to perform an action 'somewhere on screen',
    /// find the element first via find_element / inspect_element and pass its
    /// role+title to this method.
    @MainActor
    public func performAction(role: String?, title: String?, value: String?, appBundleId: String?, x: CGFloat?, y: CGFloat?, action: String) -> String {
        if Self.isBrowser(appBundleId) || (appBundleId == nil && Self.frontmostAppIsBrowser()) {
            return Self.safariPageInfo()
        }
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility permission required.")
        }
        AuditLog.log(.accessibility, "performAction(\(action)) role: \(role ?? "nil"), title: \(title ?? "nil"), value: \(value ?? "nil"), app: \(appBundleId ?? "nil")")

        if Self.isRestricted(action) {
            return errorJSON("Action '\(action)' is disabled in Accessibility Settings. Enable it in Settings to allow this action.")
        }

        // Coordinate paths are NOT supported. x/y are accepted in the signature
        // for source compatibility but ignored — the LLM must identify elements
        // by role/title/value, not by screen position.
        _ = x; _ = y

        // Resolve app name → bundle ID
        let appBundleId = resolveBundleId(appBundleId)

        // AXorcist: activate the target app first so it's frontmost
        if let bundleId = appBundleId,
           let app = RunningApplicationHelper.applications(withBundleIdentifier: bundleId).first,
           let appElement = Element.application(for: app) {
            _ = appElement.activate()
            Thread.sleep(forTimeInterval: 0.1)
        }

        // Use AXorcist PerformActionCommand — atomic find + action
        var criteria: [Criterion] = []
        if let role = role { criteria.append(Criterion(attribute: "AXRole", value: role)) }
        if let value = value { criteria.append(Criterion(attribute: "AXValue", value: value, matchType: .contains)) }

        if criteria.isEmpty && title == nil {
            return errorJSON("No search criteria — provide role, title, or value. Coordinate-based actions are disabled; find_element first if you need to locate something on screen.")
        }

        // Use computedNameContains for title — searches AXTitle + AXDescription + AXHelp
        let locator = Locator(matchAll: true, criteria: criteria, computedNameContains: title)
        let cmd = PerformActionCommand(appIdentifier: appBundleId, locator: locator, action: action, maxDepthForSearch: 100)
        let envelope = AXCommandEnvelope(commandID: UUID().uuidString, command: .performAction(cmd))
        let response = AXorcist.shared.runCommand(envelope)

        switch response {
        case .success:
            return successJSON(["message": "Action '\(action)' performed"])
        case .error(let message, _, _):
            return errorJSON("Action failed: \(message)")
        }
    }

    // MARK: - Coordinate-based input (REMOVED)
    //
    // typeText(_:at:y:), clickAt(x:y:button:clicks:), scrollAt(x:y:deltaX:deltaY:),
    // and pressKey(virtualKey:modifiers:) all used InputDriver to send raw CGEvents
    // at screen coordinates. They were unreliable (window positions shift, retina
    // scaling, multi-display setups) and bypassed AXorcist entirely. Removed.
    //
    // Use these AXorcist-based replacements instead:
    //   - clickAt(x:y:...)         → clickElement(role:title:appBundleId:)
    //   - typeText(_:at:y:)        → typeTextIntoElement(role:title:text:appBundleId:)
    //   - scrollAt(x:y:...)        → scrollToElement(role:title:appBundleId:)
    //   - pressKey(virtualKey:...) → clickElement on the relevant button, or
    //                                clickMenuItem for keyboard shortcuts
}
