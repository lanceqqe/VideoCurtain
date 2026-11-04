import AppKit
import Foundation
import SafariServices

/// Passes the extension's "enter"/"exit" on to the curtain app, launching it if needed.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        guard let state = message?["state"] as? String, state == "enter" || state == "exit",
              let url = URL(string: "videocurtain://\(state)") else {
            context.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration) { _, _ in
            context.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
