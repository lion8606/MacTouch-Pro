import AppKit
import ApplicationServices
import IOKit.pwr_mgt

// MARK: gesture state

enum Two { case undecided, scroll, zoom, rotate, rightEdge }
enum Mode {
    case idle
    case pending(CGPoint, Int)      // one finger down, not yet tap/move/hold (start, timer seq)
    case held(CGPoint)              // one-finger scroll: held still; move = drag, lift = right click
    case dragging
    case scroll1                    // one-finger scroll: scrolling with one finger
    case two(CGPoint, Double, Two)  // last centroid, start time, gesture kind
    case drag3(CGPoint)             // 3-finger trackpad drag: last centroid
    case multi(CGPoint, CGPoint, Double, Double, Int, Bool)   // 3+ fingers: origin, last centroid, start spread, start time, max fingers, fired
    case done                       // gesture consumed; wait for all fingers up
}

let heldRightClickSecs = 0.5   // one-finger scroll: holding still this long after the hold right-clicks
let moveTol = 14.0, tapMaxSecs = 0.35, dblDist = 36.0, followTol = 20.0, pinchTol = 25.0, rotateTolDeg = 12.0, spreadPinchTol = 42.0, zoomKeyStep = log(1.25)
func dblSecs() -> Double { min(0.45, max(0.30, NSEvent.doubleClickInterval)) }
// A second try after a near miss also lands soon and close by, but on something else: that is a new
// click, not a double click (which a button may ignore and a file would open).
let tapWobble = 8.0
let axSystem: AXUIElement = { let e = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(e, 0.05); return e }()
func element(at p: CGPoint) -> AXUIElement? {
    var e: AXUIElement?
    return AXUIElementCopyElementAtPosition(axSystem, Float(p.x), Float(p.y), &e) == .success ? e : nil
}
func continuesTap(_ p: CGPoint) -> Bool {
    let d = dist(p, lastTapPt)
    guard now() - lastTapTime < dblSecs(), d < dblDist else { return false }
    if d <= tapWobble || !AXIsProcessTrusted() { return true }
    guard let was = element(at: lastTapPt), let here = element(at: p) else { return true }
    if CFEqual(was, here) { return true }
    log("touch near the last tap, on something else: a new click")
    return false
}
var slots: [Int: Slot] = [:]   // keyed by finger collection cookie
var mode = Mode.idle, dirty = false, pressSeq = 0, lastN = 0
var lastPt = CGPoint.zero, twoStart = CGPoint.zero
var lastTapTime = 0.0, lastTapPt = CGPoint.zero, clicks: Int64 = 1
var pressClicks: Int64 = 1, dragClicks: Int64 = 1   // click count of this touch, and of the drag it made
var accX = 0.0, accY = 0.0
// As a finger lifts, its last report often jumps 10 pt or more, which would turn a tap into a drag
// (in a title bar, a small window move that slides the close button away). A move therefore counts
// only once the next report still has the finger down and moved. A tap clicks where the touch rested:
// the median of its reports.
var unconfirmedMove = false, restingPts: [CGPoint] = []
func confirmedMove(_ moved: Bool) -> Bool {
    defer { unconfirmedMove = moved }
    return moved && unconfirmedMove
}
var pinchStart = 0.0, pinchLast = 0.0, zoomKeyAcc = 0.0
var rotateStart = 0.0, rotateLast = 0.0
var lastTwoTapTime = 0.0, lastTwoTapPt = CGPoint.zero, twoTapTimerSeq = 0
var inDragApp = false, canHold = true, zoomHere = "gesture"   // decided per gesture from the window under the finger(s)
var edgeSnap: CGPoint?, dragOffset = CGPoint.zero   // window-edge resize: press point on the edge, finger offset
func shifted(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dragOffset.x, y: p.y + dragOffset.y) }
let src = CGEventSource(stateID: .hidSystemState)

// MARK: event output

func post(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clickState: Int64 = 1) {
    guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
    if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: clickState) }
    e.post(tap: .cghidEventTap)
}

