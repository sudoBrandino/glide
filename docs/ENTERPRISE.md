# Glide for organizations (Glide Cloud)

Status: draft, normative for `cloud/` and for the managed-mode code in `mac/` and `windows/`.
If code and this file disagree, fix one of them. The peer-to-peer wire protocol is unchanged and
stays in [`PROTOCOL.md`](PROTOCOL.md); this file specifies what sits around it.

Glide Cloud is a hosted service on Cloudflare (Workers, Durable Objects, D1). It gives an
organization single sign-on, central device enrollment and policy, a relay so machines connect
from anywhere without opening ports, and an audit log. **The organization hosts nothing**: it
deploys the signed apps with its MDM, points them at Glide Cloud with a managed setting, and
registers Glide Cloud as an app in its identity provider.

LAN mode (the rest of the docs) keeps working for personal use. A device is in **managed mode**
once it has a cloud enrollment; an org setting can then turn LAN mode off on it (§7).

## 1. Goals and non-goals

Goals:

- People, not machines, are authorized: every session is tied to a user signed in through the
  org's identity provider (OIDC: Microsoft Entra ID, Okta, Google Workspace, any compliant IdP).
- Central control of who may reach which machines, with which permissions (view only, clipboard,
  file transfer, audio), and whether the person at the host must approve.
- Reachability without inbound ports, VPN or port forwarding: both ends dial out over HTTPS (443)
  through the org's proxies.
- End-to-end encryption is kept: the relay and the cloud never see screen, input, clipboard or
  file contents (§3).
- A complete, exportable audit trail of sign-ins, sessions, approvals, file transfers and admin
  changes.
- Silent deployment: signed and notarized packages, managed configuration (macOS configuration
  profiles, Windows Group Policy / Intune), a PPPC profile for the Mac's privacy permissions.

Non-goals for this version: SAML (OIDC only), SCIM (users and groups come from ID-token claims at
sign-in), UDP transport, session recording, several viewers at once, a direct-LAN fast path for
managed sessions (they are always relayed).

## 2. Components

```
 viewer app ──HTTPS──► glide-cloud Worker ◄──HTTPS── host app
     │                  │  API (/v1/...), console (/console), OIDC (/auth/...)
     │                  ├── D1 "glide"     orgs, users, devices, policies, sessions, audit
     │                  ├── DO DeviceHub   one per device: presence, push
     │                  └── DO Relay       one per session: byte pump
     └──────wss──► Relay DO (session S) ◄──wss──────┘
                   Noise XX + records end to end inside
```

| Piece | What |
|---|---|
| `cloud/` | TypeScript Worker `glide-cloud`: API, admin console, OIDC client, Durable Objects, D1 migrations, tests (Vitest + `@cloudflare/vitest-pool-workers`) |
| D1 `glide` | All durable state (§10) |
| DO `DeviceHub` | One per enrolled device (`idFromName(device_id)`): holds the device's hub WebSocket (hibernation API), delivers session offers and settings pushes, records last-seen |
| DO `Relay` | One per session (`idFromName(session_id)`): accepts one host and one viewer WebSocket, pumps bytes, reports start, end and byte counts |
| Secrets | `TICKET_KEY` (HMAC for relay tickets), `DATA_KEY` (AES-GCM for OIDC client secrets at rest), `OPERATOR_TOKEN` (operator API) |
| Client, Rust | `windows/src/cloud/`: managed config, API client, hub, relay bridge, grants. WinHTTP on Windows (system proxy and trust store) |
| Client, Swift | `mac/Sources/GlideCore/Cloud/` plus glue in `glide-host` and `glide-viewer`. `URLSession` (system proxy and trust store) |

## 3. Trust model

### 3.1 What changes from LAN mode

In LAN mode a viewer is trusted because both users compared a pairing code once (PROTOCOL.md
§2.4). In managed mode **the org's Glide Cloud tenant is the authority** on which viewer key may
connect to which host, one session at a time:

1. Each device keeps its own X25519 static key exactly as today. The private key never leaves it.
2. At enrollment the device registers its **public** key and receives a device token (§5.1).
3. For each session the cloud tells the viewer the host's public key and tells the host the
   viewer's public key: a **session grant** (§6.3).
