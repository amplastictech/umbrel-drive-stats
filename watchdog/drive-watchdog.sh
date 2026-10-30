#!/bin/bash
# drive-watchdog: keeps Matt's Umbrel bind mounts, fstab lines and nightly
# Seagate mirror in place, and stops apps before they write to the main SSD.
#
#   sudo bash drive-watchdog.sh install   install/repair (also re-run after umbrelOS updates)
#   sudo bash drive-watchdog.sh run       one check-and-fix pass (what the timer runs)
#   bash drive-watchdog.sh status         read-only report, no sudo needed
#   bash drive-watchdog.sh login          quiet login check (prints only when broken)
#
# It never deletes anything. If an app wrote into a mount point while the drive
# was missing, that data is moved aside to <folder>.local-<timestamp>, not removed.

set -u

HOMEDIR="${DW_HOME:-/home/umbrel}"
U="${DW_UMBREL:-$HOMEDIR/umbrel}"
ETC="${DW_ETC:-/etc}"
DOCKER="${DW_DOCKER:-docker}"
SYSTEMCTL="${DW_SYSTEMCTL:-systemctl}"
SELF="$HOMEDIR/drive-watchdog.sh"
LOG="$HOMEDIR/drive-watchdog.log"
LOCK="${DW_LOCK:-/run/drive-watchdog.lock}"
FSTAB="$ETC/fstab"
UNITDIR="$ETC/systemd/system"
REINSTALL="curl -fsSL https://raw.githubusercontent.com/amplastictech/umbrel-drive-stats/main/watchdog/drive-watchdog.sh -o ~/drive-watchdog.sh && sudo bash ~/drive-watchdog.sh install"

# name | bind source | bind target | drive mount point | containers that write there
MOUNTS=(
  "bitcoin|$U/external/btc-node/bitcoin|$U/app-data/bitcoin/data/bitcoin|$U/external/btc-node|bitcoin_app_1"
  "shows|$U/external/Seagate1/Media/Shows|$U/home/Downloads/Shows|$U/external/Seagate1|qbittorrent_server_1 jellyfin_server_1"
  "movies|$U/external/Seagate1/Media/Movies|$U/home/Downloads/Movies|$U/external/Seagate1|qbittorrent_server_1 jellyfin_server_1"
)

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG" >&2; }