// Magnetic target-assist for small UI controls (e.g. 16x16 pt window close / minimize / zoom traffic-lights,
// small toolbar buttons): fingertips cover ~40 pt and panel edges often skew by 6-10 pt.
func magneticTarget(near p: CGPoint, win: (owner: String, pid: pid_t, frame: CGRect, layer: Int)?) -> (center: CGPoint, actionElement: AXUIElement?, label: String)? {
    guard AXIsProcessTrusted() else { return nil }
    // 1. Check top-left window traffic lights (Close / Minimize / Zoom) with a generous fingertip halo.
    if let w = win, w.layer == 0, w.pid > 0,
       p.x >= w.frame.minX - 10 && p.x <= w.frame.minX + 100 && p.y >= w.frame.minY - 10 && p.y <= w.frame.minY + 56 {
        var wv: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(w.pid), kAXWindowsAttribute as CFString, &wv) == .success,
           let axWins = wv as? [AXUIElement] {
            for axW in axWins {
                var wp: CFTypeRef?
                var wpt = CGPoint.zero
                if AXUIElementCopyAttributeValue(axW, kAXPositionAttribute as CFString, &wp) == .success, let wp {
                    AXValueGetValue(wp as! AXValue, .cgPoint, &wpt)
                }
                guard hypot(wpt.x - w.frame.minX, wpt.y - w.frame.minY) < 25 else { continue }
                var best: (d: Double, c: CGPoint, el: AXUIElement, name: String)?
                for (attr, name) in [(kAXCloseButtonAttribute, "close"), (kAXMinimizeButtonAttribute, "minimize"), (kAXZoomButtonAttribute, "zoom")] {
                    var bv: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(axW, attr as CFString, &bv) == .success, let btn = bv else { continue }
                    let bEl = btn as! AXUIElement
                    var bp: CFTypeRef?, bs: CFTypeRef?
                    var bpt = CGPoint.zero, bsz = CGSize.zero
                    if AXUIElementCopyAttributeValue(bEl, kAXPositionAttribute as CFString, &bp) == .success, let bp { AXValueGetValue(bp as! AXValue, .cgPoint, &bpt) }
                    if AXUIElementCopyAttributeValue(bEl, kAXSizeAttribute as CFString, &bs) == .success, let bs { AXValueGetValue(bs as! AXValue, .cgSize, &bsz) }
                    guard bsz.width > 0 else { continue }
                    let c = CGPoint(x: bpt.x + bsz.width / 2, y: bpt.y + bsz.height / 2)
                    let d = dist(p, c)
                    // Buttons are 20 pt apart horizontally: snap to whichever traffic-light center is closest within 18 pt.
                    if d <= 18 && (best == nil || d < best!.d) { best = (d, c, bEl, name) }
                }
                if let b = best {
                    return (b.c, b.name == "zoom" ? nil : b.el, b.name)
                }
            }
        }
    }
    // 2. General small button center-snap (e.g. tab close 'x' buttons <= 28x28 pt) when finger lands on or within 6 pt.
    if let el = element(at: p) {
        var r: CFTypeRef?, bp: CFTypeRef?, bs: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
        if (r as? String) == "AXButton",
           AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &bp) == .success, let bp,
           AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &bs) == .success, let bs {
            var bpt = CGPoint.zero, bsz = CGSize.zero
            AXValueGetValue(bp as! AXValue, .cgPoint, &bpt)
            AXValueGetValue(bs as! AXValue, .cgSize, &bsz)
            if bsz.width > 4 && bsz.width <= 30 && bsz.height > 4 && bsz.height <= 30 {
                return (CGPoint(x: bpt.x + bsz.width / 2, y: bpt.y + bsz.height / 2), nil, "small-btn")
            }
        }
    }
    return nil
}

var lastTouchTap = 0.0
func tap(_ rawPt: CGPoint) {
    lastTouchTap = now()
    clicks = pressClicks
    let win = windowAt(rawPt)
    let mag = clicks == 1 ? magneticTarget(near: rawPt, win: win) : nil
    let p = mag?.center ?? rawPt
    lastTapTime = now(); lastTapPt = p

    // Direct AXPress on traffic-light close/minimize buttons works reliably in 1 tap even on background windows!
    if let btn = mag?.actionElement, AXUIElementPerformAction(btn, kAXPressAction as CFString) == .success {
        log("tap (\(mag!.label) button AXPress) at \(Int(p.x)),\(Int(p.y)) (raw \(Int(rawPt.x)),\(Int(rawPt.y)))")
        return
    }

    var activatedBg = false
    if let w = win, w.pid > 0, let app = NSRunningApplication(processIdentifier: w.pid), !app.isActive {
        app.activate(options: [])
        activatedBg = true
    }

    let fireClick = {
        post(.mouseMoved, p)
        usleep(12_000)   // 12 ms hover settle so AppKit/WebKit buttons register mouseEntered before mouseDown
        post(.leftMouseDown, p, clickState: clicks)
        usleep(22_000)   // 22 ms realistic press hold so custom controls never drop 0-ms synthetic clicks
        post(.leftMouseUp, p, clickState: clicks)
        autoKeyboardTapped(at: p)
        log("tap x\(clicks) at \(Int(p.x)),\(Int(p.y))" + (mag != nil ? " (snapped \(mag!.label))" : ""))
    }

    if activatedBg {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: fireClick)
    } else {
        fireClick()
    }
}

func rightClick(_ p: CGPoint, _ why: String) {
    post(.mouseMoved, p)
    post(.rightMouseDown, p, .right)
    post(.rightMouseUp, p, .right)
    log("right click (\(why)) at \(Int(p.x)),\(Int(p.y))")
}

func startDrag(_ from: CGPoint, _ to: CGPoint, clicks n: Int64 = 1) {
    dragClicks = n; lastTapTime = 0   // a tap after this drag starts afresh
    post(.leftMouseDown, from, clickState: n); post(.leftMouseDragged, to, clickState: n)
    mode = .dragging; log("drag start\(n > 1 ? " (\(n == 2 ? "double" : "triple")-tap drag: select)" : "") at \(Int(from.x)),\(Int(from.y))")
}

