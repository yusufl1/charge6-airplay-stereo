# Troubleshooting

Check the state of everything first:

```bash
systemctl --user status snapfifo snapserver snapclient-left snapclient-right shairport-sync
systemctl status nqptp
cat /proc/asound/cards        # expect JBL_LEFT and JBL_RIGHT
journalctl --user -u shairport-sync -u snapserver -u snapclient-left -u snapclient-right -n 50
```

## The AirPlay speaker doesn't show up on my phone

- `shairport-sync` and `nqptp` must both be running (commands above). AirPlay 2
  needs `nqptp`.
- The phone and the Pi must be on the same network, and mDNS must be able to
  pass between them. Guest networks and "client isolation" often block it.
- `avahi-daemon` must be running: `systemctl status avahi-daemon`.
- A firewall must allow UDP ports 319 and 320 (nqptp) and the AirPlay ports.
- If you used `--shairport apt`, check the installer output: an AirPlay 1-only
  build still shows up, but some apps prefer AirPlay 2 devices.

## It connects, but there's no sound

1. **`Unknown PCM jbl_left`** in the snapclient log: `~/.asoundrc` is missing
   or lost the project's block. Run `./install.sh` again. See the known issue
   in [TODO.md](../TODO.md); desktop images can delete this file.
2. **`/proc/asound/cards` has no `JBL_LEFT` / `JBL_RIGHT`:**
   - Is each speaker in USB audio mode? Check with `aplay -l`; see the README.
   - Right after an install, unplug and replug both speakers (or reboot) so the
     udev rule names them.
   - Check that the serials in `/etc/udev/rules.d/85-charge6-names.rules` match
     the speakers:
     `udevadm info -a /sys/class/sound/cardN | grep 'ATTRS{serial}'`.
3. **`Device or resource busy`:** something else has the speaker open, usually
   PipeWire. Make sure
   `~/.config/wireplumber/wireplumber.conf.d/51-charge6-alsa-direct.conf`
   exists, then run `systemctl --user restart wireplumber`.
4. **The services don't start after a reboot until you log in:** lingering is
   off. Run `sudo loginctl enable-linger $USER`.

## A service fails with `status=214/SETSCHEDULER`

Your system doesn't allow real-time scheduling for user services. Override it:

```bash
for u in snapserver snapclient-left snapclient-right; do
  mkdir -p ~/.config/systemd/user/$u.service.d
  printf '[Service]\nCPUSchedulingPolicy=other\nCPUSchedulingPriority=\n' \
    > ~/.config/systemd/user/$u.service.d/no-rt.conf
done
systemctl --user daemon-reload
systemctl --user restart snapserver snapclient-left snapclient-right
```

## Left and right are swapped

Run the installer again with the serials the other way round:

```bash
./install.sh --left-serial <serial of the speaker on your left> --right-serial <the other one>
```

Then unplug and replug both speakers. List the serials with
`cat /sys/class/sound/card*/device/../serial`.

## Echo, or one side louder or late

- Unlink the speakers from each other in the JBL app (Bluetooth stereo pair or
  Auracast party mode). Linked speakers caused echo and lopsided sound in
  testing.
- Make sure Bluetooth isn't connected to either speaker at the same time.

## It's too quiet

The Charge 6 resets its hardware volume (to about 66%) every time it
reconnects. `91-charge6-volume.rules` sets it back to 100%. Check it:

```bash
amixer -c JBL_LEFT sget PCM
amixer -c JBL_RIGHT sget PCM
```

If it isn't at 100%, run `amixer -c JBL_LEFT sset PCM 100%` (and the same for
`JBL_RIGHT`), and check that the rule file exists.

## Dropouts or crackles

- Use a powered USB hub and the official 27 W power supply.
- Look for `xrun` or `underrun` in the snapclient logs.
- Check the Pi isn't overheating or throttling: `vcgencmd get_throttled`
  should print `throttled=0x0`.

## The installer stops with a conflict

The installer won't overwrite a setup it didn't create:

- **"udev rule ... already matches your speakers":** an older rule names the
  same speakers. Back it up, delete it, and run again.
- **"~/.asoundrc already defines pcm.jbl_left/jbl_right":** remove those
  definitions (back up first), then run again.

Use `./install.sh --dry-run` to see every change before it happens.
