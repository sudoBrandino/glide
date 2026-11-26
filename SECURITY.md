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
  peer, a local user on either machine; in managed mode also a member or admin of a Glide Cloud
  organization, another organization, the relay, or a holder of a device token);
- the host and viewer versions or commits, and the OS versions;
- steps to reproduce, or a proof of concept if you have one.

Glide is maintained by one person. You can expect an acknowledgement within about a week. Once a
report is confirmed, a fix and an advisory are published together, and you are credited unless you
prefer otherwise.

## Supported versions

Glide ships numbered releases (`vX.Y.Z`, [Releases](https://github.com/sudoBrandino/glide/releases)).
Security fixes are released as a patch of the **latest minor version**, and land on `main`.
Organizations that run Glide in managed mode (Glide Cloud, [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md))
also get security fixes for the **previous minor version** (N-1), so a fleet has time to roll out
an upgrade:

| Version | Security fixes |
|---|---|
| Latest minor (e.g. 0.5.x) | Yes, for everyone |
| Previous minor (e.g. 0.4.x) | Yes, for managed (Glide Cloud) deployments; others should update |
| Older | No: update to a supported version |

While the version is 0.x, a minor release may change behaviour; the
[changelog](CHANGELOG.md) says what. A fix for a supported version comes with an advisory naming
the fixed releases. The hosted Glide Cloud service always runs the latest version; the console's
`min_app_version` setting lets an organization refuse managed sessions from apps that are too old.

## Security model

The design is specified in [`docs/PROTOCOL.md`](docs/PROTOCOL.md) §1–2. What it protects and what
it doesn't (a compromised endpoint, the trust placed in the LAN, dial-out mode) is in
[`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md). In short:

- Each side has a long-term X25519 key. The handshake is `Noise_XX_25519_ChaChaPoly_SHA256`.
- A viewer is paired with a host once, with a 6-digit code that the user confirms on both screens.
  After that, each side only accepts the key it pinned.
- All traffic after the handshake is encrypted with ChaCha20-Poly1305.
- Unauthenticated connections are rate-limited and time-limited.

In managed mode ([`docs/ENTERPRISE.md`](docs/ENTERPRISE.md) §3), the organization's Glide Cloud
tenant authorizes each session instead of a pairing code, sessions are relayed, and Noise still
runs end to end: the cloud and the relay never see session contents.

In scope: anything that lets someone who is not a paired peer view or control the host, read or
alter session traffic, or pair without the user's confirmation; and anything that lets a paired
peer go beyond what the protocol allows, for example writing files outside the download folder.
In managed mode also: reaching a device or session without a grant from its organization, crossing
from one organization to another, getting session contents out of the relay or the cloud, and
getting around an organization's policy (permissions, approval, LAN mode off) or audit log.

Out of scope: an attacker who already controls an account on either machine or holds a paired
device's key, and denial of service from the local network.

LAN mode is designed for a trusted LAN. Do not expose its ports to the internet; for remote access
use managed mode (outbound HTTPS only) or a VPN.
