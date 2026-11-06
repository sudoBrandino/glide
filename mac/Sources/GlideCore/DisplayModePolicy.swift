import Foundation

/// A display mode as the policy sees it (pure data, no CoreGraphics).
public struct DisplayModeInfo: Equatable, Codable, Sendable, CustomStringConvertible {
    /// Logical size in points ("looks like").
    public var width: Int
    public var height: Int
    /// Backing size in pixels (what gets captured).
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double

    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double = 60) {
        self.width = width; self.height = height; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.refreshRate = refreshRate
    }

    public var hiDPI: Bool { pixelWidth > width }

    /// Same resolution and scale (refresh rate ignored).
    public func sameSize(_ o: DisplayModeInfo) -> Bool {
        width == o.width && height == o.height && pixelWidth == o.pixelWidth && pixelHeight == o.pixelHeight
    }

    public var description: String {
        hiDPI ? "\(width)x\(height) HiDPI (\(pixelWidth)x\(pixelHeight)px)" : "\(width)x\(height)"
    }
}

/// How the host should size its display for the viewer.
public enum DisplayModePreference: String, CaseIterable, Sendable {
    /// Crisp for ordinary viewers, `HighDPIViewerChoice` for 4K-class viewers.
    case automatic
    /// Non-HiDPI mode whose pixels match the viewer 1:1 (largest that fits).
    case crisp
    /// HiDPI mode that looks like ~2/3 of the viewer's pixels, downscaled to fit (e.g. 4K viewer ->
    /// looks like 2560x1440, 5120px captured, sent at 3840). More workspace, slightly soft.
    case smooth
    /// HiDPI mode whose backing pixels match the viewer 1:1 (4K viewer -> looks like 1920x1080).
    case retina
    /// Never change the display mode.
    case manual
}

extension DisplayModePreference {
    /// Wire value in SetDisplayPreference / DisplayInfo (PROTOCOL.md §3.3).
    public var wireValue: UInt8 {
        switch self {
        case .automatic: return 0
        case .crisp: return 1
        case .smooth: return 2
        case .retina: return 3
        case .manual: return 4
        }
    }

    public init?(wire: UInt8) {
        guard let p = DisplayModePreference.allCases.first(where: { $0.wireValue == wire }) else { return nil }
        self = p
    }
}

extension HostMessage {
    /// DisplayInfo (§3.3) for `preference` and the current mode (nil = unknown: 0x0, not HiDPI).
    public static func displayInfo(preference: DisplayModePreference, mode: DisplayModeInfo?) -> HostMessage {
        func u16(_ v: Int) -> UInt16 { UInt16(clamping: max(0, v)) }
        return .displayInfo(preference: preference.wireValue, modeW: u16(mode?.width ?? 0), modeH: u16(mode?.height ?? 0), hidpi: mode?.hiDPI ?? false)
    }
}

/// What `automatic` does for 4K-class viewers.
public enum HighDPIViewerChoice: String, CaseIterable, Sendable {
    case retina, smooth
}

public enum DisplayModePolicy {
    /// Viewers at least this big count as high-DPI (4K-class) for `automatic` (3440x1440 ultrawides don't).
    public static let highDPIViewerWidth = 3200
    public static let highDPIViewerHeight = 1800

    /// The concrete style `preference` means for this viewer (`manual` stays `manual`).
    public static func resolve(_ preference: DisplayModePreference, viewerW: Int, viewerH: Int, highDPIChoice: HighDPIViewerChoice) -> DisplayModePreference {
        guard preference == .automatic else { return preference }
        if viewerW >= highDPIViewerWidth && viewerH >= highDPIViewerHeight { return highDPIChoice == .retina ? .retina : .smooth }
        return .crisp
    }

