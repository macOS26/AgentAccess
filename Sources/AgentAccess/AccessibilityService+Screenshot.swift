import AgentAudit
import AXorcist
import Foundation
import AppKit

extension AccessibilityService {
    // MARK: - Screenshot
    //
    // Both screenshot methods spawn /usr/sbin/screencapture and call
    // process.waitUntilExit(). That's a synchronous wait of ~50-200ms which
    // BLOCKS the calling thread. The previous implementation ran on
    // MainActor and froze Agent's UI on every screenshot.
    //
    // Both are now nonisolated async with internal DispatchQueue.global()
    // dispatch via withCheckedContinuation, so the screencapture wait runs
    // on a background thread and main stays responsive. Permission checks
    // and audit logging happen on the calling actor (cheap), the actual
    // process spawn + wait + file read happens on global.

    /// Capture a screenshot of a region or window. Requires Screen Recording permission.
    /// Returns the path to the saved PNG file, or an error message.
    public nonisolated func captureScreenshot(x: CGFloat? = nil, y: CGFloat? = nil, width: CGFloat? = nil, height: CGFloat? = nil, windowID: Int? = nil) async -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility/Screen Recording permission required.")
        }
        AuditLog.log(.accessibility, "captureScreenshot(x: \(x.map(String.init) ?? "nil"), y: \(y.map(String.init) ?? "nil"), w: \(width.map(String.init) ?? "nil"), h: \(height.map(String.init) ?? "nil"), windowID: \(windowID.map(String.init) ?? "nil"))")

        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let fileName = "screenshot_\(UUID().uuidString).png"
                let outputPath = home.appendingPathComponent("Documents/AgentScript/screenshots/\(fileName)").path
                try? FileManager.default.createDirectory(atPath: home.appendingPathComponent("Documents/AgentScript/screenshots").path, withIntermediateDirectories: true)

                var args = ["-x", "-t", "png"]
                if let wid = windowID, wid > 0 {
                    args.append("-l")
                    args.append("\(wid)")
                } else if let x = x, let y = y, let w = width, let h = height {
                    args.append("-R")
                    args.append("\(Int(x)),\(Int(y)),\(Int(w)),\(Int(h))")
                }
                args.append(outputPath)

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = args
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        continuation.resume(returning: self.errorJSON("screencapture failed with exit code \(process.terminationStatus)"))
                        return
                    }
                    guard FileManager.default.fileExists(atPath: outputPath) else {
                        continuation.resume(returning: self.errorJSON("Screenshot file not created at \(outputPath)"))
                        return
                    }
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int64) ?? 0
                    continuation.resume(returning: self.successJSON([
                        "path": outputPath,
                        "size": fileSize,
                        "message": "Screenshot saved to \(outputPath)"
                    ]))
                } catch {
                    continuation.resume(returning: self.errorJSON("Failed to capture screenshot: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// Capture a screenshot of the frontmost window (or full screen if no front window).
    /// Requires Screen Recording permission. Runs off the main thread.
    public nonisolated func captureAllWindows() async -> String {
        guard Self.hasAccessibilityPermission() else {
            return errorJSON("Accessibility/Screen Recording permission required.")
        }
        AuditLog.log(.accessibility, "captureAllWindows()")

        // frontmostWindowID needs main actor for AX queries — hop, get the ID, then
        // dispatch the screencapture work to background.
        let frontWindowID: CGWindowID? = await MainActor.run { Self.frontmostWindowID() }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let fileName = "screenshot_\(UUID().uuidString).png"
                let outputPath = home.appendingPathComponent("Documents/AgentScript/screenshots/\(fileName)").path
                try? FileManager.default.createDirectory(atPath: home.appendingPathComponent("Documents/AgentScript/screenshots").path, withIntermediateDirectories: true)

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                if let wid = frontWindowID {
                    process.arguments = ["-x", "-t", "png", "-l", "\(wid)", outputPath]
                } else {
                    process.arguments = ["-x", "-t", "png", outputPath]
                }
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        continuation.resume(returning: self.errorJSON("screencapture failed with exit code \(process.terminationStatus)"))
                        return
                    }
                    guard FileManager.default.fileExists(atPath: outputPath) else {
                        continuation.resume(returning: self.errorJSON("Screenshot file not created"))
                        return
                    }
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int64) ?? 0
                    continuation.resume(returning: self.successJSON([
                        "path": outputPath,
                        "size": fileSize,
                        "message": "Fullscreen screenshot saved to \(outputPath)"
                    ]))
                } catch {
                    continuation.resume(returning: self.errorJSON("Failed to capture screenshot: \(error.localizedDescription)"))
                }
            }
        }
    }
}
