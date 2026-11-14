//! Viewer-side input logic that doesn't need Win32, so it is unit-tested on every OS:
//! key routing (local hotkeys, forwarding, keys left to Windows), keypad navigation with Num Lock
//! off, media keys, scroll source/direction, and relative-motion splitting (PROTOCOL.md §3, §3.6).
//! `win::app` feeds it the raw Win32 events.

use std::collections::HashSet;

use crate::hid::{self, HID_NUMLOCK};
use crate::hotkeys::{self, Action, Mods};
use crate::protocol::{ClientMsg, SCROLL_PRECISE};

pub const HID_CAPSLOCK: u16 = 0x39;

/// What the key router decided for one key event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyOutcome {
    /// A viewer hotkey: consumed, run the action.
    Hotkey(Action),
    /// Consumed, nothing to send (the release of a hotkey key).
    Swallow,
    /// Consumed: send `Key { usage }` (already remapped).
    Send(u16),
    /// Not ours: let Windows have it (disconnected, keyboard released, or a key Windows keeps).
    Local,
}

/// Per-event context from the UI.
#[derive(Debug, Clone, Copy, Default)]
pub struct KeyCtx {
    /// Connected, and the keyboard isn't released to Windows.
    pub forwarding: bool,
    pub ctrl_as_cmd: bool,
    /// The host takes lock-key state (§3.6 InputCaps bit2): Caps Lock / Num Lock stay with
    /// Windows (LEDs right) and their state is sent as LockState instead.
    pub locks_local: bool,
}

/// Physical key state and hotkey bookkeeping (UI thread).
///
/// The same event can reach `on_key` twice (the low-level hook, then WM_KEYDOWN for a key it let
/// through), so everything here is idempotent for a repeated event.
#[derive(Debug, Default)]
pub struct KeyRouter {
    /// Physical (pre-remap) keys held, for hotkey modifier matching.
    pub down: HashSet<u16>,
    /// Keys whose down was a hotkey: their up is swallowed too.
    swallow_up: HashSet<u16>,
}

impl KeyRouter {
    pub fn on_key(&mut self, usage: u16, down: bool, ctx: KeyCtx) -> KeyOutcome {
        // Local hotkeys (F11, Alt+Enter, Ctrl+Alt+Shift+letter), matched on physical keys.
        if down {
            if let Some(a) = hotkeys::match_hotkey(Mods::from_held(self.down.iter().copied()), usage) {
                self.swallow_up.insert(usage);
                return KeyOutcome::Hotkey(a);
            }
        }
        if !down && self.swallow_up.remove(&usage) {
            return KeyOutcome::Swallow;
        }
        if down {
            self.down.insert(usage);
        } else {
            self.down.remove(&usage);
        }
        if !ctx.forwarding {
            return KeyOutcome::Local;
        }
        if ctx.locks_local && (usage == HID_CAPSLOCK || usage == HID_NUMLOCK) {
            return KeyOutcome::Local;
        }
        KeyOutcome::Send(if ctx.ctrl_as_cmd { hid::remap_ctrl_as_cmd(usage) } else { usage })
    }

    /// Forget every held key (the host was told ReleaseAll, or the keys' releases went elsewhere:
    /// focus loss, a Glide menu, a dialog). Without this, modifiers whose ups went to a menu stayed
    /// "held" here, so a later plain letter matched a Ctrl+Alt+Shift hotkey, and the next Space up
    /// after the Ctrl+Alt+Shift+Space menu was swallowed (Space stuck down on the Mac).
    pub fn reset(&mut self) {
        self.down.clear();
        self.swallow_up.clear();
    }
}

/// With Num Lock off, Windows reports keypad keys with navigation virtual keys (same scancode).
/// Returns the HID usage the user meant: `Some(nav usage)`, `Some(0)` for keypad 5 (does nothing),
/// `None` = not a keypad navigation key (use the scancode mapping).
pub fn keypad_nav(sc: u16, vk: u32) -> Option<u16> {
    if sc & hid::EXT != 0 || !(0x47..=0x53).contains(&sc) {
        return None;
    }
    Some(match vk {
        0x24 => 0x4A, // VK_HOME
        0x26 => 0x52, // VK_UP
        0x21 => 0x4B, // VK_PRIOR (Page Up)
        0x25 => 0x50, // VK_LEFT
        0x0C => 0,    // VK_CLEAR (keypad 5)
        0x27 => 0x4F, // VK_RIGHT
        0x23 => 0x4D, // VK_END
        0x28 => 0x51, // VK_DOWN
        0x22 => 0x4E, // VK_NEXT (Page Down)
        0x2D => 0x49, // VK_INSERT
        0x2E => 0x4C, // VK_DELETE
        _ => return None,
    })
}

