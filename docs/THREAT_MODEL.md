# Threat model

This page says what Glide's security design protects, what it doesn't, and what it assumes. The
mechanism is specified in [`PROTOCOL.md`](PROTOCOL.md) §1–2; how to report a problem is in
[`SECURITY.md`](../SECURITY.md).

## Assets

- **Control of the Mac.** A session can type, click and paste, so a paired viewer can do anything
  the logged-in Mac user can do.
- **What the Mac shows and plays:** screen content and system audio.
- **Clipboards** on both machines, and **files** sent in either direction.
- **Identity keys:** the host key (`~/Library/Application Support/Glide/host-key`, mode 0600 in a
  0700 folder) and the viewer key (`identity.dpapi`, encrypted with DPAPI for the Windows user).
  Whoever holds one of these keys, plus the other side's pin, can impersonate that machine.

## Actors

| Actor | Can | Glide's answer |
|---|---|---|
| Passive observer on the network | See every byte | All traffic after the handshake is encrypted and authenticated (ChaCha20-Poly1305 with Noise XX keys, forward secret). See *What leaks* below |
| Active attacker on the network (spoofing, ARP poisoning, a rogue Wi-Fi AP) | Read, drop, change or inject traffic; impersonate either side | Mutual authentication against pinned static keys. A man in the middle can't complete a handshake with a paired peer. During pairing it has one chance in 10⁶ per attempt, and every failed attempt shows two different codes (§2.4) |
| Unpaired peer that can reach the port | Open TCP connections, send anything | Before the handshake: at most 1 KiB per handshake message, a 5 s deadline, a cap on pending sessions, and a per-address backoff (1 s doubling to 60 s). Until authenticated: 64 KiB records. An unknown key is refused unless the user opened the pairing window *and* confirms the code on both screens |
| Paired viewer | Full control of the Mac (by design) | Can't go beyond the protocol: file names are sanitized, files land only in the download folder and never overwrite anything, clipboard and image sizes are capped, malformed messages are dropped |
| Compromised or malicious host | Send the viewer arbitrary video, cursor images, clipboard content, audio and files | Treated as untrusted input by the viewer: same size caps and name sanitizing, bounded caches; received files get Mark-of-the-Web and are never opened; it can't make the viewer send input it didn't produce. It can still drop files into `Downloads\Glide` without a prompt (`file_receive`, on by default) and keep the viewer busy |
| Another local user on either machine | Read world-readable files, connect to local sockets | Key files and the host's control socket are owner-only (0600 / 0700, DPAPI on Windows) |
| Code running as the same user | Everything that user can do | Out of scope: it can read the key files, use the control socket, or simply replace the app |

## What pairing protects

Pairing pins each side's long-term public key once, after both users compare a 6-digit code
derived from the handshake (Short Authentication String). From then on:

- the viewer refuses a host whose key differs from the pin, **before** it sends its own identity
  (`HOST KEY CHANGED`);
- the host refuses a viewer whose key it hasn't pinned (AuthResult 1);
- nothing secret comes from a human: there's no password to guess, online or offline, and a
  recorded handshake gives an attacker nothing to work with.

The pairing commitment (§2.4) stops a man in the middle from grinding keys until both codes match.
What it can't stop is a user who confirms without comparing the codes. **The comparison is the
security step.** Decline any pairing prompt you didn't start.

## What pairing does not protect

- **A compromised endpoint.** If the Mac is compromised, the attacker sees and controls
  everything a viewer would, and can send the viewer hostile video, cursor images, clipboard data
  and files. If the PC is compromised, the attacker holds a paired viewer key: full control of
  the Mac. Pairing authenticates *machines*, not the person at them.
- **A stolen key.** Copying `host-key` or the viewer's `identity.dpapi` (with the user's DPAPI
  secrets) allows impersonation. Unpair (Mac: *Paired Viewers ▸ Remove…*; viewer: *Forget host*)
  and re-pair to rotate.
