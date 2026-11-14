import Foundation
import GlideCore

/// Virtual display pure logic (GlideCore/VirtualDisplayPolicy.swift, docs/VIRTUAL_DISPLAY.md): mode
/// planning from ViewSize, the HiDPI choice, the keep-alive state machine, host.json parsing.
func virtualDisplayTests() throws {
    func plan(_ p: DisplayModePreference, _ w: Int, _ h: Int, k: HighDPIViewerChoice = .retina, hz: Double = 60) -> VirtualDisplayPlan? {
        VirtualDisplayPlan.make(viewerW: w, viewerH: h, preference: p, highDPIChoice: k, refreshRate: hz)
    }
    func hi(_ w: Int, _ h: Int) -> DisplayModeInfo { .init(width: w, height: h, pixelWidth: w * 2, pixelHeight: h * 2) }
    func one(_ w: Int, _ h: Int) -> DisplayModeInfo { .init(width: w, height: h, pixelWidth: w, pixelHeight: h) }
    func exp(_ p: VirtualDisplayPlan?) -> DisplayModeInfo? { p?.expected }
    func same(_ a: DisplayModeInfo?, _ b: DisplayModeInfo) -> Bool { a.map { $0.sameSize(b) } ?? false }

    // Mode selection from ViewSize + HiDPI choice (follows DisplayModePolicy.resolve).
    let r4k = plan(.automatic, 3840, 2160)
    check(r4k?.modeWidth == 1920 && r4k?.modeHeight == 1080 && r4k?.hiDPI == true && same(exp(r4k), hi(1920, 1080)),
          "vd plan: 4K viewer, automatic -> mode 1920x1080 HiDPI (3840x2160 px)")
    check(same(exp(plan(.automatic, 3840, 2160, k: .smooth)), hi(2560, 1440)), "vd plan: 4K viewer, more-space choice -> looks like 2560x1440 (5120x2880 px)")
    let c4k = plan(.crisp, 3840, 2160)
    check(c4k?.hiDPI == false && same(exp(c4k), one(3840, 2160)), "vd plan: 4K viewer, crisp -> 3840x2160 1x")
    check(same(exp(plan(.automatic, 2560, 1440)), one(2560, 1440)) && plan(.automatic, 2560, 1440)?.style == .crisp, "vd plan: 1440p viewer, automatic -> 2560x1440 1x")
    check(same(exp(plan(.retina, 2560, 1440)), hi(1280, 720)), "vd plan: 1440p viewer, retina -> looks like 1280x720")
    check(same(exp(plan(.smooth, 2560, 1440)), hi(1704, 960)), "vd plan: 1440p viewer, smooth -> looks like 1704x960")
    check(exp(plan(.manual, 3840, 2160)) == exp(plan(.automatic, 3840, 2160)), "vd plan: manual -> automatic for a new display")
    check(same(exp(plan(.crisp, 2561, 1441)), one(2560, 1440)), "vd plan: odd viewer sizes rounded to even")
    check(same(exp(plan(.automatic, 3440, 1440)), one(3440, 1440)), "vd plan: ultrawide 3440x1440 -> exact 1x panel (no physical mode limits)")
    check(plan(.automatic, 3840, 2160, hz: 120)?.refreshRate == 120 && plan(.crisp, 1920, 1080, hz: 120)?.expected.refreshRate == 120, "vd plan: refresh rate carried")
    check(same(exp(plan(.smooth, 5120, 2880)), hi(3408, 1920)), "vd plan: 5K viewer, smooth -> looks like 3408x1920")
    let p8k = plan(.smooth, 7680, 4320)
    check(p8k?.style == .retina && same(exp(p8k), hi(3840, 2160)), "vd plan: 8K smooth exceeds the backing cap -> falls back to retina")
    check(plan(.automatic, 100, 100) == nil && plan(.automatic, 0, 0) == nil, "vd plan: unusable viewer size -> nil")
    let mm = r4k?.sizeInMillimeters
    check(mm.map { $0.w > 400 && $0.w < 500 && $0.h > 200 && $0.h < 300 } ?? false, "vd plan: ~110 pt/in physical size (\(mm.map { "\(Int($0.w))x\(Int($0.h)) mm" } ?? "-"))")

    // Consistent with the existing policy: offered exactly the three planned modes, DisplayModePolicy
    // picks the same one, so DisplayInfo and the menu agree with what the virtual display does.
    var consistent = true
    for (w, h) in [(3840, 2160), (2560, 1440), (1920, 1080), (3440, 1440), (5120, 2880)] {
        for k in HighDPIViewerChoice.allCases {
            let offered = [DisplayModePreference.crisp, .retina, .smooth].compactMap { plan($0, w, h, k: k)?.expected }
            for p in [DisplayModePreference.automatic, .crisp, .retina, .smooth] {
                let chosen = DisplayModePolicy.choose(preference: p, viewerW: w, viewerH: h, modes: offered, current: nil, highDPIChoice: k)
                if chosen.map({ !$0.sameSize(plan(p, w, h, k: k)!.expected) }) ?? true {
                    consistent = false
                    print("    mismatch \(w)x\(h) \(p.rawValue)/\(k.rawValue): policy \(chosen.map { "\($0)" } ?? "nil") vs plan \(plan(p, w, h, k: k)!.expected)")
                }
            }
        }
    }
    check(consistent, "vd plan: matches DisplayModePolicy for every viewer/preference")

    // Limits fixed at creation: every style fits, a bigger viewer needs a new display.
    let lim4k = VirtualDisplayPlan.maxPixels(viewerW: 3840, viewerH: 2160, highDPIChoice: .retina, refreshRate: 60)
    check(lim4k.w == 5120 && lim4k.h == 2880, "vd limits: 4K viewer -> 5120x2880 (room for smooth)")
    check([DisplayModePreference.crisp, .retina, .smooth].allSatisfy { plan($0, 3840, 2160)!.fits(maxPixelsWide: lim4k.w, maxPixelsHigh: lim4k.h) },
          "vd limits: crisp/retina/smooth switch without re-creating")
    let lim1440 = VirtualDisplayPlan.maxPixels(viewerW: 2560, viewerH: 1440, highDPIChoice: .retina, refreshRate: 60)
    check(lim1440.w == 3408 && lim1440.h == 1920, "vd limits: 1440p viewer -> 3408x1920")
    check(!c4k!.fits(maxPixelsWide: lim1440.w, maxPixelsHigh: lim1440.h) && !r4k!.fits(maxPixelsWide: lim1440.w, maxPixelsHigh: lim1440.h),
          "vd limits: viewer moves 1440p -> 4K: needs re-creating (3840 px backing > 3408 limit)")
    check(plan(.crisp, 1920, 1080)!.fits(maxPixelsWide: lim4k.w, maxPixelsHigh: lim4k.h), "vd limits: smaller viewer re-applies")

    // Keep-alive state machine.
    var l = VirtualDisplayLifecycle()
    check(l.sessionBegan() == .none && !l.exists, "vd life: disabled -> nothing")
    l = VirtualDisplayLifecycle(enabled: true, keepAlive: 30)
    check(l.launched() == .none, "vd life: per-session display not created at launch")
    check(l.sessionBegan() == .create && l.phase == .inUse, "vd life: session -> create")
    check(l.sessionEnded(now: 100) == .scheduleTimer(at: 130) && l.phase == .lingering(until: 130), "vd life: disconnect -> keep 30 s")
    check(l.timerFired(now: 120) == .none && l.exists, "vd life: early timer ignored")
    check(l.timerFired(now: 130) == .destroy && l.phase == .off, "vd life: keep-alive expired -> destroy")
    _ = l.sessionBegan(); _ = l.sessionEnded(now: 200)
    check(l.sessionBegan() == .none && l.phase == .inUse, "vd life: reconnect within keep-alive reuses the display")
    check(l.timerFired(now: 230) == .none && l.exists, "vd life: stale timer after reconnect ignored")
    check(l.sessionEnded(now: 240) == .scheduleTimer(at: 270), "vd life: second disconnect re-arms")
    check(l.timerFired(now: 230) == .none && l.timerFired(now: 270) == .destroy, "vd life: only the newest deadline destroys")
    var z = VirtualDisplayLifecycle(enabled: true, keepAlive: 0)
    _ = z.sessionBegan()
    check(z.sessionEnded(now: 1) == .destroy && !z.exists, "vd life: keepAlive 0 -> destroy at once")
    var a = VirtualDisplayLifecycle(enabled: true, alwaysOn: true)
    check(a.launched() == .create && a.phase == .standby, "vd life: always-on -> create at launch")
    check(a.sessionBegan() == .none && a.phase == .inUse, "vd life: always-on session reuses it")
    check(a.sessionEnded(now: 5) == .none && a.phase == .standby, "vd life: always-on stays after disconnect")
    check(a.removeRequested() == .destroy && !a.exists, "vd life: remove now (no viewer)")
    var m = VirtualDisplayLifecycle(enabled: true)
    _ = m.sessionBegan()
    check(m.removeRequested() == .none && m.exists, "vd life: remove now ignored while a viewer uses it")
    check(m.configure(enabled: false, alwaysOn: false, keepAlive: 30, now: 0) == .destroy && !m.exists, "vd life: disabled mid-session -> destroy")
    check(m.sessionEnded(now: 1) == .none, "vd life: disconnect after disabling -> nothing")
    var e = VirtualDisplayLifecycle()
    _ = e.sessionBegan()
    check(e.configure(enabled: true, alwaysOn: false, keepAlive: 30, now: 0) == .create && e.phase == .inUse, "vd life: enabled mid-session -> create now")
    var n = VirtualDisplayLifecycle()
    check(n.configure(enabled: true, alwaysOn: false, keepAlive: 30, now: 0) == .none, "vd life: enabled with no viewer -> wait for one")
    check(n.configure(enabled: true, alwaysOn: true, keepAlive: 30, now: 0) == .create && n.phase == .standby, "vd life: always-on switched on -> create")
    check(n.configure(enabled: true, alwaysOn: false, keepAlive: 30, now: 0) == .destroy, "vd life: always-on switched off with no viewer -> destroy")
    var g = VirtualDisplayLifecycle(enabled: true)
    _ = g.sessionBegan(); _ = g.sessionEnded(now: 0)
    check(g.configure(enabled: true, alwaysOn: true, keepAlive: 30, now: 1) == .none && g.phase == .standby && g.timerFired(now: 30) == .none,
          "vd life: always-on while lingering -> kept, timer ignored")
    var f = VirtualDisplayLifecycle(enabled: true)
    _ = f.sessionBegan(); f.lost()
    check(!f.exists && f.sessionEnded(now: 0) == .none && f.sessionBegan() == .create, "vd life: failed/lost -> retried next session")

    // host.json parsing: defaults, clamps, unknown strings.
    let d = try JSONDecoder().decode(VirtualDisplayConfig.self, from: Data("{}".utf8))
    check(!d.isEnabled && !d.alwaysOn && d.keepAlive == 30 && d.hz == 60 && !d.wantsMain && d.fixedSize == nil, "vd config: defaults (off, per session, 30 s, 60 Hz)")
    let c = try JSONDecoder().decode(VirtualDisplayConfig.self, from: Data(#"{"enabled":true,"lifetime":"Always","keepAliveSeconds":-5,"refreshRate":500,"width":100,"height":50,"future":1}"#.utf8))
    check(c.isEnabled && c.alwaysOn && c.keepAlive == 0 && c.hz == 240 && c.fixedSize == nil, "vd config: clamps and ignores unknown keys")
    let fx = try JSONDecoder().decode(VirtualDisplayConfig.self, from: Data(#"{"lifetime":"weekly","width":2560,"height":1440,"refreshRate":120}"#.utf8))
    check(!fx.alwaysOn && fx.fixedSize.map { $0 == (2560, 1440) } == true && fx.hz == 120, "vd config: fixed size, unknown lifetime -> per session")

    // Making a display main keeps the arrangement (translation).
    let o = VirtualDisplayArrangement.makingMain(2, origins: [1: (0, 0), 2: (-1920, 0), 3: (2560, -200)])
    check(o?[2].map { $0 == (0, 0) } == true && o?[1].map { $0 == (1920, 0) } == true && o?[3].map { $0 == (4480, -200) } == true,
          "vd arrangement: target at (0,0), others translated")
    check(VirtualDisplayArrangement.makingMain(9, origins: [1: (0, 0)]) == nil, "vd arrangement: unknown display -> nil")
}
