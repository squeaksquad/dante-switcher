# Draft issue for chris-ritsen/network-audio-controller (not posted)

**Title:** Sample-rate changes to Dante Virtual Soundcard (macOS) time out: settings sent to 8700, DVS listens on 38700

**Environment**
- netaudio 0.4.2 (PyPI wheel, macOS arm64), Python 3.14
- Dante Virtual Soundcard 4.5.2.3 on macOS (`model_id` DvsMacOs, router 4.4.0, arcp 2.8.15), Dante Controller on the same Mac
- `--interface en12` (Dante NIC)

**What happens**
```
netaudio --interface en12 --verify -n <dvs> device config sample-rate 44100 --confirm-destructive
<dvs>  Refused  sample rate readback timed out for 169.254.26.52
```
Hardware devices on the same network (Turtle AV D2USB, Ferrofish Pulse 16 DX) change rate and verify fine.

**Cause (as far as I can tell)**
DVS runs its control services on ports offset by +30000:
```
conmon_server -b=38700 -c=38800 -p=38900 ... -omd=DvsMacOs
```
and advertises `_netaudio-cmc._udp` on 38800. When Dante Controller changes DVS's
rate, it sends from port 8700 to **DVS:38700**:
```
ffff0028 1282 0000 4cea4163338f 0000 "Audinate" 073e 0081 00000064 00000001 0000ac44   # 44100
ffff0028 128f 0000 4cea4163338f 0000 "Audinate" 073e 0081 00000064 00000001 0000bb80   # 48000
```
(The 6-byte field is the controller's MAC. Here the controller and DVS share a NIC.)
netaudio's `settings_port` for DVS stays `None` (in `device list -j`), so settings
requests fall back to 8700 and get no answer.

**Suggestion**
When CMC registration doesn't yield control addresses, derive the settings port from the
advertised CMC port (`cmc_port - 100`, i.e. 38800 → 38700), or special-case `DvsMacOs`.

**Also seen:** `Invalid dante_model / make_model / lock-reset status response` warnings
for DVS 4.5.2.3 (hex payloads available).

A pcap of Dante Controller changing DVS 48k → 44.1k → 48k is available.