4. Noise XX runs end to end through the relay. The viewer refuses a host whose key isn't the one
   the cloud named; the host refuses a viewer whose key isn't the granted one. No pairing code.

### 3.2 What the cloud can and cannot do

- It **can** authorize a viewer key for a host; that is its job. Whoever controls the org's
  tenant (an org admin, or the Glide Cloud operator) can therefore grant a session. Mitigations:
  every grant is audited before it is delivered; `approval: "required"` makes the person at the
  host confirm; the host shows a persistent "NAME (email) is connected" indicator and can end the
  session at any time.
- It **cannot** read session contents, impersonate an enrolled device to another device (it holds
  no private keys), or reach a device that isn't connected to its hub.
- A stolen device token lets the thief act as that device toward the cloud. It is stored next to
  the static key with the same protection (0600 file, Keychain or DPAPI). Revoking a device in the
  console closes its hub and any relay session at once.

### 3.3 Transport security

Client↔cloud traffic is HTTPS/WSS (TLS 1.2+, terminated by Cloudflare), validated against the OS
trust store so an org's TLS-inspection root works. Glide's Noise layer is independent of TLS and
is what protects session contents.

## 4. Tenancy and roles

- **Org**: a customer, with a slug, a name, an OIDC configuration, allowed email domains,
  settings (§7) and policies (§8).
- **User**: created at first SSO sign-in, identified by OIDC `iss` + `sub`. Email, name and groups
  (claim name configurable, default `groups`) are refreshed at each sign-in.
- **Role** (console access): `owner`, `admin`, `auditor` (read only, can export audit), `member`
  (no console). Mapped from IdP groups in org settings (`role_groups`) or granted explicitly. The
  bootstrap admin (§5.4) is `owner`; the last owner can't be removed.
- **Device**: an enrolled installation with `kind` `host` or `viewer` (a machine running both
  apps is two devices), a name, platform, app and OS version, tags, and its public key.
- **Enrollment token**: org-scoped secret admins put in the MDM profile, with optional default
  tags, expiry and maximum uses; revocable.

## 5. Flows

### 5.1 Device enrollment

1. The app reads its managed configuration (§11): `CloudURL`, `EnrollmentToken`, optional
   `DeviceName` and `Tags`.
2. With no stored enrollment (or one for a different `CloudURL`) it calls `POST /v1/enroll` with
   the token, its kind, public key, name, platform, OS and app version.
3. The cloud checks the token, creates the device and returns `device_id`, `device_token` and the
   effective settings. Audit: `device.enrolled`.
4. The app stores the enrollment (§11.3) and connects to the hub.

Enrolling again with the same public key and a valid token returns the existing device (a fresh
`device_token` replaces the old one). A revoked device is not brought back: enrolling its key
again is refused with `409 device_revoked`.

### 5.2 User sign-in on a viewer (device authorization grant)

The viewer never handles passwords. It uses the OAuth 2.0 device authorization grant (RFC 8628)
shape against Glide Cloud, which runs OIDC (authorization code + PKCE) with the org's IdP:

1. `POST /v1/auth/device/start` (device token) → `{device_code, user_code, verification_uri,
   verification_uri_complete, interval, expires_in}`.
2. The app opens `verification_uri_complete` in the default browser and shows `user_code`.
3. `/auth/device?user_code=…` redirects to the org's IdP; after `/auth/callback` a Glide Cloud
   page asks "Sign in to Glide on DEVICE-NAME?" (shows the code to compare) with Approve / Deny.
4. The app polls `POST /v1/auth/device/token` every `interval` seconds and gets
   `{user_token, expires_in, user}` once approved.
5. The user token is bound to that viewer device and is only accepted together with that device's
   token. Lifetime: `user_session_hours` (default 12). Audit: `user.signed_in`.

### 5.3 Starting a session

