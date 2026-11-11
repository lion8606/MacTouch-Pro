import AppKit
import ApplicationServices

// MARK: keep the Accessibility Keyboard in place

// While the touch display sleeps it can vanish from macOS for several seconds. Windows then move to a
// stand-in display, and the Accessibility Keyboard's panels come back centred; unlocking centres them
// again. MacTouch remembers where the panels sit while the display is settled and the screen unlocked,
// and moves them back after display changes, wake, unlock and launch.
let keyboardBundleID = "com.apple.inputmethod.AssistiveControl"
var keyboardPositions = defaults.dictionary(forKey: "keyboardPositions") as? [String: String] ?? [:]
var lastReconfig = now(), restoreGen = 0
var screenLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false

// Restore after each delay; a newer request cancels the older one's remaining passes.
func scheduleRestore(_ delays: [Double], _ why: String) {
    lastReconfig = now(); restoreGen += 1
    let g = restoreGen
    for d in delays {
        DispatchQueue.main.asyncAfter(deadline: .now() + d) { if g == restoreGen { restoreKeyboard(why) } }
    }
}

func keyboardPanels() -> [(window: AXUIElement, origin: CGPoint, size: CGSize)] {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: keyboardBundleID).first else { return [] }
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &v) == .success,
          let windows = v as? [AXUIElement] else { return [] }
    let disp = CGDisplayBounds(targetDisplay())
    return windows.compactMap { w in
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
        var p = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        // Skip the transparent overlay layers: they span a whole display, possibly the stand-in one.
        if sz.width < 20 || sz.height < 20 || sz.width >= disp.width || sz.height >= disp.height { return nil }
        return (w, p, sz)
    }
}
// Panels are told apart by size: the minimized panel and the full keyboard each keep their own spot.
func panelKey(_ s: CGSize) -> String { "\(Int((s.width / 10).rounded()) * 10)x\(Int((s.height / 10).rounded()) * 10)" }

func rememberKeyboard() {
    guard cfg.keepKeyboard, AXIsProcessTrusted(), !screenLocked, now() - lastReconfig > 10 else { return }
    let d = CGDisplayBounds(targetDisplay())
    guard targetFound else { return }
    var changed = false
    for p in keyboardPanels() {
        // A panel exactly centred is where macOS puts it after a reset, not where the user left it.
        if abs(p.origin.x + p.size.width / 2 - d.midX) < 3 && abs(p.origin.y + p.size.height / 2 - d.midY) < 3 { continue }
        let k = panelKey(p.size), v = "\(Int(p.origin.x)),\(Int(p.origin.y))"
        if keyboardPositions[k] != v { keyboardPositions[k] = v; changed = true }
    }
    if changed { defaults.set(keyboardPositions, forKey: "keyboardPositions") }
}

func restoreKeyboard(_ why: String) {
    guard cfg.keepKeyboard, AXIsProcessTrusted(), !screenLocked else { return }
    _ = targetDisplay()
    guard targetFound else { return }
    for p in keyboardPanels() {
        guard let v = keyboardPositions[panelKey(p.size)]?.split(separator: ","), v.count == 2,
              let x = Double(v[0]), let y = Double(v[1]), abs(p.origin.x - x) > 3 || abs(p.origin.y - y) > 3 else { continue }
        var np = CGPoint(x: x, y: y)
        if let pv = AXValueCreate(.cgPoint, &np), AXUIElementSetAttributeValue(p.window, kAXPositionAttribute as CFString, pv) == .success {
            log("moved keyboard panel \(panelKey(p.size)) back to \(Int(x)),\(Int(y)) (\(why))")
        }
    }
}

// MARK: auto keyboard & smart hardware-keyboard detection

// When a touch puts the focus in a text field:
// - If a physical keyboard is present (built-in MacBook keyboard or recently typed external keyboard)
//   and cfg.smartKeyboard is on, stay out of the user's way so they can type directly on their real keyboard.
// - On a keyboardless headless Mac (e.g. Mac mini without keyboard activity), automatically turn on and
//   expand the macOS Accessibility Keyboard on the touch display, and hide it again when leaving the field.
let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]
var wasEditable = false, autoExpanded = false, autoTurnedOn = false, leftFieldAt = 0.0
var lastHardwareKeyTime = 0.0, lastTapTargetPt = CGPoint.zero

func hardwareKeyPressed() {
    lastHardwareKeyTime = now()
    if cfg.smartKeyboard && (autoTurnedOn || autoExpanded) {
        if autoTurnedOn {
            setKeyboard(false, "hardware keyboard typed")
            autoTurnedOn = false; autoExpanded = false
        } else if let b = keyboardButton("Minimize") {
            clickKeyboard(b); autoExpanded = false
        }
    }
}