trim_log() { [ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 2000 ] && tail -n 1000 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"; return 0; }

fstab_line() { # $1 source  $2 target  $3 drive mount point
  echo "$1 $2 none bind,nofail,x-systemd.requires-mounts-for=$3 0 0"
}

running() { [ "$($DOCKER inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

PENDING="$HOMEDIR/.drive-watchdog-stopped"   # containers the watchdog stopped and owes a restart

# True if every mount that container $1 writes to is in place.
all_mounts_ok_for() {
  local entry name src dst drive apps
  for entry in "${MOUNTS[@]}"; do
    IFS='|' read -r name src dst drive apps <<<"$entry"
    [[ " $apps " == *" $1 "* ]] && ! mountpoint -q "$dst" && return 1
  done
  return 0
}

# ---------- one check-and-fix pass ----------
run_once() {
  local entry name src dst drive apps c broken=() to_stop="" owed=""

  for entry in "${MOUNTS[@]}"; do
    IFS='|' read -r name src dst drive apps <<<"$entry"
    mountpoint -q "$dst" || { broken+=("$entry"); to_stop="$to_stop $apps"; }
  done

  # 1. Stop every app that writes to any broken mount, before touching anything.
  for c in $(echo $to_stop | tr ' ' '\n' | sort -u); do
    if running "$c" && $DOCKER stop "$c" >/dev/null 2>&1; then
      echo "$c" >>"$PENDING"; log "stopped $c (a mount it uses is missing)"
    fi
  done

  # 2. Re-bind each broken mount whose drive is present.
  for entry in "${broken[@]}"; do
    IFS='|' read -r name src dst drive apps <<<"$entry"
    if ! mountpoint -q "$drive" || [ ! -d "$src" ]; then
      log "$name: drive $drive not mounted (or $src missing) - its apps stay stopped, will retry"
      continue
    fi
    # Anything written into the mount point while the drive was missing is
    # moved aside, never deleted.
    if [ -d "$dst" ] && [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
      local aside="$dst.local-$(date +%Y%m%d-%H%M%S)"
      mv "$dst" "$aside" && log "$name: moved stray local data to $aside (review and delete it yourself)"
    fi
    mkdir -p "$dst" && chown 1000:1000 "$dst"
    if mount --bind "$src" "$dst" && mountpoint -q "$dst"; then
      log "$name: re-bound $src -> $dst"
    else
      log "$name: ERROR bind mount failed - its apps stay stopped"
    fi
  done

  # 3. Restart owed containers only once ALL of their mounts are back.
  if [ -s "$PENDING" ]; then
    for c in $(sort -u "$PENDING"); do
      if all_mounts_ok_for "$c"; then
        $DOCKER start "$c" >/dev/null 2>&1 && log "restarted $c"
      else
        owed="$owed $c"
      fi
    done
    if [ -n "$owed" ]; then echo $owed | tr ' ' '\n' >"$PENDING"; else rm -f "$PENDING"; fi
  fi

  repair_config
  write_status
  trim_log
}

# ---------- status file for the Drive Stats app (read-only mount there) ----------
STATUS_DIR="$U/drive-watchdog"
write_status() {
  local p mres mts mepoch mstate
  mkdir -p "$STATUS_DIR"
  p="$(problems)"
  mres="$($SYSTEMCTL show seagate-mirror.service -p Result --value 2>/dev/null)"
  mstate="$($SYSTEMCTL show seagate-mirror.service -p ActiveState --value 2>/dev/null)"
  mts="$($SYSTEMCTL show seagate-mirror.service -p ExecMainExitTimestamp --value 2>/dev/null)"
  mepoch="$(date -d "$mts" +%s 2>/dev/null || echo 0)"
  {
    printf '{"last_run": %s, "mirror_result": "%s", "mirror_state": "%s", "mirror_last": %s, "problems": [' \
      "$(date +%s)" "${mres:-unknown}" "${mstate:-unknown}" "${mepoch:-0}"
    local first=1 line
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      [ $first = 1 ] || printf ', '
      first=0
      printf '"%s"' "$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    done <<<"$p"
    printf ']}\n'
  } >"$STATUS_DIR/status.json.tmp" && chmod 644 "$STATUS_DIR/status.json.tmp" && mv "$STATUS_DIR/status.json.tmp" "$STATUS_DIR/status.json"
}

# ---------- restore fstab lines and timers wiped by updates ----------
repair_config() {
  local entry name src dst drive apps line
  for entry in "${MOUNTS[@]}"; do
    IFS='|' read -r name src dst drive apps <<<"$entry"
    line="$(fstab_line "$src" "$dst" "$drive")"
    # Any existing line for this target counts (don't duplicate older variants).
    if ! awk -v t="$dst" '$2==t && $0 !~ /^[[:space:]]*#/ {f=1} END{exit !f}' "$FSTAB" 2>/dev/null; then
      [ -s "$FSTAB" ] && [ -n "$(tail -c1 "$FSTAB")" ] && echo >>"$FSTAB"
      echo "$line" >>"$FSTAB" && log "fstab: restored line for $name"
    fi
  done

  local changed=0
  write_unit() { # $1 file  $2 content
    if [ ! -f "$UNITDIR/$1" ] || [ "$(cat "$UNITDIR/$1")" != "$2" ]; then
      mkdir -p "$UNITDIR" && printf '%s\n' "$2" >"$UNITDIR/$1" && changed=1 && log "systemd: wrote $1"
    fi
  }

  write_unit drive-watchdog.service "[Unit]
Description=Umbrel drive watchdog (bind mounts, fstab, mirror timer)
[Service]
Type=oneshot
ExecStart=/bin/bash $SELF run"

  write_unit drive-watchdog.timer "[Unit]
Description=Run the Umbrel drive watchdog at boot and every 2 minutes
[Timer]
OnBootSec=45s
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target"

  if [ -f "$HOMEDIR/mirror-seagate.sh" ]; then
    write_unit seagate-mirror.service "[Unit]
Description=Mirror Seagate1 to Seagate2
[Service]
Type=oneshot
ExecStart=/bin/sh $HOMEDIR/mirror-seagate.sh"

    write_unit seagate-mirror.timer "[Unit]
Description=Nightly Seagate mirror
[Timer]
OnCalendar=*-*-* 03:30 America/Los_Angeles
Persistent=true
[Install]
WantedBy=timers.target"
  fi

  if [ "$changed" = 1 ]; then
    $SYSTEMCTL daemon-reload
  fi
  for t in drive-watchdog.timer seagate-mirror.timer; do
    [ -f "$UNITDIR/$t" ] || continue
    if [ "$($SYSTEMCTL is-enabled "$t" 2>/dev/null)" != "enabled" ] || ! $SYSTEMCTL is-active -q "$t"; then
      $SYSTEMCTL enable --now "$t" >/dev/null 2>&1 && log "systemd: enabled $t"
    fi
  done
}

# ---------- reporting ----------
problems() { # prints one line per problem; no root needed
  local entry name src dst drive apps line
  for entry in "${MOUNTS[@]}"; do
    IFS='|' read -r name src dst drive apps <<<"$entry"
    mountpoint -q "$dst" || echo "$name mount missing ($dst)"
    awk -v t="$dst" '$2==t && $0 !~ /^[[:space:]]*#/ {f=1} END{exit !f}' "$FSTAB" 2>/dev/null || echo "$name fstab line missing"
  done
  [ -f "$UNITDIR/drive-watchdog.timer" ] || echo "watchdog timer missing (wiped by an update?)"
  [ -f "$UNITDIR/seagate-mirror.timer" ] || echo "nightly mirror timer missing"
  [ -s "$PENDING" ] && echo "stopped by the watchdog, waiting for a drive: $(sort -u "$PENDING" | tr '\n' ' ')"
  local d
  for d in "$U"/app-data/bitcoin/data/bitcoin.local-* "$U"/home/Downloads/*.local-*; do
    [ -e "$d" ] && echo "stray local data moved aside, review and delete: $d"
  done
  return 0
}

status() {
  local p
  p="$(problems)"
  if [ -z "$p" ]; then echo "drive-watchdog: all OK"; else echo "drive-watchdog problems:"; echo "$p" | sed 's/^/  - /'; fi
  echo "Recent log:"; tail -n 5 "$LOG" 2>/dev/null | sed 's/^/  /' || echo "  (none)"
}

login_check() {
  local p
  p="$(problems)"
  [ -z "$p" ] && return 0
  printf '\033[1;31m*** drive-watchdog: %s\033[0m\n' "attention needed"
  echo "$p" | sed 's/^/  - /'
  echo "  Fix: $REINSTALL"
}

install() {
  [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
  local here; here="$(readlink -f "$0")"
  [ "$here" != "$(readlink -f "$SELF" 2>/dev/null)" ] && cp "$here" "$SELF"
  chown 1000:1000 "$SELF"; chmod 755 "$SELF"
  touch "$LOG"; chown 1000:1000 "$LOG"

  # Login backstop lives in the home folder, which survives updates.
  local hook='[ -x ~/drive-watchdog.sh ] && ~/drive-watchdog.sh login'
  grep -qF "$hook" "$HOMEDIR/.bashrc" 2>/dev/null || echo "$hook" >>"$HOMEDIR/.bashrc"

  run_once
  echo
  status
}

case "${1:-}" in
  install) install ;;
  run)
    exec 9>"$LOCK"; flock -n 9 || exit 0
    [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
    run_once ;;
  status) status ;;
  login) login_check ;;
  *) sed -n '2,11p' "$0" ;;
esac
