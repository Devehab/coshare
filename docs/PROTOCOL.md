# The CoShare protocol (version 2)

Everything a new CoShare app needs to talk to the existing ones on iPhone, iPad, Mac, Windows, Linux and Android. If your app follows this page and passes the [test vectors](#test-vectors), it joins the same groups and shares the same clipboard. No server, no account, no registration.

The reference implementations live side by side:

| | Swift (iOS, iPadOS, macOS) | Node (Windows, Linux) | Kotlin (Android) |
|---|---|---|---|
| Crypto and frames | `Shared/GroupKey.swift`, `Shared/WireProtocol.swift` | `desktop/src/core/protocol.js` | `android/core/.../Protocol.kt` |
| Discovery and connections | `Shared/PeerNetwork.swift` | `desktop/src/core/network.js` | `android/core/.../PeerNetwork.kt` |
| Clipboard sync rules | `Shared/SyncEngine.swift` | `desktop/src/core/engine.js` | `android/core/.../SyncEngine.kt` |
| Device in/out notifications | `Shared/PresenceWatch.swift` | `desktop/src/core/presence.js` | `android/core/.../Presence.kt` |

## 1. Groups and keys

A **group** has an ID (random, URL-safe, made when the group is created), a name and a password (at least 6 characters). Devices that know the same ID and password share everything copied on any of them.

```
key = PBKDF2-HMAC-SHA256(password UTF-8, salt = "CoShare.v2.group." + groupID, 120 000 iterations, 32 bytes)
tag = hex( SHA256( key || "coshare-tag" ) )[0..8]      // first 4 bytes, lowercase hex
```

The **tag** is public. A device that wants to join checks the password it was given against it, so the group never has to send anything secret. Two groups with the same password get unrelated keys because the ID is the salt.

**Invite link** (shown as a QR code): `coshare://join?g=<groupID>&n=<name>&p=<password>`, query values percent-encoded.

## 2. Finding devices

Every device listens on **TCP port 47331**. It retries that port for a few seconds after a restart, and falls back to any free port (Bonjour then tells others which).

### Bonjour / mDNS: `_coshare._tcp`

Service name: the device ID. TXT record:

| Key | Value |
|---|---|
| `v` | `2` (ignore services without it) |
| `i` | device ID (random UUID, kept for the life of the install) |
| `n` | device name, e.g. `Ehab’s MacBook Pro` |
| `p` | platform: `mac`, `iphone`, `ipad`, `windows`, `linux`, `android` (unknown values read as `other`) |
| `g0` … `g7` | each group the device is in: `<groupID>|<tag>|<name>` (name: `|` → `/`, at most 48 characters) |
| `q` | quiet hours, if set: `<days>|<start>|<end>` (see below) |

Two devices **share a group** when an advertised `id` *and* `tag` match one of yours. Groups you aren't in are shown as "nearby", so people can join them with the password.

### Direct contact ("hello")

Bonjour doesn't work everywhere: on a phone's hotspot, or on networks that filter multicast. So every 15 s a device also sends a `hello` (§4) to the network gateway (where a hotspot's phone lives) and to every address a group member had before. Whoever answers with a key you share is a peer.

Rules that keep this working:

- **Remember addresses you can call again.** Save IPv4 addresses. Never save an IPv6 link-local address (`fe80::…`) without its interface scope: it can't be called later. When resolving a Bonjour service to call it, prefer IPv4.
- **Liveness.** Bonjour caches can list a device long after it vanished (Wi-Fi dropped, laptop asleep). A device that shares a group counts as connected only if it was heard from in the last **60 s**: any decrypted request from it, any reply, any hello either way. A device that just appeared gets 60 s from when it showed up. Greet group devices not heard from for 20 s at the address Bonjour gives.
- **Never call a device in its quiet hours,** nor one that said `bye`, until it advertises again or says hello. For 10 s after a `bye`, ignore that device's Bonjour record: its goodbye takes a moment to reach the cache.

## 3. Frames

One short TCP connection per request: connect, send one frame, read one frame back, close.

```
frame      = UInt32-BE length || sealed
sealed     = ChaCha20-Poly1305(key, nonce = 12 random bytes): nonce || ciphertext || tag(16)
plaintext  = UInt32-BE headerLength || header (UTF-8 JSON) || payload (raw bytes)
```

A frame is at most 64 MiB. A receiver tries each of its group keys. If none opens the frame (another group, a stranger, a port scan), it closes the connection without a word. The reply is sealed with the same group's key.

## 4. Messages

`header` is a JSON object:

| Field | Type | Notes |
|---|---|---|
| `type` | string | `clip`, `ack`, `pullLatest`, `latest`, `nothing`, `hello`, `bye` |
| `senderID`, `senderName` | string | as in the TXT record |
| `platform` | string | as in the TXT record |
| `clip` | object | `clip` and `latest` only (below) |
| `listenPort` | number | `hello` and `bye` |
| `groups` | array | `hello`: `[{ "id", "tag", "name" }]` |
| `quiet` | object | `hello`: `{ "days": [2,3,4,5,6], "start": 540, "end": 1020 }` |
| `quietUntil` | number | `bye`: seconds since 1970; absent means "paused" |

Ignore fields you don't know. That's how the protocol grows without breaking older apps.

| Request | Reply | Meaning |
|---|---|---|
| `clip` + payload | `ack` | "I just copied this": put it on your clipboard |
| `pullLatest` | `latest` + payload, or `nothing` | "what's the newest thing you have?" (sent when a device comes back) |
| `hello` | `hello` | "here I am, these are my groups, this is my port" |
| `bye` | `ack` | "I'm going off the network until `quietUntil` (or until I'm back)" |

`clip` object: `{ "id": UUID string, "kind": "text" | "image", "uti": "public.png" | "public.jpeg" | …, "hash": hex, "createdAt": seconds since 1970, "origin": device name }`.

- Text payload: UTF-8. Image payload: the file's bytes, unchanged.
- `hash = hex(SHA256(kind UTF-8 || payload))`. It's used to avoid loops and repeats: don't apply a clip whose hash is already on your clipboard, nor a `clip.id` you've seen.
- Apply a pulled clip only if its `createdAt` is newer than what you have.

**Quiet hours:** `days` are 1 = Sunday … 7 = Saturday. `start` and `end` are minutes after midnight, local time. `end ≤ start` means the window runs past midnight and belongs to the day it starts on. In the TXT record it is `2,3,4,5,6|540|1020`.

## 5. Behaviour every app should share

- Only new copies are shared: whatever was on the clipboard when the app started isn't news.
- History and copied images are kept for the chosen time only: 1 h, 12 h, 1 day (default), 3 days or 1 week, never more.
- Device notifications (optional, on by default):
  - A device gone for less than 30 s makes no noise.
  - Nothing is reported for 20 s after this device (re)connects or wakes.
  - A `bye` is reported at once, with its reason.
  - The first time a device ID is seen in a group it "joined"; after that it "came back".

## Test vectors

Group ID `k3x9testgroup`, password `pass1234`:

```
key   1b399077355410f50a6236b085713e78249c1d32634a5615cbb8449470a2af74
tag   f42b7b9a
```

This frame (base64) is a `hello` from sender `VECTOR` with `listenPort` 47331, `groups` `[{id: "k3x9testgroup", tag: "f42b7b9a", name: "G"}]` and the UTF-8 payload `مرحبا`:

```
AAAAxgBh8VPQHzbjeScsMqpqc0n364tsqtZR9XRS5HBOlKPbUZ1MxASl9nChaoZohz88xdxgO2aA9F2mOmotcSVvXFnysypSbOiC8u8lAoXZU1f2foi7u+kLs7WnSGDtG6mBuA0OsreOea+fXwc2Q6e8dWEwZS4uWZDt5cdAaFLBf552jAjxbtb8/6jeXI8xCc3JOaXq0ipelbPS/AH6LY5Mh9ZJDQ0x4crpGrVkedWnO3dmuUuhQUutQ0EDEdPnfgBakT3ZW8c1/Q==
```

Your implementation should derive the same key and tag, and open that frame. Then try it live: `scripts/test-peer.sh` runs a headless Swift peer on a Mac that joins your group and logs everything it sends and receives.
