# Dante Switcher — Plan

A menu-bar agent that follows the Metric Halo's sample rate and applies it to every
Dante device, Pulse 16 DX first.

## What netaudio is today (checked 2026-10-16)

`chris-ritsen/network-audio-controller` is far beyond the old Python CLI. v0.4.2
(PyPI, prebuilt macOS arm64/x86_64 wheels, Unlicense), last commit 2026-10-13.

- **Shared Rust protocol core** (`packages/netaudio-core`) with a C ABI
  (`include/netaudio_core.h`: `netaudio_client_new`, `netaudio_client_request`,
  lock/unlock, sample-rate evidence, clock-control helpers). Its own native
  iOS/iPadOS app is built on it.
- **Python CLI** on top, with `-j` JSON output on every command.
- **Daemon** with an HTTP API and server-sent events (`netaudio daemon start`).
- Commands that matter here:
  - `netaudio -j device list` — per device: `sample_rate_hz`, `requested_sample_rate`,
    `supported_sample_rates_hz`, `encoding`, `supported_encodings`, `is_locked`,
    `preferred_leader`, `clock_source`, `rx_count`/`tx_count`, decoded `clock_status`.
  - `netaudio -j lock status` — per-device lock state.
  - `netaudio -j clock` — PTP role per device (Leader/Follower).
  - `netaudio -n NAME device config sample-rate 96000` — set one device;
    `--all` for all of them; `--confirm-destructive` is needed when TX flows exceed
    capacity at the new rate. The global `--verify` flag waits for a fresh readback.
  - `netaudio device capabilities` — rate-dependent channel capacities.

### Observed on this Mac's network during the check (read-only)

| Device | Rate | Supported | Lock | Notes |
|---|---|---|---|---|
| FF-PULSE-16-DX | 48k | 44.1–192k | unlocked | preferred leader, PTP **Leader**, clock source `external/BNC` |
| D2USB-6152f1 (Turtle AV) | 48k | 44.1–96k | unlocked | follower; **no 176.4/192k** |
| USB-16x16-Inferno | — | — | unknown | Inferno-AoIP; reports no rate |
| Bryans-MacBook-Pro (DVS 4.5.2.3) | 48k | — | unknown | netaudio fails to parse DVS's model/lock replies; DVS is really on en12 / 169.254.26.52, but netaudio lists 192.168.1.67 (en0) |

Already-visible issues:
- The Pulse reports `external/BNC`, not something MADI-specific. That's probably just
  netaudio's name for clock-source code 1 ("Sync to External"), but confirm it.
- Confirmed on the studio Mac (en12) on 2026-10-16. DVS reports `model_id = "DvsMacOs"`,
  which reliably identifies it. The Inferno device has no rate fields at all, only
  encoding, so netaudio may not be able to read or set its rate.
- DVS and the Inferno device return no supported-rate list, so the "unsupported rate"
  check has to fall back to try-and-verify for them.
- DVS advertises itself under the Mac's own hostname (`Bryans-MacBook-Pro.local`).
  That name resolves to every interface's address, and netaudio picked en0
  (192.168.1.67) instead of the Dante NIC en12 (169.254.26.52). The app must use only
  the Dante interface (`--interface en12`, or the matching `NWParameters`
  `requiredInterface` in Swift) so it sends control traffic to the right address.
- `device capabilities` timed out on the Pulse (15 s), so it can't be on the hot path.
- The Metric Halo wasn't attached to this MacBook during the check, so the CoreAudio
  side is untested.

## Architecture