// Posted events don't count as user activity, so a touch alone would never wake a sleeping display
// or reset the idle timer. Declaring activity does both.
var activityID: IOPMAssertionID = 0
func declareUserActivity() {
    _ = IOPMAssertionDeclareUserActivity("MacTouch touch" as CFString, kIOPMUserActiveLocal, &activityID)
}

func endGesture() {   // release anything held, e.g. when pausing or the controller goes away
    if case .dragging = mode { post(.leftMouseUp, shifted(lastPt), clickState: dragClicks) }
    if case .drag3(let c) = mode { post(.leftMouseUp, c, clickState: 1) }
    mode = .idle
    endScroll(); stopMomentum()
    holdRing.hide()
    returnPointer(after: 0)
}

// MARK: pointer return

// Touch and mouse act like two pointers: a touch takes the pointer to the finger, and once the gesture
// is over the pointer goes back to where the mouse or trackpad left it, if that is on another display.
// Only once a mouse or trackpad has moved it: on a screen used by touch alone the pointer stays at the
// last touch. Touching the mouse during a touch hands the pointer over for good. The return waits
// 50 ms, so an app busy with the click still finds the pointer where it clicked. A momentum scroll
// does not hold it: it stays with the window it began in (see scroll).
var pointerHome: CGPoint?, handMovedPointer = false, returnSeq = 0
let returnDelay = 0.05

func touchTakesPointer() {   // touch-down
    returnSeq += 1   // a touch before the last one's return keeps its home
    guard cfg.returnPointer, handMovedPointer else { pointerHome = nil; return }
    // A pointer already on the touched display was put there to be used with it: it stays with the touch.
    if pointerHome == nil, let at = CGEvent(source: nil)?.location, !CGDisplayBounds(targetDisplay()).contains(at) {
        pointerHome = at
    }
}

func returnPointer(after delay: Double = returnDelay) {
    guard pointerHome != nil else { return }
    returnSeq += 1
    let seq = returnSeq
    let actualDelay = delay == returnDelay && now() - lastTouchTap < 0.05 ? 0.16 : delay
    DispatchQueue.main.asyncAfter(deadline: .now() + actualDelay) {
        guard seq == returnSeq, let home = pointerHome else { return }
        pointerHome = nil
        if let at = CGEvent(source: nil)?.location, dist(at, home) < 1 { return }
        post(.mouseMoved, home); log("pointer back to \(Int(home.x)),\(Int(home.y))")
    }
}

func handMoved() {   // a mouse or trackpad moved the pointer: from now on it is the mouse's
    handMovedPointer = true
    if pointerHome != nil { pointerHome = nil; log("pointer taken by the mouse") }
}

// Hold cue for one-finger scroll: once a hold registers, a ring under the finger fills over
// heldRightClickSecs. Moving while it shows drags; when it is full, the right click fires.
// "#RRGGBB" or "accent" (the system accent colour).
func color(_ spec: String) -> NSColor {
    if spec == "accent" { return .controlAccentColor }
    guard let v = UInt32(spec.dropFirst(), radix: 16) else { return .orange }
    return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

final class HoldRing {
    let size: CGFloat = 120   // wider than a fingertip, so the ring stays visible around it
    var window: NSWindow?
    let track = CAShapeLayer(), progress = CAShapeLayer()

    func show(at p: CGPoint, duration: Double) {
        let w = window ?? make()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0   // CG is top-down, Cocoa bottom-up
        w.setFrame(NSRect(x: p.x - size / 2, y: primaryHeight - p.y - size / 2, width: size, height: size), display: false)
        progress.strokeColor = color(cfg.ringColor).cgColor
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = 0; fill.toValue = 1; fill.duration = duration
        progress.removeAllAnimations()
        progress.strokeEnd = 1
        progress.add(fill, forKey: "fill")
        w.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }

    private func make() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size), styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.wantsLayer = true
        let path = CGMutablePath()   // from 12 o'clock, clockwise
        path.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: size / 2 - 10,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for (layer, color, width) in [(track, NSColor(white: 0, alpha: 0.35), 9.0), (progress, NSColor.white, 5.0)] {
            layer.path = path
            layer.fillColor = nil
            layer.strokeColor = color.cgColor
            layer.lineWidth = width
            layer.lineCap = .round
            layer.contentsScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
            v.layer?.addSublayer(layer)
        }
        w.contentView = v
        window = w
        return w
    }
}
let holdRing = HoldRing()

// Scrolls carry a trackpad's phases: began, changed and ended while fingers are down, then begin,
// continue and end for the momentum. macOS sends every event of such a scroll, momentum included, to
// the window where it began, so a momentum scroll keeps going there after the pointer has gone back
// to the mouse. (A scroll event's location would route it too, but moves the pointer there.) The
// momentum has to begin while the pointer is still at the touch.
enum ScrollPhase: Int64 { case none = 0, began = 1, changed = 2, ended = 4 }
enum MomentumPhase: Int64 { case none = 0, begin = 1, `continue` = 2, end = 3 }
var scrollPhaseOpen = false

