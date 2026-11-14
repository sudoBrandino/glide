## What and why

<!-- What does this change, and what problem does it solve? Link the issue if there is one. -->

## How it was tested

<!-- Which checks you ran, and any manual test on real hardware (Mac model, GPU, OS versions). -->

- [ ] `swift build -c release --build-system native` and `glide-selftest ../docs/test-vectors.json` (host changes)
- [ ] `cargo test` and `cargo build --target x86_64-pc-windows-gnu` (viewer changes)
- [ ] Vector regeneration check (protocol or crypto changes; see CONTRIBUTING.md)

## Protocol

- [ ] No change to the wire protocol
- [ ] `docs/PROTOCOL.md` is updated, the vectors are regenerated, and the Swift, Rust and Python implementations all pass against them

## Notes for the reviewer

<!-- Anything risky, anything left out on purpose, performance measurements. -->
