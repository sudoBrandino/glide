import Foundation

/// Glide's release version. The repository's `VERSION` file is the source of truth;
/// `tools/version.sh set X.Y.Z` rewrites this constant and `tools/version.sh check` (CI, release)
/// fails if it drifts.
public enum GlideVersion {
    /// Marketing version (semver), e.g. "0.2.0". Keep in sync with `VERSION` via tools/version.sh.
    public static let version = "0.2.0"

    /// Wire protocol version spoken by this build (PROTOCOL.md).
    public static var protocolVersion: UInt16 { GlideHandshake.version }

    /// Git commit the app bundle was built from (Info.plist `GlideCommit`, set by
    /// tools/make-host-app.sh). Nil for plain `swift build` binaries.
    public static var commit: String? {
        (Bundle.main.object(forInfoDictionaryKey: "GlideCommit") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "0.2.0" or "0.2.0 (abc1234)".
    public static var display: String { commit.map { "\(version) (\($0))" } ?? version }

    /// One line for `--version` and log banners: "glide-host 0.2.0 (abc1234), protocol v2".
    public static func banner(_ program: String) -> String {
        "\(program) \(display), protocol v\(protocolVersion)"
    }
}