    /// Picks the display mode to use for a viewer showing `viewerW` x `viewerH` physical pixels.
    /// Returns nil when nothing should change (manual, unknown viewer size, no usable modes).
    /// When the current mode is already the best fit it is returned as-is (no switch needed).
    public static func choose(preference: DisplayModePreference, viewerW: Int, viewerH: Int,
                              modes: [DisplayModeInfo], current: DisplayModeInfo?,
                              highDPIChoice: HighDPIViewerChoice = .retina) -> DisplayModeInfo? {
        guard viewerW > 0, viewerH > 0, !modes.isEmpty else { return nil }
        let style = resolve(preference, viewerW: viewerW, viewerH: viewerH, highDPIChoice: highDPIChoice)
        switch style {
        case .manual, .automatic: return nil
        case .crisp:
            return best(modes.filter { !$0.hiDPI }, fits: { $0.pixelWidth <= viewerW && $0.pixelHeight <= viewerH },
                        size: { ($0.pixelWidth, $0.pixelHeight) }, viewerW: viewerW, viewerH: viewerH, current: current)
        case .retina:
            let hi = modes.filter { $0.hiDPI && $0.pixelWidth == $0.width * 2 && $0.pixelHeight == $0.height * 2 }
            if hi.isEmpty { return choose(preference: .crisp, viewerW: viewerW, viewerH: viewerH, modes: modes, current: current) }
            return best(hi, fits: { $0.pixelWidth <= viewerW && $0.pixelHeight <= viewerH },
                        size: { ($0.pixelWidth, $0.pixelHeight) }, viewerW: viewerW, viewerH: viewerH, current: current)
        case .smooth:
            let hi = modes.filter { $0.hiDPI }
            if hi.isEmpty { return choose(preference: .crisp, viewerW: viewerW, viewerH: viewerH, modes: modes, current: current) }
            // Looks like <= 2/3 of the viewer's pixels.
            return best(hi, fits: { $0.width * 3 <= viewerW * 2 && $0.height * 3 <= viewerH * 2 },
                        size: { ($0.width, $0.height) }, viewerW: viewerW, viewerH: viewerH, current: current)
        }
    }

    /// Among `candidates` that `fit`, prefer the viewer's aspect ratio, then the largest `size`, then
    /// the current mode / current refresh rate / highest refresh. If none fit, the smallest candidate.
    private static func best(_ candidates: [DisplayModeInfo], fits: (DisplayModeInfo) -> Bool,
                             size: (DisplayModeInfo) -> (Int, Int), viewerW: Int, viewerH: Int,
                             current: DisplayModeInfo?) -> DisplayModeInfo? {
        guard !candidates.isEmpty else { return nil }
        let viewerAspect = Double(viewerW) / Double(viewerH)
        func aspectMatches(_ m: DisplayModeInfo) -> Bool {
            abs(Double(m.pixelWidth) / Double(m.pixelHeight) - viewerAspect) / viewerAspect < 0.03
        }
        func area(_ m: DisplayModeInfo) -> Int { let s = size(m); return s.0 * s.1 }
        func tieBreak(_ a: DisplayModeInfo, _ b: DisplayModeInfo) -> Bool {  // true if a is better
            if let c = current {
                if a.sameSize(c) != b.sameSize(c) { return a.sameSize(c) }
                if (a.refreshRate == c.refreshRate) != (b.refreshRate == c.refreshRate) { return a.refreshRate == c.refreshRate }
            }
            return a.refreshRate > b.refreshRate
        }
        let fitting = candidates.filter(fits)
        if fitting.isEmpty {
            return candidates.min { area($0) != area($1) ? area($0) < area($1) : tieBreak($0, $1) }
        }
        let pool = fitting.contains(where: aspectMatches) ? fitting.filter(aspectMatches) : fitting
        var pick = pool.max { area($0) != area($1) ? area($0) < area($1) : !tieBreak($0, $1) }!
        // Same resolution as the current mode -> keep the current mode object (no switch).
        if let c = current, pick.sameSize(c), pool.contains(c) { pick = c }
        return pick
    }
}