func scroll(_ dx: Double, _ dy: Double, _ phase: ScrollPhase = .none, momentum: MomentumPhase = .none) {
    let dir = cfg.invertScroll ? -1.0 : 1.0
    accX += dx * cfg.scrollScale * dir; accY += dy * cfg.scrollScale * dir
    let ix = Int32(accX.rounded(.towardZero)), iy = Int32(accY.rounded(.towardZero))
    let marker = phase == .began || phase == .ended || momentum == .begin || momentum == .end   // sent even without movement
    if ix == 0 && iy == 0 && !marker { return }
    accX -= Double(ix); accY -= Double(iy)
    guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0) else { return }
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
    e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)
    e.post(tap: .cghidEventTap)
}

func beginScroll() { scroll(0, 0, .began); scrollPhaseOpen = true }
func endScroll() {   // fingers off or the gesture turned into something else
    guard scrollPhaseOpen else { return }
    scroll(0, 0, .ended); scrollPhaseOpen = false
}

// MARK: scroll momentum

// As on iOS, a scroll keeps going after the lift at the finger's speed, slowing by cfg.momentum every
// millisecond (0.998 is UIScrollView's normal rate), and a touch stops it.
var scrollSamples: [(t: Double, dx: Double, dy: Double)] = []   // this scroll's last 100 ms of moves
var momentum: (v: CGPoint, last: Double, timer: Timer)?, caughtMomentum = false

func fingerScroll(_ dx: Double, _ dy: Double) {
    let t = now()
    scrollSamples.removeAll { t - $0.t > 0.1 }
    scrollSamples.append((t, dx, dy))
    scroll(dx, dy, .changed)
}

/// The finger's speed as it lifted, in points per second: its moves over the last 100 ms, leaving out
/// the last one (as a finger lifts its last report often jumps). Nil if it was not moving by then.
func releaseVelocity(_ s: [(t: Double, dx: Double, dy: Double)], at t: Double) -> CGPoint? {
    guard s.count >= 3, let last = s.last, t - last.t < 0.06 else { return nil }
    let moves = s.dropLast(), span = moves.last!.t - s.first!.t
    guard span > 0.005 else { return nil }
    let counted = moves.dropFirst()   // the first move's time only marks the start of the span
    return CGPoint(x: counted.reduce(0) { $0 + $1.dx } / span, y: counted.reduce(0) { $0 + $1.dy } / span)
}

func startMomentum() {
    defer { scrollSamples = [] }
    guard cfg.momentum > 0, let v0 = releaseVelocity(scrollSamples, at: now()) else { return }
    let speed = hypot(v0.x, v0.y), cap = min(1, 6000 / max(speed, 1))
    guard speed > 150 else { return }   // a slow release just stops
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in momentumTick() }
    RunLoop.main.add(timer, forMode: .common)
    momentum = (CGPoint(x: v0.x * cap, y: v0.y * cap), now(), timer)
    scroll(0, 0, momentum: .begin)
    log("momentum at \(Int(speed * cap)) pt/s")
}

func momentumTick() {
    guard var m = momentum else { return }
    let t = now(), dt = t - m.last, k = pow(cfg.momentum, dt * 1000)
    m.v = CGPoint(x: m.v.x * k, y: m.v.y * k); m.last = t
    guard hypot(m.v.x, m.v.y) > 15, cfg.momentum > 0 else { stopMomentum(); return }
    momentum = m
    scroll(m.v.x * dt, m.v.y * dt, momentum: .continue)
}

/// Stops the momentum scroll, if any; returns whether one was running.
@discardableResult
func stopMomentum() -> Bool {
    guard let m = momentum else { return false }
    m.timer.invalidate(); momentum = nil
    scroll(0, 0, momentum: .end)
    return true
}

// Trackpad-style native gestures: NSEventTypeGesture (29) carrying:
//   kIOHIDEventTypeRotation (5)     -> NSEvent.EventType.rotate (field 114 = degrees)
//   kIOHIDEventTypeZoom (8)         -> NSEvent.EventType.magnify (field 113 = magnification)
//   kIOHIDEventTypeSmartMagnify (22)-> NSEvent.EventType.smartMagnify
let gestureType = unsafeBitCast(UInt32(29), to: CGEventType.self)
func field(_ n: UInt32) -> CGEventField { unsafeBitCast(n, to: CGEventField.self) }

func magnify(_ m: Double, phase: Int64, at p: CGPoint) {   // phase: 1 began, 2 changed, 4 ended
    guard let e = CGEvent(source: nil) else { return }
    e.type = gestureType
    e.location = p
    e.setIntegerValueField(field(110), value: 8)
    e.setIntegerValueField(field(132), value: phase)
    e.setDoubleValueField(field(113), value: m)
    e.post(tap: .cghidEventTap)
}

func rotate(_ deg: Double, phase: Int64, at p: CGPoint) {   // deg: counter-clockwise positive in Cocoa
    guard let e = CGEvent(source: nil) else { return }
    e.type = gestureType
    e.location = p
    e.setIntegerValueField(field(110), value: 5)
    e.setIntegerValueField(field(132), value: phase)
    e.setDoubleValueField(field(114), value: deg)
    e.post(tap: .cghidEventTap)
}

