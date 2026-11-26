import Foundation

/// Display strings that come from the cloud (user names and emails, device, host and org names,
/// tags) or from a peer (a viewer's name), made safe to show (ENTERPRISE.md §6.7). The same rules
/// as the Windows apps: controls, bidirectional marks and overrides, line and paragraph
/// separators, every Unicode format (Cf) character, tag characters and variation selectors are
/// removed; runs of whitespace collapse to one space; the result is trimmed and capped.
public enum CloudText {
    /// Names and emails are capped at this many characters (with an ellipsis).
    public static let maxName = 64

    /// True for a scalar that is never shown.
    public static func isRemoved(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: break
        }
        switch u.value {
        case 0x200E, 0x200F, 0x061C, 0x202A...0x202E, 0x2066...0x2069: return true  // bidi marks, embeddings, overrides, isolates
        case 0x2028, 0x2029: return true                                          // line / paragraph separator
        case 0xE0000...0xE007F: return true                                       // tag characters
        case 0xFE00...0xFE0F, 0xE0100...0xE01EF, 0x180B...0x180D, 0x180F: return true  // variation selectors
        default: return false
        }
    }

    /// Removed characters dropped, whitespace runs collapsed, trimmed. No length cap.
    public static func strip(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for u in s.unicodeScalars where !isRemoved(u) {
            if u.properties.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(u)
        }
        return String(out)
    }

    /// `strip`, then at most `max` characters: a longer string keeps `max - 1` and gets "…".
    public static func clean(_ s: String, max: Int = maxName) -> String {
        let t = strip(s)
        guard t.count > max, max > 0 else { return t }
        return String(t.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// An email address, stripped and capped at `max` characters without ever hiding its real
    /// domain: truncating from the end would turn `it@yourcompany.com.evil.example` into
    /// `it@yourcompany.com.e…`. The whole domain is kept and only the local part is shortened
    /// (`loc…@domain`); a domain that alone is over the cap keeps its end (the registrable part)
    /// behind a leading ellipsis (`…ample.com`).
    public static func email(_ s: String, max: Int = maxName) -> String {
        let t = strip(s)
        guard t.count > max, max > 1 else { return t }
        guard let at = t.lastIndex(of: "@") else { return clean(t, max: max) }  // not an address: a name
        let local = t[..<at], domain = t[t.index(after: at)...]
        if domain.count + 2 <= max {
            let keep = max - domain.count - 2  // room for "…@"
            return String(local.prefix(keep)) + "…@" + domain
        }
        return "…" + String(domain.suffix(max - 1))
    }

    /// `clean`, or `fallback` when nothing is left.
    public static func name(_ s: String, fallback: String, max: Int = maxName) -> String {
        let t = clean(s, max: max)
        return t.isEmpty ? fallback : t
    }
}
