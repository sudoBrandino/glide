//! The viewer's context menu as data: commands, their ids, labels with hotkey hints, and the
//! checked/enabled state for a given `MenuState`. `win::menu` turns this into a Win32 popup (and
//! the window's system menu); keeping it pure makes the contents unit-testable on any OS.

use crate::protocol::{Mode, DISPLAY_PREF_AUTOMATIC, DISPLAY_PREF_CRISP, DISPLAY_PREF_MANUAL, DISPLAY_PREF_RETINA, DISPLAY_PREF_SMOOTH};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Cmd {
    ModeFast,
    ModeHybrid,
    ModeSharp,
    DisplayAutomatic,
    DisplayCrisp,
    DisplayRetina,
    DisplaySmooth,
    DisplayManual,
    SendSpotlight,
    SendMissionControl,
    SendAppSwitcher,
    SendForceQuit,
    SendLockScreen,
    SendScreenshot,
    ToggleMute,
    ToggleClipboard,
    ToggleHud,
    ToggleFullscreen,
    ToggleKeyboard,
    PinBar,
    RefreshPicture,
    Reconnect,
    Disconnect,
    Connect,
    Settings,
    /// File transfer (PROTOCOL.md §6): pick files (multi-select) → Mac.
    SendFiles,
    /// System menu only: open the full Glide menu at the cursor.
    OpenMenu,
    /// Pick folders → Mac.
    SendFolder,
    /// FilePull: the files copied in Finder (= Ctrl+Alt+Shift+V).
    ReceiveFiles,
    CancelFiles,
    OpenReceived,
    /// Latency test mode (docs/LATENCY.md).
    LatencyTest,
    /// Stream the host's default Mac display (SelectDisplay 0, PROTOCOL.md §3.5).
    ShowDefaultDisplay,
    /// Stream the Mac display at this index of the host's DisplayList (ids are dynamic; see `id`).
    ShowDisplay(u8),
    /// Input submenu: Ctrl → Command / Win → Control on or off.
    ToggleCtrlAsCmd,
    /// Input submenu: invert scrolling.
    ToggleNaturalScroll,
    /// Input submenu: relative mouse (pointer lock, PROTOCOL.md §3.6).
    ToggleRelativeMouse,
}

// New commands go at the end: ids are positions in this list.
const ALL: [Cmd; 36] = [
    Cmd::ModeFast,
    Cmd::ModeHybrid,
    Cmd::ModeSharp,
    Cmd::DisplayAutomatic,
    Cmd::DisplayCrisp,
    Cmd::DisplayRetina,
    Cmd::DisplaySmooth,
    Cmd::DisplayManual,
    Cmd::SendSpotlight,
    Cmd::SendMissionControl,
    Cmd::SendAppSwitcher,
    Cmd::SendForceQuit,
    Cmd::SendLockScreen,
    Cmd::SendScreenshot,
    Cmd::ToggleMute,
    Cmd::ToggleClipboard,
    Cmd::ToggleHud,
    Cmd::ToggleFullscreen,
    Cmd::ToggleKeyboard,
    Cmd::PinBar,
    Cmd::RefreshPicture,
    Cmd::Reconnect,
    Cmd::Disconnect,
    Cmd::Connect,
    Cmd::Settings,
    Cmd::SendFiles,
    Cmd::OpenMenu,
    Cmd::SendFolder,
    Cmd::ReceiveFiles,
    Cmd::CancelFiles,
    Cmd::OpenReceived,
    Cmd::LatencyTest,
    Cmd::ShowDefaultDisplay,
    Cmd::ToggleCtrlAsCmd,
    Cmd::ToggleNaturalScroll,
    Cmd::ToggleRelativeMouse,
];

/// Menu ids: 0x2000 + 16·index. Low nibble zero and below 0xF000, so the same ids work as
/// WM_SYSCOMMAND values in the window's system menu.
const ID_BASE: u32 = 0x2000;
/// `ShowDisplay(i)`: 0xE000 + 16·i (≤ 0xEFF0, still below the system's SC_* range).
const DISPLAY_ID_BASE: u32 = 0xE000;

