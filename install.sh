#!/usr/bin/env bash
# install.sh: turn two JBL Charge 6 speakers on USB-C into an AirPlay stereo
# pair driven by a Raspberry Pi 5. Safe to run more than once. See README.md.
# shellcheck disable=SC2088  # "~/..." is this project's logical "in $HOME" path prefix, expanded by resolve(), never by the shell.
set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"

SHAIRPORT_TAG=5.6.2
NQPTP_TAG=1.2.9
JBL_VENDOR=0ecb
JBL_PRODUCT="JBL Charge 6"

AIRPLAY_NAME="Charge 6 Stereo"
LEFT_SERIAL=""
RIGHT_SERIAL=""
SHAIRPORT_FROM=source
FORCE=0
CODENAME=""

usage() {
  cat <<EOF
Usage: ./install.sh [options]

Sets up shairport-sync (AirPlay) -> Snapcast -> two JBL Charge 6 speakers on USB,
one playing the left channel and one the right.

Options:
  --name NAME            AirPlay name shown on your phone (default: "$AIRPLAY_NAME")
  --left-serial SERIAL   USB serial of the LEFT speaker  } detected and asked for
  --right-serial SERIAL  USB serial of the RIGHT speaker } if you leave these out
  --shairport source|apt Build shairport-sync $SHAIRPORT_TAG + nqptp $NQPTP_TAG from source
                         (default, AirPlay 2), or use the Debian package (quicker; the
                         script tells you if that build is AirPlay 1 only)
  --dry-run              Show what would change, change nothing
  --stage DIR            Write all files under DIR (DIR/home, DIR/root) and run no
                         system commands. For testing the installer.
  --force                Continue on hardware/OS this was not tested on
  -h, --help             Show this help
EOF
}

while (( $# )); do
  case $1 in
    --name)         AIRPLAY_NAME=${2:?--name needs a value}; shift 2 ;;
    --left-serial)  LEFT_SERIAL=${2:?--left-serial needs a value}; shift 2 ;;
    --right-serial) RIGHT_SERIAL=${2:?--right-serial needs a value}; shift 2 ;;
    --shairport)    SHAIRPORT_FROM=${2:?--shairport needs source or apt}; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --stage)        STAGE=${2:?--stage needs a directory}; shift 2 ;;
    --force)        FORCE=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown option: $1 (see --help)" ;;
  esac
done

case $SHAIRPORT_FROM in
  source) SHAIRPORT_BIN=/usr/local/bin/shairport-sync ;;
  apt)    SHAIRPORT_BIN=/usr/bin/shairport-sync ;;
  *)      die "--shairport must be 'source' or 'apt'" ;;
esac
[[ -n $AIRPLAY_NAME && $AIRPLAY_NAME != *[\"\\]* ]] || die "--name must not be empty or contain \" or \\"

# ---------------------------------------------------------------- checks

check_platform() {
  log "Checking hardware and OS"
  (( EUID != 0 )) || die "Run this as your normal user, not root. It uses sudo where it needs to."
  local model="unknown"
  [[ -r /proc/device-tree/model ]] && model=$(tr -d '\0' </proc/device-tree/model)
  if [[ $model == "Raspberry Pi 5"* ]]; then
    info "hardware: $model"
  elif (( FORCE )); then
    warn "hardware is '$model', not a Raspberry Pi 5. Untested, continuing because of --force."
  else
    die "hardware is '$model', not a Raspberry Pi 5. Use --force to try anyway (untested)."
  fi
  # shellcheck disable=SC1091
  CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")
  case $CODENAME in
    trixie)   info "OS: Debian/Raspberry Pi OS $CODENAME (tested)" ;;
    bookworm) warn "OS is $CODENAME. This setup was tested on trixie; bookworm should work but is untested." ;;
    *)        (( FORCE )) || die "OS is '$CODENAME'. Only Raspberry Pi OS trixie is tested. Use --force to try anyway."
              warn "OS is '$CODENAME'. Untested, continuing because of --force." ;;
  esac
  command -v sudo >/dev/null || die "sudo is required"
}