- **The person at the viewer.** A paired viewer is trusted to control the Mac. There is no
  per-session approval and no restricted (view-only) mode in LAN mode; managed mode has both
  ([below](#managed-mode-glide-cloud)).
- **Denial of service** from the local network: anyone who can reach the port can keep it busy
  or reset connections. A paired peer can also overload the other side (for example a host
  flooding video reconfigurations); the caps above prevent crashes and unbounded memory from
  parsing, not every way to waste CPU.

### What leaks

- The plaintext preambles show that a connection is Glide and which versions it speaks.
- Noise XX reveals the **host's** public key (and so its fingerprint) to anyone who connects,
  and tells them whether the host's pairing window is open. The viewer's key is encrypted and
  is sent only after the host key matched its pin.
- Record sizes and timing aren't hidden. An observer can tell when the screen changes, roughly
  how much, and **when keys are pressed** (each key event is its own small record). It can't
  tell which keys were pressed.

## Trust in the network

Glide is built for a **trusted LAN**. The cryptography doesn't depend on the network, but the
exposure does: the host listens on TCP 7420 on all interfaces, and its pre-auth defences limit
load rather than prevent it. Don't forward the port to the internet. To reach a Mac remotely,
use a VPN (WireGuard, Tailscale and so on) and treat it as part of the LAN.

## Dial-out mode (host → viewer)

Once the Mac knows the PC's address (setup window, `glide-host --connect PC` or `connect` in
host.json), it dials the viewer, and a viewer that knows the Mac's address listens as well as
dialing (`accept_incoming`, default on). Either direction then works, whichever the network allows.
By default the Mac **keeps listening** too. To have nothing listening on the Mac (a Mac on a
locked-down segment), set `"listen": false` in host.json or pass `--no-listen`; the viewer's
counterpart is `"accept_incoming": false` / `--no-listen`. The cryptography is the same either
way: the viewer is still the Noise initiator, and pins still decide.

What changes is the exposure of the viewer:

- Anyone who can reach the viewer's port can start a handshake. The viewer answers only after
  admission control (`windows/src/peers.rs`): the `allowed_peers` IP/CIDR allowlist, or, if
  that's empty, the IP of the first host that completed an authenticated session (trust on first
  use); plus a per-address backoff.
- An unpaired viewer shows a pairing prompt to a Glide host that connects to it only during its
  15-minute inbound pairing window (from start, the setup dialog, *Forget host* or the tray's
  *Allow the Mac to pair*), and only if that host's pairing window is open. Cancel is the default
  button and confirming is possible only after 1 s, so a stray keystroke can't pair. Pair only
  while you are pairing your own Mac, and only if both screens show the same code.
- The trust-on-first-use IP may move: with a pinned host key, a connection from a new address must
  present that key before the viewer reveals anything, and only then replaces the pinned IP. List
  the Mac's address as a CIDR (or several entries) in `allowed_peers` to forbid that.
- Recommended: set `allowed_peers` to the Mac's address and add a Windows Firewall rule that
  admits only the Mac to `glide-client.exe`.

The host redials every 2 s (backing off to 60 s while it is refused), doesn't dial while a viewer
that dialed in is connected, and doesn't dial at all while it has no paired viewer and its pairing
window is closed. Its own dialed sessions never count against the inbound rate limiter. It sends nothing about
itself beyond what any host sends to a connecting viewer.

## Managed mode (Glide Cloud)

In managed mode ([ENTERPRISE.md](ENTERPRISE.md) §3) the organization's Glide Cloud tenant, not a
pairing code, decides which viewer key may reach which host, one session at a time. Each device
keeps its own X25519 key and registers only the public half at enrollment. For each session the
cloud sends the viewer the host's public key and the host the viewer's (a *session grant*), and
Noise XX runs end to end through a relay: the viewer refuses a host whose key isn't the granted
one, and the host refuses a viewer whose key isn't. Everything in *What pairing protects* about
records and keys still holds; what changes is who decides, and that every session passes through
a relay. Client↔cloud traffic is HTTPS/WSS (TLS 1.2+) validated against the OS trust store, but
Noise, not TLS, is what protects session contents.

