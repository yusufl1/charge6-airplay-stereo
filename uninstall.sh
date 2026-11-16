#!/usr/bin/env bash
# uninstall.sh: remove what install.sh set up. Every removed file is backed up first.
# Packages (snapserver, snapclient, ...) are left installed; see the hint at the end.
# shellcheck disable=SC2088  # "~/..." is this project's logical "in $HOME" path prefix, expanded by resolve(), never by the shell.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"

REMOVE_BINARIES=0

usage() {
  cat <<EOF
Usage: ./uninstall.sh [options]

  --remove-binaries  Also stop nqptp and delete the shairport-sync and nqptp
                     binaries that install.sh built into /usr/local
  --dry-run          Show what would be removed, change nothing
  --stage DIR        Act on files under DIR instead of / and \$HOME (testing)
  -h, --help         Show this help
EOF
}

while (( $# )); do
  case $1 in
    --remove-binaries) REMOVE_BINARIES=1; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --stage)           STAGE=${2:?--stage needs a directory}; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die "unknown option: $1 (see --help)" ;;
  esac
done

(( EUID != 0 )) || die "Run this as your normal user, not root."
set_paths

log "Stopping and disabling user services"
run systemctl --user disable --now "${USER_UNITS[@]}" || warn "some services were not running"

log "Removing files"
WIREPLUMBER_CHANGED=0
UDEV_CHANGED=0
for f in "${HOME_FILES[@]}"; do
  remove_file "$f"
  [[ $f == *wireplumber* ]] && (( LAST_CHANGED )) && WIREPLUMBER_CHANGED=1
done
for f in "${SYSTEM_FILES[@]}"; do
  remove_file "$f"
  (( LAST_CHANGED )) && UDEV_CHANGED=1
done

asrc=$(resolve "~/.asoundrc")
if [[ -f $asrc ]] && grep -qxF "$MARK_BEGIN" "$asrc"; then
  if (( DRY_RUN )); then
    info "would remove the $PROJECT block from ~/.asoundrc"
  else
    backup "$asrc" "~/.asoundrc"
    strip_block "$asrc" >"$WORK/asoundrc"
    if grep -q '[^[:space:]]' "$WORK/asoundrc"; then
      cp "$WORK/asoundrc" "$asrc"
      info "removed the $PROJECT block from ~/.asoundrc"
    else
      rm -f "$asrc"
      info "removed ~/.asoundrc (it only held the $PROJECT block)"
    fi
  fi
else
  info "no $PROJECT block in ~/.asoundrc"
fi

log "Reloading"
run systemctl --user daemon-reload
if (( UDEV_CHANGED )); then run sudo udevadm control --reload-rules; fi
if (( WIREPLUMBER_CHANGED )); then run systemctl --user restart wireplumber; fi

if (( REMOVE_BINARIES )); then
  log "Removing the shairport-sync and nqptp builds in /usr/local"
  run sudo systemctl disable --now nqptp || warn "nqptp was not running"
  for f in /usr/local/bin/shairport-sync /usr/local/bin/nqptp /usr/local/lib/systemd/system/nqptp.service; do
    if [[ -e $(resolve "$f") ]]; then run sudo rm -f "$(resolve "$f")"; else info "not present  $f"; fi
  done
  run sudo systemctl daemon-reload
fi

echo
if (( DRY_RUN )); then
  log "Dry run finished. Nothing was changed."
else
  log "Uninstalled."
  [[ -d $BACKUP_DIR ]] && info "Removed files are backed up in $BACKUP_DIR"
  info "Backups of files that install.sh replaced are in $STATE_DIR/backup-*"
fi
info "Packages were left installed. If nothing else needs them:"
info "  sudo apt remove snapserver snapclient   (and shairport-sync / nqptp if you used --shairport apt)"
info "Re-plug the speakers so they get their default ALSA names back."