# Fills SPK_SERIALS / SPK_CARDS with every Charge 6 that is in USB audio mode.
detect_speakers() {
  SPK_SERIALS=()
  SPK_CARDS=()
  local c dev
  for c in /sys/class/sound/card[0-9]*; do
    [[ -e $c/device ]] || continue
    dev=$(readlink -f "$c/device/..")
    [[ -r $dev/idVendor && $(<"$dev/idVendor") == "$JBL_VENDOR" ]] || continue
    [[ -r $dev/product && $(<"$dev/product") == "$JBL_PRODUCT" ]] || continue
    [[ -r $dev/serial ]] || continue
    SPK_SERIALS+=("$(<"$dev/serial")")
    SPK_CARDS+=("${c##*/card}")
  done
}

# Serials from a previous run, so re-running does not ask again.
serials_from_existing_rule() {
  local rule
  rule=$(resolve /etc/udev/rules.d/85-charge6-names.rules)
  [[ -r $rule ]] || return 0
  [[ -n $LEFT_SERIAL ]] || LEFT_SERIAL=$(sed -n 's/.*ATTRS{serial}=="\([^"]*\)".*ATTR{id}="JBL_LEFT".*/\1/p' "$rule")
  [[ -n $RIGHT_SERIAL ]] || RIGHT_SERIAL=$(sed -n 's/.*ATTRS{serial}=="\([^"]*\)".*ATTR{id}="JBL_RIGHT".*/\1/p' "$rule")
}

