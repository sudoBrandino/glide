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

    // Generous creation limits: the one display Glide keeps serves bigger viewers without re-creating.
    let cl1440 = VirtualDisplayPlan.creationLimits(viewerW: 2560, viewerH: 1440, highDPIChoice: .retina)
    check(cl1440.w == 6144 && cl1440.h == 3456, "vd limits: created with at least 6K (6144x3456) limits")
    check(r4k!.fits(maxPixelsWide: cl1440.w, maxPixelsHigh: cl1440.h) && c4k!.fits(maxPixelsWide: cl1440.w, maxPixelsHigh: cl1440.h)
          && plan(.smooth, 3840, 2160)!.fits(maxPixelsWide: cl1440.w, maxPixelsHigh: cl1440.h),
          "vd limits: a display created for 1440p takes a 4K viewer (crisp/retina/smooth) by re-applying settings")
    let cl8k = VirtualDisplayPlan.creationLimits(viewerW: 7680, viewerH: 4320, highDPIChoice: .retina)
    check(cl8k.w == 7680 && cl8k.h == 4320, "vd limits: capped at 7680x4320")

    // A monitor already in exactly the viewer's mode is streamed 1:1 instead.
    check(plan(.automatic, 2560, 1440)!.matches(one(2560, 1440)) && !plan(.automatic, 2560, 1440)!.matches(hi(2304, 1296))
          && !plan(.automatic, 2560, 1440)!.matches(nil), "vd match: physical 2560x1440 1x matches a 1440p viewer; 4608 px HiDPI doesn't")
    check(plan(.retina, 2560, 1440)!.matches(hi(1280, 720)) && !plan(.retina, 2560, 1440)!.matches(one(2560, 1440)),
          "vd match: HiDPI style must match too")

    // Lifecycle: created per session, kept through short reconnects, idle -> removed unless it is
    // the only display (headless) or always-on.
    var l = VirtualDisplayLifecycle()
    check(l.sessionBegan() == .none && !l.exists, "vd life: disabled -> nothing")
    l = VirtualDisplayLifecycle(enabled: true, keepAlive: 10)
    check(l.launched() == .none, "vd life: per-session display not created at launch")
    check(l.sessionBegan() == .create && l.phase == .inUse && l.creating, "vd life: session -> create")
    check(l.created() == .streaming && !l.creating, "vd life: created for the viewer -> streaming arrangement")
    check(l.sessionEnded(now: 100, onlyDisplay: false) == .scheduleTimer(at: 110) && l.phase == .lingering(until: 110), "vd life: disconnect -> keep 10 s")
    check(l.timerFired(now: 105, onlyDisplay: false) == .none && l.exists, "vd life: early timer ignored")
    check(l.timerFired(now: 110, onlyDisplay: false) == .destroy && l.phase == .off, "vd life: idle with a monitor -> restore arrangement, remove")
    _ = l.sessionBegan(); _ = l.created(); _ = l.sessionEnded(now: 200, onlyDisplay: false)
    check(l.sessionBegan() == .resume && l.phase == .inUse, "vd life: reconnect within keep-alive resumes the same display")
    check(l.timerFired(now: 210, onlyDisplay: false) == .none && l.exists, "vd life: stale timer after reconnect ignored")
    check(l.sessionEnded(now: 240, onlyDisplay: false) == .scheduleTimer(at: 250), "vd life: second disconnect re-arms")
    check(l.timerFired(now: 210, onlyDisplay: false) == .none && l.timerFired(now: 250, onlyDisplay: false) == .destroy, "vd life: only the newest deadline acts")
    var h = VirtualDisplayLifecycle(enabled: true, keepAlive: 10)
    _ = h.sessionBegan(); _ = h.created(); _ = h.sessionEnded(now: 0, onlyDisplay: true)
    check(h.timerFired(now: 10, onlyDisplay: true) == .standby && h.phase == .standby, "vd life: headless (only display) -> kept on standby")
    check(h.sessionBegan() == .resume, "vd life: headless reconnect resumes")
    check(h.configure(enabled: true, alwaysOn: false, keepAlive: 10, onlyDisplay: true) == .none, "vd life: settings change keeps a headless display")
    var z = VirtualDisplayLifecycle(enabled: true, keepAlive: 0)
    _ = z.sessionBegan()
    check(z.sessionEnded(now: 1, onlyDisplay: false) == .destroy && !z.exists, "vd life: keepAlive 0 -> idle at once")
    var a = VirtualDisplayLifecycle(enabled: true, alwaysOn: true)
    check(a.launched() == .create && a.phase == .standby && a.creating, "vd life: always-on -> create at launch")
    check(a.created() == .standby && !a.creating, "vd life: always-on created with no viewer -> standby (hidden)")
    check(a.sessionBegan() == .resume && a.phase == .inUse, "vd life: always-on session resumes it")
    check(a.sessionEnded(now: 5, onlyDisplay: false) == .scheduleTimer(at: 15), "vd life: always-on keeps the streaming arrangement for keep-alive")
    check(a.timerFired(now: 15, onlyDisplay: false) == .standby && a.phase == .standby, "vd life: always-on idle -> standby (hidden), not removed")
    check(a.removeRequested() == .destroy && !a.exists, "vd life: remove now (no viewer)")
    var m = VirtualDisplayLifecycle(enabled: true)
    _ = m.sessionBegan()
    check(m.removeRequested() == .none && m.exists, "vd life: remove now ignored while a viewer uses it")
    check(m.configure(enabled: false, alwaysOn: false, keepAlive: 10, onlyDisplay: false) == .destroy && !m.exists, "vd life: disabled mid-session -> destroy")
    check(m.sessionEnded(now: 1, onlyDisplay: false) == .none, "vd life: disconnect after disabling -> nothing")
    var e = VirtualDisplayLifecycle()
    _ = e.sessionBegan()
    check(e.configure(enabled: true, alwaysOn: false, keepAlive: 10, onlyDisplay: false) == .create && e.phase == .inUse, "vd life: enabled mid-session -> create now")
    var n = VirtualDisplayLifecycle()
    check(n.configure(enabled: true, alwaysOn: false, keepAlive: 10, onlyDisplay: false) == .none, "vd life: enabled with no viewer -> wait for one")
    check(n.configure(enabled: true, alwaysOn: true, keepAlive: 10, onlyDisplay: false) == .create && n.phase == .standby, "vd life: always-on switched on -> create")
    check(n.configure(enabled: true, alwaysOn: false, keepAlive: 10, onlyDisplay: false) == .destroy, "vd life: always-on switched off with no viewer -> destroy")
    var g = VirtualDisplayLifecycle(enabled: true)
    _ = g.sessionBegan(); _ = g.created(); _ = g.sessionEnded(now: 0, onlyDisplay: false)
    check(g.configure(enabled: true, alwaysOn: true, keepAlive: 10, onlyDisplay: false) == .standby && g.phase == .standby && g.timerFired(now: 30, onlyDisplay: false) == .none,
          "vd life: always-on while lingering -> standby now, timer ignored")
    var f = VirtualDisplayLifecycle(enabled: true)
    _ = f.sessionBegan(); f.lost()
    check(!f.exists && f.sessionEnded(now: 0, onlyDisplay: false) == .none && f.sessionBegan() == .create, "vd life: failed/lost/skipped -> retried next session")

    // Finding 1: a viewer that connects while the launch create is still in flight is answered by
    // the creation, which arranges for the phase *when it finishes* (streaming), never standby.
    var race = VirtualDisplayLifecycle(enabled: true, alwaysOn: true)
    _ = race.launched()
    check(race.sessionBegan() == .awaitCreation && race.phase == .inUse, "vd race: viewer during the launch create -> waits for it (no second create/resume)")
    check(race.created() == .streaming, "vd race: launch create finishing after the viewer connected -> streaming arrangement, not standby")
    check(race.sessionEnded(now: 0, onlyDisplay: false) == .scheduleTimer(at: 10), "vd race: then a normal disconnect")
    var left = VirtualDisplayLifecycle(enabled: true, alwaysOn: true)
    _ = left.launched(); _ = left.sessionBegan()
    check(left.sessionEnded(now: 0, onlyDisplay: false) == .scheduleTimer(at: 10) && left.created() == .keep,
          "vd race: viewer came and went during the create -> keep (the timer decides)")
    check(left.timerFired(now: 10, onlyDisplay: false) == .standby, "vd race: ... then standby")
    var gone = VirtualDisplayLifecycle(enabled: true, keepAlive: 0)
    _ = gone.sessionBegan()
    check(gone.sessionEnded(now: 0, onlyDisplay: false) == .destroy && !gone.creating && gone.created() == .discard,
          "vd race: per-session viewer left during the create (keep-alive 0) -> destroy; a late completion discards")
    var quick = VirtualDisplayLifecycle(enabled: true, alwaysOn: true, keepAlive: 0)
    _ = quick.launched(); _ = quick.sessionBegan()
    check(quick.sessionEnded(now: 0, onlyDisplay: false) == .none && quick.phase == .standby && quick.created() == .standby,
          "vd race: always-on, viewer left during the create -> the creation sets up standby itself")
    var re = VirtualDisplayLifecycle(enabled: true)
    _ = re.sessionBegan(); _ = re.created()
    re.recreating()
    check(re.creating && re.phase == .inUse && re.displaysChanged(onlyDisplay: false) == .none && re.created() == .streaming,
          "vd race: re-create (viewer outgrew the limits) -> streaming decided at completion")
    var reIdle = VirtualDisplayLifecycle(enabled: true, alwaysOn: true)
    _ = reIdle.launched(); _ = reIdle.created(); _ = reIdle.sessionBegan(); _ = reIdle.sessionEnded(now: 0, onlyDisplay: false)
    _ = reIdle.timerFired(now: 10, onlyDisplay: false)
    reIdle.recreating()
    check(reIdle.sessionBegan() == .awaitCreation && reIdle.created() == .streaming, "vd race: viewer during a standby re-create -> streaming")
    var offRe = VirtualDisplayLifecycle(enabled: true)
    offRe.recreating()
    check(!offRe.creating, "vd race: nothing to re-create while off")
    var lostC = VirtualDisplayLifecycle(enabled: true, alwaysOn: true)
    _ = lostC.launched(); lostC.lost()
    check(!lostC.creating && lostC.sessionBegan() == .create, "vd race: a failed create clears the in-flight flag")

    // Finding 4: idle standby re-evaluated on display changes.
    var hs = VirtualDisplayLifecycle(enabled: true, keepAlive: 0)
    _ = hs.sessionBegan(); _ = hs.created(); _ = hs.sessionEnded(now: 0, onlyDisplay: true)
    check(hs.phase == .standby && hs.displaysChanged(onlyDisplay: true) == .standby, "vd displays: headless standby, still headless -> re-hide (no-op)")
    check(hs.displaysChanged(onlyDisplay: false) == .destroy && !hs.exists, "vd displays: headless standby, monitor plugged in / lid opened -> removed")
    var ao = VirtualDisplayLifecycle(enabled: true, alwaysOn: true)
    _ = ao.launched(); _ = ao.created()
    check(ao.displaysChanged(onlyDisplay: false) == .standby && ao.phase == .standby, "vd displays: always-on standby, monitor change -> hide behind the new main monitor")
    var aoc = VirtualDisplayLifecycle(enabled: true, alwaysOn: true)
    _ = aoc.launched()
    check(aoc.displaysChanged(onlyDisplay: false) == .none, "vd displays: ignored while it is being created")
    var use = VirtualDisplayLifecycle(enabled: true)
    _ = use.sessionBegan(); _ = use.created()
    check(use.displaysChanged(onlyDisplay: false) == .none && use.displaysChanged(onlyDisplay: false, wanted: false) == .none,
          "vd displays: a connected viewer keeps it")
    var lin = VirtualDisplayLifecycle(enabled: true)
    _ = lin.sessionBegan(); _ = lin.created(); _ = lin.sessionEnded(now: 0, onlyDisplay: false)
    check(lin.displaysChanged(onlyDisplay: false) == .none && lin.exists, "vd displays: lingering -> the timer decides")
    var poff = VirtualDisplayLifecycle(enabled: true)
    check(poff.displaysChanged(onlyDisplay: true) == .none && !poff.exists, "vd displays: per-session, off, headless -> created at the next session")
    var dis = VirtualDisplayLifecycle(enabled: false)
    check(dis.displaysChanged(onlyDisplay: true) == .none, "vd displays: disabled -> nothing")

    // Finding 11: "stream" with a monitor means no virtual display, always-on included.
    var st = VirtualDisplayLifecycle(enabled: true, alwaysOn: true)
    check(st.launched(wanted: false) == .none && !st.exists, "vd stream: always-on + stream + monitor -> not created at launch")
    check(st.displaysChanged(onlyDisplay: true, wanted: true) == .create && st.phase == .standby, "vd stream: monitor unplugged (headless) -> always-on display created")
    _ = st.created()
    check(st.displaysChanged(onlyDisplay: false, wanted: false) == .destroy && !st.exists, "vd stream: monitor plugged back in -> idle always-on display removed")
    var st2 = VirtualDisplayLifecycle(enabled: true, alwaysOn: true)
    _ = st2.launched(); _ = st2.created()
    check(st2.configure(enabled: true, alwaysOn: true, keepAlive: 10, onlyDisplay: false, wanted: false) == .destroy, "vd stream: switched to stream from the menu -> idle display removed")
    var st3 = VirtualDisplayLifecycle(enabled: true, alwaysOn: true)
    _ = st3.launched(); _ = st3.created()
    check(st3.sessionBegan(wanted: false) == .destroy && !st3.exists && st3.sessionActive, "vd stream: viewer connects to an always-on display in stream mode -> removed, monitor streamed")
    check(st3.sessionEnded(now: 0, onlyDisplay: false, wanted: false) == .none, "vd stream: ... nothing to do on disconnect")
    var st4 = VirtualDisplayLifecycle(enabled: true, alwaysOn: true, keepAlive: 0)
    _ = st4.launched(); _ = st4.created(); _ = st4.sessionBegan()
    check(st4.sessionEnded(now: 0, onlyDisplay: false, wanted: false) == .destroy, "vd stream: always-on idles with a monitor in stream mode -> removed, not hidden")
    var st5 = VirtualDisplayLifecycle(enabled: true)
    check(st5.sessionBegan(wanted: false) == .none && !st5.exists, "vd stream: per-session + monitor -> nothing created")
    check(st5.configure(enabled: true, alwaysOn: false, keepAlive: 10, onlyDisplay: false, wanted: false) == .none, "vd stream: enabled mid-session with a monitor -> still nothing")
    var st6 = VirtualDisplayLifecycle(enabled: true, alwaysOn: true)
    check(st6.configure(enabled: true, alwaysOn: true, keepAlive: 10, onlyDisplay: false, wanted: false) == .none && !st6.exists,
          "vd stream: always-on switched on in stream mode with a monitor -> nothing")

    // Arrangement while streaming.
    typealias D = VirtualDisplayTopology.Display
    let V: UInt32 = 10, OMEN: UInt32 = 2, BUILTIN: UInt32 = 1
    check(VirtualDisplayTopology.choose(mode: .mirror, makeMain: true, virtual: V, main: V, displays: [D(id: V)]) == .alone, "vd topology: headless -> alone")
    check(VirtualDisplayTopology.choose(mode: .mirror, makeMain: true, virtual: V, main: OMEN, displays: [D(id: OMEN), D(id: V)]) == .mirror(physical: OMEN),
          "vd topology: a monitor -> it mirrors the virtual display (default)")
    check(VirtualDisplayTopology.choose(mode: .mirror, makeMain: true, virtual: V, main: V, displays: [D(id: OMEN, mirrorOf: V), D(id: V)]) == .mirror(physical: OMEN),
          "vd topology: reconnect keeps the monitor that mirrors it")
    check(VirtualDisplayTopology.choose(mode: .mirror, makeMain: true, virtual: V, main: OMEN, displays: [D(id: BUILTIN), D(id: OMEN), D(id: V)]) == .mirror(physical: OMEN),
          "vd topology: two monitors -> only the main one mirrors it")
    check(VirtualDisplayTopology.choose(mode: .mirror, makeMain: true, virtual: V, main: OMEN, displays: [D(id: BUILTIN, mirrorOf: OMEN), D(id: OMEN), D(id: V)]) == .extend(main: true),
          "vd topology: the user already mirrors displays -> extend instead (their setup wins)")
    check(VirtualDisplayTopology.choose(mode: .extend, makeMain: true, virtual: V, main: OMEN, displays: [D(id: OMEN), D(id: V)]) == .extend(main: true)
          && VirtualDisplayTopology.choose(mode: .extend, makeMain: false, virtual: V, main: OMEN, displays: [D(id: OMEN), D(id: V)]) == .extend(main: false),
          "vd topology: extend (main or not)")
    check(!VirtualDisplayTopology.wantsVirtual(mode: .stream, physicalDisplays: 1) && VirtualDisplayTopology.wantsVirtual(mode: .stream, physicalDisplays: 0)
          && VirtualDisplayTopology.wantsVirtual(mode: .mirror, physicalDisplays: 2), "vd topology: \"stream\" uses the monitor, the virtual display only headless")

    // Finding 4: the recorded arrangement follows displays that go offline or come back mirroring.
    let LID: UInt32 = 1
    typealias L = VirtualDisplayLayout
    check(L.reconcile(.mirror(physical: LID), virtual: V, streaming: true, mode: .mirror, displays: [D(id: OMEN)]) == [.forget(LID)],
          "vd reconcile: lid closed while the built-in panel mirrors it -> forget it (no transaction on the offline panel)")
    check(L.reconcile(.hidden(behind: LID), virtual: V, streaming: false, mode: .mirror, displays: []) == [.forget(LID)],
          "vd reconcile: lid closed while idle and hidden behind the panel -> forget it")
    check(L.reconcile(.none, virtual: V, streaming: false, mode: .mirror, displays: [D(id: LID, mirrorOf: V)]) == [.unmirror(LID)],
          "vd reconcile: lid opened, panel came back still mirroring the idle display -> end that mirror")
    check(L.reconcile(.hidden(behind: OMEN), virtual: V, streaming: false, mode: .mirror, displays: [D(id: OMEN), D(id: LID, mirrorOf: V)]) == [.unmirror(LID)],
          "vd reconcile: stray mirror while hidden -> ended")
    check(L.reconcile(.none, virtual: V, streaming: true, mode: .mirror, displays: [D(id: LID, mirrorOf: V)]) == [.adopt(LID)],
          "vd reconcile: streaming (mirror), panel came back mirroring -> adopted as the streaming mirror")
    check(L.reconcile(.extendMain(previousMain: OMEN), virtual: V, streaming: true, mode: .extend, displays: [D(id: OMEN), D(id: LID, mirrorOf: V)]) == [.unmirror(LID)],
          "vd reconcile: streaming (extend), a monitor mirrors it -> ended")
    check(L.reconcile(.mirror(physical: OMEN), virtual: V, streaming: true, mode: .mirror, displays: [D(id: OMEN, mirrorOf: V), D(id: LID)]).isEmpty
          && L.reconcile(.none, virtual: V, streaming: false, mode: .mirror, displays: [D(id: OMEN)]).isEmpty,
          "vd reconcile: nothing to fix -> nothing")
    check(L.reconcile(.mirror(physical: LID), virtual: V, streaming: true, mode: .mirror, displays: [D(id: OMEN, mirrorOf: V)]) == [.forget(LID), .adopt(OMEN)],
          "vd reconcile: mirror monitor swapped -> forget the old one, adopt the new one")
    check(L.mirror(physical: OMEN).mirroring == OMEN && L.hidden(behind: OMEN).mirroring == nil && L.extendMain(previousMain: LID).physical == LID && L.none.physical == nil,
          "vd layout: accessors")

    // Findings 2, 5, 8: the saved mode is restored onto the right monitor, at its refresh rate,
    // and a pending restore is never overwritten by the mirrored mode.
    func ident(_ id: UInt32, _ v: UInt32, _ m: UInt32, _ s: UInt32) -> DisplayIdentity { DisplayIdentity(id: id, vendor: v, model: m, serial: s, name: "") }
    let omen = ident(2, 0x30AE, 0x6A1F, 777), builtin = ident(1, 0x610, 0xA050, 0)
    check(ModeRestore.resolve(identity: omen, legacyID: 2, online: [builtin, omen]) == .display(2), "restore target: same ID and hardware")
    check(ModeRestore.resolve(identity: omen, legacyID: 2, online: [builtin, ident(5, 0x30AE, 0x6A1F, 777)]) == .display(5), "restore target: monitor replugged with a new ID -> followed by serial")
    check(ModeRestore.resolve(identity: omen, legacyID: 2, online: [ident(2, 0x1E6D, 0x5B11, 42), builtin]) == .notConnected,
          "restore target: ID reused by a different monitor after a reboot -> not that one (kept until the OMEN is back)")
    check(ModeRestore.resolve(identity: builtin, legacyID: 1, online: [ident(3, 0x610, 0xA050, 0), omen]) == .display(3), "restore target: no serial, one vendor/model match -> it")
    check(ModeRestore.resolve(identity: ident(4, 0x22, 0x33, 0), legacyID: nil, online: [ident(5, 0x22, 0x33, 0), ident(6, 0x22, 0x33, 0)]) == .notConnected,
          "restore target: no serial, two identical monitors -> ambiguous, not guessed")
    check(ModeRestore.resolve(identity: ident(4, 0x22, 0x33, 0), legacyID: nil, online: [ident(4, 0x22, 0x33, 0), ident(6, 0x22, 0x33, 0)]) == .display(4),
          "restore target: no serial but the same ID and hardware -> it")
    check(ModeRestore.resolve(identity: nil, legacyID: 2, online: [omen]) == .display(2) && ModeRestore.resolve(identity: nil, legacyID: 9, online: [omen]) == .notConnected
          && ModeRestore.resolve(identity: nil, legacyID: nil, online: [omen]) == .served, "restore target: old files (bare ID, or none) still work")
    check(ModeRestore.beforeMirror(pending: nil, display: 2, served: 10) == .remember, "before mirror: nothing pending -> remember")
    check(ModeRestore.beforeMirror(pending: .display(2), display: 2, served: 10) == .keepPending,
          "before mirror: a restore for this monitor is pending (failed un-mirror, earlier switch) -> never overwritten by the current mode")
    check(ModeRestore.beforeMirror(pending: .display(1), display: 2, served: 10) == .otherPending, "before mirror: another connected display's restore -> left alone")
    check(ModeRestore.beforeMirror(pending: .notConnected, display: 2, served: 10) == .remember, "before mirror: pending for a display that's gone -> replaced")
    check(ModeRestore.beforeMirror(pending: .served, display: 2, served: 2) == .keepPending && ModeRestore.beforeMirror(pending: .served, display: 2, served: 10) == .otherPending,
          "before mirror: legacy restore (served display)")
    func md(_ w: Int, _ h: Int, _ hz: Double, hi: Bool = false) -> DisplayModeInfo { .init(width: w, height: h, pixelWidth: hi ? w * 2 : w, pixelHeight: hi ? h * 2 : h, refreshRate: hz) }
    let omenModes = [md(3840, 2160, 60), md(3840, 2160, 120), md(3840, 2160, 165), md(2560, 1440, 60), md(2560, 1440, 165), md(1920, 1080, 60, hi: true), md(1920, 1080, 165, hi: true)]
    check(ModeRestore.choose(saved: md(3840, 2160, 165), current: md(3840, 2160, 60), available: omenModes) == .switchTo(md(3840, 2160, 165)),
          "restore: 165 Hz monitor left at 60 Hz by the mirror -> back to 165 Hz (same size isn't enough)")
    check(ModeRestore.choose(saved: md(3840, 2160, 165), current: md(3840, 2160, 165), available: omenModes) == .alreadyThere, "restore: already at size and rate -> nothing")
    check(ModeRestore.choose(saved: md(3840, 2160, 164.99), current: md(1920, 1080, 60, hi: true), available: omenModes) == .switchTo(md(3840, 2160, 165)),
          "restore: rates within 0.5 Hz are the same (164.99 / 165)")
    check(ModeRestore.choose(saved: md(2560, 1440, 240), current: md(3840, 2160, 60), available: omenModes) == .switchTo(md(2560, 1440, 165)),
          "restore: saved rate no longer offered -> same size, closest rate")
    check(ModeRestore.choose(saved: md(2560, 1440, 240), current: md(2560, 1440, 60), available: omenModes) == .alreadyThere,
          "restore: saved rate gone and already at the size -> size only, left alone")
    check(ModeRestore.choose(saved: md(1920, 1080, 165, hi: true), current: md(1920, 1080, 60, hi: true), available: omenModes) == .switchTo(md(1920, 1080, 165, hi: true)),
          "restore: HiDPI mode at its rate")
    check(ModeRestore.choose(saved: md(5120, 2880, 60, hi: true), current: md(3840, 2160, 60), available: omenModes) == .unavailable, "restore: size no longer offered -> unavailable")
    check(ModeRestore.choose(saved: md(2560, 1440, 0), current: md(3840, 2160, 60), available: omenModes) == .switchTo(md(2560, 1440, 60))
          && ModeRestore.choose(saved: md(2560, 1440, 0), current: md(2560, 1440, 165), available: omenModes) == .alreadyThere, "restore: no saved rate -> size only")

    // host.json "display": old files (bare restoreDisplay) decode; new ones carry the identity.
    let oldJSON = #"{"mode":"retina","restore":{"width":3840,"height":2160,"pixelWidth":3840,"pixelHeight":2160,"refreshRate":165},"restoreDisplay":2}"#
    let oldS = try JSONDecoder().decode(DisplaySettings.self, from: Data(oldJSON.utf8))
    check(oldS.restore == md(3840, 2160, 165) && oldS.restoreDisplay == 2 && oldS.restoreIdentity == nil && oldS.preference == .retina,
          "display settings: files without restoreIdentity still decode (bare display ID)")
    let newS = DisplaySettings(restore: md(3840, 2160, 165), restoreDisplay: 2, restoreIdentity: omen)
    let rt = try JSONDecoder().decode(DisplaySettings.self, from: JSONEncoder().encode(newS))
    check(rt == newS && rt.restoreIdentity?.serial == 777, "display settings: restoreIdentity round-trips")
    check(try JSONDecoder().decode(DisplaySettings.self, from: Data("{}".utf8)) == DisplaySettings(), "display settings: empty -> defaults")
    check(ModeRestore.afterMirrorSettle > 0 && ModeRestore.afterMirrorSettle <= 2, "restore: exit waits at most ~1.5 s for a monitor that just stopped mirroring")

    // host.json parsing: defaults (on, mirror, viewer's refresh), clamps, unknown strings.
    let d = try JSONDecoder().decode(VirtualDisplayConfig.self, from: Data("{}".utf8))
    check(d.isEnabled && !d.explicitlyEnabled && !d.alwaysOn && d.keepAlive == 10 && d.monitorMode == .mirror && d.wantsMain && d.fixedSize == nil,
          "vd config: defaults (on, per session, 10 s, monitor mirrors it)")
    check(d.refreshRate(viewerHz: 144) == 144 && d.refreshRate(viewerHz: 60) == 60 && d.refreshRate(viewerHz: 0) == 120 && d.refreshRate(viewerHz: nil) == 120
          && d.refreshRate(viewerHz: 10) == 120 && d.refreshRate(viewerHz: 360) == 240, "vd config: refresh = viewer's monitor (max_fps), else 120 Hz, 24...240")
    let off = try JSONDecoder().decode(VirtualDisplayConfig.self, from: Data(#"{"enabled":false}"#.utf8))
    check(!off.isEnabled, "vd config: opt-out")
    let c = try JSONDecoder().decode(VirtualDisplayConfig.self, from: Data(#"{"enabled":true,"lifetime":"Always","keepAliveSeconds":-5,"refreshRate":500,"width":100,"height":50,"whenMonitorAttached":"EXTEND","makeMain":false,"future":1}"#.utf8))
    check(c.isEnabled && c.explicitlyEnabled && c.alwaysOn && c.keepAlive == 0 && c.refreshRate(viewerHz: 60) == 240 && c.fixedSize == nil
          && c.monitorMode == .extend && !c.wantsMain, "vd config: clamps, case-insensitive, ignores unknown keys; host.json refresh beats the viewer's")
    let fx = try JSONDecoder().decode(VirtualDisplayConfig.self, from: Data(#"{"lifetime":"weekly","width":2560,"height":1440,"refreshRate":120,"whenMonitorAttached":"sideways"}"#.utf8))
    check(!fx.alwaysOn && fx.fixedSize.map { $0 == (2560, 1440) } == true && fx.refreshRate(viewerHz: 60) == 120 && fx.monitorMode == .mirror,
          "vd config: fixed size; unknown lifetime/monitor mode -> defaults")

    // Read-back of the virtual display's mode from a child process (--list-display-modes).
    let listing = "display 10: main no, builtin no, bounds -1280,0 1280x720 pt\ncurrent: 1280x720 px=2560x1440 hz=120\nusable modes: 14\n"
    let parsed = DisplayModeInfo.parseListing(listing)
    check(parsed.map { $0.sameSize(hi(1280, 720)) && $0.refreshRate == 120 } == true, "vd readback: parses the child's current mode")
    check(DisplayModeInfo.parseListing("display 10: not online") == nil && DisplayModeInfo.parseListing("current: unknown") == nil, "vd readback: no mode -> nil")

    // Making a display main keeps the arrangement (translation).
    let o = VirtualDisplayArrangement.makingMain(2, origins: [1: (0, 0), 2: (-1920, 0), 3: (2560, -200)])
    check(o?[2].map { $0 == (0, 0) } == true && o?[1].map { $0 == (1920, 0) } == true && o?[3].map { $0 == (4480, -200) } == true,
          "vd arrangement: target at (0,0), others translated")
    check(VirtualDisplayArrangement.makingMain(9, origins: [1: (0, 0)]) == nil, "vd arrangement: unknown display -> nil")
}
