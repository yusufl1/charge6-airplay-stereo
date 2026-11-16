# TODO

Help with any of these is welcome. Open an issue or a pull request.

## Fix: `~/.asoundrc` gets deleted on desktop images

**Symptom:** after a reboot the speakers are silent, `~/.asoundrc` is gone, and
`journalctl --user -u snapclient-left` shows `Unknown PCM jbl_left`.

**What we know:**
- It happened twice on the tested Pi (Raspberry Pi OS desktop, trixie). Both
  times the file was already missing at the start of a boot.
- No user, script, cron job or sync tool removed it.
- The prime suspect is the desktop volume plugin, `wfplug-volumepulse` (version
  1.20 tested), which runs inside `wf-panel-pi` at every desktop login. It
  builds the path `$HOME/.asoundrc` and calls `remove()`. This hasn't been
  proven yet.

**Plan:**
- Confirm the cause: log in to the desktop with a test `~/.asoundrc` in place
  and watch it with `inotifywait`.
- Move the PCM definitions out of `~/.asoundrc` into a system-wide file the
  plugin doesn't touch, such as `/etc/alsa/conf.d/50-charge6-stereo.conf`.
  Check that the user services pick it up.
- Until then, the workaround is to run `./install.sh` again.

## Android: Google Cast

Android users can't AirPlay to this setup.

A real **Google Cast** target isn't realistic: Google only licenses the Cast
receiver to certified devices, and there is no open-source receiver that works
with current Android or Chrome senders.

Options to evaluate:
- **Spotify Connect** via [librespot](https://github.com/librespot-org/librespot),
  fed into Snapcast as a second stream. This already runs on the author's Pi
  but isn't in the repo yet. It works from any phone, Spotify only.
- **UPnP/DLNA renderer** (e.g. gmrender-resurrect or upmpdcli) as another
  Snapcast stream, with an Android app such as BubbleUPnP.
- **Music Assistant** or Home Assistant as a controller in front of Snapcast.

## Lossless Spotify Connect

Spotify has a lossless tier, but **lossless over Spotify Connect is only
allowed on certified devices**. An open-source receiver like librespot can't
get it and tops out at 320 kbps Ogg Vorbis. Options:
- Watch whether Spotify ever opens lossless Connect to uncertified receivers.
- Until then, Spotify on this setup (once added, see above) is 320 kbps lossy.
  Document that clearly.

## Video lip-sync

Snapcast's 1-second buffer is invisible to the AirPlay sender, so video is out
of sync. Look into shairport-sync's latency offset setting, or a smaller
Snapcast buffer, and measure the result.

## Unknowns to test and document

- Does a Charge 6 stay in USB audio mode after a power loss, or does it need
  the hold-Play gesture again?
- Battery behaviour on long USB playback: charging, holding, or slowly
  draining?
- Raspberry Pi OS Bookworm, Raspberry Pi OS Lite, Pi 4, and lower-RAM Pi 5
  models.
