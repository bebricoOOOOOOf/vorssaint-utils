// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreGraphics

/// Decides whether a click reported by the global mouse monitor actually went
/// to one of our own windows. Out-of-process content we host (the system
/// AirPlay route picker) reaches the global monitor like a click in another
/// app, so the monitor asks the window server which window was frontmost at
/// the click instead of trusting window rectangles: a visible window of ours
/// covered by another app does not count, and neither do click-through
/// overlays (extra brightness, notch probes), which never receive clicks.
enum PopoverDismissSupport {
    struct Window {
        let number: Int
        let ownerPID: pid_t
        /// Window-server coordinates: origin at the top left of the main display.
        let bounds: CGRect
        let alpha: Double
    }

    /// `windows` front to back, as the window server lists them.
    static func clickLandedInOwnWindow(at point: CGPoint, windows: [Window], ownPID: pid_t,
                                       clickThroughWindowNumbers: Set<Int>) -> Bool {
        let recipient = windows.first { window in
            window.alpha > 0
                && window.bounds.contains(point)
                && !(window.ownerPID == ownPID && clickThroughWindowNumbers.contains(window.number))
        }
        return recipient?.ownerPID == ownPID
    }

    /// Converts `NSEvent.mouseLocation` (origin at the bottom left of the main
    /// display) into window-server coordinates.
    static func windowServerPoint(for location: CGPoint, mainDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: location.x, y: mainDisplayHeight - location.y)
    }

    static func clickLandedInOwnWindow(at mouseLocation: CGPoint) -> Bool {
        guard let mainHeight = NSScreen.screens.first?.frame.height,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let windows: [Window] = list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let owner = info[kCGWindowOwnerPID as String] as? Int,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return Window(number: number, ownerPID: pid_t(owner), bounds: bounds,
                          alpha: info[kCGWindowAlpha as String] as? Double ?? 1)
        }
        let clickThrough = Set(NSApplication.shared.windows.filter(\.ignoresMouseEvents).map(\.windowNumber))
        return clickLandedInOwnWindow(at: windowServerPoint(for: mouseLocation, mainDisplayHeight: mainHeight),
                                      windows: windows,
                                      ownPID: ProcessInfo.processInfo.processIdentifier,
                                      clickThroughWindowNumbers: clickThrough)
    }
}