```
┌──────────────── DanteSwitcher.app (menu bar, SwiftUI MenuBarExtra) ────────────────┐
│                                                                                     │
│  RateSource ──► RateDebouncer ──► SyncCoordinator ──► DanteBackend ──► Notifier     │
│  (CoreAudio      (settle window,    (ordering, exclude   (protocol)     (UNUser-    │
│   listener;       relock gate,       list, per-device                   Notification│
│   MIO fallback)   echo suppression)  results, retries)                  Center)     │
│                                                                                     │
│  Settings (exclude list, target device UID, timings) · Log view · "Sync now"        │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

- **RateSource**: a protocol with two implementations.
  - `CoreAudioRateSource`: finds the MH device by UID, adds an
    `AudioObjectAddPropertyListenerBlock` for `kAudioDevicePropertyNominalSampleRate`,
    and also watches `kAudioHardwarePropertyDevices` so it re-binds after the MH
    disappears and comes back (rate changes can make it re-enumerate).
  - `MIOConsoleRateSource` (fallback): reads the rate from MIOConsole3d's protocol.
    Only built if Phase 0 shows CoreAudio misses MIOConsole3d-initiated changes.
- **RateDebouncer**: emits a rate only after it has been stable for N seconds (default 2)
  **and** the Pulse reports sync (see "Relock gate" below).
- **SyncCoordinator**: a Swift `actor`. It builds the plan (Pulse first, then
  everyone else concurrently, minus the exclude list), runs it, verifies, and collects
  a `[DeviceResult]`. Only one run at a time; a newer target rate cancels the old run.
- **DanteBackend**: a protocol (`discover()`, `state(of:)`, `setSampleRate(_:on:)`).
  How it's implemented is the Phase 2 decision.
- **Notifier**: one summary notification ("96 kHz: 5 ok, 1 locked, 1 unsupported")
  plus a detailed log in the menu.

### Edge-case handling

| Case | Handling |
|---|---|
| Device Lock | Read `is_locked` before setting. Skip and report "locked". Never try to unlock (PIN). |
| Unsupported rate | Check `supported_sample_rates_hz` when it's reported. If it isn't (DVS, Inferno), try, verify, and report. Either way, fail that device and keep going. |
| Channel-count drop | Compare per-rate channel capacities (from `capabilities`, cached once per device off the hot path) against active subscriptions/TX flows. Warn before the change. Never pass `--confirm-destructive` automatically. |
| DVS feedback loop | DVS is a separate CoreAudio device, so the MH listener only fires if DVS's change propagates back to the MH clock. Guard against it anyway: an "expected rate" token (ignore listener events matching the rate we're applying while a run is in flight), plus a cooldown after each run. |
| Dropouts / reboots | After each set, poll with backoff (e.g. 1, 2, 4, 8 s, up to 30 s) until the readback matches and the device is online again. A device that vanishes from mDNS mid-change shows as "rebooting", not "failed", until the timeout. |
| netaudio's capacity gate | netaudio refuses any rate change on a device that has TX flows but didn't report its channel capacity at the target rate (seen on the D2USB, 48k→44.1k). Overriding it takes `--confirm-destructive`. The app policy: channel capacity is tied to the rate band (1× = 44.1/48, 2× = 88.2/96, 4× = 176.4/192). Moving down a band or staying in one can't lose channels, so confirm those automatically. Moving up a band with unknown capacity means skip the device and report it, unless the user has opted that device in. |
| Multicast bandwidth | IGMP snooping is off, so every multicast flow reaches every port, including the D2USB's 100 Mb link. Doubling or quadrupling the rate doubles or quadruples that traffic. Before a high-rate change, add up the multicast TX flows (`netaudio flow`) at the target rate and warn if they'd saturate a 100 Mb device. Better still, enable IGMP snooping and a querier on the switch. |
| Relock gate | Before touching Dante, wait until the Pulse's Dante `clock_status` shows it's leading and stable at the new rate (or a timeout, then proceed with a warning). Whether the Pulse's MADI lock state is visible over Dante is an open question. If it isn't, use a fixed settle delay. |
| MIOConsole3d changes | Phase 0 test, below. |

## Phases

### Phase 0 — CoreAudio detection (small Swift CLI, before the app)
A ~50-line `swift` script that logs every `NominalSampleRate` callback for the MH
device with a timestamp. Change the rate from (a) Audio MIDI Setup, (b) a DAW,
(c) **MIOConsole3d**, (d) the MH front panel if it has a rate control. Record which
ones fire, how many times, and whether the device re-enumerates.
Decides: whether the MIOConsole fallback is needed.

**Result (2026-10-16, `scripts/rate_watch.swift`): CoreAudio is reliable, so the
MIOConsole fallback is not needed.** Four MH changes, the first made from
**MIOConsole3d**. Each fired `NominalSampleRate` on `MHLink [49057]`
(`com.mhlabs.mhlink.00075900bfa1`) exactly once, with no device removal or
re-enumeration. The Fireface UC (clocked from the MH) followed about 2.2 s later
every time. DVS did not move. Match the MH by UID prefix `com.mhlabs.mhlink.`.

### Phase 1 — Prove netaudio on your network (now)
1. `scripts/dante_inventory.py`: read-only inventory (rate, encoding, lock, leader).
2. Next, a manual set test on **one** non-critical device (e.g. the D2USB):
   `netaudio --verify -n D2USB-6152f1 device config sample-rate 96000`, then back
   to 48000. Time it, and check if the device drops off mDNS.
   **Result (2026-10-16):** 48k→44.1k→48k both verified with `--confirm-destructive`,
   keeping 2 TX / 2 RX. Each call took ~13 s, but a call that wrote nothing took
   ~12 s, so almost all of that is mDNS discovery. The app should keep discovery
   running all the time, not rediscover per change. The D2 never left Dante Controller
   or rebooted. Its subscriptions in both directions went red while its rate didn't
   match the network's, and came back green on their own once it matched again. So red
   routing partway through a sync is expected, and the final verify should also check
   that subscriptions have recovered.
   **DVS result (2026-10-16):** `Refused: sample rate readback timed out` in both
   directions, in ~16 s. netaudio reads the current rate before any write, and DVS
   4.5.2.3 never answers that request, so **nothing was sent**. (`device list` still
   shows 48k for DVS, so that value must come from a different query.) Open: can Dante
   Controller change DVS's rate? If so, capture what Dante Controller sends and take it
   upstream. If not, DVS is excluded and the app only warns about it.
   → **Dante Controller can.** DVS drops out of Dante Controller briefly while it
   switches (it restarts its engine), so the app needs a re-discovery wait for DVS.
   **Capture findings** (`captures/dvs-rate-change.pcap`, 2026-10-16):
   - DVS's control ports are shifted by +30000: `conmon_server -b=38700 -c=38800
     -p=38900` (settings / CMC / conmon). Dante Controller sends the rate change from
     port 8700 to **DVS:38700**. DVS gets no packets on 8700.
   - The set-rate packet (40 bytes, sent with no reply; the result shows up in DVS's
     heartbeat on 224.0.0.233:8708):
     `ffff 0028 <seq16> 0000 <controller-mac6> 0000 "Audinate" 073e 0081 00000064 00000001 <rate32>` (the MAC is the sender's; confirmed with the Inferno, where controller and device are separate machines)
     with rate `0000ac44` = 44100 and `0000bb80` = 48000. The same opcode with flag 0
     and no value reads the rate.
   - netaudio only learns a non-default settings port through CMC registration. For
     DVS that left `settings_port` empty, so it fell back to 8700. That is the likely
     cause of the timeout. To be confirmed by a write test, then reported upstream.
   - After the change, DVS re-advertised itself under the Mac's real hostname
     (`Bryans-MBP-M2-Max`, previously `Bryans-MacBook-Pro`). **Track devices by
     instance ID** (`4cea41fffe63338f`), never by name.
   - The app runs on the DVS Mac, so it can read DVS's supported rates and current
     rate locally from `dvs_ape`'s arguments (`--srate=…`, `--currSrate=…`): all six
     rates, 16×16.
   - **Confirmed:** under the new name, netaudio still refuses with the same readback
     timeout. Issue drafted in `notes/netaudio-dvs-issue.md` (not posted). The direct
     test is `scripts/dvs_set_rate.py`; its packet matches the capture byte for byte.
   - **Direct packet works (2026-10-16):** `dvs_set_rate.py` changed 48k→44.1k→48k,
     confirmed through `dvs_ape --currSrate`, in 2.4 s and 2.9 s. An ephemeral source
     port is fine; it doesn't need 8700. **Decision: the app sets DVS with this packet
     and checks the result locally, and uses netaudio only for hardware.**
   - Original fallback idea: the app sends the 40-byte packet above to
     127.0.0.1/en12:38700 itself, then confirms through the 8708 heartbeat or
     re-discovery.
   **Inferno USB-16x16:** being made to support this in a separate chat. For the app it
   needs to: report `sample_rate_hz` and `supported_sample_rates_hz` in
   `netaudio device list`, and accept the standard settings opcode `0x0081` (flag 1 +
   rate32) on its settings port with a readback that `--verify` can confirm. Until it
   does, it stays on the exclude list.
   **Mismatch found (2026-10-16):** the MH (CoreAudio `MHLink [49057]`, UID
   `com.mhlabs.mhlink.00075900bfa1`) and the Pulse's MADI side are at 44.1k, while
   Dante is at 48k. CoreAudio reports the MH's rate correctly. While mismatched, the
   Pulse's Dante clock status is `undisciplined` / servo `none` / stratum 121 /
   offset 0 ppb, the same as when first inventoried. **Dante shows nothing about MADI
   lock**, so the relock gate can't rely on it (snapshot in `captures/`). Compare with
   the matched state.
   → **Corrected after the manual sync to 44.1k** (Pulse, then D2 via netaudio, then
   DVS via direct packet; all verified). The clock record does carry a lock signal.
   Mismatched → matched:
   `word_clock_state` invalid(2) → **valid(3)**, stratum 121 → 41, frequency
   offset 0 → +1759 ppb (now tracking external). **Relock gate = Pulse
   `word_clock_state == valid` at the target rate**, polled through `clock_status`.
   Snapshots: `captures/pulse-mismatched-*.json`, `captures/pulse-matched-44k1.json`.
   After the sync, every subscription among Pulse/D2/DVS was `DYNAMIC`/connected. The
   only failures involved the Inferno (still at 48k): Inferno→Pulse 16×`CHANNEL_FORMAT`,
   Pulse→Inferno 14×`TX_FAIL` + 2×`UNRESOLVED`. These are the patterns the final
   verify should report as "device didn't follow".
3. Then the Pulse with the MH at the new rate. Check the Pulse follows "Sync to
   External" cleanly.
4. Try DVS: can netaudio set its rate at all, or does DVS only take rate changes
   from its own app/CoreAudio? (Given the parse errors, this is the riskiest one.)

### Phase 2 — Backend decision
Three options, not two. netaudio's Rust core changes the picture:

| Option | Pros | Cons |
|---|---|---|
| **A. Subprocess the CLI** (bundled Python + netaudio) | Fastest to ship; reuses upstream fixes; `--verify` and JSON already exist | Bundling a Python runtime inside a notarized app (every `.so`/`.dylib` signed, hardened runtime); ~30 s discovery per call; spawn overhead; parsing a CLI that's changing quickly |
| **B. Link the Rust core via its C ABI** | Native, fast, one static lib; upstream iOS app proves it embeds; protocol fixes come from upstream; easy to sign | Need to build the Rust crate (universal binary); C ABI is JSON-in/JSON-out and not a stable public API; discovery (mDNS) and orchestration still have to be written in Swift (`NWBrowser` handles that) |
| **C. Port packets to Swift** | No dependencies; full control | Re-implements an evolving reverse-engineered protocol; you'd own every firmware quirk (see the DVS parse errors) |

~~Original recommendation: B.~~ Superseded by what Phase 0/1 found (below).

**Decision (2026-10-16): C, narrowly scoped. Native Swift, no bundled Python or Rust.**
This app needs four things on the wire, and each is now known and small:

| Need | On the wire | Status |
|---|---|---|
| Find devices | mDNS `_netaudio-arc._udp` / `_netaudio-cmc._udp` (`NWBrowser`). Track by instance ID; DVS = `model=DvsMacOs`, CMC on 38800 | known |
| Live rate per device | Passive multicast heartbeat `224.0.0.233:8708`, header `fffe`, record type **0x8003**, rate at payload +8 (`0000ac44`). Seen ~1/s from Pulse, D2, DVS. No requests needed. | **verified** (`hb_listen` 2026-10-16) |
| Set rate | Settings packet opcode **0x0081**, flag 1 + rate32, to port **8700** (hardware) / **38700** (DVS). No reply; confirm by heartbeat. | DVS **verified**; hardware = same opcode Dante Controller sends (Inferno chat) |
| Pulse locked to MADI | Settings opcode **0x0020** clock-status reply: `word_clock_state` valid(3) vs invalid(2), stratum 41 vs 121. Sent **only on request**, not unsolicited (15 s passive listen: nothing). | Reply format known; **request bytes still to pin down** (likely the 92 B `0x0021` that netaudio and Dante Controller both send; the encoder is in netaudio-core `clock_configuration.rs`) |

Why not A or B now:
- **A (CLI subprocess):** about 13–20 s per call, mostly discovery; netaudio refuses
  DVS; a Python runtime has to be signed and notarized inside the app.
- **B (Rust core):** a large dependency for the four packets above, and it still has
  the DVS port bug.

What C gives up, and the mitigation:
- **netaudio's topology safety gate** (channel capacity per rate): use the band rule
  plus a pre-change warning when TX/RX counts drop.
- **Device Lock and supported-rate detection:** treat "no rate change in the heartbeat
  within N s" as failed (locked or unsupported), and cache supported rates from a
  one-time netaudio inventory or the heartbeat.
- **Subscription health for the final verify:** heartbeat records 0x8003/0x8004 look
  like per-flow receive stats; to confirm in Phase 3, otherwise skip.

Keep netaudio installed as the **diagnostic and reference tool** (inventory script,
`--dissect`), not as a runtime dependency. Hide the wire code behind a
`DanteBackend` protocol so B stays a fallback if firmware quirks pile up.

### Phase 3 — App

**Step 1 done (2026-10-16): `dante-sync` CLI + `DanteSyncCore` library** (Swift package
at the repo root). It is native only: CoreAudio, BSD multicast sockets, and `NWBrowser`.
- `dante-sync status`: MH rate, each device's rate from heartbeats, and the leader's
  word-clock lock (via the 92 B query; the reply arrives on 224.0.0.231:8702). Takes
  about 5 s, against about 60 s for the netaudio inventory.
- `dante-sync sync [--rate] [--exclude] [--dry-run] [--allow-band-up]`: leader first,
  wait for lock, then followers in parallel, each verified by heartbeat.
- `swift test`: packet builders and parsers are checked against bytes captured on this
  network.
- Not yet run for real: a live sync (status and dry-run only).

**Step 2 done (2026-10-17): the USB 16x16 follows and leads.** The USB 16x16 is the Pi's
UAC2 gadget bridged to the Inferno Dante device (repo `~/Development/USB 16x16`,
`work/dante-mode/SAMPLE_RATE_DESIGN.md`, "Transparent switching"; the operator decided
there that this app owns the Mac side and that the Mac decides the rate).
- The USB 16x16 is a CoreAudio target: `sync` sets its `NominalSampleRate` alongside the
  Dante followers, so the Pi gets its Dante `0x0081` set and its gadget's rate change as
  one change, and verifies by reading it back. Found by UID prefix
  `AppleUSBAudioEngine:Bryan DiMaio:USB 16x16:`. Today the gadget offers only 48k (the
  protected baseline), so any other rate reports it as failed with the reason; and the
  Inferno refuses anything but 48k until the Pi's arbiter exists.
- It is also a rate source (`--source usb16x16`): a DAW session on the USB 16x16 sets that
  device, not the Metric Halo. When the source is not the Metric Halo, the Metric Halo is
  set first (CoreAudio) and verified, because the Pulse locks to its MADI clock; if it does
  not change, nothing else is touched. `--leave-master` and `--no-usb` turn either off.
- `dante-sync watch [--dry-run]`: polls both CoreAudio devices four times a second and
  follows a change that holds for 2 s, the changed device being the source
  (`RateFollower`, tested: settle time, last change wins, the sync's own sets and a
  bounce-back within 5 s are reported, not followed, a device plugged in is not a change).
  Polling rather than a listener so a device that re-enumerates is found again without
  re-binding. This is the loop the menu-bar app will run.
- Checked read-only on 2026-10-17: `status` lists the USB 16x16 (48k, offers 48k) and the
  Inferno by heartbeat (48k); `sync --dry-run` plans both; `watch --dry-run` starts. `watch` not
  yet run live. Seen in passing: DVS and the D2USB at 44.1k while the Pulse, the MH and
  the Pi are at 48k (left from the manual 44.1k test).
- **First live sync (2026-10-17 03:56:55 UTC):** `dante-sync sync --rate 48000`, exit 0.
  Pulse already at 48k and word clock locked; DVS 44.1k → 48k verified by heartbeat after
  3.1 s, D2USB 44.1k → 48k after 0.8 s; Inferno and USB 16x16 already at 48k. `status`
  afterwards: every device 48k, Pulse LOCKED (state 3, stratum 41). The Pi's endpoint
  stayed up through it (start check still `ok`).
MenuBarExtra UI, settings (MH device picker, exclude list, timings), SyncCoordinator,
notifications, "Sync now", launch-at-login (`SMAppService`), log view.

### Phase 4 — Ship
Developer ID signing, hardened runtime, notarization, DMG, using the
macos-notarization skill. Entitlements: `com.apple.security.network.client`/`server`
if sandboxed (non-sandboxed is likely simpler for multicast/mDNS), and
`NSLocalNetworkUsageDescription` + `NSBonjourServices` in Info.plist (macOS 15+
local-network privacy prompt).

## Open questions for you
1. Which Mac will run this? Is it the one running DVS (Bryans-MacBook-Pro), and which
   network interface carries Dante?
2. ~~Is the Inferno USB 16x16 your own build? Should it follow, or go on the exclude list?~~
   Answered 2026-10-16: yes, and it follows (Dante side and USB side), and this app owns the
   Mac side of its rate changes.
3. Is the Dante Via device in use, and should it follow?
4. Do you want encoding (bit depth) to follow too, or rate only?

**88.2k settle on the USB 16x16 (2026-10-18).** On the Pi's multi-rate gadget, macOS
latches the USB 16x16's audio into zeros, both ways, when an app starts audio within a few
seconds of an 88.2k stream restart, and it stays that way until the rate is changed again
(USB 16x16 repo: `PROJECT_HANDOFF.md`, the 2026-10-18 FOUND entries, and
`work/pi-tuning/MULTIRATE_GADGET_PLAN.md`, "88.2 kHz and macOS"). The USB stream itself
stays correct; 44.1k, 48k and 96k are not affected. So:
- `sync` holds `--usb882-settle` seconds (default 10) after the USB 16x16 is verified at
  88.2k before it reports: start audio on it only after the sync finishes.
  `CoreAudioRate.settleTime` decides, tested in `SettleTimeTests`.
- `watch` cannot hold an app that set 88.2k itself, so it logs a warning with the recovery:
  stop audio, set 48k, wait 10 s, set 88.2k, wait 10 s, start audio.
- Checked: `swift test` (7 tests) and `sync --rate 88200 --dry-run`. The hold has not
  run live: a live 88.2k sync moves every Dante device a band up, and the Pi's Dante side
  still refuses anything but 48k.