```
viewer                          cloud                             host (hub connected)
POST /v1/sessions {host_id} ──► policy check, insert session,
                                audit session.requested
                                hub: session_offer ─────────────►  approval prompt if required
                                ◄──────────────────────────────── session_answer {accept}
◄── 201 {session_id, relay_url, audit session.approved / denied
    ticket, host key, perms}
wss relay (viewer ticket) ────────────► Relay DO ◄─────────────── wss relay (host ticket)
Noise XX, viewer = initiator, through the relay; host checks viewer key == grant
records (PROTOCOL.md §2–6, unchanged)
close ────────────────────────► Relay DO: session.ended (duration, bytes, who closed)
```

- `POST /v1/sessions` waits for the host's answer: up to 60 s when approval is required, 10 s
  otherwise. No answer → `504 host_no_answer`. Host not on its hub → `409 host_offline`.
- The host's relay ticket comes in the offer; it opens the relay only after accepting.
- Tickets expire 120 s after issue (they only open the relay socket).
- A session ends when either socket closes, when `session_max_minutes` passes, when an admin ends
  it, or when either device is revoked.

### 5.4 Org onboarding (operator-provisioned)

1. The operator calls `POST /v1/operator/orgs` (bearer `OPERATOR_TOKEN`) with
   `{slug, name, owner_email}` and gets a one-time **setup link** (`/setup/<token>`, 7 days).
2. The owner opens it and enters the OIDC issuer URL, client ID, client secret and allowed email
   domains; the page shows the redirect URI to register (`https://<cloud>/auth/callback`). The
   cloud validates the issuer with OIDC discovery.
3. The owner completes a test sign-in. The ID token's `email` must equal `owner_email` (and be
   `email_verified` when the IdP sends that claim). They become `owner`; the link is consumed.
4. Afterwards the console is at `/console`: enter the org slug or a work email, then SSO.

If an org loses access to its IdP, the operator issues a new setup link (audit
`org.setup_link_issued`, actor `operator`).

## 6. Wire formats

API bodies are JSON (`application/json; charset=utf-8`). Times are RFC 3339 UTC strings. IDs are
opaque: a prefix (`org_`, `usr_`, `dev_`, `ses_`, `pol_`, `enr_`, `evt_`) plus 26 random base32
characters. Errors look like

```json
{ "error": { "code": "host_offline", "message": "The host is not connected." } }
```

with a matching HTTP status. Clients ignore unknown fields.

### 6.1 Credentials

| Credential | Format | Sent as | Lifetime |
|---|---|---|---|
| Device token | `gd_` + 43 base64url chars (32 random bytes) | `Authorization: Bearer gd_…` | until revoked or re-enrolled |
| User token | `gu_` + 43 base64url chars | `X-Glide-User: gu_…` together with the device bearer | `user_session_hours` |
| Relay ticket | `base64url(payload JSON) "." base64url(HMAC-SHA256(TICKET_KEY, first part))` | `?ticket=` on the relay URL | 120 s |
| Console session | 32 random bytes in cookie `glide_console` (`HttpOnly; Secure; SameSite=Lax; Path=/`); mutations also need the `X-CSRF-Token` header (or form field) from the page | cookie | 8 h idle, 24 h absolute |

The cloud stores only SHA-256 hashes of device, user, console, setup and enrollment tokens.
Relay ticket payload: `{"sid":"ses_…","role":"host"|"viewer","dev":"dev_…","exp":<unix s>}`.

### 6.2 Device API

All with `Authorization: Bearer gd_…` unless noted; "user" = also needs `X-Glide-User`.