impl Cmd {
    pub fn id(self) -> u32 {
        if let Cmd::ShowDisplay(i) = self {
            return DISPLAY_ID_BASE + 16 * i as u32;
        }
        ID_BASE + 16 * ALL.iter().position(|c| *c == self).unwrap() as u32
    }
    pub fn from_id(id: u32) -> Option<Cmd> {
        if (DISPLAY_ID_BASE..0xF000).contains(&id) {
            return id.is_multiple_of(16).then(|| Cmd::ShowDisplay(((id - DISPLAY_ID_BASE) / 16) as u8));
        }
        let off = id.checked_sub(ID_BASE)?;
        if off % 16 != 0 {
            return None;
        }
        ALL.get((off / 16) as usize).copied()
    }
    /// Name for the `GLIDE_TEST_ACTIONS=menu:<name>` test hook.
    pub fn name(self) -> String {
        format!("{self:?}").to_ascii_lowercase()
    }
    pub fn from_name(s: &str) -> Option<Cmd> {
        let s = s.trim().to_ascii_lowercase();
        if let Some(i) = s.strip_prefix("showdisplay(").and_then(|r| r.strip_suffix(')')).and_then(|n| n.parse().ok()) {
            return Some(Cmd::ShowDisplay(i));
        }
        ALL.iter().copied().find(|c| c.name() == s)
    }
    pub fn mode(self) -> Option<Mode> {
        match self {
            Cmd::ModeFast => Some(Mode::Fast),
            Cmd::ModeHybrid => Some(Mode::Hybrid),
            Cmd::ModeSharp => Some(Mode::Sharp),
            _ => None,
        }
    }
    /// SetDisplayPreference value.
    pub fn display_pref(self) -> Option<u8> {
        match self {
            Cmd::DisplayAutomatic => Some(DISPLAY_PREF_AUTOMATIC),
            Cmd::DisplayCrisp => Some(DISPLAY_PREF_CRISP),
            Cmd::DisplayRetina => Some(DISPLAY_PREF_RETINA),
            Cmd::DisplaySmooth => Some(DISPLAY_PREF_SMOOTH),
            Cmd::DisplayManual => Some(DISPLAY_PREF_MANUAL),
            _ => None,
        }
    }
}

// HID usages (keyboard page) for the Mac shortcuts. On the Mac side GUI = Command.
const CTRL: u16 = 0xE0;
const SHIFT: u16 = 0xE1;
const OPT: u16 = 0xE2;
const CMD: u16 = 0xE3;

/// The key sequence for a "Send to Mac" command: modifiers down, key down, key up, modifiers up
/// (reverse order). Usages are Mac-side (sent as-is, no Ctrl→Cmd remap).
pub fn mac_shortcut(c: Cmd) -> Option<Vec<(u16, bool)>> {
    let keys: &[u16] = match c {
        Cmd::SendSpotlight => &[CMD, 0x2C],            // Cmd+Space
        Cmd::SendMissionControl => &[CTRL, 0x52],      // Ctrl+Up
        Cmd::SendAppSwitcher => &[CMD, 0x2B],          // Cmd+Tab
        Cmd::SendForceQuit => &[CMD, OPT, 0x29],       // Cmd+Opt+Esc
        Cmd::SendLockScreen => &[CTRL, CMD, 0x14],     // Ctrl+Cmd+Q
        Cmd::SendScreenshot => &[CMD, SHIFT, 0x22],    // Cmd+Shift+5
        _ => return None,
    };
    let mut v: Vec<(u16, bool)> = keys.iter().map(|&k| (k, true)).collect();
    v.extend(keys.iter().rev().map(|&k| (k, false)));
    Some(v)
}