func smartZoomGesture(at p: CGPoint) {
    post(.mouseMoved, p)
    for ph: Int64 in [1, 4] {
        guard let e = CGEvent(source: nil) else { continue }
        e.type = gestureType
        e.location = p
        e.setIntegerValueField(field(110), value: 22)
        e.setIntegerValueField(field(132), value: ph)
        e.post(tap: .cghidEventTap)
    }
    log("smart zoom (two-finger double-tap) at \(Int(p.x)),\(Int(p.y))")
}

func angleDeg(_ a: CGPoint, _ b: CGPoint) -> Double { atan2(b.y - a.y, b.x - a.x) * 180.0 / .pi }
func angleDiffDeg(_ a: Double, _ b: Double) -> Double {
    var d = a - b
    while d > 180 { d -= 360 }
    while d < -180 { d += 360 }
    return d
}
func meanRadius(_ pts: [CGPoint], around c: CGPoint) -> Double {
    guard !pts.isEmpty else { return 0 }
    return pts.reduce(0) { $0 + dist($1, c) } / Double(pts.count)
}

typealias CoreDockSendNotificationFn = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void
let dockNotifyFn: CoreDockSendNotificationFn? = {
    guard let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
          let sym = dlsym(h, "CoreDockSendNotification") else { return nil }
    return unsafeBitCast(sym, to: CoreDockSendNotificationFn.self)
}()

func dockNotification(_ name: String) -> Bool {
    guard let fn = dockNotifyFn else { return false }
    fn(name as CFString, nil)
    return true
}

func toggleShowDesktop() {
    if !dockNotification("com.apple.showdesktop.awake") { missionControl(["1"]) }
    log("trackpad spread: Show Desktop")
}

func toggleLaunchpad() {
    if !dockNotification("com.apple.launchpad.toggle") {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Launchpad.app"), configuration: config, completionHandler: nil)
    }
    log("trackpad 4/5-finger pinch: Launchpad")
}

func toggleNotificationCenter() {
    if let cc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first {
        let app = AXUIElementCreateApplication(cc.processIdentifier)
        var bar: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &bar) == .success, let bar {
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
            for c in (children as? [AXUIElement] ?? []) {
                var id: CFTypeRef?
                AXUIElementCopyAttributeValue(c, kAXIdentifierAttribute as CFString, &id)
                if (id as? String) == "com.apple.menuextra.clock" {
                    if AXUIElementPerformAction(c, kAXPressAction as CFString) == .success {
                        log("two-finger right-edge swipe: Notification Center")
                        return
                    }
                }
            }
        }
    }
}

func lookUpTap(at p: CGPoint) {
    post(.mouseMoved, p)
    usleep(12_000)
    // Ctrl + Cmd + D triggers macOS system-wide Trackpad Look Up & Data Detectors under the cursor.
    let flags: CGEventFlags = [.maskControl, .maskCommand]
    func send(_ c: CGKeyCode, _ down: Bool, _ f: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: down) else { return }
        if c == 59 || c == 55 { e.type = .flagsChanged }
        e.flags = f
        e.post(tap: .cghidEventTap)
    }
    send(59, true, .maskControl)
    send(55, true, flags)
    send(2, true, flags); send(2, false, flags)   // keycode 2 = 'D'
    send(55, false, .maskControl)
    send(59, false, [])
    log("three-finger tap: Look Up at \(Int(p.x)),\(Int(p.y))")
}

// Presses a key like a keyboard does: modifier keys go down first and come up last, so the system
// never believes ⌃ or ⌘ stays held. (Approach from macTouchScreen.)
func keyCombo(_ code: CGKeyCode, _ flags: CGEventFlags) {
    func send(_ c: CGKeyCode, _ down: Bool, _ f: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: down) else { return }
        if c == 59 || c == 55 { e.type = .flagsChanged }
        e.flags = f
        e.post(tap: .cghidEventTap)
    }
    let mods: [(CGKeyCode, CGEventFlags)] = [(59, .maskControl), (55, .maskCommand)].filter { flags.contains($0.1) }
    var held: CGEventFlags = []
    for (m, f) in mods { held.insert(f); send(m, true, held) }
    send(code, true, flags); send(code, false, flags)
    for (m, f) in mods.reversed() { held.remove(f); send(m, false, held) }
}

func zoomKey(_ zoomIn: Bool) { keyCombo(zoomIn ? 24 : 27, .maskCommand) }   // Cmd+= / Cmd+-

// Launching Mission Control toggles it whatever the keyboard shortcuts are; argument "2" opens App
// Exposé for the frontmost app.
func missionControl(_ arguments: [String] = []) {
    let config = NSWorkspace.OpenConfiguration()
    config.arguments = arguments
    config.activates = false
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"),
                                       configuration: config) { _, error in if let error { log("Mission Control: \(error)") } }
}