| Method & path | Request → response |
|---|---|
| `POST /v1/enroll` | no bearer. `{enrollment_token, kind, public_key (64 hex), name, platform ("macos"\|"windows"), os_version, app_version, tags?}` → `201 {device_id, device_token, org:{id,slug,name}, settings}` |
| `GET /v1/device` | → `{device_id, kind, name, tags, org, settings}` |
| `POST /v1/device/heartbeat` | `{app_version, os_version, name?}` → `204` |
| `POST /v1/audit` | `{events:[{type, ts, session_id?, detail}]}` (≤ 100) → `202`; only the client types of §9 |
| `GET /v1/hub` | WebSocket upgrade → hub (§6.4) |
| `POST /v1/auth/device/start` | viewer devices only → `{device_code, user_code, verification_uri, verification_uri_complete, interval, expires_in}` |
| `POST /v1/auth/device/token` | `{device_code}` → `200 {user_token, expires_in, user:{id,email,name}}`, or `400` with code `authorization_pending`, `slow_down`, `expired_token` or `access_denied` |
| `POST /v1/auth/signout` | user → `204` (revokes the user token) |
| `GET /v1/me` | user → `{user:{id,email,name,groups}, org}` |
| `GET /v1/hosts` | user → `{hosts:[{id, name, platform, tags, online, last_seen, permissions, approval}]}`: the hosts this user may reach and what a session would allow |
| `POST /v1/sessions` | user. `{host_id, view_only?}` → `201 {session_id, relay_url, ticket, host:{id,name,public_key}, permissions, approval_required, expires_at}`. Errors: `403 not_allowed`, `409 host_offline`, `403 denied_by_host`, `409 host_busy`, `504 host_no_answer` |
| `POST /v1/sessions/{id}/end` | user (the session's viewer) or the session's host device → `204` |

`relay_url` is `wss://<cloud>/v1/relay/<session_id>`; the client appends `?ticket=<ticket>`.

### 6.3 Session grant and permissions

The host's offer (§6.4) and the `POST /v1/sessions` response carry the same **permissions**:

```json
{ "control": true, "clipboard": "both", "files": "both", "audio": true }
```

- `control: false` = view only: the host drops all input messages and refuses the viewer's file
  offers and clipboard pushes.
- `clipboard`, `files`: `"both"`, `"to_host"`, `"to_viewer"` or `"off"`, from the data's point of
  view (`to_host` = viewer → host). Each side enforces both what it sends and what it accepts, so
  a modified peer can't get around the other side's check.
- `audio`: host → viewer system audio.

The host keeps a grant `{session_id, viewer_key, viewer_name, user:{email,name}, permissions,
expires_at}` in memory only and accepts exactly one Noise session from `viewer_key` while it is
live. It is never written to `pairedViewers`. The viewer pins `host.public_key` for target
`relay:<session_id>`, in memory only.

### 6.4 Hub protocol (`GET /v1/hub`, WebSocket, JSON text frames)

One JSON object per frame, with a `type`. Server → device:

| type | fields | meaning |
|---|---|---|
| `hello` | `device_id`, `settings`, `server_time` | first frame |
| `session_offer` | `session_id`, `viewer:{device_id,name,public_key}`, `user:{id,email,name}`, `permissions`, `approval` (`"none"`\|`"required"`), `relay_url`, `ticket`, `expires_at` | hosts only |
| `session_cancel` | `session_id`, `reason` | viewer gave up, admin ended it, or timeout |
| `settings` | `settings` | org settings or policies changed |
| `revoked` | `reason` | delete the stored enrollment, end sessions, close |
| `ping` | `t` | every 30 s |

Device → server:

| type | fields |
|---|---|
| `session_answer` | `session_id`, `accept`, `reason?` (`"declined"`, `"busy"`, `"timeout"`, `"policy"`) |
| `session_state` | `session_id`, `state` (`"connected"`\|`"ended"`), `detail?` |
| `pong` | `t` |

With `approval: "none"` the host accepts at once unless it is busy with another session. With
`"required"` it shows a prompt naming the user and email: **Decline** is the default button,
Accept is enabled after 1 s, and the prompt declines by itself after 50 s.

Clients reconnect with exponential backoff (1 s doubling to 60 s, ±20 % jitter). A `401` on the
upgrade or a `revoked` frame means the device is no longer enrolled.

### 6.5 Relay protocol (`GET /v1/relay/{session_id}?ticket=…`, WebSocket)

- The ticket's `sid` must match the path and be unexpired, and its role must not already be
  connected; otherwise the upgrade is answered `401` or `409`.
- **Binary** frames are opaque bytes of the Glide stream (what would go over TCP). Frame
  boundaries mean nothing; order is kept per direction. Senders keep frames ≤ 1 MiB.
- **Text** frames are relay control, JSON, relay → client only: `{"type":"waiting"}` on connect
  while the other side is absent, `{"type":"peer_joined"}` to both once both are connected,
  `{"type":"peer_left"}` before the relay closes the remaining socket.
- A client sends no binary frame before `peer_joined`; the relay closes a socket that does
  (4002).
- The relay waits 60 s for the second side.
- Close codes: 1000 normal, 4001 ticket invalid, 4002 protocol violation, 4003 ended by an admin
  or revoked, 4004 peer did not join, 4005 session time limit.

### 6.6 Client-side relay bridge

The apps' session code runs on TCP streams. A managed session plugs the relay in with a loopback
**bridge**, so nothing below the transport changes:

1. Bind `127.0.0.1:0`, connect to it, accept. The accepted socket's peer port must equal the
   connecting socket's local port; otherwise close both and retry (another local process won the
   race). Close the listener.
