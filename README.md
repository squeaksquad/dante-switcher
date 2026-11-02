# Dante Switcher

A macOS menu bar app that keeps a Dante network at the same sample rate as your Mac's audio
interface. Change the rate in your DAW or your interface's control app, and Dante Switcher moves
every Dante device to match: the clock leader first, waiting for it to lock, then everyone else,
each one checked afterwards.

The menu bar shows the network's rate (`48k`), with ⚠ when any device disagrees.

## What it does

- **Watches** the Dante network's heartbeats and the CoreAudio devices you pick as rate sources.
- **Follows** a rate change on any source (when Follow Rate Changes is on), or syncs on demand
  with Sync Now To ▸.
- **Orders the change:** a source that clocks the Dante leader (through MADI or word clock) is set
  first; then the Dante clock leader, waiting for it to lock; then the other Dante devices and
  sources together.
- **Speaks Dante natively** (no Dante Controller, no helper tools), including Dante Virtual
  Soundcard on the same Mac.

It never unlocks a device, and a device that doesn't follow is reported in the menu and the log,
not retried forever.

## Install

Download the latest `DanteSwitcher-<version>.pkg` from
[Releases](https://github.com/squeaksquad/dante-switcher/releases) and open it. It installs to
`/Applications` and starts the app. Requires macOS 14 or later, Apple silicon or Intel.

The first time, macOS asks to let Dante Switcher find devices on your local network: allow it,
or it hears no Dante devices (System Settings → Privacy & Security → Local Network). If the Dante
devices show `—` right after an install or update, quit the app and open it again.

The app checks GitHub for a newer release once a day and shows it in the menu.

## Set up

Open the menu and choose **Settings…**:

1. **Network interface:** the Mac's port on the Dante network.
2. **Clock leader:** the Dante device that leads the clock, or None to set every device at once.
3. **Rate sources:** the audio interfaces whose rate the network should follow. Turn on
   **Clocks Dante** for one that clocks the Dante leader.

Then turn on **Follow Rate Changes** in the menu. It's off until you do, because following moves
every device on the network.

## Command line

`dante-sync` (built from the same package) does the same from a shell:
`dante-sync status`, `dante-sync sync --dry-run`, `dante-sync watch`. Run it with `--help`.
Its sources are still the author's (a Metric Halo and a USB-AoIP); the app has no such defaults.

## Build

```sh
swift test
scripts/build_app.sh --install      # build/DanteSwitcher.app, signed, copied to /Applications
scripts/release.sh 0.3.0            # signed, notarized pkg (needs the author's certificates)
```

`build_app.sh` signs with the author's Developer ID; change `IDENTITY` to your own. Sign it with
something stable: macOS ties the local network permission to the signature.

`PLAN.md` is the design log: the Dante packets, what was measured on a real network, and why.

## License

GPL-3.0. See [LICENSE](LICENSE). Not affiliated with Audinate; Dante is a trademark of Audinate.