// Fires the swipe action once the fingers have travelled far enough; returns whether it fired.
// Directions follow the trackpad: fingers moving left show the Space to the right.
func swipeAction(_ dx: Double, _ dy: Double, at c: CGPoint) -> Bool {
    let b = CGDisplayBounds(targetDisplay())
    let needX = min(b.width * 0.1, 160), needY = min(b.height * 0.12, 120)
    let arrows: CGEventFlags = [.maskControl, .maskSecondaryFn]   // exactly the system shortcut's flags
    post(.mouseMoved, c)   // act on the touched display
    if abs(dx) > needX && abs(dx) > 1.5 * abs(dy) {
        keyCombo(dx < 0 ? 124 : 123, arrows); log("swipe \(dx < 0 ? "left: next" : "right: previous") Space")
    } else if abs(dy) > needY && abs(dy) > 1.5 * abs(dx) {
        if dy < 0 { missionControl(); log("swipe up: Mission Control") } else { missionControl(["2"]); log("swipe down: App Exposé") }
    } else { return false }
    return true
}

func pinch(_ d: Double, at c: CGPoint) {
    defer { pinchLast = d }
    guard pinchLast > 0 else { return }
    switch zoomHere {
    case "keys":
        zoomKeyAcc += log(d / pinchLast) * cfg.zoomScale
        while zoomKeyAcc > zoomKeyStep { zoomKey(true); zoomKeyAcc -= zoomKeyStep }
        while zoomKeyAcc < -zoomKeyStep { zoomKey(false); zoomKeyAcc += zoomKeyStep }
    case "gesture":
        magnify((d / pinchLast - 1) * cfg.zoomScale, phase: 2, at: c)
    default: break
    }
}

// MARK: gesture recognition, run once per HID report