2. Pump: socket → WebSocket binary frames (read up to 256 KiB, send as one frame), WebSocket
   binary → socket. Either side closing closes both.
3. Hand the other end to the existing code: the viewer treats it as a connection it dialed to
   target `relay:<session_id>`; the host treats it as a connection it dialed out (not charged to
   the inbound rate limiter, PROTOCOL.md §2.5).

Noise authenticates the peer whatever happens on the loopback hop.

## 7. Org settings (effective per device)

Returned by `/v1/enroll`, `/v1/device` and the hub's `hello` and `settings` frames:

```json
{
  "lan_mode": true,
  "allow_local_pairing": true,
  "owner_access": true,
  "user_session_hours": 12,
  "session_max_minutes": 480,
  "audit_file_names": true,
  "audit_retention_days": 365,
  "min_app_version": null
}
```

- `lan_mode: false`: the app neither listens on nor dials its LAN port; managed sessions only.
- `allow_local_pairing: false`: the LAN pairing window can't be opened. Already-pinned LAN peers
  still work while `lan_mode` is true.
- `owner_access`: enables the built-in owner rule (§8).
- `audit_file_names: false`: clients report file counts and sizes but not names.
- `min_app_version`: an older app says "update required" and refuses managed sessions.

A device's local `DisableLANMode` (§11) can only make this stricter.

## 8. Access policies

An org has an ordered list of rules. The first enabled rule that matches the (user, host) pair
decides; no match means deny.

```json
{
  "id": "pol_…",
  "name": "IT support",
  "enabled": true,
  "users": { "groups": ["it-helpdesk"], "emails": [] },
  "hosts": { "tags": ["staff-macs"], "device_ids": [] },
  "permissions": { "control": true, "clipboard": "both", "files": "to_host", "audio": false },
  "approval": "required",
  "session_max_minutes": 60
}
```

- `users` matches if the user is in a listed group or has a listed email (case-insensitive);
  `{"all": true}` matches every org user. An empty selector matches nobody.
- `hosts` matches a listed tag or device; `{"all": true}` matches every host.
- After the custom rules, a built-in **owner rule** (when `owner_access` is on): a host tagged
  `owner:<email>` is reachable by that user with full permissions and `approval: "none"`.
- `session_max_minutes` in a rule overrides the org setting when lower.
- `view_only: true` on a session request lowers `control` to false and `clipboard` and `files`
  to `"off"`. A request can never raise permissions.

## 9. Audit log

Each event: `{id, org_id, ts, actor:{type:"user"|"device"|"admin"|"operator"|"system", id, label},
type, target?:{type, id, label}, session_id?, ip?, country?, detail}`. `ip` and `country` come
from Cloudflare (`CF-Connecting-IP`, `request.cf.country`) for events the cloud observes.

Generated by the cloud: `org.created`, `org.setup_link_issued`, `org.sso_updated`,
`org.settings_updated`, `admin.signed_in`, `admin.role_changed`, `user.signed_in`,
`user.signed_out`, `user.sign_in_failed`, `device.enrolled`, `device.renamed`,
`device.tags_updated`, `device.revoked`, `enrollment_token.created`, `enrollment_token.revoked`,
`policy.created`, `policy.updated`, `policy.deleted`, `policy.reordered`, `session.requested`,
`session.denied` (`reason`: `not_allowed`, `declined`, `host_offline`, `timeout`, `busy`),
`session.approved`, `session.started` (both relay sockets joined), `session.ended`
(`duration_s`, `bytes_to_viewer`, `bytes_to_host`, `closed_by`), `session.terminated` (by an
admin).

