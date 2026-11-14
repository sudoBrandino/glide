# Security policy

Glide gives a remote machine full control of a Mac's screen, keyboard, mouse, clipboard and
files, so security reports are taken seriously.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Report it privately through GitHub:
[**Report a vulnerability**](https://github.com/sudoBrandino/glide/security/advisories/new)
(the repository's *Security* tab → *Advisories* → *Report a vulnerability*).

Please include:

- what an attacker can do, and from which position (on the LAN, a paired viewer, an unpaired
  peer, a local user on either machine);
- the host and viewer versions or commits, and the OS versions;
- steps to reproduce, or a proof of concept if you have one.

Glide is maintained by one person. You can expect an acknowledgement within about a week. Once a
report is confirmed, a fix and an advisory are published together, and you are credited unless you
prefer otherwise.

## Supported versions

There are no numbered releases yet. Only the latest commit on `main` is supported, and fixes land
there.

## Security model

The design is specified in [`docs/PROTOCOL.md`](docs/PROTOCOL.md) §1–2. What it protects and what
it doesn't (a compromised endpoint, the trust placed in the LAN, dial-out mode) is in
[`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md). In short:

- Each side has a long-term X25519 key. The handshake is `Noise_XX_25519_ChaChaPoly_SHA256`.
- A viewer is paired with a host once, with a 6-digit code that the user confirms on both screens.
  After that, each side only accepts the key it pinned.
- All traffic after the handshake is encrypted with ChaCha20-Poly1305.
- Unauthenticated connections are rate-limited and time-limited.

In scope: anything that lets someone who is not a paired peer view or control the host, read or
alter session traffic, or pair without the user's confirmation; and anything that lets a paired
peer go beyond what the protocol allows, for example writing files outside the download folder.

Out of scope: an attacker who already controls an account on either machine or holds a paired
device's key, and denial of service from the local network.

Glide is designed for a trusted LAN. Do not expose its port to the internet.
