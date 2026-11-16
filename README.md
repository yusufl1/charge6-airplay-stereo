# charge6-airplay-stereo

Turn two **JBL Charge 6** speakers into a **wired, 24-bit stereo pair** that you
play to with **AirPlay 2**, using a **Raspberry Pi 5**.

```
iPhone / iPad / Mac
        │  AirPlay 2 (Wi-Fi)
        ▼
┌──────────────── Raspberry Pi 5 ─────────────────┐
│ shairport-sync ──► FIFO ──► snapserver           │
│                               ├─► snapclient L ──┼── USB-C ──► Charge 6 (LEFT)
│                               └─► snapclient R ──┼── USB-C ──► Charge 6 (RIGHT)
└──────────────────────────────────────────────────┘
```

This project is a set of configs and an installer. It builds on
[shairport-sync](https://github.com/mikebrady/shairport-sync),
[nqptp](https://github.com/mikebrady/nqptp) and
[Snapcast](https://github.com/badaix/snapcast), and does not fork any of them.

## Why

The Charge 6 has a USB-C audio input: plug it into a computer and it shows up
as a USB sound card. That gives a clean digital signal, but JBL's own stereo
mode is Bluetooth only, the speakers have no AirPlay, and running two of them
from a laptop means a pile of dongles.

A Pi 5 fixes that. It receives AirPlay, splits the stereo signal, and feeds each
speaker its own channel over USB:

- **Wired digital stereo.** Each speaker plays one channel (left or right) on
  both of its drivers, at 24-bit / 48 kHz, the best the Charge 6 accepts over
  USB.
- **AirPlay 2.** It shows up as a normal AirPlay speaker on iPhone, iPad and
  Mac, with working volume control.
- **Hands-off.** It starts by itself at boot, and the speakers are still
  portable: unplug one and it's a normal JBL again.

About "lossless": the USB link to the speakers is lossless. AirPlay itself is
lossless only when the sending app sends lossless (Apple Music can, as ALAC);
many apps send AAC. shairport-sync converts everything to 48 kHz because that
is the only rate the speakers accept.

## Supported setup

| | Tested | Untested (may work) |
|---|---|---|
| Board | Raspberry Pi 5 (8 GB) | Other Pi 5 RAM sizes, Pi 4 |
| OS | Raspberry Pi OS based on Debian 13 "trixie" (image of 2026-10-06), 64-bit | Bookworm (installer warns), Raspberry Pi OS Lite |
| Speakers | 2 x JBL Charge 6 | Other JBL models with USB audio |
| Software | shairport-sync 5.6.2, nqptp 1.2.9, Snapcast 0.31.0, PipeWire 1.4.2, WirePlumber 0.5.8 | |

Anything not in the "Tested" column is untested. Reports are welcome.

## Hardware

- Raspberry Pi 5 with the official 27 W USB-C power supply. With a weaker
  supply the Pi limits the current on its USB ports.
- 2 x JBL Charge 6.
- A **powered** USB hub. The tested setup uses a UGREEN powered hub, so the
  speakers' USB power doesn't come from the Pi.
- 2 x USB-C cables (speaker to hub).
- A microSD card or NVMe drive for the OS.

### Wiring

```
Pi 5 USB port ──► powered USB hub ──┬──► USB-C ──► Charge 6 #1  (placed LEFT)
                                     └──► USB-C ──► Charge 6 #2  (placed RIGHT)
```

Any port works. Left and right are tied to each speaker's **USB serial number**,
not to a port, so you can swap cables freely. During install you choose which
speaker is left (see Quick start).

## Put the Charge 6 in USB audio mode

Do this for each speaker:

1. Turn the speaker off.
2. **Hold the Play button while you plug in the USB-C cable.**
3. Check that the Pi sees it: `aplay -l` should list a card called `JBL Charge 6`.

Also **unlink the two speakers from each other** (Bluetooth stereo pair or
Auracast party mode). When they were still linked, the sound in testing
echoed and was lopsided.

**After a reboot or power loss:** the Pi side comes back by itself (services
start at boot, and the udev rules restore card names and volume). Whether the
speaker itself stays in USB audio mode after it loses power has **not been
tested yet**. If a speaker goes quiet after a power cut, repeat the steps
above. Please open an issue with what you see.

## Quick start

On the Pi, as your normal user (not root):

```bash
git clone https://github.com/yusufl1/charge6-airplay-stereo.git
cd charge6-airplay-stereo
./install.sh --dry-run          # optional: shows exactly what it would change
./install.sh --name "Living Room Stereo"
```

The installer:

1. Checks that it's a Pi 5 running a supported OS.
2. Finds both speakers, plays a short tone on one, and asks if that's the
   left one.
3. Installs the packages. With `--shairport source` (the default) it builds
   shairport-sync 5.6.2 and nqptp 1.2.9 from upstream for AirPlay 2, which takes
   a few minutes. With `--shairport apt` it uses Debian's package instead,
   which is quicker; the installer warns you if that build is AirPlay 1 only.
4. Copies the configs, backs up any file it replaces, and enables the services.

Then pick your AirPlay name on your phone and play something.

Already know the serials? Skip the question:

```bash
./install.sh --left-serial XXXXXX-XXXXXXXXXX --right-serial YYYYYY-YYYYYYYYYY
```

Running `install.sh` again is safe: unchanged files are left alone. Run it
again after changing `--name`, or to swap left and right with new
`--left-serial` / `--right-serial` values.

To remove everything: `./uninstall.sh` (add `--remove-binaries` to also delete
the shairport-sync and nqptp builds in `/usr/local`).

### What gets installed

| File | Purpose |
|---|---|
| `~/.config/shairport-sync/shairport-sync.conf` | AirPlay receiver, outputs 48 kHz / 24-bit into a FIFO |
| `~/.config/snapcast/snapserver.conf` | Reads the FIFO and serves it to the two clients (local only, 127.0.0.1) |
| `~/.asoundrc` (marked block) | `jbl_left` / `jbl_right` ALSA devices, one per speaker |
| `~/.config/wireplumber/wireplumber.conf.d/51-charge6-alsa-direct.conf` | Keeps PipeWire off the speakers |
| `~/.config/systemd/user/{snapfifo,snapserver,snapclient-left,snapclient-right,shairport-sync}.service` | User services, started at boot (lingering) |
| `/etc/udev/rules.d/85-charge6-names.rules` | Names the cards `JBL_LEFT` / `JBL_RIGHT` by USB serial |
| `/etc/udev/rules.d/91-charge6-volume.rules` | Sets the speaker's hardware volume to 100% when plugged in |
| `/usr/local/bin/{shairport-sync,nqptp}` + `nqptp.service` | Only with `--shairport source` |

## How L/R sync and clock drift are handled

Two separate USB sound cards normally drift apart, because each has its own
clock. This setup avoids that in two ways:

1. **Both speakers run on the Pi's clock.** The Charge 6 uses an *adaptive* USB
   audio endpoint: it follows the pace at which the host sends samples instead
   of running its own clock. Both speakers are fed by the same Pi, so they play
   samples at the same rate and can't drift against each other.
2. **Snapcast keeps the two streams aligned.** One snapserver sends the same
   timestamped audio to two snapclients, one per speaker. Both clients follow
   the server's clock and play each chunk at its scheduled time, correcting
   any small offset as they go. This keeps the left and right speakers in step
   across track changes, pauses and restarts.

The clients run with real-time scheduling (`CPUSchedulingPolicy=fifo`) so other
load on the Pi doesn't cause dropouts.

Why not a PipeWire combine-sink? That was tried first. The two speakers kept
slipping about one buffer period apart. Driving each speaker straight through
ALSA, with Snapcast handling the timing, was steadier.

## Power and battery

- The hub powers the speakers over USB-C while they play.
- The installer pins the speaker's hardware volume at 100% whenever it is
  plugged in (it falls back to about 66% each time it reconnects). You control
  loudness with the AirPlay slider.
- **Long-term battery behaviour on USB audio has not been measured yet.** It's
  unknown whether the Charge 6 keeps its battery topped up, holds it, or slowly
  drains it during long USB playback. Please share what you find (see
  [TODO.md](TODO.md)).

## Known limitations

- **AirPlay only.** No Android casting yet, and no Spotify Connect in this repo
  (see [TODO.md](TODO.md)).
- **For music, not video.** Snapcast adds a 1-second buffer that iOS doesn't
  know about, so expect video lip-sync to be off.
- **48 kHz only.** The speakers accept nothing else, so 44.1 kHz sources are
  resampled. Hi-res (96/192 kHz) isn't possible over this link.
- **`~/.asoundrc` can disappear on desktop images.** On the tested Pi it was
  deleted twice, apparently by the desktop's volume panel plugin when you log
  in. When that happens the speakers go silent. Fix: run `./install.sh` again.
  A proper fix is on the [TODO list](TODO.md).
- **One pair, one Pi.** The configs assume exactly two Charge 6 speakers.
- **Snapweb is local only.** The Snapcast web UI listens on 127.0.0.1:1780. Use
  an SSH tunnel to see it: `ssh -L 1780:127.0.0.1:1780 <pi>`.

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Contributing

Issues and pull requests are welcome, especially test reports from other
hardware or OS versions. `main` is protected, so changes go in through pull
requests. Please run `shellcheck -x install.sh uninstall.sh lib/common.sh`
before opening one; CI runs it too.

## License

[MIT](LICENSE), covering the files in this repository only. shairport-sync,
nqptp and Snapcast are separate projects with their own licenses; the installer
downloads or installs them, it doesn't include them.

JBL and Charge 6 are trademarks of Harman International. AirPlay is a trademark
of Apple Inc. This project is not affiliated with either.