Reported by clients through `POST /v1/audit`, attributed to the reporting device, accepted only
for a session that device is part of (or none): `session.file_sent`, `session.file_received`
(`count`, `bytes`, `names?`), `session.clipboard` (`direction`, `kind`: `text`|`image`, `bytes`;
never contents), `session.local_end` (`by`: `host_user`|`viewer_user`), `client.error`
(`code`, `message`).

The console filters by time, type, user, device and session, and exports CSV or NDJSON
(`GET /console/audit/export?format=csv&from=…&to=…`). A daily cron deletes events older than
`audit_retention_days`.

## 10. Data model (D1)

Tables (`cloud/migrations/`): `orgs`, `org_sso` (issuer, client_id, encrypted client_secret,
groups_claim, allowed_domains), `org_settings`, `users`, `user_groups`, `admin_roles`,
`console_sessions`, `devices`, `enrollment_tokens`, `device_codes`, `user_tokens`, `policies`
(ordered, JSON body), `sessions`, `audit_events` (indexed by `(org_id, ts)` and
`(org_id, session_id)`), `setup_links`, `oidc_states`. Every row carries `org_id` (except
operator-level rows) and every query is scoped by it.

## 11. Managed configuration and local state

### 11.1 macOS

Preference domain `dev.brandino.glide`, read with `CFPreferencesCopyAppValue` (which sees
`/Library/Managed Preferences`, so a configuration profile sets it):

| Key | Type | Meaning |
|---|---|---|
| `CloudURL` | string | e.g. `https://glide.example.com` |
| `EnrollmentToken` | string | from the console |
| `DeviceName` | string | optional; default the computer name |
| `Tags` | array of strings | optional tags added at enrollment |
| `DisableLANMode` | bool | local override; can only be stricter than the org setting |

Bundle identifiers: `dev.brandino.glide.host` and `dev.brandino.glide.viewer`. A PPPC profile
template (`packaging/mdm/`) grants Accessibility and lets standard users approve Screen Recording
(Apple does not allow MDM to pre-grant it) for the host's Developer ID code requirement.

### 11.2 Windows

Registry, machine policy first, then user policy: `HKLM\SOFTWARE\Policies\Glide`, then
`HKCU\SOFTWARE\Policies\Glide`. Values: `CloudURL` (REG_SZ), `EnrollmentToken` (REG_SZ),
`DeviceName` (REG_SZ), `Tags` (REG_MULTI_SZ), `DisableLANMode` (REG_DWORD). ADMX and ADML
templates in `packaging/windows/admx/` work with Group Policy and Intune.

### 11.3 Enrollment state

- Mac host: `~/Library/Application Support/Glide/cloud-host.json` (0600, folder 0700).
- Mac viewer: same folder, `cloud-viewer.json`.
- Windows: `cloud-host.dpapi` / `cloud-viewer.dpapi` next to the app's `config.json` (DPAPI,
  current user).

Content: `{"cloud_url", "org_id", "device_id", "device_token", "enrolled_at"}`; the viewer also
keeps `user_token` and `user_token_expires` there so a restart within the token lifetime doesn't
force a new sign-in.

## 12. Limits

| Limit | Value |
|---|---|
| Relay frame | ≤ 1 MiB |
| Session request wait | 60 s with approval, 10 s without |
| Relay ticket lifetime | 120 s |
| Wait for the second relay peer | 60 s |
| Device code lifetime / poll interval | 600 s / 5 s |
| Audit batch | ≤ 100 events, ≤ 256 KiB |
| Rate limits | 120 requests/min per device; 10/min per IP on `/v1/enroll` and `/auth/*` |

## 13. Operating Glide Cloud

[`cloud/README.md`](../cloud/README.md) covers the Cloudflare account requirements (the Workers
Paid plan for production Durable Object volume), deployment with `wrangler`, secrets, the custom
domain, migrations, the operator API, and backups (D1 Time Travel).
