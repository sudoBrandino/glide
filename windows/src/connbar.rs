//! Connection bar (pull-down tab at the top-center of the viewer, like Microsoft Remote Desktop /
//! Jump): when it shows, where it is, when it hides. Pure state machine (unit-tested); the window
//! glue is in `win::app`, drawing in `win::render`.
//!
//! - Revealed when the pointer touches the top edge (`REVEAL_PX`, DPI-scaled) of the middle third
//!   of the window — not the whole width, so reaching for the Mac's menu bar near the corners
//!   doesn't keep popping it up.
//! - Stays while the pointer is over the tab (plus a small margin) or the menu is open; hides
//!   `HIDE_AFTER` after the pointer left. Pinned = always shown.
//! - While the pointer is over the visible tab, mouse input is not forwarded to the host.

use std::time::{Duration, Instant};

pub const REVEAL_PX: i32 = 4;
pub const HIDE_AFTER: Duration = Duration::from_millis(1500);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    pub fn contains(&self, px: i32, py: i32) -> bool {
        px >= self.x && px < self.x + self.w && py >= self.y && py < self.y + self.h
    }
    fn grow(&self, m: i32) -> Rect {
        Rect { x: self.x - m, y: self.y - m, w: self.w + 2 * m, h: self.h + 2 * m }
    }
}

/// The tab: centered at the top of a `client_w`-wide client area.
pub fn tab_rect(client_w: i32, tab_w: i32, tab_h: i32) -> Rect {
    Rect { x: (client_w - tab_w) / 2, y: 0, w: tab_w, h: tab_h }
}

/// Where touching the top edge reveals the bar (`scale` = DPI / 96).
pub fn reveal_zone(client_w: i32, scale: f32) -> Rect {
    let h = ((REVEAL_PX as f32 * scale).round() as i32).max(2);
    Rect { x: client_w / 3, y: 0, w: client_w - 2 * (client_w / 3), h }
}

#[derive(Debug, Clone, Default)]
pub struct ConnBar {
    pub pinned: bool,
    shown: bool,
    /// Menu open (or another reason to keep it up regardless of the pointer).
    held: bool,
    hide_at: Option<Instant>,
}

impl ConnBar {
    pub fn new(pinned: bool) -> ConnBar {
        ConnBar { pinned, ..Default::default() }
    }

    pub fn visible(&self) -> bool {
        self.pinned || self.shown || self.held
    }

    /// Pointer at client (x, y) (None = outside the window). `tab` = the tab's rect if it were
    /// visible. Returns true if visibility changed.
    pub fn pointer(&mut self, p: Option<(i32, i32)>, client_w: i32, tab: Rect, scale: f32, now: Instant) -> bool {
        let before = self.visible();
        let margin = ((6.0 * scale) as i32).max(2);
        let near_tab = p.is_some_and(|(x, y)| self.visible() && tab.grow(margin).contains(x, y));
        let in_zone = p.is_some_and(|(x, y)| reveal_zone(client_w, scale).contains(x, y));
        if near_tab || in_zone {
            self.shown = true;
            self.hide_at = None;
        } else if self.shown && self.hide_at.is_none() {
            self.hide_at = Some(now + HIDE_AFTER);
        }
        before != self.visible()
    }

    /// Whether the pointer is over the visible tab (input there goes to the bar, not the host).
    pub fn hit(&self, p: (i32, i32), tab: Rect) -> bool {
        self.visible() && tab.contains(p.0, p.1)
    }

    /// Periodic check (timer). Returns true if visibility changed.
    pub fn tick(&mut self, now: Instant) -> bool {
        let before = self.visible();
        if !self.held && self.hide_at.is_some_and(|t| now >= t) {
            self.shown = false;
            self.hide_at = None;
        }
        before != self.visible()
    }

    /// Show it now (keyboard-opened menu, test hook) and start the hide timer.
    pub fn reveal(&mut self, now: Instant) -> bool {
        let before = self.visible();
        self.shown = true;
        self.hide_at = Some(now + HIDE_AFTER);
        before != self.visible()
    }

