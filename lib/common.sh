# shellcheck shell=bash
# shellcheck disable=SC2088  # "~/..." is this project's logical "in $HOME" path prefix, expanded by resolve(), never by the shell.
# shellcheck disable=SC2034  # variables here are used by the scripts that source this file.
# Shared helpers for install.sh and uninstall.sh. Sourced, not executed.

PROJECT=charge6-airplay-stereo
MARK_BEGIN="# >>> ${PROJECT} >>>"
MARK_END="# <<< ${PROJECT} <<<"

# Started in this order; systemd sorts out the dependencies.
USER_UNITS=(snapfifo.service snapserver.service snapclient-left.service snapclient-right.service shairport-sync.service)

# Files this project owns. "~/" paths are in the user's home, "/" paths are system paths.
HOME_FILES=(
  "~/.config/shairport-sync/shairport-sync.conf"
  "~/.config/snapcast/snapserver.conf"
  "~/.config/wireplumber/wireplumber.conf.d/51-charge6-alsa-direct.conf"
  "~/.config/systemd/user/snapfifo.service"
  "~/.config/systemd/user/snapserver.service"
  "~/.config/systemd/user/snapclient-left.service"
  "~/.config/systemd/user/snapclient-right.service"
  "~/.config/systemd/user/shairport-sync.service"
)
SYSTEM_FILES=(
  "/etc/udev/rules.d/85-charge6-names.rules"
  "/etc/udev/rules.d/91-charge6-volume.rules"
)

DRY_RUN=0       # --dry-run: print what would happen, write nothing
STAGE=""        # --stage DIR: write files under DIR instead of / and $HOME, run no system commands
CHANGED=0       # set to 1 when any file was written or removed
LAST_CHANGED=0  # set by put_file/remove_file for the most recent call

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Call once, after option parsing.
set_paths() {
  if [[ -n $STAGE ]]; then
    mkdir -p "$STAGE"
    STAGE=$(cd "$STAGE" && pwd)
    T_HOME="$STAGE/home"
    T_ROOT="$STAGE/root"
  else
    T_HOME=$HOME
    T_ROOT=""
  fi
  RUNTIME_DIR="/run/user/$(id -u)"
  STATE_DIR="$T_HOME/.config/$PROJECT"
  BACKUP_DIR="$STATE_DIR/backup-$(date +%Y%m%d-%H%M%S)"
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
}

mode_name() { if (( DRY_RUN )); then echo "dry-run"; else echo "stage"; fi; }

# True when we may change the running system.
live() { (( DRY_RUN == 0 )) && [[ -z $STAGE ]]; }

# run CMD...: a command that changes the system. Skipped (printed) in dry-run/stage mode.
run() {
  if live; then
    info "+ $*"
    "$@"
  else
    info "[skipped: $(mode_name)] $*"
  fi
}

# Logical path ("~/..." or "/...") -> real path on disk (respects --stage).
resolve() {
  case $1 in
    "~/"*) printf '%s/%s' "$T_HOME" "${1#\~/}" ;;
    /*)    printf '%s%s' "$T_ROOT" "$1" ;;
    *)     die "internal: bad path $1" ;;
  esac
}

# True when writing this logical path needs sudo.
needs_sudo() { [[ $1 == /* && -z $STAGE ]]; }

backup() {
  local real=$1 logical=$2 rel
  rel=${logical#\~/}; rel=${rel#/}
  case $logical in "~/"*) rel="home/$rel" ;; *) rel="root/$rel" ;; esac
  mkdir -p "$(dirname "$BACKUP_DIR/$rel")"
  cp -p "$real" "$BACKUP_DIR/$rel"
  info "backed up  $logical -> $BACKUP_DIR/$rel"
}

# put_file SRC LOGICAL_DEST MODE: install SRC at DEST if the content differs.
# The old file, if any, is backed up first.
put_file() {
  local src=$1 dest=$2 mode=$3 real
  real=$(resolve "$dest")
  LAST_CHANGED=0
  if [[ -f $real ]] && cmp -s "$src" "$real"; then
    info "unchanged  $dest"
    return 0
  fi
  if (( DRY_RUN )); then
    if [[ -e $real ]]; then
      info "would update  $dest (the old file would be backed up). Diff:"
      diff -u "$real" "$src" | sed 's/^/        /' || true
    else
      info "would create  $dest"
    fi
    CHANGED=1
    LAST_CHANGED=1
    return 0
  fi
  if [[ -e $real ]]; then backup "$real" "$dest"; fi
  if needs_sudo "$dest"; then
    sudo install -D -m "$mode" "$src" "$real"
  else
    install -D -m "$mode" "$src" "$real"
  fi
  info "installed  $dest"
  CHANGED=1
  LAST_CHANGED=1
}

# remove_file LOGICAL: back up and delete a file, but only if it is one of ours
# (it mentions the project name). Anything else is left alone.
remove_file() {
  local dest=$1 real
  real=$(resolve "$dest")
  LAST_CHANGED=0
  [[ -e $real ]] || { info "not present  $dest"; return 0; }
  if ! grep -qF "$PROJECT" "$real"; then
    warn "$dest was not installed by $PROJECT, leaving it alone"
    return 0
  fi
  if (( DRY_RUN )); then info "would remove  $dest"; CHANGED=1; LAST_CHANGED=1; return 0; fi
  backup "$real" "$dest"
  if needs_sudo "$dest"; then sudo rm -f "$real"; else rm -f "$real"; fi
  info "removed  $dest"
  CHANGED=1
  LAST_CHANGED=1
}

# Print FILE without our marked block.
strip_block() {
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0 == b { s = 1; next } $0 == e { s = 0; next } !s' "$1"
}
