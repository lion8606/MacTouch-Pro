import AppKit
import CoreGraphics

// MARK: Retina HiDPI smooth scaling via CGVirtualDisplay hardware mirroring

// Apple Silicon macOS refuses to expose 2x Retina HiDPI modes on sub-4K (e.g. 1080p FHD) displays.
// Following the BetterDisplay / hidpi-mirror architecture, MacTouch creates a 2x Retina CGVirtualDisplay
// with paired (2x, 1x) mode tables and hardware-mirrors the physical touch display onto it. Both MacTouch's
// menu bar AND macOS System Settings > Displays can switch Retina resolutions live with zero flicker.

let hiDPIPresets: [(label: String, key: String, w: UInt32, h: UInt32)] = [
    ("关闭（原生 1x 标准分辨率）", "off", 0, 0),
    ("2560 × 1440 HiDPI（2K 超清细腻）", "2560x1440", 2560, 1440),
    ("2048 × 1152 HiDPI（大视野清晰）", "2048x1152", 2048, 1152),
    ("1920 × 1080 HiDPI（原生尺寸 2x 锐利）", "1920x1080", 1920, 1080),
    ("1600 × 900 HiDPI（推荐 120% 黄金比例）", "1600x900", 1600, 900),
    ("1440 × 810 HiDPI（舒适 133% 放大）", "1440x810", 1440, 810),
    ("1280 × 720 HiDPI（大字触控 150%）", "1280x720", 1280, 720),
]

final class HiDPIManager {
    var virtualObj: Any?
    var virtualID: CGDirectDisplayID = 0
    var activeProfileID = ""
    var activeSpec = ""
    var activeMode = "off"
    var savedRotation = 0
    var savedUnmirroredOrigin: CGPoint?
    var busy = false

    func effectiveRotation(for d: CGDirectDisplayID) -> Int {
        if virtualID != 0 && (d == virtualID || CGDisplayMirrorsDisplay(d) == virtualID) {
            if let preset = hiDPIPresets.first(where: { $0.key == activeMode }), preset.h > preset.w {
                return savedRotation != 0 ? savedRotation : 90
            }
        }
        return Int(CGDisplayRotation(d))
    }