/// Media keys by virtual key (Windows reports them with VKs; most have no Keyboard-page usage).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaKey {
    /// Volume up/down/mute: kept on this PC. The Mac's audio plays here, so this PC's volume is the
    /// one that matters (and the Mac's output volume doesn't change the captured stream).
    Volume,
    /// Play/pause, next, previous, stop: HID Consumer usage for the Mac (§3.6 ConsumerKey).
    Transport(u16),
}

pub fn media_key(vk: u32) -> Option<MediaKey> {
    Some(match vk {
        0xAD..=0xAF => MediaKey::Volume, // VK_VOLUME_MUTE / DOWN / UP
        0xB0 => MediaKey::Transport(0xB5), // VK_MEDIA_NEXT_TRACK
        0xB1 => MediaKey::Transport(0xB6), // VK_MEDIA_PREV_TRACK
        0xB2 => MediaKey::Transport(0xB7), // VK_MEDIA_STOP
        0xB3 => MediaKey::Transport(0xCD), // VK_MEDIA_PLAY_PAUSE
        _ => return None,
    })
}

/// Windows `WHEEL_DELTA`: one notch.
pub const WHEEL_DELTA: f32 = 120.0;
/// A precise source keeps counting as precise for this long, so a touchpad or high-resolution
/// wheel event that happens to be a whole notch doesn't end the gesture on the Mac.
const PRECISE_STICKY_US: u64 = 250_000;

/// Scroll source tracking and the message for one WM_MOUSEWHEEL / WM_MOUSEHWHEEL.
#[derive(Debug, Default)]
pub struct WheelState {
    last_precise_us: Option<u64>,
}

impl WheelState {
    /// `delta`: the message's wheel delta (120 = one notch; positive = away from the user / right).
    /// `touchpad`: Windows says the message came from a touchpad. `natural`: invert both axes.
    /// `scroll_msg`: the host accepts §3.6 Scroll (else legacy MouseWheel).
    pub fn message(&mut self, delta: i16, horizontal: bool, touchpad: bool, natural: bool, scroll_msg: bool, now_us: u64) -> ClientMsg {
        let fine = touchpad || delta as i32 % WHEEL_DELTA as i32 != 0;
        if fine {
            self.last_precise_us = Some(now_us);
        }
        let precise = fine || self.last_precise_us.is_some_and(|t| now_us.saturating_sub(t) < PRECISE_STICKY_US);
        let mut v = delta as f32 / WHEEL_DELTA;
        if natural {
            v = -v;
        }
        let (dx, dy) = if horizontal { (v, 0.0) } else { (0.0, v) };
        if scroll_msg {
            ClientMsg::Scroll { flags: if precise { SCROLL_PRECISE } else { 0 }, dx, dy }
        } else {
            ClientMsg::MouseWheel { dx, dy }
        }
    }
}

/// Relative motion (raw input counts) as MouseDelta messages: accumulated motion is sent in
/// chunks that fit `i16`.
pub fn mouse_deltas(mut dx: i64, mut dy: i64) -> Vec<ClientMsg> {
    let mut out = Vec::new();
    while dx != 0 || dy != 0 {
        let cx = dx.clamp(i16::MIN as i64, i16::MAX as i64);
        let cy = dy.clamp(i16::MIN as i64, i16::MAX as i64);
        out.push(ClientMsg::MouseDelta { dx: cx as i16, dy: cy as i16 });
        dx -= cx;
        dy -= cy;
    }
    out
}

/// Merge a backlog of queued input before it is sent (after the link stalled, or a 1–8 kHz mouse
/// in relative mode outpacing the writer): a run of consecutive `MouseMove`s becomes its last one
/// (positions are absolute), and a run of consecutive `MouseDelta`s becomes their exact sum (split
/// again as `mouse_deltas` does; a zero sum sends nothing). Every other message is kept as is, and
/// nothing is reordered: a run ends at any other message, so motion stays on the same side of each
/// button, key, wheel and lock-state message.
pub fn coalesce(msgs: impl IntoIterator<Item = ClientMsg>) -> Vec<ClientMsg> {
    enum Run {
        None,
        Move(ClientMsg),
        Delta(i64, i64),
    }
    fn flush(run: &mut Run, out: &mut Vec<ClientMsg>) {
        match std::mem::replace(run, Run::None) {
            Run::None => {}
            Run::Move(m) => out.push(m),
            Run::Delta(dx, dy) => out.extend(mouse_deltas(dx, dy)),
        }
    }
    let mut out = Vec::new();
    let mut run = Run::None;
    for m in msgs {
        match (m, &mut run) {
            (m @ ClientMsg::MouseMove { .. }, Run::Move(last)) => *last = m,
            (m @ ClientMsg::MouseMove { .. }, _) => {
                flush(&mut run, &mut out);
                run = Run::Move(m);
            }
            (ClientMsg::MouseDelta { dx, dy }, Run::Delta(sx, sy)) => {
                *sx += dx as i64;
                *sy += dy as i64;
            }
            (ClientMsg::MouseDelta { dx, dy }, _) => {
                flush(&mut run, &mut out);
                run = Run::Delta(dx as i64, dy as i64);
            }
            (m, _) => {
                flush(&mut run, &mut out);
                out.push(m);
            }
        }
    }
    flush(&mut run, &mut out);
    out
}