| Actor | Can | Glide's answer |
|---|---|---|
| Org admin (console `owner` / `admin`) | Write policies, enroll and revoke devices, change org settings, so grant any org user (themselves included) a session to any org host | By design: the admin decides access. Every grant is audited before it is delivered; a policy with `approval: "required"` makes the person at the host accept each session (Decline is the default, 50 s timeout); the host shows a persistent "NAME (email) is connected" indicator and can end the session. A local `DisableLANMode` can only make a device stricter |
| Glide Cloud operator (runs the service, holds `OPERATOR_TOKEN` and the database) | Everything an org admin can, in any org; read and change the database, including the audit log; issue a new setup link | Same as for an admin: approval prompts and the connected indicator are enforced by the apps, not the cloud. It holds no device private keys, so it can't impersonate an enrolled device to another device or read sessions. The audit log is only as trustworthy as the operator: an organization that needs more should keep `approval: "required"` and export the log regularly |
| The relay (a Durable Object per session, or anyone who can observe or alter its traffic) | See, delay, drop, reorder or alter the bytes of a session | Records are authenticated end to end (ChaCha20-Poly1305, Noise XX keys): changes and reordering are detected and end the session. A relay acting as a peer fails the handshake: it holds neither granted key. See *What leaks to the relay* |
| Holder of a stolen device token (`gd_…`, stored next to the device key with the same protection: 0600 file, Keychain or DPAPI) | Act as that device toward the cloud: connect its hub, receive its session offers (user names and emails, permissions), report audit events, read org settings | Can't complete a session without the device's private key: peers check the granted key. A viewer token alone can't request sessions: that needs a user token (`gu_…`) bound to that device, obtained only by an SSO sign-in. Revoking the device in the console closes its hub and relay sessions at once; tokens are stored hashed in the cloud |
| Another organization | Use the same Glide Cloud | Every row carries `org_id` and every query is scoped by it; grants and relay tickets name the session's devices |

### What leaks to the relay

The relay sees what a passive observer on the LAN sees in LAN mode (*What leaks* above), plus the
session's timing:

- the plaintext preambles: that it is Glide, and which protocol versions both sides speak;
- record sizes and timing in both directions: when the screen changes and roughly how much, and
  **when keys are pressed** (each key event is its own small record), not which keys;
- both ends' IP addresses, as Cloudflare sees them.

It doesn't see the static keys (Noise XX encrypts both) or anything inside the records: screen,
input, clipboard, files, audio.

### What the cloud sees

Session **metadata**, not contents: which user (email, name, IdP groups) asked for which host from
which viewer, when, with which permissions, whether the host approved, how long the session lasted,
how many bytes went each way and who closed it; devices' names, platforms, OS and app versions,
tags, public keys, last-seen times, IP addresses and countries. Clients also report file transfers
(counts, sizes and, unless the org turns `audit_file_names` off, names) and clipboard use
(direction, kind, size; never contents). All of it is in the organization's audit log
([ENTERPRISE.md §9](ENTERPRISE.md#9-audit-log)).

## Untrusted input, by side

- **Host** (from any peer): handshake messages (≤ 1 KiB each), records (≤ 64 KiB until
  authenticated, ≤ 32 MiB after), input events (non-finite or absurd coordinates and wheel
  deltas are dropped), clipboard (≤ 16 MiB, PNG header checked before decoding, ≤ 64 Mpx), file
  offers (names per §6.3, ≤ 8 GiB and 10 000 files by default, never overwriting, quarantined).
- **Viewer** (from the host): the same record, clipboard and file rules (PNG decoding also skips
  colour-profile and text chunks), plus video bitstreams (passed to the Windows Media Foundation
  decoder), cursor images (at most 256×256, cache bounded), audio (format checked) and display
  lists (bounded). The video decoder is the largest parsing surface that Glide
  doesn't control. Its exposure is limited to a host the viewer has paired with.

Both sides' decoders are fuzzed in CI: `cargo test` (`windows/src/fuzz_tests.rs`) and
`glide-selftest` (`FuzzTests.swift`) mutate every message in the test vectors with fixed seeds.
