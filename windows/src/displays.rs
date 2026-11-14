//! Mac display picker (docs/PROTOCOL.md §3.5), platform-independent: the host's display list,
//! identity matching to remember a display across reconnects, next/previous cycling, and the
//! labels and toasts the UI shows. `win::app` wires it to the menu, hotkeys and HUD.

use crate::protocol::{
    MacDisplay, DISPLAY_FLAG_BUILTIN, DISPLAY_FLAG_HIDPI, DISPLAY_FLAG_MAIN, DISPLAY_REASON_DEFAULT, DISPLAY_REASON_FALLBACK,
    DISPLAY_REASON_HOST, DISPLAY_REASON_RESTORED, DISPLAY_REASON_SELECTED, DISPLAY_REASON_UNAVAILABLE,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// A display's stable identity, remembered in the config per host (`last_display`). `id` is the
/// volatile id it had; vendor/model/serial are the EDID numbers (0 = unknown).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Default)]
#[serde(default)]
pub struct DisplayIdentity {
    pub id: u32,
    pub vendor: u32,
    pub model: u32,
    pub serial: u32,
    pub name: String,
}

impl DisplayIdentity {
    pub fn of(d: &MacDisplay) -> DisplayIdentity {
        DisplayIdentity { id: d.id, vendor: d.vendor, model: d.model, serial: d.serial, name: d.name.clone() }
    }

    fn same_hardware(&self, d: &MacDisplay) -> bool {
        d.vendor == self.vendor && d.model == self.model && d.serial == self.serial
    }

    /// The display in `list` this identity refers to (normative §3.5 rule, shared vectors): same
    /// id and hardware; else, with a serial, the same vendor/model/serial; else the same
    /// vendor/model without serial — by name too when vendor and model are unknown — preferring
    /// an equal name. "First" is list order.
    pub fn find(&self, list: &[MacDisplay]) -> Option<u32> {
        if let Some(d) = list.iter().find(|d| d.id == self.id && self.same_hardware(d)) {
            return Some(d.id);
        }
        if self.serial != 0 {
            return list.iter().find(|d| self.same_hardware(d)).map(|d| d.id);
        }
        let cands: Vec<&MacDisplay> = list
            .iter()
            .filter(|d| self.same_hardware(d) && (self.vendor != 0 || self.model != 0 || d.name == self.name))
            .collect();
        cands.iter().find(|d| d.name == self.name).or(cands.first()).map(|d| d.id)
    }
}

/// The host's displays for the current connection (from DisplayList).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct DisplayState {
    /// The display being captured.
    pub streamed: u32,
    /// The session's selection; 0 = following the host's default.
    pub selected: u32,
    /// List order (left to right).
    pub displays: Vec<MacDisplay>,
    /// Every id → name seen in this connection, so a display that just went away can still be
    /// named in the toast.
    pub names: HashMap<u32, String>,
}

impl DisplayState {
    pub fn apply_list(&mut self, streamed: u32, selected: u32, displays: Vec<MacDisplay>) {
        for d in &displays {
            self.names.insert(d.id, d.name.clone());
        }
        self.streamed = streamed;
        self.selected = selected;
        self.displays = displays;
    }

    pub fn by_id(&self, id: u32) -> Option<&MacDisplay> {
        self.displays.iter().find(|d| d.id == id)
    }

    /// `“DELL U2723QE”`-style name for toasts, also for displays no longer listed.
    pub fn name(&self, id: u32) -> String {
        self.by_id(id).map(|d| d.name.clone()).or_else(|| self.names.get(&id).cloned()).unwrap_or_else(|| format!("display {id}"))
    }

    /// The next (`step` > 0) or previous display relative to the streamed one, wrapping around.
    /// None with fewer than two displays.
    pub fn cycle(&self, step: i32) -> Option<u32> {
        let n = self.displays.len() as i32;
        if n < 2 {
            return None;
        }
        let i = match self.displays.iter().position(|d| d.id == self.streamed) {
            Some(i) => (i as i32 + step).rem_euclid(n),
            None if step > 0 => 0,
            None => n - 1,
        };
        Some(self.displays[i as usize].id)
    }

    /// 1-based position of `id` in the list ("2/3" in toasts).
    pub fn position(&self, id: u32) -> Option<(usize, usize)> {
        self.displays.iter().position(|d| d.id == id).map(|i| (i + 1, self.displays.len()))
    }
}

