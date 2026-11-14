//! Glide's release version. The repository's `VERSION` file is the source of truth; the crate
//! version in Cargo.toml must match it (`tools/version.sh set X.Y.Z` updates both, and the test
//! below fails if they drift).

/// Marketing version (semver), e.g. "0.2.0".
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Git commit the release was built from (set by tools/release.sh via `GLIDE_BUILD_COMMIT`).
pub const COMMIT: Option<&str> = option_env!("GLIDE_BUILD_COMMIT");

/// "0.2.0" or "0.2.0 (abc1234)".
pub fn display() -> String {
    match COMMIT.filter(|c| !c.is_empty()) {
        Some(c) => format!("{VERSION} ({c})"),
        None => VERSION.to_string(),
    }
}

/// One line for `--version`: "glide-client 0.2.0 (abc1234), protocol v2".
pub fn banner() -> String {
    format!("glide-client {}, protocol v{}", display(), crate::protocol::PROTOCOL_VERSION)
}

#[cfg(test)]
mod tests {
    #[test]
    fn matches_version_file() {
        let file = include_str!("../../VERSION").trim();
        assert_eq!(super::VERSION, file, "windows/Cargo.toml version != VERSION; run tools/version.sh set {file}");
    }

    #[test]
    fn banner_names_protocol() {
        assert!(super::banner().starts_with(&format!("glide-client {}", super::VERSION)));
        assert!(super::banner().ends_with(&format!("protocol v{}", crate::protocol::PROTOCOL_VERSION)));
    }
}