/// LockState bits from the three toggle states.
pub fn lock_bits(caps: bool, num: bool, scroll: bool) -> u8 {
    use crate::protocol::{LOCK_CAPS, LOCK_NUM, LOCK_SCROLL};
    (if caps { LOCK_CAPS } else { 0 }) | (if num { LOCK_NUM } else { 0 }) | (if scroll { LOCK_SCROLL } else { 0 })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hid::{HID_LALT, HID_LCTRL, HID_LGUI, HID_LSHIFT};
    use crate::hotkeys::{KEY_H, KEY_SPACE};

    const FWD: KeyCtx = KeyCtx { forwarding: true, ctrl_as_cmd: true, locks_local: false };

    fn mv(x: f32) -> ClientMsg {
        ClientMsg::MouseMove { x, y: 1.0 - x }
    }
    fn d(dx: i16, dy: i16) -> ClientMsg {
        ClientMsg::MouseDelta { dx, dy }
    }
    fn delta_sum(m: &[ClientMsg]) -> (i64, i64) {
        m.iter().fold((0, 0), |(x, y), m| match m {
            ClientMsg::MouseDelta { dx, dy } => (x + *dx as i64, y + *dy as i64),
            _ => (x, y),
        })
    }

    #[test]
    fn coalesce_keeps_last_move_of_each_run_and_order() {
        let btn = |down| ClientMsg::MouseButton { button: 0, down };
        let key = ClientMsg::Key { hid_usage: 0x04, down: true };
        let wheel = ClientMsg::Scroll { flags: SCROLL_PRECISE, dx: 0.0, dy: 0.25 };
        let locks = ClientMsg::LockState { locks: 1 };
        let input = vec![
            mv(0.1),
            mv(0.2),
            mv(0.3),
            btn(true),
            mv(0.4),
            mv(0.5),
            btn(false),
            key.clone(),
            mv(0.6),
            wheel.clone(),
            wheel.clone(),
            mv(0.7),
            locks.clone(),
            ClientMsg::ReleaseAll,
            mv(0.8),
            mv(0.9),
        ];
        let want = vec![
            mv(0.3),
            btn(true),
            mv(0.5),
            btn(false),
            key,
            mv(0.6),
            wheel.clone(),
            wheel, // wheel and other messages are never merged
            mv(0.7),
            locks,
            ClientMsg::ReleaseAll,
            mv(0.9),
        ];
        assert_eq!(coalesce(input), want);
        assert_eq!(coalesce(Vec::new()), Vec::<ClientMsg>::new());
        assert_eq!(coalesce(vec![ClientMsg::ReleaseAll]), vec![ClientMsg::ReleaseAll]);
    }

    #[test]
    fn coalesce_sums_delta_runs_exactly() {
        let btn = |down| ClientMsg::MouseButton { button: 1, down };
        // A 8 kHz mouse for a while: 4000 reports, mixed signs.
        let run1: Vec<ClientMsg> = (0..4000).map(|i| d((i % 7) as i16 - 2, (i % 5) as i16 - 3)).collect();
        let run2 = vec![d(i16::MAX, i16::MIN), d(i16::MAX, i16::MIN), d(5, 0)];
        let mut input = run1.clone();
        input.push(btn(true));
        input.extend(run2.clone());
        input.push(btn(false));
        input.extend([d(3, -4), d(-3, 4)]); // sums to zero: nothing to send
        input.push(mv(0.5));
        input.push(d(1, 1));
        let out = coalesce(input);

        let b_down = out.iter().position(|m| *m == btn(true)).unwrap();
        let b_up = out.iter().position(|m| *m == btn(false)).unwrap();
        assert_eq!(delta_sum(&out[..b_down]), delta_sum(&run1));
        assert_eq!(b_down, 1, "4000 reports merge into one message: {:?}", &out[..b_down]);
        // Larger than i16: exact, split into several messages.
        assert_eq!(delta_sum(&out[b_down + 1..b_up]), (2 * i16::MAX as i64 + 5, 2 * i16::MIN as i64));
        assert_eq!(b_up - b_down - 1, 3);
        assert_eq!(&out[b_up + 1..], &[mv(0.5), d(1, 1)]);
    }

    #[test]
    fn coalesce_never_merges_across_moves_and_deltas() {
        // Absolute and relative motion don't commute: keep each run where it was.
        let out = coalesce(vec![mv(0.1), d(1, 0), d(2, 0), mv(0.2), mv(0.3), d(-4, 1)]);
        assert_eq!(out, vec![mv(0.1), d(3, 0), mv(0.3), d(-4, 1)]);
    }

    #[test]
    fn forwards_with_remap_and_tracks_physical_keys() {
        let mut r = KeyRouter::default();
        assert_eq!(r.on_key(HID_LCTRL, true, FWD), KeyOutcome::Send(HID_LGUI), "Ctrl -> Cmd");
        assert_eq!(r.on_key(0x06, true, FWD), KeyOutcome::Send(0x06));
        assert_eq!(r.on_key(0x06, false, FWD), KeyOutcome::Send(0x06));
        assert_eq!(r.on_key(HID_LCTRL, false, FWD), KeyOutcome::Send(HID_LGUI));
        assert!(r.down.is_empty());
        let plain = KeyCtx { ctrl_as_cmd: false, ..FWD };
        assert_eq!(r.on_key(HID_LCTRL, true, plain), KeyOutcome::Send(HID_LCTRL), "swap off");
        assert_eq!(r.on_key(HID_LGUI, true, plain), KeyOutcome::Send(HID_LGUI), "Win -> Cmd with the swap off");
    }

    #[test]
    fn local_when_not_forwarding() {
        let mut r = KeyRouter::default();
        let off = KeyCtx { forwarding: false, ..FWD };
        assert_eq!(r.on_key(0x04, true, off), KeyOutcome::Local);
        assert!(r.down.contains(&0x04), "still tracked for hotkeys");
    }

    #[test]
    fn hotkey_and_its_release_are_swallowed() {
        let mut r = KeyRouter::default();
        for m in [HID_LCTRL, HID_LALT, HID_LSHIFT] {
            assert!(matches!(r.on_key(m, true, FWD), KeyOutcome::Send(_)));
        }
        assert_eq!(r.on_key(KEY_H, true, FWD), KeyOutcome::Hotkey(Action::ToggleHud));
        assert_eq!(r.on_key(KEY_H, false, FWD), KeyOutcome::Swallow);
        assert_eq!(r.on_key(KEY_H, true, FWD), KeyOutcome::Hotkey(Action::ToggleHud), "modifiers still held");
    }

    #[test]
    fn menu_reset_prevents_phantom_hotkeys_and_stuck_space() {
        // Ctrl+Alt+Shift+Space opens the menu; the releases go to the menu, not to us.
        let mut r = KeyRouter::default();
        for m in [HID_LCTRL, HID_LALT, HID_LSHIFT] {
            r.on_key(m, true, FWD);
        }
        assert_eq!(r.on_key(KEY_SPACE, true, FWD), KeyOutcome::Hotkey(Action::OpenMenu));
        r.reset(); // what open_menu does now
        assert_eq!(r.on_key(KEY_H, true, FWD), KeyOutcome::Send(KEY_H), "plain H types h, not the HUD hotkey");
        assert_eq!(r.on_key(KEY_SPACE, true, FWD), KeyOutcome::Send(KEY_SPACE));
        assert_eq!(r.on_key(KEY_SPACE, false, FWD), KeyOutcome::Send(KEY_SPACE), "Space up reaches the Mac");
    }

    #[test]
    fn repeated_event_is_idempotent() {
        // Hook passes a lock key through to Windows, then WM_KEYDOWN delivers the same event again.
        let mut r = KeyRouter::default();
        let ctx = KeyCtx { locks_local: true, ..FWD };
        assert_eq!(r.on_key(HID_CAPSLOCK, true, ctx), KeyOutcome::Local);
        assert_eq!(r.on_key(HID_CAPSLOCK, true, ctx), KeyOutcome::Local);
        assert_eq!(r.on_key(HID_NUMLOCK, true, ctx), KeyOutcome::Local);
        assert_eq!(r.on_key(HID_CAPSLOCK, false, ctx), KeyOutcome::Local);
        assert_eq!(r.on_key(HID_CAPSLOCK, false, ctx), KeyOutcome::Local);
        assert!(!r.down.contains(&HID_CAPSLOCK));
        assert_eq!(r.on_key(HID_CAPSLOCK, true, FWD), KeyOutcome::Send(HID_CAPSLOCK), "old host: forwarded as before");
    }

    #[test]
    fn keypad_navigation_with_num_lock_off() {
        assert_eq!(keypad_nav(0x47, 0x24), Some(0x4A), "KP7 as Home");
        assert_eq!(keypad_nav(0x48, 0x26), Some(0x52), "KP8 as Up");
        assert_eq!(keypad_nav(0x53, 0x2E), Some(0x4C), "KP. as Delete");
        assert_eq!(keypad_nav(0x52, 0x2D), Some(0x49), "KP0 as Insert");
        assert_eq!(keypad_nav(0x4C, 0x0C), Some(0), "KP5 does nothing");
        assert_eq!(keypad_nav(0x47, 0x67), None, "Num Lock on: VK_NUMPAD7 keeps the keypad usage");
        assert_eq!(keypad_nav(0xE047, 0x24), None, "the real Home key (extended) is mapped by scancode");
        assert_eq!(keypad_nav(0x1E, 0x24), None);
    }

    #[test]
    fn media_keys() {
        assert_eq!(media_key(0xAF), Some(MediaKey::Volume));
        assert_eq!(media_key(0xAD), Some(MediaKey::Volume));
        assert_eq!(media_key(0xB3), Some(MediaKey::Transport(0xCD)));
        assert_eq!(media_key(0xB0), Some(MediaKey::Transport(0xB5)));
        assert_eq!(media_key(0xB1), Some(MediaKey::Transport(0xB6)));
        assert_eq!(media_key(0x41), None);
    }

    #[test]
    fn wheel_source_and_direction() {
        let mut w = WheelState::default();
        // Notched wheel: discrete, dy > 0 = up.
        assert_eq!(w.message(120, false, false, false, true, 0), ClientMsg::Scroll { flags: 0, dx: 0.0, dy: 1.0 });
        assert_eq!(w.message(-240, false, false, false, true, 10), ClientMsg::Scroll { flags: 0, dx: 0.0, dy: -2.0 });
        // Horizontal: positive = tilt right = dx > 0.
        assert_eq!(w.message(120, true, false, false, true, 20), ClientMsg::Scroll { flags: 0, dx: 1.0, dy: 0.0 });
        // Natural scrolling inverts.
        assert_eq!(w.message(120, false, false, true, true, 30), ClientMsg::Scroll { flags: 0, dx: 0.0, dy: -1.0 });
        // Sub-notch deltas (touchpad / hi-res wheel) are precise, and stay precise briefly.
        let t = 1_000_000;
        assert_eq!(w.message(8, false, false, false, true, t), ClientMsg::Scroll { flags: SCROLL_PRECISE, dx: 0.0, dy: 8.0 / 120.0 });
        assert_eq!(w.message(120, false, false, false, true, t + 100_000), ClientMsg::Scroll { flags: SCROLL_PRECISE, dx: 0.0, dy: 1.0 });
        assert_eq!(w.message(120, false, false, false, true, t + 400_000), ClientMsg::Scroll { flags: 0, dx: 0.0, dy: 1.0 });
        // Windows says touchpad: precise even for whole notches.
        assert_eq!(w.message(120, false, true, false, true, 5_000_000), ClientMsg::Scroll { flags: SCROLL_PRECISE, dx: 0.0, dy: 1.0 });
        // Old host: legacy MouseWheel with the same values.
        assert_eq!(w.message(-60, true, false, false, false, 9_000_000), ClientMsg::MouseWheel { dx: -0.5, dy: 0.0 });
    }

    #[test]
    fn relative_motion_chunks() {
        assert!(mouse_deltas(0, 0).is_empty());
        assert_eq!(mouse_deltas(5, -3), vec![ClientMsg::MouseDelta { dx: 5, dy: -3 }]);
        let big = mouse_deltas(70_000, -1);
        assert_eq!(big.len(), 3);
        let (sx, sy) = big.iter().fold((0i64, 0i64), |a, m| match m {
            ClientMsg::MouseDelta { dx, dy } => (a.0 + *dx as i64, a.1 + *dy as i64),
            _ => a,
        });
        assert_eq!((sx, sy), (70_000, -1), "nothing lost");
    }

    #[test]
    fn lock_state_bits() {
        assert_eq!(lock_bits(true, false, false), 1);
        assert_eq!(lock_bits(false, true, true), 6);
    }
}
