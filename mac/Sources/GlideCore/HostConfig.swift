import Foundation

/// host.json `"clipboard": {"enabled": true, "syncConcealed": false}` (PROTOCOL.md §5).
public struct ClipboardSettings: Codable, Equatable, Sendable {
    /// Sync the clipboard with viewers that support it. Default true.
    public var enabled: Bool?
    /// Send pasteboard items marked org.nspasteboard.ConcealedType (passwords). Default false.
    public var syncConcealed: Bool?

    public init(enabled: Bool? = nil, syncConcealed: Bool? = nil) {
        self.enabled = enabled; self.syncConcealed = syncConcealed
    }

    public var isEnabled: Bool { enabled ?? true }
    public var syncsConcealed: Bool { syncConcealed ?? false }
}

/// host.json `"audio": {"enabled": true}` (PROTOCOL.md §3.2). `GLIDE_NO_AUDIO=1` also turns it off.
public struct AudioSettings: Codable, Equatable, Sendable {
    /// Send the Mac's system audio to viewers that support it. Default true.
    public var enabled: Bool?

    public init(enabled: Bool? = nil) { self.enabled = enabled }

    public var isEnabled: Bool { enabled ?? true }
}

/// host.json `"files": {"enabled": true, "receive": true, "downloadDir": "~/Downloads/Glide",
/// "maxTotalBytes": 8589934592, "maxFiles": 10000}` (PROTOCOL.md §6).
public struct FileSettings: Codable, Equatable, Sendable {
    public var enabled: Bool?
    /// Accept files dropped on the viewer window.
    public var receive: Bool?
    public var downloadDir: String?
    public var maxTotalBytes: UInt64?
    public var maxFiles: Int?

    public init(enabled: Bool? = nil, receive: Bool? = nil, downloadDir: String? = nil, maxTotalBytes: UInt64? = nil, maxFiles: Int? = nil) {
        self.enabled = enabled; self.receive = receive; self.downloadDir = downloadDir
        self.maxTotalBytes = maxTotalBytes; self.maxFiles = maxFiles
    }

    public static let defaultDownloadDir = "~/Downloads/Glide"
}

/// host.json (`~/Library/Application Support/Glide`, or $GLIDE_HOST_CONFIG_DIR). Every key is
/// optional; nil means the default. Reading, writing and the folder are in glide-host (main.swift);
/// the decisions made from it are here so glide-selftest can check them.
public struct HostConfig: Codable, Equatable {
    /// v1 leftovers: no longer used (security v2 pairs keys), but kept untouched in the file so a
    /// rollback to the v1 host still finds its password.
    public var salt: String?
    public var password: String?
    /// The PC to dial (`--connect` overrides). The host listens as well unless `listen` is false.
    public var connect: String?
    /// false: saved `connect` is not dialed when Glide Host starts (menu bar → Connect to PC, or
    /// Settings → Connect Now, starts it). Default true. `--connect` always dials.
    public var connectAtLaunch: Bool?
    /// false: don't listen while a PC address is set (nothing on this Mac accepts connections;
    /// THREAT_MODEL.md "Dial-out mode"). Default true.
    public var listen: Bool?
    /// Display-mode policy (DisplayModeController.swift).
    public var display: DisplaySettings?
    /// Clipboard sync options (ClipboardSync.swift).
    public var clipboard: ClipboardSettings?
    /// System audio (AudioPipeline.swift).
    public var audio: AudioSettings?
    /// Viewers allowed to connect (security v2 pairing).
    public var pairedViewers: [PairedViewer]?
    /// File transfer options (HostFiles.swift).
    public var files: FileSettings?
    /// Optional virtual display sized to the viewer (VirtualDisplay.swift, docs/VIRTUAL_DISPLAY.md).
    public var virtualDisplay: VirtualDisplayConfig?
    /// The version whose setup window was last finished (Setup.swift); nil = never.
    public var setupVersion: String?

    public init(salt: String? = nil, password: String? = nil, connect: String? = nil, connectAtLaunch: Bool? = nil,
                listen: Bool? = nil, display: DisplaySettings? = nil, clipboard: ClipboardSettings? = nil,
                audio: AudioSettings? = nil, pairedViewers: [PairedViewer]? = nil, files: FileSettings? = nil,
                virtualDisplay: VirtualDisplayConfig? = nil, setupVersion: String? = nil) {
        self.salt = salt; self.password = password; self.connect = connect; self.connectAtLaunch = connectAtLaunch
        self.listen = listen; self.display = display; self.clipboard = clipboard; self.audio = audio
        self.pairedViewers = pairedViewers; self.files = files; self.virtualDisplay = virtualDisplay
        self.setupVersion = setupVersion
    }