/// True when this Mac has an built-in Apple keyboard (MacBook) or a physical keyboard was typed on recently.
func hasActiveHardwareKeyboard() -> Bool {
    if CGDisplayIsBuiltin(CGMainDisplayID()) != 0 { return true }
    for d in onlineDisplays() where CGDisplayIsBuiltin(d) != 0 { return true }
    if lastHardwareKeyTime > 0 && now() - lastHardwareKeyTime < 600 { return true }
    return false
}

func axString(_ e: AXUIElement, _ a: String) -> String {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v as? String ?? "" : ""
}

func axBool(_ e: AXUIElement, _ a: String) -> Bool {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success && (v as? Bool == true)
}

func isElementEditable(_ e: AXUIElement) -> Bool {
    let role = axString(e, kAXRoleAttribute)
    if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { return true }
    if axBool(e, "AXEditable") { return true }
    return false
}

func focusIsEditable() -> Bool? {   // nil: focus is on the keyboard itself, so nothing changed
    if let front = NSWorkspace.shared.frontmostApplication {
        if front.bundleIdentifier == keyboardBundleID { return nil }
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var fv: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &fv) == .success {
            return isElementEditable(fv as! AXUIElement)
        }
    }
    var v: CFTypeRef?
    if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &v) == .success {
        let e = v as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(e, &pid)
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == keyboardBundleID { return nil }
        return isElementEditable(e)
    }
    if lastTapTargetPt != .zero, let hit = element(at: lastTapTargetPt) {
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == keyboardBundleID { return nil }
        return isElementEditable(hit)
    }
    return false
}

// Frame of the keyboard button titled "Keyboard"/"键盘" (minimized panel) or "Minimize"/"最小化" (full panel).
func keyboardButton(_ title: String) -> CGRect? {
    let titles: Set<String> = title == "Keyboard" ? ["Keyboard", "键盘", "輔助使用鍵盤", "辅助功能键盘"]
                            : title == "Minimize" ? ["Minimize", "最小化", "收起"] : [title]
    func find(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
        if axString(e, kAXRoleAttribute) == "AXButton" && titles.contains(axString(e, kAXTitleAttribute)) { return e }
        var v: CFTypeRef?
        guard depth < 3, AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success,
              let kids = v as? [AXUIElement] else { return nil }
        for k in kids { if let f = find(k, depth + 1) { return f } }
        return nil
    }
    for p in keyboardPanels() {
        guard let b = find(p.window, 0) else { continue }
        var pv: CFTypeRef?, sv: CFTypeRef?
        var o = CGPoint.zero, sz = CGSize.zero
        if AXUIElementCopyAttributeValue(b, kAXPositionAttribute as CFString, &pv) == .success { AXValueGetValue(pv as! AXValue, .cgPoint, &o) }
        if AXUIElementCopyAttributeValue(b, kAXSizeAttribute as CFString, &sv) == .success { AXValueGetValue(sv as! AXValue, .cgSize, &sz) }
        return CGRect(origin: o, size: sz)
    }
    return nil
}

func clickKeyboard(_ r: CGRect) {
    let back = CGEvent(source: nil)?.location ?? .zero, p = CGPoint(x: r.midX, y: r.midY)
    post(.mouseMoved, p); post(.leftMouseDown, p); post(.leftMouseUp, p); post(.mouseMoved, back)
}

// Polling runs only when it can matter: every 0.25 s for 2.5 s after a tap, then every second while
// MacTouch has the keyboard expanded, otherwise not at all.
var autoKeyboardTimer: Timer?, autoKeyboardInterval = 0.0

func autoKeyboardTapped(at p: CGPoint = .zero) {
    guard cfg.autoKeyboard else { return }
    lastTapTargetPt = p
    if !autoExpanded, !autoTurnedOn, let e = focusIsEditable() { wasEditable = e }   // focus before this tap lands
    scheduleAutoKeyboard(0.25)
}

func scheduleAutoKeyboard(_ interval: Double) {
    guard interval != autoKeyboardInterval || autoKeyboardTimer == nil else { return }
    autoKeyboardTimer?.invalidate()
    autoKeyboardInterval = interval
    let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
        autoKeyboardTick()
        if now() - lastTouchTap < 2.5 { scheduleAutoKeyboard(0.25) }
        else if (autoExpanded || autoTurnedOn) && cfg.autoKeyboard { scheduleAutoKeyboard(1) }
        else { autoKeyboardTimer?.invalidate(); autoKeyboardTimer = nil; autoKeyboardInterval = 0 }
    }
    t.tolerance = interval * 0.2
    autoKeyboardTimer = t
}

func moveKeyboardToTouchDisplay() {
    let d = CGDisplayBounds(targetDisplay())
    for p in keyboardPanels() where !d.contains(CGPoint(x: p.origin.x + p.size.width / 2, y: p.origin.y + p.size.height / 2)) {
        var np = CGPoint(x: d.midX - p.size.width / 2, y: d.maxY - p.size.height - 48)
        if let pv = AXValueCreate(.cgPoint, &np) {
            AXUIElementSetAttributeValue(p.window, kAXPositionAttribute as CFString, pv)
        }
    }
}