/// Mac display info from the host (DisplayInfo, PROTOCOL.md §3.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct DisplayInfo {
    pub preference: u8,
    pub mode_w: u16,
    pub mode_h: u16,
    pub hidpi: bool,
}

impl DisplayInfo {
    pub fn describe(&self) -> String {
        if self.mode_w == 0 {
            return "unknown".into();
        }
        format!("{}×{}{}", self.mode_w, self.mode_h, if self.hidpi { " Retina" } else { "" })
    }
}

pub fn display_pref_name(p: u8) -> &'static str {
    match p {
        DISPLAY_PREF_AUTOMATIC => "automatic",
        DISPLAY_PREF_CRISP => "crisp",
        DISPLAY_PREF_SMOOTH => "smooth",
        DISPLAY_PREF_RETINA => "retina",
        DISPLAY_PREF_MANUAL => "don't change",
        _ => "?",
    }
}

/// Everything the menu needs to know.
#[derive(Debug, Clone, Default)]
pub struct MenuState {
    pub host_name: String,
    pub connected: bool,
    /// Tray "Disconnect" / menu Disconnect: not connecting until Connect.
    pub paused: bool,
    pub mode: Option<Mode>,
    pub has444: bool,
    /// None = the host never sent DisplayInfo (old host): submenu disabled.
    pub display: Option<DisplayInfo>,
    /// None = audio disabled (--no-audio); Some(muted).
    pub audio_muted: Option<bool>,
    pub clipboard_on: bool,
    pub hud: bool,
    pub fullscreen: bool,
    pub keyboard_released: bool,
    pub bar_pinned: bool,
    /// File transfer is on in this viewer (config `file_transfer`).
    pub files_on: bool,
    /// The connected host accepts files (FileCaps bit 0).
    pub file_transfer: bool,
    /// The connected host can send files (FileCaps bit 1: "Receive files copied on the Mac").
    pub file_pull: bool,
    /// A file transfer is running (or queued).
    pub files_busy: bool,
    /// Latency test mode is on (Ctrl+Alt+Shift+L).
    pub latency_test: bool,
    /// The Mac's displays (DisplayList, §3.5); None = this host doesn't support choosing.
    pub displays: Option<crate::displays::DisplayState>,
    /// Ctrl → Command, Win → Control.
    pub ctrl_as_cmd: bool,
    pub natural_scrolling: bool,
    /// None = the connected host doesn't take relative motion (or not connected); Some(on).
    pub relative_mouse: Option<bool>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Item {
    Cmd { cmd: Cmd, label: String, checked: bool, radio: bool, enabled: bool },
    /// Disabled informational line.
    Info(String),
    Sub { label: String, enabled: bool, items: Vec<Item> },
    Separator,
}

fn cmd(cmd: Cmd, label: &str, checked: bool, enabled: bool) -> Item {
    Item::Cmd { cmd, label: label.to_string(), checked, radio: false, enabled }
}

fn radio(cmd: Cmd, label: &str, checked: bool, enabled: bool) -> Item {
    Item::Cmd { cmd, label: label.to_string(), checked, radio: true, enabled }
}

fn stream_mode_items(s: &MenuState) -> Vec<Item> {
    vec![
        radio(Cmd::ModeFast, "&Fast (4:2:0)", s.mode == Some(Mode::Fast), true),
        radio(Cmd::ModeHybrid, "&Hybrid (4:2:0 + 4:4:4 at rest)", s.mode == Some(Mode::Hybrid), s.has444),
        radio(Cmd::ModeSharp, "&Sharp (4:4:4)", s.mode == Some(Mode::Sharp), s.has444),
        Item::Separator,
        Item::Info("Cycle: Ctrl+Alt+Shift+M".into()),
    ]
}

/// "Show Mac display" submenu: automatic + one radio item per Mac display (§3.5).
fn display_picker_items(s: &MenuState) -> Vec<Item> {
    let Some(st) = s.displays.as_ref().filter(|_| s.connected) else {
        return vec![Item::Info(if s.connected { "Not supported by this host".into() } else { "Not connected".into() })];
    };
    let mut v = vec![Item::Info(format!("Showing: {}", st.name(st.streamed))), Item::Separator];
    v.push(radio(Cmd::ShowDefaultDisplay, "&Automatic (the Mac's main display)", st.selected == 0, true));
    for (i, d) in st.displays.iter().enumerate().take(255) {
        let accel = if i < 9 { format!("&{}  ", i + 1) } else { String::new() };
        v.push(radio(Cmd::ShowDisplay(i as u8), &format!("{accel}{}", crate::displays::label(d)), st.selected != 0 && st.streamed == d.id, true));
    }
    v.push(Item::Separator);
    v.push(Item::Info("Next / previous: Ctrl+Alt+Shift+→ / ←".into()));
    v
}

fn input_items(s: &MenuState) -> Vec<Item> {
    vec![
        cmd(Cmd::ToggleCtrlAsCmd, "&Ctrl as Command (Win as Control)", s.ctrl_as_cmd, true),
        cmd(Cmd::ToggleNaturalScroll, "&Natural scrolling (reverse direction)", s.natural_scrolling, true),
        cmd(Cmd::ToggleRelativeMouse, "&Relative mouse (games, 3D)\tCtrl+Alt+Shift+G", s.relative_mouse == Some(true), s.relative_mouse.is_some()),
    ]
}

/// The full context menu (connection bar / Ctrl+Alt+Shift+Space).
pub fn build(s: &MenuState) -> Vec<Item> {
    let live = s.connected;
    let d = s.display;
    let dp = d.map(|d| d.preference);
    let mut display = vec![Item::Info(match d {
        Some(d) => format!("Now: {}", d.describe()),
        None => "Not supported by this host".into(),
    })];
    display.push(Item::Separator);
    for (c, label) in [
        (Cmd::DisplayAutomatic, "&Automatic"),
        (Cmd::DisplayCrisp, "&Crisp (1:1 pixels)"),
        (Cmd::DisplayRetina, "&Retina (HiDPI, 1:1 backing)"),
        (Cmd::DisplaySmooth, "&Smooth (HiDPI, more space)"),
        (Cmd::DisplayManual, "&Don't change"),
    ] {
        display.push(radio(c, label, dp.is_some() && dp == c.display_pref(), live && d.is_some()));
    }
    let send = vec![
        cmd(Cmd::SendSpotlight, "&Spotlight\tCmd+Space", false, live),
        cmd(Cmd::SendMissionControl, "&Mission Control\tCtrl+Up", false, live),
        cmd(Cmd::SendAppSwitcher, "&App switcher\tCmd+Tab", false, live),
        cmd(Cmd::SendForceQuit, "&Force Quit…\tCmd+Opt+Esc", false, live),
        cmd(Cmd::SendLockScreen, "&Lock screen\tCtrl+Cmd+Q", false, live),
        cmd(Cmd::SendScreenshot, "Screens&hot…\tCmd+Shift+5", false, live),
    ];
    let mut v = vec![
        Item::Info(if live { format!("Connected to {}", s.host_name) } else if s.paused { "Disconnected".into() } else { "Not connected".into() }),
        Item::Separator,
        Item::Sub { label: "Stream &mode".into(), enabled: true, items: stream_mode_items(s) },
        Item::Sub { label: "Mac &display".into(), enabled: true, items: display },
        Item::Sub { label: "Show Mac displa&y".into(), enabled: true, items: display_picker_items(s) },
        Item::Sub { label: "Send to &Mac".into(), enabled: live, items: send },
        Item::Separator,
        cmd(Cmd::ToggleMute, "M&ute audio\tCtrl+Alt+Shift+A", s.audio_muted == Some(true), s.audio_muted.is_some()),
        cmd(Cmd::ToggleClipboard, "&Clipboard sync", s.clipboard_on, true),
        cmd(Cmd::ToggleHud, "S&tats overlay\tCtrl+Alt+Shift+H", s.hud, true),
        cmd(Cmd::LatencyTest, "&Latency test\tCtrl+Alt+Shift+L", s.latency_test, true),
        cmd(Cmd::ToggleFullscreen, "F&ullscreen\tCtrl+Alt+Shift+F", s.fullscreen, true),
        cmd(Cmd::ToggleKeyboard, "Release &keyboard\tCtrl+Alt+Shift+K", s.keyboard_released, true),
        Item::Sub { label: "&Input".into(), enabled: true, items: input_items(s) },
        cmd(Cmd::PinBar, "&Pin connection bar", s.bar_pinned, true),
        Item::Separator,
        cmd(Cmd::RefreshPicture, "Re&fresh picture\tCtrl+Alt+Shift+R", false, live),
        cmd(Cmd::Reconnect, "&Reconnect\tCtrl+Alt+Shift+D", false, !s.paused),
    ];
    if s.paused {
        v.push(cmd(Cmd::Connect, "C&onnect", false, true));
    } else {
        v.push(cmd(Cmd::Disconnect, "D&isconnect", false, true));
    }
    v.push(Item::Separator);
    if s.files_on {
        let send = live && s.file_transfer;
        v.extend([
            cmd(Cmd::SendFiles, "Send &files to the Mac…", false, send),
            cmd(Cmd::SendFolder, "Send f&older to the Mac…", false, send),
            cmd(Cmd::ReceiveFiles, "Recei&ve files copied on the Mac\tCtrl+Alt+Shift+V", false, live && s.file_pull),
            cmd(Cmd::CancelFiles, "Cancel file trans&fer\tCtrl+Alt+Shift+X", false, s.files_busy),
            cmd(Cmd::OpenReceived, "Open recei&ved files folder", false, true),
            Item::Separator,
        ]);
    }
    v.push(cmd(Cmd::Settings, "S&ettings…", false, true));
    v
}

/// The items appended to the window's system menu (title-bar right-click / Alt+Space).
pub fn system_items(s: &MenuState) -> Vec<Item> {
    vec![
        Item::Separator,
        cmd(Cmd::OpenMenu, "&Glide menu…\tCtrl+Alt+Shift+Space", false, true),
        Item::Sub { label: "Stream &mode".into(), enabled: true, items: stream_mode_items(s) },
        cmd(Cmd::ToggleMute, "M&ute audio\tCtrl+Alt+Shift+A", s.audio_muted == Some(true), s.audio_muted.is_some()),
        cmd(Cmd::ToggleHud, "S&tats overlay\tCtrl+Alt+Shift+H", s.hud, true),
        cmd(Cmd::ToggleFullscreen, "F&ullscreen\tCtrl+Alt+Shift+F", s.fullscreen, true),
        cmd(Cmd::RefreshPicture, "Re&fresh picture\tCtrl+Alt+Shift+R", false, s.connected),
        cmd(Cmd::Reconnect, "&Reconnect\tCtrl+Alt+Shift+D", false, !s.paused),
        cmd(Cmd::Settings, "S&ettings…", false, true),
    ]
}

/// Plain-text rendering (test hook `GLIDE_DUMP_MENU=1`, and unit tests).
pub fn to_text(items: &[Item]) -> String {
    fn go(items: &[Item], depth: usize, out: &mut String) {
        for it in items {
            let pad = "  ".repeat(depth);
            match it {
                Item::Cmd { label, checked, radio, enabled, .. } => {
                    let mark = match (checked, radio) {
                        (true, true) => "(•) ",
                        (true, false) => "[x] ",
                        (false, true) => "( ) ",
                        (false, false) => "",
                    };
                    let dis = if *enabled { "" } else { "  (disabled)" };
                    out.push_str(&format!("{pad}{mark}{}{dis}\n", label.replace('&', "").replace('\t', "    ")));
                }
                Item::Info(t) => out.push_str(&format!("{pad}— {t}\n")),
                Item::Sub { label, enabled, items } => {
                    out.push_str(&format!("{pad}{} ▸{}\n", label.replace('&', ""), if *enabled { "" } else { "  (disabled)" }));
                    go(items, depth + 1, out);
                }
                Item::Separator => out.push_str(&format!("{pad}----\n")),
            }
        }
    }
    let mut s = String::new();
    go(items, 0, &mut s);
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn find(items: &[Item], c: Cmd) -> Option<&Item> {
        for it in items {
            match it {
                Item::Cmd { cmd, .. } if *cmd == c => return Some(it),
                Item::Sub { items, .. } => {
                    if let Some(x) = find(items, c) {
                        return Some(x);
                    }
                }
                _ => {}
            }
        }
        None
    }

    fn state(items: &[Item], c: Cmd) -> (bool, bool) {
        match find(items, c) {
            Some(Item::Cmd { checked, enabled, .. }) => (*checked, *enabled),
            _ => panic!("{c:?} missing"),
        }
    }

    #[test]
    fn ids_roundtrip_and_fit_syscommand() {
        for c in ALL {
            let id = c.id();
            assert_eq!(id & 0xF, 0, "{c:?}: WM_SYSCOMMAND needs the low 4 bits clear");
            assert!(id < 0xF000);
            assert_eq!(Cmd::from_id(id), Some(c));
            assert_eq!(Cmd::from_name(&c.name()), Some(c));
        }
        assert_eq!(Cmd::from_id(ID_BASE + 1), None);
        assert_eq!(Cmd::from_id(0xF100), None);
        assert_eq!(Cmd::from_id(0), None);
    }

    #[test]
    fn connected_menu_state() {
        let s = MenuState {
            host_name: "mac".into(),
            connected: true,
            mode: Some(Mode::Hybrid),
            has444: true,
            display: Some(DisplayInfo { preference: DISPLAY_PREF_RETINA, mode_w: 1920, mode_h: 1080, hidpi: true }),
            audio_muted: Some(false),
            clipboard_on: true,
            hud: true,
            ..Default::default()
        };
        let m = build(&s);
        assert_eq!(state(&m, Cmd::ModeHybrid), (true, true));
        assert_eq!(state(&m, Cmd::ModeFast), (false, true));
        assert_eq!(state(&m, Cmd::DisplayRetina), (true, true));
        assert_eq!(state(&m, Cmd::DisplayAutomatic), (false, true));
        assert_eq!(state(&m, Cmd::ToggleMute), (false, true));
        assert_eq!(state(&m, Cmd::ToggleClipboard), (true, true));
        assert_eq!(state(&m, Cmd::ToggleHud), (true, true));
        assert_eq!(state(&m, Cmd::LatencyTest), (false, true));
        assert!(to_text(&m).contains("Latency test    Ctrl+Alt+Shift+L"));
        assert_eq!(state(&build(&MenuState { latency_test: true, ..s.clone() }), Cmd::LatencyTest), (true, true));
        assert_eq!(state(&m, Cmd::SendSpotlight), (false, true));
        assert!(find(&m, Cmd::SendFiles).is_none(), "file transfer off in this viewer → no file items");
        assert!(find(&m, Cmd::Disconnect).is_some() && find(&m, Cmd::Connect).is_none());
        let text = to_text(&m);
        assert!(text.contains("— Now: 1920×1080 Retina"), "{text}");
        assert!(text.contains("(•) Retina (HiDPI, 1:1 backing)"), "{text}");
        assert!(text.contains("Mute audio    Ctrl+Alt+Shift+A"), "{text}");
    }

    #[test]
    fn display_picker() {
        use crate::displays::DisplayState;
        use crate::protocol::MacDisplay;
        let d = |id: u32, name: &str, flags: u8| MacDisplay {
            id,
            flags,
            width: 1920,
            height: 1080,
            pixel_width: 1920,
            pixel_height: 1080,
            refresh: 6000,
            name: name.into(),
            ..Default::default()
        };
        let mut st = DisplayState::default();
        st.apply_list(7, 0, vec![d(7, "Built-in", 1 | 2 | 8), d(9, "DELL", 0)]);
        let base = MenuState { connected: true, displays: Some(st.clone()), ..Default::default() };
        let m = build(&base);
        assert_eq!(state(&m, Cmd::ShowDefaultDisplay), (true, true), "no selection → automatic checked");
        assert_eq!(state(&m, Cmd::ShowDisplay(0)), (false, true));
        assert_eq!(state(&m, Cmd::ShowDisplay(1)), (false, true));
        let text = to_text(&m);
        assert!(text.contains("— Showing: Built-in"), "{text}");
        assert!(text.contains("( ) 2  DELL — 1920×1080 @ 60 Hz"), "{text}");
        assert!(text.contains("Ctrl+Alt+Shift+→ / ←"), "{text}");
        st.apply_list(9, 9, st.displays.clone());
        let m = build(&MenuState { displays: Some(st), ..base.clone() });
        assert_eq!(state(&m, Cmd::ShowDisplay(1)), (true, true));
        assert_eq!(state(&m, Cmd::ShowDefaultDisplay), (false, true));
        // old host / disconnected: an explanation instead of items
        let m = build(&MenuState { displays: None, ..base.clone() });
        assert!(find(&m, Cmd::ShowDefaultDisplay).is_none());
        assert!(to_text(&m).contains("Not supported by this host"));
        assert!(to_text(&build(&MenuState { connected: false, ..base })).contains("— Not connected"));
        // dynamic ids
        for i in [0u8, 1, 8, 255] {
            let id = Cmd::ShowDisplay(i).id();
            assert!(id & 0xF == 0 && id < 0xF000);
            assert_eq!(Cmd::from_id(id), Some(Cmd::ShowDisplay(i)));
            assert_eq!(Cmd::from_name(&Cmd::ShowDisplay(i).name()), Some(Cmd::ShowDisplay(i)));
        }
        assert_eq!(Cmd::from_id(0xE001), None);
    }

    #[test]
    fn input_items() {
        let s = MenuState { connected: true, ctrl_as_cmd: true, ..Default::default() };
        let m = build(&s);
        assert_eq!(state(&m, Cmd::ToggleCtrlAsCmd), (true, true));
        assert_eq!(state(&m, Cmd::ToggleNaturalScroll), (false, true));
        assert_eq!(state(&m, Cmd::ToggleRelativeMouse), (false, false), "host without relative motion");
        let m = build(&MenuState { relative_mouse: Some(true), natural_scrolling: true, ..s });
        assert_eq!(state(&m, Cmd::ToggleRelativeMouse), (true, true));
        assert_eq!(state(&m, Cmd::ToggleNaturalScroll), (true, true));
        assert!(to_text(&m).contains("Relative mouse (games, 3D)    Ctrl+Alt+Shift+G"));
    }

    #[test]
    fn file_items() {
        let base = MenuState { connected: true, files_on: true, ..Default::default() };
        // Host without file transfer: send/receive disabled, the folder is always reachable.
        let m = build(&base);
        assert_eq!(state(&m, Cmd::SendFiles), (false, false));
        assert_eq!(state(&m, Cmd::SendFolder), (false, false));
        assert_eq!(state(&m, Cmd::ReceiveFiles), (false, false));
        assert_eq!(state(&m, Cmd::CancelFiles), (false, false));
        assert_eq!(state(&m, Cmd::OpenReceived), (false, true));
        let m = build(&MenuState { file_transfer: true, file_pull: true, ..base.clone() });
        assert_eq!(state(&m, Cmd::SendFiles), (false, true));
        assert_eq!(state(&m, Cmd::SendFolder), (false, true));
        assert_eq!(state(&m, Cmd::ReceiveFiles), (false, true));
        assert_eq!(state(&m, Cmd::CancelFiles), (false, false), "cancel only while a transfer runs");
        let m = build(&MenuState { file_transfer: true, files_busy: true, ..base.clone() });
        assert_eq!(state(&m, Cmd::CancelFiles), (false, true));
        assert_eq!(state(&m, Cmd::ReceiveFiles), (false, false), "host can't send");
        // Disconnected: nothing to send to.
        let m = build(&MenuState { connected: false, file_transfer: true, file_pull: true, ..base });
        assert_eq!(state(&m, Cmd::SendFiles), (false, false));
        assert!(to_text(&m).contains("Receive files copied on the Mac    Ctrl+Alt+Shift+V"));
    }

    #[test]
    fn disconnected_old_host_no_444_no_audio() {
        let s = MenuState { paused: true, mode: Some(Mode::Fast), has444: false, audio_muted: None, ..Default::default() };
        let m = build(&s);
        assert_eq!(state(&m, Cmd::ModeHybrid), (false, false));
        assert_eq!(state(&m, Cmd::ModeSharp), (false, false));
        assert_eq!(state(&m, Cmd::DisplayAutomatic), (false, false), "no DisplayInfo → disabled");
        assert_eq!(state(&m, Cmd::ToggleMute), (false, false));
        assert_eq!(state(&m, Cmd::RefreshPicture), (false, false));
        assert_eq!(state(&m, Cmd::Reconnect), (false, false));
        assert!(find(&m, Cmd::Connect).is_some() && find(&m, Cmd::Disconnect).is_none());
        assert!(to_text(&m).contains("Not supported by this host"));
        let sys = system_items(&s);
        assert!(matches!(sys[0], Item::Separator));
        assert!(find(&sys, Cmd::OpenMenu).is_some() && find(&sys, Cmd::ModeFast).is_some());
    }

    #[test]
    fn mac_shortcuts() {
        assert_eq!(
            mac_shortcut(Cmd::SendSpotlight).unwrap(),
            vec![(0xE3, true), (0x2C, true), (0x2C, false), (0xE3, false)]
        );
        assert_eq!(
            mac_shortcut(Cmd::SendForceQuit).unwrap(),
            vec![(0xE3, true), (0xE2, true), (0x29, true), (0x29, false), (0xE2, false), (0xE3, false)]
        );
        assert_eq!(mac_shortcut(Cmd::SendLockScreen).unwrap()[..3], [(0xE0, true), (0xE3, true), (0x14, true)]);
        assert_eq!(mac_shortcut(Cmd::SendScreenshot).unwrap()[2], (0x22, true));
        assert_eq!(mac_shortcut(Cmd::SendMissionControl).unwrap()[1], (0x52, true));
        assert_eq!(mac_shortcut(Cmd::SendAppSwitcher).unwrap()[1], (0x2B, true));
        assert_eq!(mac_shortcut(Cmd::Settings), None);
        // every shortcut releases what it pressed
        for c in ALL {
            if let Some(seq) = mac_shortcut(c) {
                let downs: Vec<u16> = seq.iter().filter(|k| k.1).map(|k| k.0).collect();
                let mut ups: Vec<u16> = seq.iter().filter(|k| !k.1).map(|k| k.0).collect();
                ups.reverse();
                assert_eq!(downs, ups, "{c:?}");
            }
        }
    }

    #[test]
    fn display_prefs() {
        assert_eq!(Cmd::DisplayRetina.display_pref(), Some(3));
        assert_eq!(Cmd::DisplayManual.display_pref(), Some(4));
        assert_eq!(display_pref_name(2), "smooth");
        assert_eq!(DisplayInfo::default().describe(), "unknown");
        assert_eq!(DisplayInfo { preference: 1, mode_w: 2560, mode_h: 1440, hidpi: false }.describe(), "2560×1440");
    }
}
