// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics

/// A click outside the panel closes it, unless the window server delivered it
/// to one of our own windows (the out-of-process AirPlay route picker).
enum PopoverDismissContract {
    static func run(_ suite: TestSuite) {
        let own: pid_t = 100
        let other: pid_t = 200
        let click = CGPoint(x: 400, y: 300)
        let picker = PopoverDismissSupport.Window(number: 1, ownerPID: own,
                                                  bounds: CGRect(x: 350, y: 250, width: 200, height: 200), alpha: 1)
        let settings = PopoverDismissSupport.Window(number: 2, ownerPID: own,
                                                    bounds: CGRect(x: 0, y: 0, width: 900, height: 700), alpha: 1)
        let foreground = PopoverDismissSupport.Window(number: 3, ownerPID: other,
                                                      bounds: CGRect(x: 100, y: 100, width: 800, height: 600), alpha: 1)
        let brightness = PopoverDismissSupport.Window(number: 4, ownerPID: own,
                                                      bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117), alpha: 1)
        let invisible = PopoverDismissSupport.Window(number: 5, ownerPID: own,
                                                     bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117), alpha: 0)
        func landsInOwn(_ windows: [PopoverDismissSupport.Window], clickThrough: Set<Int> = []) -> Bool {
            PopoverDismissSupport.clickLandedInOwnWindow(at: click, windows: windows, ownPID: own,
                                                         clickThroughWindowNumbers: clickThrough)
        }

        suite.expect(landsInOwn([picker, foreground, settings]),
                     "a click in the route picker keeps the panel open")
        suite.expect(!landsInOwn([foreground, settings]),
                     "a click in another app over our Settings window closes the panel")
        suite.expect(!landsInOwn([brightness, foreground], clickThrough: [4]),
                     "a click-through overlay does not keep the panel open")
        suite.expect(!landsInOwn([invisible, foreground]),
                     "a transparent window does not keep the panel open")
        let elsewhere = PopoverDismissSupport.Window(number: 6, ownerPID: own,
                                                     bounds: CGRect(x: 1_200, y: 800, width: 200, height: 200), alpha: 1)
        suite.expect(!landsInOwn([elsewhere]) && !landsInOwn([]),
                     "a click outside every window closes the panel")
        suite.expect(PopoverDismissSupport.windowServerPoint(for: CGPoint(x: 10, y: 1_000), mainDisplayHeight: 1_117)
                     == CGPoint(x: 10, y: 117),
                     "mouse locations convert to window-server coordinates")
    }
}