func autoKeyboardTick() {
    guard cfg.autoKeyboard, !cfg.paused, AXIsProcessTrusted(), !screenLocked, !piano.active, !calibrator.active, !(sketch.active && !sketch.overlay),
          let editable = focusIsEditable() else { return }
    defer { wasEditable = editable }
    if editable {
        leftFieldAt = 0
        if cfg.smartKeyboard && hasActiveHardwareKeyboard() { return }
        if now() - lastTouchTap < 2.2 {
            if keyboardOn() == false && !keyboardHandedBack {
                setKeyboard(true, "auto keyboard: text field focused")
                autoTurnedOn = true; autoExpanded = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { moveKeyboardToTouchDisplay() }
            } else if !wasEditable, let b = keyboardButton("Keyboard") {
                clickKeyboard(b); autoExpanded = true; log("auto keyboard: expanded")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { moveKeyboardToTouchDisplay() }
            }
        }
    } else if autoTurnedOn {
        if leftFieldAt == 0 { leftFieldAt = now() }
        if now() - leftFieldAt > 1.5 {
            setKeyboard(false, "auto keyboard: left text field")
            autoTurnedOn = false; autoExpanded = false
        }
    } else if autoExpanded {
        if keyboardButton("Keyboard") != nil { autoExpanded = false; return }   // minimized by hand
        if leftFieldAt == 0 { leftFieldAt = now() }
        if now() - leftFieldAt > 1.5, let b = keyboardButton("Minimize") {
            clickKeyboard(b); autoExpanded = false; log("auto keyboard: minimized")
        }
    }
}

// MARK: turning the keyboard on and off

// The Accessibility Keyboard's switch in System Settings ▸ Accessibility ▸ Keyboard, through the
// UniversalAccess functions System Settings calls. They are private, so MacTouch looks them up at run
// time and leaves the keyboard alone (the menu item disabled) where they are missing.
let keyboardSwitch: (isOn: @convention(c) () -> Bool, set: @convention(c) (Bool) -> Void)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess", RTLD_LAZY),
          let isOn = dlsym(h, "UAVirtualKeyboardIsEnabled"), let set = dlsym(h, "UAVirtualKeyboardSetEnabled") else {
        log("cannot switch the Accessibility Keyboard on and off on this macOS"); return nil
    }
    return (unsafeBitCast(isOn, to: (@convention(c) () -> Bool).self), unsafeBitCast(set, to: (@convention(c) (Bool) -> Void).self))
}()

/// Whether the Accessibility Keyboard is on; nil if MacTouch cannot tell.
func keyboardOn() -> Bool? { keyboardSwitch?.isOn() }

let keyboardWasMinimized = "keyboardWasMinimized", keyboardOffForNoTouchscreen = "keyboardOffForNoTouchscreen"

func setKeyboard(_ on: Bool, _ why: String) {
    guard let sw = keyboardSwitch, sw.isOn() != on else { return }
    if !on { defaults.set(keyboardButton("Keyboard") != nil, forKey: keyboardWasMinimized) }
    sw.set(on)
    log("Accessibility Keyboard \(on ? "on" : "off") (\(why))")
    guard on else { return }
    // It comes back expanded and centred: minimize it again if it was, and put its panels where they were.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        if defaults.bool(forKey: keyboardWasMinimized), AXIsProcessTrusted(), let b = keyboardButton("Minimize") { clickKeyboard(b) }
    }
    scheduleRestore([1.5, 4], "keyboard on")
}

// With no touchscreen connected for 10 s (longer than a replug or a controller changing mode), the
// keyboard goes off; it comes back when a touchscreen connects, if MacTouch turned it off. That is
// remembered across restarts. Once the keyboard is turned on by hand, it is left alone until a
// touchscreen connects. Time with the displays asleep or the screen locked doesn't count: some
// monitors power their USB hub down with the picture.
var noTouchscreenSince: Double?, keyboardHandedBack = false
func keyboardFollowTouchscreens() {
    guard cfg.keyboardFollowsTouch, hidOpen, !probe, !checkOnly else { return }
    let key = keyboardOffForNoTouchscreen
    if !touchDevices().isEmpty {
        noTouchscreenSince = nil; keyboardHandedBack = false
        if defaults.bool(forKey: key) { defaults.removeObject(forKey: key); setKeyboard(true, "a touchscreen is connected") }
    } else if defaults.bool(forKey: key), keyboardOn() == true {   // turned on by hand (System Settings)
        defaults.removeObject(forKey: key); keyboardHandedBack = true
    } else if keyboardHandedBack || screenLocked || CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
        noTouchscreenSince = nil
    } else if let since = noTouchscreenSince {
        if now() - since > 10, keyboardOn() == true, !defaults.bool(forKey: key) {
            setKeyboard(false, "no touchscreen connected"); defaults.set(true, forKey: key)
        }
    } else {
        noTouchscreenSince = now()
    }
}