    func copyHiDPIMode(_ display: CGDirectDisplayID, width: UInt32, height: UInt32) -> CGDisplayMode? {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode] else { return nil }
        return modes.first {
            $0.width == Int(width) && $0.height == Int(height) && $0.pixelWidth == Int(width * 2)
        }
    }

    func desiredSpecAndMode() -> (profileID: String, spec: String, mode: String, name: String)? {
        for (id, p) in screens.sorted(by: { $0.key < $1.key }) {
            if let m = p["hidpi"] as? String, m != "off", !m.isEmpty,
               let sp = p["display"] as? String, !sp.isEmpty, sp != "main" {
                let nm = (p["name"] as? String ?? "Touch Display") + " HiDPI"
                return (id, sp, m, nm)
            }
        }
        return nil
    }

    /// Detects if the user manually picked a different resolution inside macOS System Settings > Displays
    /// while our CGVirtualDisplay mirror is active, and syncs our saved setting so MacTouch never fights them.
    func syncExternalModeChangeIfNeeded() {
        guard virtualObj != nil, virtualID != 0, !activeProfileID.isEmpty,
              let cur = CGDisplayCopyDisplayMode(virtualID) else { return }
        let cw = UInt32(cur.width), ch = UInt32(cur.height)
        guard cur.pixelWidth == Int(cw * 2) else { return }
        let key = "\(cw)x\(ch)"
        if key != activeMode && hiDPIPresets.contains(where: { $0.key == key }) {
            activeMode = key
            setProfile(activeProfileID, "hidpi", key)
            cfg = loadConfig()
            log("HiDPI: synced resolution changed in System Settings -> \(key) @ 2x")
        }
    }

    func reconcile(explicitChange: Bool = false) {
        guard !busy, !checkOnly, !probe else { return }
        let awake = onlineDisplays().contains { $0 != virtualID && CGDisplayIsAsleep($0) == 0 }
        guard awake else { return }

        guard let want = desiredSpecAndMode(),
              let preset = hiDPIPresets.first(where: { $0.key == want.mode }),
              preset.w > 0 else {
            if virtualObj != nil { tearDown() }
            return
        }

        guard let phys = onlineDisplays().first(where: { $0 != virtualID && matches(want.spec, $0) }) else {
            if virtualObj != nil {
                log("HiDPI: physical display \(want.spec) disconnected; removing virtual display")
                tearDown()
            }
            return
        }

        // If already up and mirroring: on periodic polls (!explicitChange), sync any resolution change the user
        // made in macOS System Settings > Displays and return immediately without overwriting their choice or layout.
        if virtualObj != nil, virtualID != 0, activeSpec == want.spec, CGDisplayMirrorsDisplay(phys) == virtualID {
            if !explicitChange {
                syncExternalModeChangeIfNeeded()
                return
            } else if activeMode == want.mode {
                return
            }
        }

        busy = true

        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let physRot = Int(CGDisplayRotation(phys))
        let isPortrait = (physRot == 90 || physRot == 270)
        if isPortrait { savedRotation = physRot }
        let targetW = isPortrait ? preset.h : preset.w
        let targetH = isPortrait ? preset.w : preset.h

        if CGDisplayMirrorsDisplay(phys) == kCGNullDirectDisplay {
            let b = CGDisplayBounds(phys)
            if CGDisplayIsBuiltin(CGMainDisplayID()) != 0 && b.origin.x >= 0 {
                savedUnmirroredOrigin = b.origin
            } else if CGDisplayIsBuiltin(CGMainDisplayID()) == 0 {
                savedUnmirroredOrigin = b.origin
            }
        } else if onlineDisplays().contains(virtualID) {
            let vb = CGDisplayBounds(virtualID)
            if vb.origin.x >= 0 { savedUnmirroredOrigin = vb.origin }
        }
        let defaultOrigin = CGDisplayIsBuiltin(CGMainDisplayID()) != 0
            ? CGPoint(x: mainBounds.maxX, y: 0)
            : .zero
        let targetOrigin = savedUnmirroredOrigin ?? defaultOrigin

        let orientationChanged: Bool = {
            guard virtualObj != nil, onlineDisplays().contains(virtualID) else { return true }
            let curB = CGDisplayBounds(virtualID)
            return (curB.height > curB.width) != (targetH > targetW)
        }()

        if virtualObj != nil && (activeSpec != want.spec || orientationChanged) {
            unmirror(phys)
            virtualObj = nil
            virtualID = 0
        }

        let createdFresh = (virtualObj == nil)
        if virtualObj == nil {
            var vid: CGDirectDisplayID = 0
            let tag: UInt32 = targetH > targetW ? 2 : 1
            guard let obj = MTCreateHiDPIVirtualDisplay(want.name, targetW, targetH, tag, &vid), vid != 0 else {
                busy = false
                log("HiDPI: failed to create CGVirtualDisplay for \(want.mode)")
                return
            }
            virtualObj = obj
            virtualID = vid
            log("HiDPI: created virtual display \(vid) for \(targetW)x\(targetH) (\(targetW * 2)x\(targetH * 2) framebuffer)")
        }
        activeProfileID = want.profileID
        activeSpec = want.spec
        activeMode = want.mode

        let targetVD = virtualID
        let delay = createdFresh ? 0.35 : 0.02
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            guard self.virtualID == targetVD else { return }
            guard let physNow = onlineDisplays().first(where: { $0 != targetVD && matches(want.spec, $0) }) else { return }
            let wantMode = self.copyHiDPIMode(targetVD, width: targetW, height: targetH)
            let alreadyMirrored = (CGDisplayMirrorsDisplay(physNow) == targetVD)
            var cfgRef: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&cfgRef) == .success, let cfg = cfgRef else { return }
            if let m = wantMode {
                CGConfigureDisplayWithDisplayMode(cfg, targetVD, m, nil)
            }
            if !alreadyMirrored {
                CGConfigureDisplayOrigin(cfg, targetVD, Int32(targetOrigin.x), Int32(targetOrigin.y))
                CGConfigureDisplayMirrorOfDisplay(cfg, physNow, targetVD)
            }
            let err = CGCompleteDisplayConfiguration(cfg, .forSession)
            cachedDisplay = nil
            log("HiDPI: configured display \(physNow) -> virtual \(targetVD) (\(targetW)x\(targetH) @ 2x): \(err == .success ? "OK" : "err \(err.rawValue)")")
        }
    }

    func unmirror(_ phys: CGDirectDisplayID) {
        guard CGDisplayMirrorsDisplay(phys) != kCGNullDirectDisplay else { return }
        var cfgRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfgRef) == .success, let cfg = cfgRef else { return }
        CGConfigureDisplayMirrorOfDisplay(cfg, phys, kCGNullDirectDisplay)
        CGCompleteDisplayConfiguration(cfg, .forSession)
    }

    func tearDown() {
        if !activeSpec.isEmpty, let phys = onlineDisplays().first(where: { $0 != virtualID && matches(activeSpec, $0) }) {
            unmirror(phys)
        }
        virtualObj = nil
        virtualID = 0
        activeProfileID = ""
        activeSpec = ""
        activeMode = "off"
        cachedDisplay = nil
        log("HiDPI: virtual display torn down")
    }
}

let hidpi = HiDPIManager()