    /// Dial the saved PC when Glide Host starts (default true, today's behavior).
    public var dialsAtLaunch: Bool { connectAtLaunch ?? true }

    /// The PC to dial right after launch: `--connect` always; otherwise the saved address, unless
    /// `connectAtLaunch` is false.
    public func launchDialTarget(cli: String?) -> String? {
        if let c = cli?.trimmingCharacters(in: .whitespaces), !c.isEmpty { return c }
        guard dialsAtLaunch, let c = connect?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return nil }
        return c
    }

    /// Listen for viewers at launch: always, except with `listen: false` (or `--no-listen`) while
    /// a PC address is known, saved or given with `--connect` (dial-out mode).
    public func listensAtLaunch(cli: String?, noListenFlag: Bool) -> Bool {
        let target = cli ?? connect
        let off = noListenFlag || listen == false
        return target == nil || !off
    }

    /// "Reset Settings" (Settings window): every preference back to its default. Kept: the paired
    /// viewers (removing them is its own action), the v1 leftovers (a rollback to v1 still works),
    /// setup having been finished, and the display mode Glide still has to give back to a monitor
    /// (`display.restore…`; dropping it could leave a monitor in the viewer's mode).
    public func resettingPreferences() -> HostConfig {
        var c = HostConfig(salt: salt, password: password, pairedViewers: pairedViewers, setupVersion: setupVersion)
        if let d = display, d.restore != nil || d.restoreDisplay != nil || d.restoreIdentity != nil || d.restoreFromMirror != nil {
            c.display = DisplaySettings(restore: d.restore, restoreDisplay: d.restoreDisplay, restoreIdentity: d.restoreIdentity,
                                        restoreFromMirror: d.restoreFromMirror)
        }
        return c
    }
}

extension DialPolicy {
    /// "host", "host:port" or "[v6]:port" → (host, port); nil for an empty string. A missing or
    /// unreadable port is 7420 (use `validateTarget` to reject it in a form).
    public static func parseTarget(_ s: String) -> (host: String, port: UInt16)? {
        let s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            return (host, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? 7420 : 7420)
        }
        // One colon: host:port. More (fe80::1): a bare IPv6 address, which can't carry a port.
        if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
            return (String(s[..<colon]), UInt16(s[s.index(after: colon)...]) ?? 7420)
        }
        return (s, 7420)  // a bare name, or an IPv6 address without brackets
    }

    /// Why `s` is not a usable PC address, or nil when it is (an empty string is fine: it clears
    /// the address). Accepts a name or IPv4 address with an optional `:port`, `[IPv6]:port`, or a
    /// bare IPv6 address.
    public static func validateTarget(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s.contains(where: { $0.isWhitespace }) { return "An address can't contain spaces." }
        func portProblem<S: StringProtocol>(_ p: S) -> String? {
            guard let n = Int(p), (1...65535).contains(n) else { return "The port must be a number from 1 to 65535." }
            return nil
        }
        /// Hex digits, colons and dots (an embedded IPv4), plus an optional `%zone` (en0).
        func isIPv6<S: StringProtocol>(_ a: S) -> Bool {
            let parts = a.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
            guard let addr = parts.first, addr.contains(":"), addr.unicodeScalars.allSatisfy(hex.contains) else { return false }
            return parts.count == 1 || (!parts[1].isEmpty && parts[1].unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains))
        }
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return "An IPv6 address in brackets needs a closing ]." }
            let host = s[s.index(after: s.startIndex)..<close]
            guard isIPv6(host) else {
                return "That isn't an IPv6 address."
            }
            let rest = s[s.index(after: close)...]
            if rest.isEmpty { return nil }
            guard rest.hasPrefix(":") else { return "Put the port after the brackets, like [fe80::1]:7420." }
            return portProblem(rest.dropFirst())
        }
        let colons = s.filter { $0 == ":" }.count
        if colons > 1 {
            return isIPv6(s) ? nil : "That isn't an IPv6 address. Use [address]:port for a port."
        }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        let host = parts[0]
        guard !host.isEmpty else { return "Enter the PC's name or IP address before the port." }
        let nameChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard host.unicodeScalars.allSatisfy(nameChars.contains), !host.hasPrefix("."), !host.hasPrefix("-") else {
            return "Use the PC's name or IP address, like 192.168.1.20 or gaming-pc.local."
        }
        return parts.count == 2 ? portProblem(parts[1]) : nil
    }
}
