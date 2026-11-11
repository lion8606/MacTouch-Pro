import AppKit
import IOKit.hid

// MARK: menu bar app

/// Redraws the menu bar icon and tooltip after the touchscreens or permissions changed.
func refreshStatusIcon() { (NSApp.delegate as? AppDelegate)?.updateIcon() }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var lastApp: NSRunningApplication?   // the app in front before the menu opened
    var axTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        startHID()
        // Put the keyboard back after display changes settle, after wake and unlock (which re-centre it),
        // and at launch. Later passes catch late moves.
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in scheduleRestore([3, 8], "display change") }, nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            screenLocked = true; log("screen locked")
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            screenLocked = false; log("screen unlocked"); scheduleRestore([1, 3, 8], "unlock")
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            scheduleRestore([3, 8], "wake")
        }
        scheduleRestore([2], "launch")
        // Panels move when dragged (remembered right after each drag); this catches anything else.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in rememberKeyboard() }.tolerance = 5
        updateIcon()
    }

    func startHID() {
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { _, _, _, dev in
            attached(dev)
            refreshStatusIcon()
        }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { _, _, _, dev in
            detached(dev)
            DispatchQueue.main.async { refreshStatusIcon() }
        }, nil)
        IOHIDManagerRegisterInputValueCallback(mgr, valueCB, nil)
        watchRawDigitizers()
        // A touchscreen's display can arrive after the touchscreen, and the notice can be missed.
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if !flags.contains(.beginConfigurationFlag) { DispatchQueue.main.async { refreshDisplays() } }
        }, nil)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            let before = devices.values.map { $0.display }
            refreshDisplays()
            if devices.values.map({ $0.display }) != before { self?.updateIcon() }
            keyboardFollowTouchscreens()
        }.tolerance = 1
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        log("start \(Bundle.main.bundleIdentifier ?? "unbundled") probe=\(probe) settings: \(cfg)")
        // Input Monitoring applies to new processes only, and a running process never sees the grant:
        // after a while, let a fresh process try again.
        // Opening fails as a whole if one matched device cannot be opened (a keyboard interface, say), so
        // only a missing permission counts as missing.
        let opened = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if opened != kIOReturnSuccess && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
            log("HID manager open returned \(hex(UInt32(bitPattern: opened))) with Input Monitoring granted; carrying on")
        }
        guard opened == kIOReturnSuccess || IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            log("Input Monitoring missing (open returned \(hex(UInt32(bitPattern: opened)))); enable MacTouch in System Settings > Privacy & Security > Input Monitoring")
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in restartProcess() }
            return
        }
        hidOpen = true
        log("Input Monitoring granted; HID manager open")
        // Accessibility applies to the running process.
        if !probe && !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
            log("Accessibility missing; enable MacTouch in System Settings > Privacy & Security > Accessibility")
            axTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard AXIsProcessTrusted() else { return }
                t.invalidate(); log("Accessibility granted"); startEventTap(); self?.updateIcon()
            }
        } else if !probe { startEventTap() }
        log("ready; touchscreens: " + (touchDevices().map { "\($0.label) (\($0.role.label))" }.joined(separator: ", ")).ifEmpty("none"))
    }

    // One line per connected touchscreen.
    var statusLines: [String] {
        if !hidOpen { return ["正在等待“输入监控”权限（点击前往系统设置开启…）"] }
        if !probe && !AXIsProcessTrusted() { return ["正在等待“辅助功能”权限（点击前往系统设置开启…）"] }
        if touchDevices().isEmpty { return ["未连接触摸屏"] }
        if cfg.paused { return ["触控已暂停"] }
        if probe { return ["探测模式：仅记录日志"] }
        return touchDevices().map { t in
            if let d = t.display {
                // Came up as a mouse, but has a multi-touch mode (the CX158): power-cycling may bring it.
                let hint = t.couldBeMultiTouch ? "（当前单点模式；拔掉电源等待 15 秒重插可恢复多点触控）" : ""
                return "触控已就绪：\(t.name) → \(displayName(d))" + hint
            }
            if pairing.device === t { return "\(t.name)：请点击屏幕上的橙色靶心完成配对" }
            return t.role == .singleTouch ? "\(t.name)：尚未配对显示器（触摸屏设备 ▸ 配对显示器…）"
                                          : "\(t.name)：未找到对应显示器，暂作用于主屏幕"
        }
    }
    var status: String { statusLines.joined(separator: "；") }

    // The screen the top-level screen settings act on: the one touched last, else the only one connected.
    var menuProfile: String? {
        if let t = activeDevice, touchDevices().contains(where: { $0 === t }) { return t.profile }
        return touchDevices().first?.profile ?? (screens.count == 1 ? screens.keys.first : nil)
    }

    func updateIcon() {
        let ok = statusLines.contains { $0.hasPrefix("触控已就绪") }
        let img = NSImage(systemSymbolName: ok ? "hand.point.up.left" : "hand.raised.slash", accessibilityDescription: "MacTouch")
        img?.isTemplate = true
        item?.button?.image = img
        item?.button?.toolTip = "MacTouch：" + status
    }

    // MARK: menu

    func menuWillOpen(_ menu: NSMenu) {
        let front = NSWorkspace.shared.frontmostApplication
        lastApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        updateIcon()
        if !hidOpen {
            add(menu, "⚠️ 正在等待“输入监控”权限（点击打开系统设置…）", #selector(openInputMonitoringSettings(_:)))
        } else if !probe && !AXIsProcessTrusted() {
            add(menu, "⚠️ 正在等待“辅助功能”权限（点击打开系统设置…）", #selector(openAccessibilitySettings(_:)))
        } else {
            for line in statusLines { add(menu, line, nil) }
        }
        menu.addItem(.separator())
        add(menu, "暂停触控", #selector(toggle(_:)), on: cfg.paused, obj: "paused")
        add(menu, "触控后归位鼠标指针", #selector(toggle(_:)), on: cfg.returnPointer, obj: ["returnPointer"])
        menu.addItem(.separator())
        // Screen settings act on the screen touched last; with several connected, its name says which.
        let mp = menuProfile, p = mp.flatMap { screens[$0] } ?? [:]
        let suffix = touchDevices().count > 1 ? "（\(mp.map(profileName) ?? "?")）" : ""
        let multi = touchDevices().contains { $0.role == .multiTouch && $0.mode != .single } || touchDevices().isEmpty
        let only = multi ? "" : "（仅多点触控屏可用）"
        let curHiDPI = p["hidpi"] as? String ?? cfg.hidpi
        choices(menu, "Retina 高清缩放 (HiDPI)" + suffix, "hidpi", curHiDPI, hiDPIPresets.map { ($0.label, $0.key) }, profile: mp)
        trackpadItems(menu, mp, p, suffix, multi: multi, only: only)
        keyboardItems(menu)
        add(menu, "窗口边缘触控缩放", #selector(toggleEdge(_:)), on: cfg.edge > 0)
        ringColors(menu)
        menu.addItem(.separator())
        appList(menu, "单指直接拖拽的应用", "dragApps", cfg.dragApps, "在这些应用中，单指移动始终执行拖拽而非滚屏：")
        appList(menu, "使用快捷键缩放的应用", "zoomKeyApps", cfg.zoomKeyApps, "在这些应用中，双指捏合发送 ⌘+ / ⌘− 缩放：")
        menu.addItem(.separator())
        let canTouch = hidOpen && !touchDevices().isEmpty
        add(menu, piano.active ? "关闭触控乐器" : "触控乐器…", #selector(togglePiano(_:)), enabled: canTouch)
        add(menu, sketch.active && !sketch.overlay ? "关闭全屏白板" : "全屏白板…", #selector(toggleBoard(_:)), enabled: canTouch)
        add(menu, sketch.active && sketch.overlay ? "停止屏幕批注" : "屏幕画笔批注…", #selector(toggleOverlay(_:)), enabled: canTouch)
        menu.addItem(.separator())
        calibrationItems(menu, mp, suffix)
        touchscreens(menu)
        menu.addItem(.separator())
        startAtLoginItem(menu)
        add(menu, "查看运行日志", #selector(openLog(_:)))
        add(menu, "GitHub 项目主页", #selector(openRepo(_:)))
        add(menu, "退出 MacTouch", #selector(quit(_:)), key: "q")
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector?, on: Bool = false, obj: Any? = nil,
             enabled: Bool = true, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.state = on ? .on : .off
        i.representedObject = obj
        i.isEnabled = enabled && action != nil
        menu.addItem(i)
        return i
    }

    @discardableResult
    func choices<T: Equatable>(_ menu: NSMenu, _ title: String, _ key: String, _ current: T, _ opts: [(String, T)],
                               profile: String? = nil) -> NSMenuItem {
        let sub = NSMenu(); sub.autoenablesItems = false
        for (label, v) in opts { add(sub, label, #selector(choose(_:)), on: v == current, obj: [key, v, profile as Any] as [Any]) }
        let i = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
    }

    func calibrationItems(_ menu: NSMenu, _ id: String?, _ suffix: String) {
        let connected = touchDevices().contains { $0.profile == id && ($0.role == .multiTouch || $0.driven && $0.display != nil) }
        let cal = calibration(id)
        add(menu, "触控校准…" + suffix, #selector(calibrate(_:)), obj: id as Any, enabled: hidOpen && connected)
        add(menu, "撤销上次校准", #selector(undoCalibration(_:)), obj: id as Any, enabled: previousCal(id).map { $0 != cal } ?? false)
        add(menu, "重置校准数据", #selector(resetCalibration(_:)), obj: id as Any, enabled: cal != identityCal)
    }

    // One submenu per touchscreen MacTouch knows, connected or not.
    func touchscreens(_ menu: NSMenu) {
        let sub = NSMenu(); sub.autoenablesItems = false
        for (id, p) in screens.sorted(by: { profileName($0.key) < profileName($1.key) }) {
            let dev = touchDevices().first { $0.profile == id } ?? devices.values.first { $0.profile == id }
            let mode = profileMode(id), spec = p["display"] as? String ?? ""
            let place = dev?.display.map(displayName) ?? (spec.isEmpty ? "尚未配对显示器" : "显示器未连接")
            let what = dev == nil ? "未连接" : mode == .ignore ? "已忽略（非触摸屏）" : dev!.role.label
            let s = NSMenu(); s.autoenablesItems = false
            add(s, what + " · " + place, nil)
            s.addItem(.separator())
            add(s, "配对显示器…", #selector(pairScreen(_:)), obj: id, enabled: dev != nil && mode != .ignore && hidOpen)
            calibrationItems(s, id, "")
            choices(s, "Retina 高清缩放 (HiDPI)", "hidpi", p["hidpi"] as? String ?? "off", hiDPIPresets.map { ($0.label, $0.key) }, profile: id)
            add(s, "单指滑动滚屏", #selector(toggle(_:)), on: p["oneFingerScroll"] as? Bool ?? cfg.oneFingerScroll, obj: ["oneFingerScroll", id])
            var modes: [(String, String)] = [("自动识别" + (dev.map { "（\($0.kind.label)）" } ?? ""), ScreenMode.auto.rawValue)]
            if dev?.kind != .singleTouch { modes.append(("多点触控模式", ScreenMode.multi.rawValue)) }
            modes += [("单点鼠标模式", ScreenMode.single.rawValue), ("忽略此设备（非触摸屏）", ScreenMode.ignore.rawValue)]
            choices(s, "驱动模式", "mode", mode.rawValue, modes, profile: id)
            s.addItem(.separator())
            add(s, "移除此触摸屏记录", #selector(forgetScreen(_:)), obj: id)
            let title = (p["name"] as? String ?? id) + (dev == nil ? "（未连接）" : "")
            sub.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = s
        }
        if screens.isEmpty { add(sub, "（暂无设备：请连接触摸屏）", nil) }
        menu.addItem(withTitle: "触摸屏设备管理", action: nil, keyEquivalent: "").submenu = sub
    }

    func trackpadItems(_ menu: NSMenu, _ mp: String?, _ p: [String: Any], _ suffix: String, multi: Bool, only: String) {
        // Core everyday trackpad gestures directly visible at top level + full sub-panels matching macOS Trackpad Settings
        add(menu, "单指滑动滚屏（自然方向）" + suffix, #selector(toggle(_:)), on: p["oneFingerScroll"] as? Bool ?? cfg.oneFingerScroll,
            obj: ["oneFingerScroll", mp as Any])
        add(menu, "双指轻点辅助点按（右键）" + only, #selector(toggle(_:)), on: cfg.twoFingerTap, obj: ["twoFingerTap"], enabled: multi)
        add(menu, "三指轻点查询与数据检测器" + only, #selector(toggle(_:)), on: cfg.threeFingerTap, obj: ["threeFingerTap"], enabled: multi)

        let sub = NSMenu(); sub.autoenablesItems = false
        add(sub, "── 光标与点按 ──", nil)
        add(sub, "双指轻点辅助点按（右键）", #selector(toggle(_:)), on: cfg.twoFingerTap, obj: ["twoFingerTap"], enabled: multi)
        add(sub, "三指轻点查询与数据检测器 (⌃⌘D)", #selector(toggle(_:)), on: cfg.threeFingerTap, obj: ["threeFingerTap"], enabled: multi)
        add(sub, "三指拖移窗口与选区（开启后桌面切换用四指）", #selector(toggle(_:)), on: cfg.threeFingerDrag, obj: ["threeFingerDrag"], enabled: multi)
        choices(sub, "单指长按触发右键时间" + suffix, "hold", p["hold"] as? Double ?? cfg.hold,
                [0.4, 0.5, 0.6, 0.8, 1.0].map { (String(format: "%.1f 秒", $0), $0) }, profile: mp)

        sub.addItem(.separator())
        add(sub, "── 滚动与缩放 ──", nil)
        add(sub, "单指滑动滚屏（双指滑动始终可用）" + suffix, #selector(toggle(_:)), on: p["oneFingerScroll"] as? Bool ?? cfg.oneFingerScroll,
            obj: ["oneFingerScroll", mp as Any])
        add(sub, "反转滚动方向（传统滚轮方向）", #selector(toggle(_:)), on: cfg.invertScroll, obj: ["invertScroll"])
        choices(sub, "双指捏合放大或缩小", "zoom", cfg.zoom, [("触控板原生无级缩放", "gesture"), ("快捷键 ⌘+ / ⌘−", "keys"), ("关闭", "off")]).isEnabled = multi
        add(sub, "双指轻点两下智能缩放 (Smart Zoom)", #selector(toggle(_:)), on: cfg.smartZoom, obj: ["smartZoom"], enabled: multi)
        add(sub, "双指旋转手势 (Rotate)", #selector(toggle(_:)), on: cfg.rotateGesture, obj: ["rotateGesture"], enabled: multi)
        choices(sub, "滚动速度", "scrollScale", cfg.scrollScale, [0.5, 0.75, 1.0, 1.5, 2.0].map { ("\($0)×", $0) })
        choices(sub, "滚动惯性", "momentum", cfg.momentum, [("默认顺滑 (iOS/触控板级)", 0.998), ("较短收停", 0.995), ("关闭惯性", 0.0)])

        sub.addItem(.separator())
        add(sub, "── 更多手势 ──", nil)
        choices(sub, "调度中心 / App Exposé / 切换桌面空间", "swipes", cfg.swipes,
                [("三指或四指滑动", "3"), ("仅四指滑动", "4"), ("关闭", "off")]).isEnabled = multi
        add(sub, "四指/五指张开显示桌面 · 捏合打开启动台", #selector(toggle(_:)), on: cfg.fourFingerPinch, obj: ["fourFingerPinch"], enabled: multi)
        add(sub, "双指从屏幕右边缘向左轻扫打开通知中心", #selector(toggle(_:)), on: cfg.rightEdgeNC, obj: ["rightEdgeNC"], enabled: multi)

        menu.addItem(withTitle: "Mac 触控板全套手势设置", action: nil, keyEquivalent: "").submenu = sub
    }

    func keyboardItems(_ menu: NSMenu) {
        let sub = NSMenu(); sub.autoenablesItems = false
        add(sub, "显示屏幕键盘", #selector(toggleKeyboard(_:)), on: keyboardOn() == true, enabled: keyboardOn() != nil)
        sub.addItem(.separator())
        add(sub, "拔出触摸屏时自动隐藏键盘", #selector(toggle(_:)), on: cfg.keyboardFollowsTouch, obj: ["keyboardFollowsTouch"],
            enabled: keyboardOn() != nil)
        add(sub, "记住屏幕键盘位置", #selector(toggle(_:)), on: cfg.keepKeyboard, obj: ["keepKeyboard"])
        add(sub, "点击输入框自动弹出键盘", #selector(toggle(_:)), on: cfg.autoKeyboard, obj: ["autoKeyboard"])
        add(sub, "接入物理键盘时智能免弹", #selector(toggle(_:)), on: cfg.smartKeyboard, obj: ["smartKeyboard"])
        menu.addItem(withTitle: "屏幕虚拟键盘", action: nil, keyEquivalent: "").submenu = sub
    }

    func startAtLoginItem(_ menu: NSMenu) {
        if let other = startedByOther { add(menu, "开机自动启动（已由 \(other) 配置守护）", nil, on: true); return }
        let status = loginAgent.status
        add(menu, status == .requiresApproval ? "开机自动启动（需在“系统设置 ▸ 登录项”中允许）" : "开机自动启动",
            #selector(toggleStartAtLogin(_:)), on: status == .enabled || status == .requiresApproval)
    }

    func ringColors(_ menu: NSMenu) {
        let presets = [("仪表橙", "#FF6A00"), ("琥珀黄", "#FFB000"), ("纯白", "#FFFFFF"),
                       ("翠绿", "#34C759"), ("亮红", "#FF3B30"), ("跟随系统强调色", "accent")]
        let sub = NSMenu(); sub.autoenablesItems = false
        for (label, v) in presets {
            let i = add(sub, label, #selector(choose(_:)), on: v == cfg.ringColor, obj: ["ringColor", v] as [Any])
            i.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                color(v).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill(); return true
            }
        }
        if !presets.contains(where: { $0.1 == cfg.ringColor }) { add(sub, "自定义 \(cfg.ringColor)", nil, on: true) }
        menu.addItem(withTitle: "长按圆环颜色", action: nil, keyEquivalent: "").submenu = sub
    }

    func appList(_ menu: NSMenu, _ title: String, _ key: String, _ apps: [String], _ hint: String) {
        let sub = NSMenu(); sub.autoenablesItems = false
        add(sub, hint, nil)
        for a in apps { add(sub, a, #selector(removeApp(_:)), on: true, obj: [key, a]) }
        if apps.isEmpty { add(sub, "（无）", nil) }
        sub.addItem(.separator())
        if let app = lastApp {
            let name = ownerName(of: app)
            add(sub, "添加“\(name)”", #selector(addApp(_:)), obj: [key, name], enabled: !apps.contains(name))
        } else {
            add(sub, "添加方法：先切换到目标应用，再打开此菜单", nil)
        }
        sub.addItem(.separator())
        add(sub, "点击已勾选的应用即可移除", nil)
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = sub
    }

    func value(_ key: String, _ profile: String?) -> Bool {
        if profileKeys.contains(key), let id = profile, let v = screens[id]?[key] as? Bool { return v }
        switch key {
        case "paused": return cfg.paused
        case "oneFingerScroll": return cfg.oneFingerScroll
        case "twoFingerTap": return cfg.twoFingerTap
        case "rotateGesture": return cfg.rotateGesture
        case "smartZoom": return cfg.smartZoom
        case "rightEdgeNC": return cfg.rightEdgeNC
        case "threeFingerTap": return cfg.threeFingerTap
        case "threeFingerDrag": return cfg.threeFingerDrag
        case "fourFingerPinch": return cfg.fourFingerPinch
        case "returnPointer": return cfg.returnPointer
        case "invertScroll": return cfg.invertScroll
        case "keepKeyboard": return cfg.keepKeyboard
        case "autoKeyboard": return cfg.autoKeyboard
        case "smartKeyboard": return cfg.smartKeyboard
        case "keyboardFollowsTouch": return cfg.keyboardFollowsTouch
        default: return false
        }
    }

    // representedObject: the key, or [key] / [key, profile]
    @objc func toggle(_ s: NSMenuItem) {
        let kv = s.representedObject as? [Any] ?? [s.representedObject as Any]
        guard let key = kv.first as? String else { return }
        let id = kv.count > 1 ? kv[1] as? String : nil
        if key == "paused" { endGesture() }
        if key == "keyboardFollowsTouch" { defaults.removeObject(forKey: keyboardOffForNoTouchscreen) }
        setSetting(key, !value(key, id), profile: id)
        if key == "paused" { updateSeizes() }   // paused screens go back to macOS
        updateIcon()
    }
    @objc func toggleKeyboard(_ s: NSMenuItem) {   // by hand: no longer MacTouch's to turn on or off
        defaults.removeObject(forKey: keyboardOffForNoTouchscreen); keyboardHandedBack = true
        setKeyboard(!(keyboardOn() ?? true), "from the menu")
    }
    @objc func toggleStartAtLogin(_ s: NSMenuItem) { setStartAtLogin(s.state != .on) }
    @objc func toggleEdge(_ s: NSMenuItem) { setSetting("edge", cfg.edge > 0 ? 0.0 : 12.0) }
    @objc func choose(_ s: NSMenuItem) {
        guard let kv = s.representedObject as? [Any], let key = kv[0] as? String else { return }
        let id = kv.count > 2 ? kv[2] as? String : nil
        if key == "mode", let id {   // a screen's mode lives only in its profile
            setProfile(id, "mode", kv[1]); log("set mode = \(kv[1]) for \(profileName(id))")
            if activeDevice?.profile == id { endGesture() }
            refreshDisplays(); updateIcon(); return
        }
        setSetting(key, kv[1], profile: id)
        if key == "hidpi" { hidpi.reconcile(explicitChange: true) }
        if key.hasPrefix("piano") { piano.settingsChanged() }
    }
    @objc func pairScreen(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String, let t = devices.values.first(where: { $0.profile == id }) else { return }
        pairing.request(t)
    }
    @objc func forgetScreen(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        var all = screens; all[id] = nil; screens = all
        log("forgot touchscreen profile \(id)")
        for t in allDevices() where t.profile == id {   // a connected one starts over as new
            if activeDevice === t { endGesture(); activeDevice = nil; activeProfile = nil; cfg = loadConfig() }
            if t.raw != nil { t.profile = nil; register(t); continue }
            for d in t.services { devices[ObjectIdentifier(d)] = nil }
            for d in t.services { attached(d) }
        }
        updateIcon()
    }
    @objc func togglePiano(_ s: NSMenuItem) {
        if piano.active { piano.close() } else { if sketch.active { sketch.close() }; piano.open() }
    }
    @objc func toggleBoard(_ s: NSMenuItem) { toggleSketch(overlay: false) }
    @objc func toggleOverlay(_ s: NSMenuItem) { toggleSketch(overlay: true) }
    func toggleSketch(overlay: Bool) {
        let same = sketch.active && sketch.overlay == overlay
        if sketch.active { sketch.close() }
        if same { return }
        if piano.active { piano.close() }
        sketch.open(overlay: overlay)
    }
    @objc func addApp(_ s: NSMenuItem) {
        guard let kv = s.representedObject as? [String] else { return }
        let list = kv[0] == "dragApps" ? cfg.dragApps : cfg.zoomKeyApps
        setSetting(kv[0], list + [kv[1]])
    }
    @objc func removeApp(_ s: NSMenuItem) {
        guard let kv = s.representedObject as? [String] else { return }
        let list = kv[0] == "dragApps" ? cfg.dragApps : cfg.zoomKeyApps
        setSetting(kv[0], list.filter { $0 != kv[1] })
    }
    @objc func calibrate(_ s: NSMenuItem) {   // on the screen whose profile the item belongs to
        if let id = s.representedObject as? String, let t = touchDevices().first(where: { $0.profile == id }) { activate(t) }
        calibrator.start()
    }
    @objc func resetCalibration(_ s: NSMenuItem) { setCalibration(identityCal, profile: s.representedObject as? String) }
    @objc func undoCalibration(_ s: NSMenuItem) {   // a second undo redoes
        let id = s.representedObject as? String
        if let p = previousCal(id) { setCalibration(p, profile: id) }
    }
    @objc func openInputMonitoringSettings(_ s: NSMenuItem) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(u) }
    }
    @objc func openAccessibilitySettings(_ s: NSMenuItem) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
    }
    @objc func openLog(_ s: NSMenuItem) {
        let url = URL(fileURLWithPath: logPath)
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: logPath) ? url : url.deletingLastPathComponent())
    }
    @objc func openRepo(_ s: NSMenuItem) { NSWorkspace.shared.open(URL(string: repoURL)!) }
    @objc func quit(_ s: NSMenuItem) { endGesture(); hidpi.tearDown(); log("quit from menu"); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { hidpi.tearDown() }
}