choose_sides() {
  log "Finding the speakers"
  serials_from_existing_rule
  if [[ -n $LEFT_SERIAL && -n $RIGHT_SERIAL ]]; then
    [[ $LEFT_SERIAL != "$RIGHT_SERIAL" ]] || die "left and right serial are the same"
    info "left:  $LEFT_SERIAL"
    info "right: $RIGHT_SERIAL"
    return 0
  fi
  detect_speakers
  if (( ${#SPK_SERIALS[@]} != 2 )); then
    die "found ${#SPK_SERIALS[@]} Charge 6 in USB audio mode (${SPK_SERIALS[*]:-none}), need exactly 2.
       Put each speaker in USB audio mode (README: 'USB audio mode'), or pass
       --left-serial and --right-serial."
  fi
  if [[ -n $LEFT_SERIAL || -n $RIGHT_SERIAL ]]; then
    local known=${LEFT_SERIAL:-$RIGHT_SERIAL} other
    if [[ $known == "${SPK_SERIALS[0]}" ]]; then other=${SPK_SERIALS[1]}
    elif [[ $known == "${SPK_SERIALS[1]}" ]]; then other=${SPK_SERIALS[0]}
    else die "serial $known is not one of the connected speakers: ${SPK_SERIALS[*]}"; fi
    if [[ -n $LEFT_SERIAL ]]; then RIGHT_SERIAL=$other; else LEFT_SERIAL=$other; fi
  elif live && [[ -t 0 ]]; then
    info "A test tone will play on ONE speaker for a few seconds."
    speaker-test -D "plughw:${SPK_CARDS[0]},0" -c 2 -t sine -f 440 -l 1 >/dev/null 2>&1 \
      || warn "could not play the test tone (is something else using the speaker?)"
    local answer
    read -r -p "    Did the speaker you want on the LEFT just play? [y/n] " answer
    if [[ $answer == [yY]* ]]; then
      LEFT_SERIAL=${SPK_SERIALS[0]}; RIGHT_SERIAL=${SPK_SERIALS[1]}
    else
      LEFT_SERIAL=${SPK_SERIALS[1]}; RIGHT_SERIAL=${SPK_SERIALS[0]}
    fi
  elif ! live; then
    LEFT_SERIAL=${SPK_SERIALS[0]}; RIGHT_SERIAL=${SPK_SERIALS[1]}
    warn "$(mode_name): assuming ${LEFT_SERIAL} is LEFT. A real run asks you (or pass --left-serial/--right-serial)."
  else
    die "pass --left-serial and --right-serial. Connected speakers: ${SPK_SERIALS[*]}"
  fi
  info "left:  $LEFT_SERIAL"
  info "right: $RIGHT_SERIAL"
}

# A conflict stops the install (unless --force). In --dry-run it is only reported.
conflict() {
  if (( FORCE )); then warn "$* (continuing because of --force)"
  elif (( DRY_RUN )); then warn "$* (a real install would stop here)"
  else die "$*"; fi
}

check_conflicts() {
  log "Checking for conflicting configuration"
  local f ours found=0
  ours=$(resolve /etc/udev/rules.d/85-charge6-names.rules)
  for f in "$(resolve /etc/udev/rules.d)"/*.rules; do
    [[ -e $f && $f != "$ours" ]] || continue
    if grep -v '^[[:space:]]*#' "$f" | grep -qF -e "$LEFT_SERIAL" -e "$RIGHT_SERIAL"; then
      conflict "udev rule $f already matches your speakers and would fight over the card names.
       Back it up and remove it, then run this again."
      found=1
    fi
  done
  local asrc
  asrc=$(resolve "~/.asoundrc")
  if [[ -f $asrc ]] && strip_block "$asrc" | grep -qE '^[[:space:]]*pcm[.]jbl_(left|right)(_route)?[[:space:]]*[{]'; then
    conflict "~/.asoundrc already defines pcm.jbl_left/jbl_right outside the $PROJECT block.
       Back it up and remove those definitions, then run this again."
    found=1
  fi
  local u
  for u in "${USER_UNITS[@]}"; do
    if [[ -d $(resolve "~/.config/systemd/user/$u.d") ]]; then
      warn "~/.config/systemd/user/$u.d exists; its drop-ins still apply on top of this setup"
    fi
  done
  (( found )) || info "no conflicts"
}

# ---------------------------------------------------------------- packages

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }
apt_has()       { apt-cache show "$1" >/dev/null 2>&1; }

# True when the pinned upstream version is already built and installed.
shairport_built() {
  local v=""
  [[ -x /usr/local/bin/shairport-sync ]] && v=$(/usr/local/bin/shairport-sync -V 2>/dev/null || true)
  [[ $v == "$SHAIRPORT_TAG"-AirPlay2-* ]]
}
nqptp_built() {
  local v=""
  [[ -x /usr/local/bin/nqptp ]] && v=$(/usr/local/bin/nqptp -V 2>&1 || true)
  [[ $v == "Version: $NQPTP_TAG."* ]]
}

# True when something has to be compiled, so the build tools are needed.
needs_build() {
  if [[ $SHAIRPORT_FROM == source ]]; then
    ! shairport_built || ! nqptp_built
  else
    ! apt_has nqptp && ! nqptp_built
  fi
}

install_packages() {
  log "Installing packages"
  local pkgs=(snapserver snapclient alsa-utils avahi-daemon) missing=() p
  if [[ $SHAIRPORT_FROM == apt ]]; then
    pkgs+=(shairport-sync)
    if apt_has nqptp; then pkgs+=(nqptp); fi
  fi
  if needs_build; then
    # From shairport-sync's BUILD.md (AirPlay 2) plus nqptp's needs.
    pkgs+=(build-essential git autoconf automake libtool libpopt-dev libconfig-dev
           libasound2-dev libavahi-client-dev libssl-dev libsoxr-dev libplist-dev
           libsodium-dev uuid-dev libgcrypt20-dev xxd libplist-utils libavutil-dev
           libavcodec-dev libavformat-dev)
    [[ $CODENAME == bookworm ]] || pkgs+=(systemd-dev)
  else
    info "shairport-sync/nqptp builds are already installed, so no build tools are needed"
  fi
  for p in "${pkgs[@]}"; do pkg_installed "$p" || missing+=("$p"); done
  if (( ${#missing[@]} == 0 )); then
    info "all packages already installed"
    return 0
  fi
  info "missing: ${missing[*]}"
  run sudo apt-get update
  run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
}

# The Debian packages start their own system-wide services. They would grab the
# same ports and the same AirPlay name, so turn them off. Our copies run as user services.
disable_system_services() {
  log "Disabling the packages' system-wide services"
  local u
  for u in snapserver.service snapclient.service shairport-sync.service; do
    if systemctl is-enabled --quiet "$u" 2>/dev/null || systemctl is-active --quiet "$u" 2>/dev/null; then
      run sudo systemctl disable --now "$u"
    else
      info "$u: not enabled"
    fi
  done
}

build_upstream() {
  local name=$1 tag=$2; shift 2
  local src="$T_HOME/.cache/$PROJECT/src/$name"
  if ! live; then
    info "[skipped: $(mode_name)] clone github.com/mikebrady/$name at $tag, ./configure $*, make, sudo make install"
    return 0
  fi
  rm -rf "$src"
  mkdir -p "$(dirname "$src")"
  info "+ git clone --depth 1 --branch $tag https://github.com/mikebrady/$name.git"
  git clone --quiet --depth 1 --branch "$tag" "https://github.com/mikebrady/$name.git" "$src"
  info "+ autoreconf -fi && ./configure $* && make"
  (cd "$src" && autoreconf -fi >/dev/null 2>&1 && ./configure "$@" >/dev/null && make -j"$(nproc)" >/dev/null)
  info "+ sudo make install"
  (cd "$src" && sudo make install >/dev/null)
}

install_shairport() {
  log "Installing shairport-sync ($SHAIRPORT_FROM)"
  if [[ $SHAIRPORT_FROM == source ]]; then
    if shairport_built; then
      info "shairport-sync $SHAIRPORT_TAG with AirPlay 2 already installed"
    else
      build_upstream shairport-sync "$SHAIRPORT_TAG" \
        --sysconfdir=/etc --with-alsa --with-pipe --with-soxr --with-avahi --with-ssl=openssl --with-airplay-2
    fi
  fi
  if live; then
    [[ -x $SHAIRPORT_BIN ]] || die "$SHAIRPORT_BIN not found after install"
    local version
    version=$("$SHAIRPORT_BIN" -V 2>/dev/null || true)
    info "shairport-sync: $version"
    [[ $version == *-pipe-* || $version == *-pipe ]] || die "this shairport-sync was built without the pipe backend, which this setup needs"
    [[ $version == *AirPlay2* ]] || warn "this shairport-sync is classic AirPlay (AirPlay 1) only. It works, but
         without AirPlay 2 (multi-room, Siri). Use --shairport source for AirPlay 2."
  fi
}

install_nqptp() {
  # nqptp is the timing companion AirPlay 2 needs.
  if [[ $SHAIRPORT_FROM == apt ]] && pkg_installed nqptp; then
    info "nqptp installed from apt"
  elif [[ $SHAIRPORT_FROM == apt ]] && apt_has nqptp && ! live; then
    info "nqptp will come from apt"
  else
    log "Installing nqptp $NQPTP_TAG from source"
    if nqptp_built; then
      info "nqptp $NQPTP_TAG already installed"
    else
      build_upstream nqptp "$NQPTP_TAG" --with-systemd-startup
    fi
  fi
  if live && systemctl is-enabled --quiet nqptp 2>/dev/null && systemctl is-active --quiet nqptp; then
    info "nqptp.service enabled and running"
  else
    run sudo systemctl enable --now nqptp
  fi
}

# ---------------------------------------------------------------- files

declare -A SUBST

render() {
  local tpl=$1 out=$2 content key
  content=$(<"$tpl")
  for key in "${!SUBST[@]}"; do
    content=${content//"@${key}@"/"${SUBST[$key]}"}
  done
  printf '%s\n' "$content" >"$out"
  if grep -qE '@[A-Z_]+@' "$out"; then die "internal: unfilled placeholder in $tpl"; fi
}

install_asound_block() {
  local real new="$WORK/asoundrc"
  real=$(resolve "~/.asoundrc")
  : >"$new"
  if [[ -f $real ]]; then
    strip_block "$real" >"$new"
    # Keep a newline between the user's own content and our block.
    if [[ -s $new && -n $(tail -c1 "$new") ]]; then echo >>"$new"; fi
  fi
  { printf '%s\n' "$MARK_BEGIN"; cat "$REPO_DIR/config/asoundrc"; printf '%s\n' "$MARK_END"; } >>"$new"
  put_file "$new" "~/.asoundrc" 644
}

install_files() {
  log "Installing configuration"
  SUBST=(
    [AIRPLAY_NAME]=$AIRPLAY_NAME
    [RUNTIME_DIR]=$RUNTIME_DIR
    [SNAP_DATA_DIR]="$HOME/.local/share/snapserver"
    [SHAIRPORT_BIN]=$SHAIRPORT_BIN
    [LEFT_SERIAL]=$LEFT_SERIAL
    [RIGHT_SERIAL]=$RIGHT_SERIAL
  )
  local u
  render "$REPO_DIR/config/shairport-sync.conf.in" "$WORK/shairport-sync.conf"
  put_file "$WORK/shairport-sync.conf" "~/.config/shairport-sync/shairport-sync.conf" 644

  render "$REPO_DIR/config/snapserver.conf.in" "$WORK/snapserver.conf"
  put_file "$WORK/snapserver.conf" "~/.config/snapcast/snapserver.conf" 644
  (( DRY_RUN )) || mkdir -p "$(resolve "~/.local/share/snapserver")"

  install_asound_block

  put_file "$REPO_DIR/config/51-charge6-alsa-direct.conf" "~/.config/wireplumber/wireplumber.conf.d/51-charge6-alsa-direct.conf" 644
  WIREPLUMBER_CHANGED=$LAST_CHANGED

  for u in snapfifo snapserver snapclient-left snapclient-right; do
    put_file "$REPO_DIR/systemd/$u.service" "~/.config/systemd/user/$u.service" 644
  done
  render "$REPO_DIR/systemd/shairport-sync.service.in" "$WORK/shairport-sync.service"
  put_file "$WORK/shairport-sync.service" "~/.config/systemd/user/shairport-sync.service" 644

  UDEV_CHANGED=0
  render "$REPO_DIR/udev/85-charge6-names.rules.in" "$WORK/85-charge6-names.rules"
  put_file "$WORK/85-charge6-names.rules" /etc/udev/rules.d/85-charge6-names.rules 644
  (( LAST_CHANGED )) && UDEV_CHANGED=1
  put_file "$REPO_DIR/udev/91-charge6-volume.rules" /etc/udev/rules.d/91-charge6-volume.rules 644
  (( LAST_CHANGED )) && UDEV_CHANGED=1
  return 0
}

# ---------------------------------------------------------------- activate

activate() {
  log "Enabling services"
  if id -nG | tr ' ' '\n' | grep -qx audio; then
    info "$USER is in the audio group"
  else
    run sudo usermod -aG audio "$USER"
    warn "added $USER to the audio group. Log out and back in (or reboot) before testing."
  fi
  # Lingering starts the user services at boot, without anyone logging in.
  if [[ $(loginctl show-user "$USER" -p Linger --value 2>/dev/null) == yes ]]; then
    info "lingering already enabled for $USER"
  else
    run sudo loginctl enable-linger "$USER"
  fi
  if (( UDEV_CHANGED )); then
    run sudo udevadm control --reload-rules
    # Re-apply the rules to speakers that are already plugged in, so they get
    # their new names without unplugging them.
    run sudo udevadm trigger --action=add --subsystem-match=sound --sysname-match='card*'
    run sudo udevadm settle
  fi
  if (( WIREPLUMBER_CHANGED )) && { ! live || systemctl --user is-active --quiet wireplumber; }; then
    run systemctl --user restart wireplumber
  fi
  run systemctl --user daemon-reload
  run systemctl --user enable "${USER_UNITS[@]}"
  if (( CHANGED )); then
    run systemctl --user restart "${USER_UNITS[@]}"
  else
    run systemctl --user start "${USER_UNITS[@]}"
  fi
  if live && ! [[ -e /proc/asound/JBL_LEFT && -e /proc/asound/JBL_RIGHT ]]; then
    warn "the speakers don't have their new names (JBL_LEFT / JBL_RIGHT) yet.
         Check both are in USB audio mode, then unplug and replug them, or reboot."
  fi
}

main() {
  set_paths
  check_platform
  choose_sides
  check_conflicts
  install_packages
  install_shairport
  install_nqptp
  disable_system_services
  install_files
  activate
  echo
  if (( DRY_RUN )); then
    log "Dry run finished. Nothing was changed."
  elif [[ -n $STAGE ]]; then
    log "Staged install finished. Files are under $STAGE (nothing on this system was changed)."
  else
    log "Done. On your iPhone, iPad or Mac, pick \"$AIRPLAY_NAME\" as the AirPlay output."
    if [[ -d $BACKUP_DIR ]]; then info "Files that were replaced are backed up in $BACKUP_DIR"; fi
  fi
}

main