    /// Keep it up while the menu is open; `release` restarts the hide timer.
    pub fn hold(&mut self) {
        self.held = true;
    }
    pub fn release(&mut self, now: Instant) {
        self.held = false;
        if self.shown {
            self.hide_at = Some(now + HIDE_AFTER);
        }
    }

    /// The timer only needs to run while something can still change.
    pub fn needs_timer(&self) -> bool {
        self.hide_at.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const W: i32 = 1500;
    fn tab() -> Rect {
        tab_rect(W, 200, 28)
    }

    #[test]
    fn geometry() {
        assert_eq!(tab(), Rect { x: 650, y: 0, w: 200, h: 28 });
        let z = reveal_zone(W, 1.0);
        assert_eq!(z, Rect { x: 500, y: 0, w: 500, h: 4 });
        assert_eq!(reveal_zone(W, 1.5).h, 6);
        assert!(z.contains(500, 0) && z.contains(999, 3) && !z.contains(1000, 0) && !z.contains(700, 4));
    }

    #[test]
    fn reveal_hover_hide() {
        let t0 = Instant::now();
        let mut b = ConnBar::new(false);
        assert!(!b.visible());
        // moving around the screen, or along the top edge near the corners: nothing
        assert!(!b.pointer(Some((700, 300)), W, tab(), 1.0, t0));
        assert!(!b.pointer(Some((100, 0)), W, tab(), 1.0, t0));
        assert!(!b.hit((700, 10), tab()), "hidden tab doesn't eat input");
        // touch the top edge in the middle: shown
        assert!(b.pointer(Some((720, 1)), W, tab(), 1.0, t0));
        assert!(b.visible() && b.hit((700, 10), tab()));
        // over the tab: stays
        assert!(!b.pointer(Some((700, 20)), W, tab(), 1.0, t0));
        assert!(!b.tick(t0 + Duration::from_secs(10)));
        // leave: hides 1.5 s later, not before
        let t1 = t0 + Duration::from_secs(11);
        b.pointer(Some((700, 400)), W, tab(), 1.0, t1);
        assert!(b.needs_timer());
        assert!(!b.tick(t1 + Duration::from_millis(1400)));
        assert!(b.tick(t1 + HIDE_AFTER));
        assert!(!b.visible() && !b.needs_timer());
        // coming back to the tab area while hidden doesn't reveal (only the edge does)
        assert!(!b.pointer(Some((700, 20)), W, tab(), 1.0, t1 + Duration::from_secs(3)));
    }

    #[test]
    fn returning_cancels_hide_and_menu_holds() {
        let t0 = Instant::now();
        let mut b = ConnBar::new(false);
        b.pointer(Some((720, 0)), W, tab(), 1.0, t0);
        b.pointer(Some((720, 300)), W, tab(), 1.0, t0);
        b.pointer(Some((720, 30)), W, tab(), 1.0, t0 + Duration::from_millis(500)); // within margin
        assert!(!b.tick(t0 + Duration::from_secs(5)), "back over the tab cancels the hide");
        b.hold();
        b.pointer(None, W, tab(), 1.0, t0 + Duration::from_secs(6));
        assert!(!b.tick(t0 + Duration::from_secs(60)), "held while the menu is open");
        b.release(t0 + Duration::from_secs(60));
        assert!(b.tick(t0 + Duration::from_secs(62)));
    }

    #[test]
    fn pinned_and_reveal() {
        let t0 = Instant::now();
        let mut b = ConnBar::new(true);
        assert!(b.visible());
        b.pointer(None, W, tab(), 1.0, t0);
        b.tick(t0 + Duration::from_secs(9));
        assert!(b.visible(), "pinned never hides");
        let mut b = ConnBar::new(false);
        assert!(b.reveal(t0));
        assert!(b.tick(t0 + HIDE_AFTER));
    }
}