func commit() {
    dirty = false
    var tipped = slots.sorted { $0.key < $1.key }.filter { $0.value.tip }
    if profileMode(activeProfile) == .single { tipped = Array(tipped.prefix(1)) }   // a screen set to single touch
    let fracs = tipped.map { frac($0.value) }
    let active = fracs.map(toScreen)
    let n = active.count
    defer {
        lastN = n; if n == 1 { lastPt = active[0] }
        if case .held = mode {} else { holdRing.hide() }
    }
    if pairing.active { pairing.feed(tipped.first?.value); return }
    if calibrator.active { calibrator.feed(tipped.map { panel($0.value) }); return }
    if piano.active {
        piano.feed(Dictionary(uniqueKeysWithValues: slots.filter { $0.value.tip }.map { ($0.key, toScreen(frac($0.value))) }))
        return
    }
    if sketch.active {   // a gesture is drawn if it starts while drawing, or on the drawing's bar
        if n > 0 && lastN == 0 { sketch.capturing = !sketch.overlay || sketch.drawing || sketch.onBar(active[0]) }
        if sketch.capturing || sketch.hasFingers {
            sketch.feed(Dictionary(uniqueKeysWithValues: slots.filter { $0.value.tip }.map { ($0.key, toScreen(frac($0.value))) }))
            if n == 0 { sketch.capturing = false }
            return
        }
    }
    if probe {
        if n != lastN || n > 0 { log("contacts=\(n) " + active.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " ")) }
        return
    }
    if cfg.paused { mode = .idle; return }
    if n > 0 && lastN == 0 {   // touch-down
        caughtMomentum = stopMomentum()   // a tap that stops a scroll does nothing else, as on iOS
        let asleep = CGDisplayIsAsleep(targetDisplay()) != 0
        declareUserActivity()
        if asleep { mode = .done; log("touch woke the display"); return }   // wake only, like a phone
        touchTakesPointer()
    }
    switch n {
    case 0:
        switch mode {
        case .pending(let s, _):
            // An unconfirmed move far beyond the lift-off jump is a quick flick: better no click than one
            // where it started.
            if unconfirmedMove && dist(lastPt, s) > 3 * moveTol { log("flick too short to scroll or drag") }
            else if caughtMomentum { log("tap stopped the scroll") }
            else { tap(median(restingPts)) }
        case .held(let s): rightClick(s, "long press")
        case .dragging:
            post(.leftMouseUp, shifted(lastPt), clickState: dragClicks); log("drag end at \(Int(lastPt.x)),\(Int(lastPt.y))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { rememberKeyboard() }   // the keyboard may have moved
        case .drag3(let c):
            post(.leftMouseUp, c, clickState: 1); log("three-finger drag end at \(Int(c.x)),\(Int(c.y))")
        case .multi(let origin, _, _, let t0, let maxN, let fired):
            if !fired {
                if maxN == 3 && cfg.threeFingerTap && now() - t0 < tapMaxSecs && dist(origin, lastPt) < 35 {
                    lookUpTap(at: origin)
                } else {
                    log("multi-finger gesture end (too short)")
                }
            }
        case .scroll1: log("scroll end (1 finger)"); endScroll(); startMomentum()
        case .two(let c, let t0, let kind):
            switch kind {
            case .zoom: if zoomHere == "gesture" { magnify(0, phase: 4, at: c) }; log("zoom end")
            case .rotate: rotate(0, phase: 4, at: c); log("rotate end")
            case .scroll: log("scroll end"); endScroll(); startMomentum()
            case .rightEdge: break
            case .undecided:
                if now() - t0 < tapMaxSecs {
                    let pt = twoStart
                    if cfg.smartZoom && now() - lastTwoTapTime < dblSecs() && dist(pt, lastTwoTapPt) < 55 {
                        twoTapTimerSeq += 1
                        lastTwoTapTime = 0
                        smartZoomGesture(at: pt)
                    } else if cfg.smartZoom && cfg.twoFingerTap {
                        lastTwoTapTime = now(); lastTwoTapPt = pt
                        twoTapTimerSeq += 1
                        let seq = twoTapTimerSeq
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                            guard seq == twoTapTimerSeq, lastTwoTapTime > 0 else { return }
                            lastTwoTapTime = 0
                            rightClick(pt, "two-finger tap")
                        }
                    } else if cfg.twoFingerTap {
                        rightClick(pt, "two-finger tap")
                    } else if cfg.smartZoom {
                        lastTwoTapTime = now(); lastTwoTapPt = pt
                    }
                }
            }
        default: break
        }
        mode = .idle
        returnPointer()
    case 1:
        let p = active[0]
        switch mode {
        case .idle:
            post(.mouseMoved, p)
            dragOffset = .zero; restingPts = [p]; unconfirmedMove = false
            edgeSnap = edgeGrab(p)
            let win = windowAt(p), app = win?.owner ?? ""
            let onTitlebar = win.map { $0.layer == 0 && p.y - $0.frame.minY < cfg.titlebar } ?? false
            let inTrafficLights = win.map { $0.layer == 0 && p.x - $0.frame.minX < 100 && p.y - $0.frame.minY < 56 } ?? false
            let onDesktop = win == nil   // nothing to scroll there: select and move icons instead
            inDragApp = cfg.dragApps.contains(app) || onTitlebar || edgeSnap != nil || onDesktop
            canHold = !inDragApp || onDesktop   // in title bars, drag apps and at edges a press is only ever a drag
            if inDragApp { log("down \(onDesktop ? "on the desktop" : "in " + app)\(edgeSnap != nil ? " window edge" : onTitlebar ? " title bar" : ""): drag mode") }
            pressClicks = !inTrafficLights && continuesTap(p) ? min(clicks + 1, 3) : 1
            pressSeq += 1
            let seq = pressSeq
            mode = .pending(p, seq)
            DispatchQueue.main.asyncAfter(deadline: .now() + cfg.hold) {   // a second or third tap never holds
                guard case .pending(let s, let q) = mode, q == seq, canHold, pressClicks == 1 else { return }
                if cfg.oneFingerScroll || inDragApp {   // the ring, so that moving after the hold still drags
                    mode = .held(s); log("hold at \(Int(s.x)),\(Int(s.y))")
                    holdRing.show(at: s, duration: heldRightClickSecs)
                    // Still holding without moving: right click now rather than waiting for the lift.
                    DispatchQueue.main.asyncAfter(deadline: .now() + heldRightClickSecs) {
                        guard case .held(let h) = mode, pressSeq == seq else { return }
                        holdRing.hide(); rightClick(h, "long press"); mode = .done
                    }
                } else { rightClick(s, "long press"); mode = .done }
            }
        case .pending(let s, _):
            let moved = dist(p, s) > (pressClicks > 1 ? followTol : moveTol)   // a second tap may wobble more
            if !moved && restingPts.count < 30 { restingPts.append(p) }   // the first quarter second or so is plenty
            if confirmedMove(moved) {
                if let snap = edgeSnap {   // resize: press on the edge, then keep the finger's offset
                    dragOffset = CGPoint(x: snap.x - s.x, y: snap.y - s.y)
                    post(.mouseMoved, snap); startDrag(snap, shifted(p))
                } else if pressClicks > 1 {   // tap, then touch and move: select by word (or line)
                    startDrag(lastTapPt, p, clicks: pressClicks)
                } else if cfg.oneFingerScroll && !inDragApp {
                    mode = .scroll1; accX = 0; accY = 0; scrollSamples = []
                    beginScroll(); fingerScroll(p.x - s.x, p.y - s.y); log("scroll start (1 finger)")
                } else { startDrag(s, p) }
            }
        case .held(let s):
            if confirmedMove(dist(p, s) > moveTol) { startDrag(s, p) }
        case .dragging:
            if p != lastPt { post(.leftMouseDragged, shifted(p), clickState: dragClicks) }
        case .scroll1:
            if lastN == 1 { fingerScroll(p.x - lastPt.x, p.y - lastPt.y) }
        default: break   // one finger left over from a two-finger gesture
        }
    default:
        let c = CGPoint(x: active.map(\.x).reduce(0, +) / Double(n), y: active.map(\.y).reduce(0, +) / Double(n))
        let d = dist(active[0], active[1])
        let ang = angleDeg(active[0], active[1])
        let dispBounds = CGDisplayBounds(targetDisplay())
        let swipeMinFingers = (cfg.swipes == "4" || cfg.threeFingerDrag) ? 4 : 3
        if case .scroll1 = mode { endScroll() }   // a second finger: what follows is a new gesture

        if case .drag3(let lastC) = mode {
            if n == 3 {
                if c != lastC { post(.leftMouseDragged, c, clickState: 1) }
                mode = .drag3(c)
                return
            } else if n >= 4 {
                post(.leftMouseUp, lastC, clickState: 1)
                mode = .multi(c, c, meanRadius(active, around: c), now(), n, false)
                return
            }
            return
        }

        if case .multi(let origin, let last, var startR, let t0, let prevMaxN, var fired) = mode {
            let maxN = max(prevMaxN, n)
            let curR = meanRadius(active, around: c)
            let o: CGPoint
            if n != lastN {
                o = CGPoint(x: origin.x + c.x - last.x, y: origin.y + c.y - last.y)
                startR = curR
            } else {
                o = origin
            }
            if !fired {
                // 3-finger Trackpad Drag option
                if n == 3 && maxN == 3 && cfg.threeFingerDrag && dist(c, o) > moveTol {
                    post(.mouseMoved, o)
                    post(.leftMouseDown, o, clickState: 1)
                    post(.leftMouseDragged, c, clickState: 1)
                    mode = .drag3(c)
                    log("three-finger drag start at \(Int(o.x)),\(Int(o.y))")
                    return
                }
                // 4/5-finger Trackpad Pinch -> Launchpad, Spread -> Show Desktop
                if n >= 4 && cfg.fourFingerPinch && abs(curR - startR) > spreadPinchTol && abs(curR - startR) > dist(c, o) * 0.85 {
                    if curR < startR { toggleLaunchpad() } else { toggleShowDesktop() }
                    fired = true
                } else if cfg.swipes != "off" && n >= swipeMinFingers {
                    fired = swipeAction(c.x - o.x, c.y - o.y, at: c)
                }
            }
            mode = .multi(o, c, startR, t0, maxN, fired)
            return
        }

        if n >= 3 && (cfg.swipes != "off" || cfg.threeFingerTap || cfg.threeFingerDrag || cfg.fourFingerPinch) {
            var start = false
            switch mode {
            case .two(_, _, .undecided), .idle, .pending, .held, .scroll1, .dragging: start = true
            default: break
            }
            if start {
                if case .dragging = mode { post(.leftMouseUp, shifted(lastPt)) }
                lastPt = c
                mode = .multi(c, c, meanRadius(active, around: c), now(), n, false)
                log("multi-finger start (\(n) fingers)")
                return
            }
        }

        switch mode {
        case .two(let last, let t0, var kind):
            if n == lastN {   // finger count changed -> re-anchor instead of jumping
                if case .undecided = kind {
                    // Two-finger swipe inward from the right bezel -> Notification Center (just like macOS Trackpad)
                    if cfg.rightEdgeNC && twoStart.x >= dispBounds.maxX - 44 && (twoStart.x - c.x) > 48 && abs(c.y - twoStart.y) < 50 {
                        kind = .rightEdge
                        toggleNotificationCenter()
                    } else {
                        let dd = abs(d - pinchStart), dc = dist(c, twoStart), da = abs(angleDiffDeg(ang, rotateStart))
                        if cfg.rotateGesture && d > 55 && da > rotateTolDeg && (da * 2.2) > dd && (da * 2.0) > dc {
                            kind = .rotate; rotateLast = ang
                            rotate(0, phase: 1, at: c)
                            log("rotate start at \(Int(c.x)),\(Int(c.y))")
                        } else if cfg.zoom != "off" && dd > pinchTol && dd > dc {
                            kind = .zoom; pinchLast = d; zoomKeyAcc = 0
                            let app = windowAt(c)?.owner ?? ""
                            zoomHere = cfg.zoomKeyApps.contains(app) ? "keys" : cfg.zoom
                            if zoomHere == "gesture" { magnify(0, phase: 1, at: c) }
                            log("zoom start (\(zoomHere)) in \(app)")
                        } else if dc > moveTol {
                            kind = .scroll; scrollSamples = []; beginScroll(); log("scroll start (\(n) fingers)")
                        }
                    }
                }
                switch kind {
                case .scroll: fingerScroll(c.x - last.x, c.y - last.y)
                case .zoom: pinch(d, at: c)
                case .rotate:
                    // CG screen Y points down while Cocoa rotation is counter-clockwise positive: invert angle delta!
                    let step = -angleDiffDeg(ang, rotateLast)
                    rotateLast = ang
                    if abs(step) > 0.05 && abs(step) < 45 { rotate(step, phase: 2, at: c) }
                case .rightEdge, .undecided: break
                }
            } else {
                if case .zoom = kind { pinchLast = d }
                if case .rotate = kind { rotateLast = ang }
            }
            mode = .two(c, t0, kind)
        case .done: break
        default:
            if case .dragging = mode { post(.leftMouseUp, shifted(lastPt)) }
            twoStart = c; pinchStart = d; pinchLast = 0; rotateStart = ang; rotateLast = ang; accX = 0; accY = 0
            post(.mouseMoved, c)
            mode = .two(c, now(), .undecided)
        }
    }
}