/// Menu label: `DELL U2723QE — 2560×1440 @ 59.94 Hz · main`.
pub fn label(d: &MacDisplay) -> String {
    let mut s = format!("{} — {}×{}", d.name, d.width, d.height);
    if d.flags & DISPLAY_FLAG_HIDPI != 0 {
        s.push_str(" HiDPI");
    }
    if d.refresh > 0 {
        let hz = d.refresh as f64 / 100.0;
        if d.refresh % 100 == 0 {
            s.push_str(&format!(" @ {hz:.0} Hz"));
        } else {
            s.push_str(&format!(" @ {hz:.2} Hz"));
        }
    }
    if d.flags & DISPLAY_FLAG_MAIN != 0 {
        s.push_str(" · main");
    } else if d.flags & DISPLAY_FLAG_BUILTIN != 0 {
        s.push_str(" · built-in");
    }
    s
}

/// What to send after a DisplayList: the remembered display, if it is listed and not already the
/// session's selection (only once per connection; the caller tracks that).
pub fn restore_choice(remembered: Option<&DisplayIdentity>, state: &DisplayState) -> Option<u32> {
    let id = remembered?.find(&state.displays)?;
    (state.selected != id).then_some(id)
}

/// How a DisplayChanged affects the remembered display: Some(Some(identity)) = remember it,
/// Some(None) = forget (back to automatic), None = leave it (only the viewer's own choices count).
pub fn remember_after(state: &DisplayState, display_id: u32, reason: u8, requested: u32) -> Option<Option<DisplayIdentity>> {
    if reason != DISPLAY_REASON_SELECTED {
        return None;
    }
    if requested == 0 {
        return Some(None);
    }
    state.by_id(display_id).map(|d| Some(DisplayIdentity::of(d)))
}

