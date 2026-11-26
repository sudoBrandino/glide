# Contributing to Glide

Thanks for your interest in Glide. Bug reports, fixes and well-scoped features are welcome.

Glide is maintained by one person in their spare time, so reviews can take a while. For anything
larger than a small fix, open an issue or a discussion first, so nobody builds something that
doesn't fit the [roadmap](docs/ROADMAP.md).

By taking part you agree to follow the [code of conduct](CODE_OF_CONDUCT.md). Report security
problems privately, as described in [SECURITY.md](SECURITY.md), not in a public issue.

## Layout

| Path | What |
|---|---|
| `mac/` | The host: a Swift package with `GlideCore` (protocol, crypto, logic), `glide-host`, `glide-probe` and `glide-selftest` |
| `windows/` | The viewer: a Rust crate. Everything outside `src/win/` is platform-independent and unit-tested |
| `docs/PROTOCOL.md` | The wire protocol. It is **normative**: the code follows the document |
| `docs/*.json` | Test vectors that both implementations are checked against |
| `tools/` | The Python reference implementation and vector generator, a mock host, and packaging scripts |

## Setup

- **Host:** macOS 14 or later on Apple silicon, with Swift 6 from Xcode or the Command Line Tools.
- **Viewer:** Rust stable. To cross-compile from macOS or Linux you also need MinGW-w64
  (`brew install mingw-w64`, or `apt install gcc-mingw-w64-x86-64`) and the Rust target
  (`rustup target add x86_64-pc-windows-gnu`).
- **Vector checks:** Python 3 with `pip install cryptography`.

You can work on the viewer without a Mac: `tools/mock_host.py` plays the host's side of the
protocol (see [`windows/README.md`](windows/README.md)).

## Checks to run before a pull request

CI runs all of these on every pull request. Run the ones that cover what you changed.

```sh
# 1. Host: release build. With only the Command Line Tools installed, the native build system
#    is required; with Xcode, plain `swift build -c release` also works.
cd mac && swift build -c release --build-system native

# 2. Host: protocol self-test against the vectors (run from mac/)
.build/release/glide-selftest ../docs/test-vectors.json

# 3. Viewer: unit tests (they run on macOS, Linux and Windows)
cd ../windows && cargo test

# 4. Viewer: Windows build
cargo build --target x86_64-pc-windows-gnu

# 5. Test vectors: the Python reference must reproduce the committed files (run from the repo root)
cd .. && python3 tools/glide_noise.py
python3 tools/gen_vectors.py /tmp/glide-vectors.json && cmp /tmp/glide-vectors.json docs/test-vectors.json
python3 tools/gen_vectors.py --check docs/test-vectors-rust.json
```

The host has no XCTest target, because XCTest is not available with the Command Line Tools alone.
Host tests live in the `glide-selftest` executable; add yours there.

## Protocol changes

`docs/PROTOCOL.md` is the specification, and three implementations follow it: Swift (`mac/`),
Rust (`windows/`) and the Python reference (`tools/`). A change to the wire format must keep all
of them in step, in the same pull request:

1. Update `docs/PROTOCOL.md` first.
2. Update the Python reference and regenerate the vectors:
   `python3 tools/gen_vectors.py docs/test-vectors.json`.
3. Update the Swift host and the Rust viewer until checks 2, 3 and 5 pass against the new vectors.
4. If the change is not backward compatible, say so in the pull request and handle the version
   mismatch as described in PROTOCOL.md.

Never edit a vectors file by hand to make a test pass.

## Pull requests

- Keep each pull request to one topic, and describe what changed and why.
- Add or update tests for behavior you change.
- Match the style of the code around your change. Run `cargo fmt` only on code you touched.
- Don't commit build output, credentials, or details of your own machine or network. Use
  placeholder addresses such as `192.168.1.50` in examples and tests.
- Changes to capture, encode, decode or present paths should say how you measured them
  (see [`docs/LATENCY.md`](docs/LATENCY.md)).
- Add a line for user-visible changes under `[Unreleased]` in [`CHANGELOG.md`](CHANGELOG.md).
- Pull requests are squash-merged.

## Versions and releases

The version lives in the `VERSION` file. `windows/Cargo.toml` and
`mac/Sources/GlideCore/Version.swift` carry copies that `tools/version.sh check` keeps in step
(CI runs it, and `cargo test` fails on a mismatch). Never edit the copies by hand:

```sh
tools/version.sh               # print the version
tools/version.sh set 0.3.0     # update VERSION and every copy
```

To cut a release (maintainers):

1. On `main`, set the version (`tools/version.sh set X.Y.Z`), move the `[Unreleased]` entries
   in `CHANGELOG.md` under a new `## [X.Y.Z] - YYYY-MM-DD` heading, update the links at the
   bottom, and merge that through a pull request.
2. Optionally build locally first: `tools/release.sh` writes both zips, `RELEASE_NOTES.md` and
   `SHA256SUMS` to `dist/release/X.Y.Z/`. It runs the host selftest and `cargo test` first, and
   reads `.dev/build.env` like the other packaging scripts. Leave `GLIDE_BUNDLE_ID` at its default
   for a public build.
3. Tag the merge commit and push the tag:
   `git tag -a vX.Y.Z -m "Glide X.Y.Z" && git push origin vX.Y.Z`. The
   [release workflow](.github/workflows/release.yml) checks that the tag matches `VERSION` and is
   on `main`, builds and tests both artifacts, and creates a **draft** GitHub Release with the
   notes from `CHANGELOG.md`.
4. Download the draft's files, check them (see [`docs/INSTALL.md`](docs/INSTALL.md)), and publish
   the draft on the Releases page.

Running the workflow by hand (Actions → Release → Run workflow) is a dry run: it builds everything
and attaches the files to the run, but creates no release.

Signing (Developer ID, notarization, Azure Artifact Signing), the secrets it needs and how to get
them, and the Windows MSI build are described in [`docs/RELEASING.md`](docs/RELEASING.md).

## License

Glide is released under the [MIT License](LICENSE). By contributing, you agree that your
contributions are licensed under the same terms.