/// Toast for a DisplayChanged. `restoring` = the viewer re-selected its remembered display.
pub fn changed_toast(state: &DisplayState, display_id: u32, reason: u8, requested: u32, restoring: bool) -> String {
    let name = state.name(display_id);
    let pos = state.position(display_id).filter(|p| p.1 > 1).map(|(i, n)| format!(" ({i}/{n})")).unwrap_or_default();
    match reason {
        DISPLAY_REASON_SELECTED if restoring => format!("Showing “{name}” (remembered)"),
        DISPLAY_REASON_SELECTED if requested == 0 => format!("Mac display: automatic — “{name}”"),
        DISPLAY_REASON_SELECTED => format!("Mac display: “{name}”{pos}"),
        DISPLAY_REASON_UNAVAILABLE => format!("That Mac display isn't available — still showing “{name}”"),
        DISPLAY_REASON_FALLBACK => format!("“{}” went away — showing “{name}”", state.name(requested)),
        DISPLAY_REASON_RESTORED => format!("“{name}” is back"),
        DISPLAY_REASON_HOST => format!("Mac display: “{name}” (chosen on the Mac)"),
        DISPLAY_REASON_DEFAULT => format!("Mac display changed to “{name}”"),
        _ => format!("Mac display: “{name}”"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::*;

    fn vectors() -> serde_json::Value {
        serde_json::from_str(include_str!("../../docs/display-vectors.json")).unwrap()
    }

    fn entry(v: &serde_json::Value) -> MacDisplay {
        let u = |k: &str| v[k].as_u64().unwrap();
        let i = |k: &str| v[k].as_i64().unwrap() as i32;
        MacDisplay {
            id: u("id") as u32,
            flags: u("flags") as u8,
            x: i("x"),
            y: i("y"),
            width: u("width") as u16,
            height: u("height") as u16,
            pixel_width: u("pixel_width") as u16,
            pixel_height: u("pixel_height") as u16,
            refresh: u("refresh") as u16,
            vendor: u("vendor") as u32,
            model: u("model") as u32,
            serial: u("serial") as u32,
            name: v["name"].as_str().unwrap().to_string(),
        }
    }

    fn match_list() -> Vec<MacDisplay> {
        vectors()["match_list"].as_array().unwrap().iter().map(entry).collect()
    }

    fn by(list: &[MacDisplay], id: u32) -> MacDisplay {
        list.iter().find(|d| d.id == id).unwrap().clone()
    }

    #[test]
    fn identity_matching_vectors() {
        let v = vectors();
        let list = match_list();
        let cases = v["match"].as_array().unwrap();
        assert!(cases.len() >= 10);
        for c in cases {
            let w = &c["want"];
            let want = DisplayIdentity {
                id: w["id"].as_u64().unwrap() as u32,
                vendor: w["vendor"].as_u64().unwrap() as u32,
                model: w["model"].as_u64().unwrap() as u32,
                serial: w["serial"].as_u64().unwrap() as u32,
                name: w["name"].as_str().unwrap().into(),
            };
            let expect = c["expect"].as_u64().map(|x| x as u32);
            assert_eq!(want.find(&list), expect, "{}", c["what"]);
        }
    }

    #[test]
    fn messages_match_reference_bytes() {
        let v = vectors();
        let list = match_list();
        let unicode = MacDisplay {
            id: 11,
            flags: 9,
            x: -1,
            y: -2,
            width: 1,
            height: 2,
            pixel_width: 3,
            pixel_height: 4,
            refresh: 0,
            vendor: 1,
            model: 2,
            serial: 3,
            name: "Écran 日本".into(),
        };
        let host = |n: &str| -> Option<HostMsg> {
            Some(match n {
                "DisplayChanged" => HostMsg::DisplayChanged { display_id: 2, reason: DISPLAY_REASON_FALLBACK, requested: 5 },
                "DisplayChangedUnavailable" => {
                    HostMsg::DisplayChanged { display_id: 1, reason: DISPLAY_REASON_UNAVAILABLE, requested: 0xDEAD_BEEF }
                }
                "DisplayListBuiltin" => HostMsg::DisplayList { streamed: 1, selected: 0, displays: vec![by(&list, 1)] },
                "DisplayList" => HostMsg::DisplayList {
                    streamed: 5,
                    selected: 5,
                    displays: vec![by(&list, 1), by(&list, 9), by(&list, 5), by(&list, 6)],
                },
                "DisplayListEmpty" => HostMsg::DisplayList { streamed: 3, selected: 0, displays: vec![] },
                "DisplayListUnicode" => HostMsg::DisplayList { streamed: 11, selected: 11, displays: vec![unicode.clone()] },
                _ => return None,
            })
        };
        let client = |n: &str| match n {
            "SelectDisplay" => Some(ClientMsg::SelectDisplay { display_id: 2 }),
            "SelectDisplayAutomatic" => Some(ClientMsg::SelectDisplay { display_id: 0 }),
            _ => None,
        };
        let msgs = v["messages"].as_array().unwrap();
        for m in msgs {
            let name = m["name"].as_str().unwrap();
            let want = crate::util::unhex(m["hex"].as_str().unwrap());
            if let Some(h) = host(name) {
                assert_eq!(crate::util::hex(&h.encode()), crate::util::hex(&want), "{name}");
                assert_eq!(HostMsg::decode(want.clone()).unwrap(), h, "{name}");
                for n in 1..want.len() {
                    assert!(HostMsg::decode(want[..n].to_vec()).is_err(), "{name} truncated to {n}");
                }
            } else if let Some(c) = client(name) {
                assert_eq!(c.encode(), want, "{name}");
                assert_eq!(ClientMsg::decode(&want).unwrap(), c, "{name}");
                for n in 1..want.len() {
                    assert!(ClientMsg::decode(&want[..n]).is_err(), "{name} truncated to {n}");
                }
            } else {
                panic!("unknown display vector {name}");
            }
        }
        assert_eq!(CAP_DISPLAYS, 0x2000);
    }

    fn state(streamed: u32, selected: u32, ids: &[u32]) -> DisplayState {
        let list = match_list();
        let mut s = DisplayState::default();
        s.apply_list(streamed, selected, ids.iter().map(|&i| by(&list, i)).collect());
        s
    }

    #[test]
    fn cycling_wraps_and_copes() {
        let s = state(5, 0, &[1, 9, 5, 6]);
        assert_eq!(s.cycle(1), Some(6));
        assert_eq!(s.cycle(-1), Some(9));
        let s = state(6, 6, &[1, 9, 5, 6]);
        assert_eq!(s.cycle(1), Some(1), "wraps to the first");
        let s = state(1, 0, &[1, 9, 5, 6]);
        assert_eq!(s.cycle(-1), Some(6), "wraps to the last");
        let s = state(42, 0, &[1, 5]);
        assert_eq!((s.cycle(1), s.cycle(-1)), (Some(1), Some(5)), "streamed display not listed");
        assert_eq!(state(1, 0, &[1]).cycle(1), None, "one display");
        assert_eq!(state(1, 0, &[]).cycle(-1), None);
        assert_eq!(state(5, 0, &[1, 9, 5, 6]).position(5), Some((3, 4)));
    }

    #[test]
    fn remembering_and_restoring() {
        let s = state(1, 0, &[1, 9, 5, 6]);
        // the viewer's own choice is remembered; automatic forgets; host/hot-plug changes don't count
        let dell = remember_after(&s, 5, DISPLAY_REASON_SELECTED, 5).unwrap().unwrap();
        assert_eq!(dell, DisplayIdentity::of(&by(&match_list(), 5)));
        assert_eq!(remember_after(&s, 1, DISPLAY_REASON_SELECTED, 0), Some(None));
        assert_eq!(remember_after(&s, 1, DISPLAY_REASON_FALLBACK, 5), None);
        assert_eq!(remember_after(&s, 6, DISPLAY_REASON_HOST, 6), None);
        assert_eq!(remember_after(&s, 1, DISPLAY_REASON_UNAVAILABLE, 5), None);
        // next connection: ids changed, the identity still finds it
        let mut next = state(1, 0, &[1, 9, 6]);
        let mut moved = by(&match_list(), 5);
        moved.id = 70;
        next.displays.push(moved);
        assert_eq!(restore_choice(Some(&dell), &next), Some(70));
        assert_eq!(restore_choice(None, &next), None);
        // already selected (e.g. the host kept it): nothing to send
        next.selected = 70;
        assert_eq!(restore_choice(Some(&dell), &next), None);
        // gone: leave the default alone
        assert_eq!(restore_choice(Some(&dell), &state(1, 0, &[1, 9])), None);
        // it's fine to re-select the streamed display (makes it an explicit selection)
        assert_eq!(restore_choice(Some(&DisplayIdentity::of(&by(&match_list(), 1))), &state(1, 0, &[1, 9])), Some(1));
    }

    #[test]
    fn labels_and_toasts() {
        let list = match_list();
        assert_eq!(label(&by(&list, 1)), "Built-in Retina Display — 1512×982 HiDPI @ 120 Hz · main");
        assert_eq!(label(&by(&list, 6)), "DELL U2723QE — 2560×1440 @ 59.94 Hz");
        let mut s = state(5, 5, &[1, 9, 5, 6]);
        assert_eq!(changed_toast(&s, 5, DISPLAY_REASON_SELECTED, 5, false), "Mac display: “DELL U2723QE” (3/4)");
        assert_eq!(changed_toast(&s, 5, DISPLAY_REASON_SELECTED, 5, true), "Showing “DELL U2723QE” (remembered)");
        assert_eq!(changed_toast(&s, 1, DISPLAY_REASON_SELECTED, 0, false), "Mac display: automatic — “Built-in Retina Display”");
        // fallback: the list no longer has the display that went away, the toast still names it
        s.apply_list(1, 5, vec![by(&list, 1), by(&list, 9)]);
        assert_eq!(changed_toast(&s, 1, DISPLAY_REASON_FALLBACK, 6, false), "“DELL U2723QE” went away — showing “Built-in Retina Display”");
        assert_eq!(changed_toast(&s, 9, DISPLAY_REASON_RESTORED, 9, false), "“Glide Virtual Display” is back");
        assert_eq!(changed_toast(&s, 1, DISPLAY_REASON_UNAVAILABLE, 77, false), "That Mac display isn't available — still showing “Built-in Retina Display”");
        assert_eq!(changed_toast(&s, 9, DISPLAY_REASON_HOST, 9, false), "Mac display: “Glide Virtual Display” (chosen on the Mac)");
        assert_eq!(changed_toast(&s, 1, DISPLAY_REASON_DEFAULT, 0, false), "Mac display changed to “Built-in Retina Display”");
        assert_eq!(s.name(12345), "display 12345");
    }

    #[test]
    fn identity_serde_roundtrip() {
        let i = DisplayIdentity { id: 5, vendor: 0x10AC, model: 0x4268, serial: 7, name: "DELL".into() };
        let j = serde_json::to_string(&i).unwrap();
        assert_eq!(serde_json::from_str::<DisplayIdentity>(&j).unwrap(), i);
        assert_eq!(serde_json::from_str::<DisplayIdentity>(r#"{"name":"x"}"#).unwrap().vendor, 0, "missing fields default");
    }
}
