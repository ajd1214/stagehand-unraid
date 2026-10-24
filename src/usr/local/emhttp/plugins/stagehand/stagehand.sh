#!/bin/bash
# Stagehand for Unraid
# Copies the media file being played from array disks to an SSD pool and
# live-switches playback to the copy. Releases copies later only after proving
# an identical array copy exists. Never writes to or deletes from array disks.
#
# Usage: stagehand.sh [run|clean|check|status] [-c /path/to/stagehand.cfg]
#   run    one cycle: detect playback, copy, switch, copy next episodes (cron: every minute)
#   clean  release expired pool copies that have a verified array twin (cron: hourly)
#   check  validate config and environment, change nothing
#   explain show how each active session would be handled and why (read-only)
#   status show tracked items
#   apply  write or remove the cron schedule from the config (used by the plugin page)
#   enable-mover-ignore   back up Mover Tuning's config and turn on its ignore list
#   uninstall-cleanup     remove Stagehand's block from the Mover Tuning ignore file
#   pause / resume        create or remove the kill file
#   release-all           release every pool copy now, ignoring keep time (same safety checks as clean;
#                         works while paused, so: pause, then release-all, to empty the pool)
#
# Design credit: alturismo's Cache Mover (https://github.com/alturismo/unraid-cache-mover).

set -o pipefail
# Use a UTF-8 locale when one exists (Unraid ships en_US.UTF-8, not C.UTF-8), else plain C.
for _l in en_US.UTF-8 en_US.utf8 C.UTF-8; do
  if locale -a 2>/dev/null | grep -qix "${_l/UTF-8/utf8}\|$_l"; then export LANG="$_l" LC_ALL="$_l"; break; fi
done
[ -z "$LC_ALL" ] && export LANG=C LC_ALL=C
unset _l

STAGEHAND_VERSION="2026.10.24d"
CMD="${1:-run}"; shift || true
CFG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -c) CFG="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$CFG" ]; then
  if [ -f /boot/config/plugins/stagehand/stagehand.cfg ]; then CFG=/boot/config/plugins/stagehand/stagehand.cfg
  elif [ -f "$SCRIPT_DIR/stagehand.cfg" ]; then CFG="$SCRIPT_DIR/stagehand.cfg"
  else CFG="$SCRIPT_DIR/default.cfg"; fi
fi
[ -f "$CFG" ] || { echo "config not found: $CFG" >&2; exit 2; }
# shellcheck source=stagehand.cfg
source <(tr -d '\r' < "$CFG")

: "${ENABLED:=no}" "${DRY_RUN:=yes}" "${KILL_FILE:=/boot/config/plugins/stagehand/DISABLE}"
: "${STATE_DIR:=/mnt/user/appdata/stagehand}" "${LOG_FILE:=$STATE_DIR/stagehand.log}" "${LOG_MAX_MB:=5}"
: "${SYSLOG:=yes}" "${NOTIFY:=errors}" "${POOL:=}" "${SHARES:=}" "${SUBFOLDERS:=}" "${EXCLUSIONS:=}"
: "${FILETYPES:=mkv mp4}" "${WAIT_SECONDS:=60}" "${NEXT_EPISODES:=0}" "${SWITCH_MODE:=switch}"
: "${GDB_TIMEOUT_SECONDS:=10}" "${KEEP_HOURS:=24}" "${KEEP_RULES:=}" "${RELEASE_VERIFY:=size}"
: "${MIN_FREE_GB:=100}" "${SKIP_ON_FS_ERRORS:=yes}" "${SKIP_ON_IO_ERRORS:=yes}"
: "${IO_ERROR_WINDOW_MIN:=${HEALTH_IO_ERROR_WINDOW_MIN:-60}}" "${CLEAN_EMPTY_DIRS:=yes}"
# Older configs: HEALTH_CHECK="no" turned off all error checks.
[ "${HEALTH_CHECK:-yes}" = "no" ] && SKIP_ON_FS_ERRORS=no && SKIP_ON_IO_ERRORS=no
: "${MAX_COPY_GB_PER_RUN:=60}" "${COPY_BWLIMIT_KBPS:=0}"
: "${MEDIASERVER_TYPE:=plex}" "${MEDIASERVER_URL:=http://127.0.0.1:32400}" "${MEDIASERVER_TOKEN:=auto}"
: "${MEDIASERVER_CONTAINER:=plex}" "${PATH_MAP:=auto}" "${MANAGE_MOVER_IGNORE:=no}"
: "${MOVER_IGNORE_FILE:=/mnt/user/system/mover/mover_ignore.txt}"
: "${MOVER_TUNING_CFG:=/boot/config/plugins/ca.mover.tuning/ca.mover.tuning.cfg}"
: "${SOURCE_ROOTS:=auto}" "${ALLOW_OTHER_POOL:=no}" "${ORPHAN_ACTION:=report}"
: "${ORPHAN_GRACE_MIN:=30}"
for _n in 1 2 3 4 5 6; do
  eval ": \"\${ARR${_n}_TYPE:=none}\" \"\${ARR${_n}_URL:=}\" \"\${ARR${_n}_KEY:=auto}\" \"\${ARR${_n}_CONTAINER:=}\""
done
unset _n
: "${SCHEDULE:=no}" "${RUN_CRON:=* * * * *}" "${CLEAN_CRON:=17 * * * *}"
: "${NEXT_EPISODE_REGEX:=[Ss][0-9]+[Ee][0-9]+}" "${COPY_SIDECARS:=yes}" "${SIDECAR_TYPES:=srt ass ssa sub idx vtt sup}"

ITEMS="$STATE_DIR/items.tsv"     # pool_path  share  rel  size  copied_epoch  last_played_epoch  reason  array_mtime
ORPHANS="$STATE_DIR/orphans.tsv" # array_path  share  rel  size  array_mtime  detected_epoch  status
WARNED="$STATE_DIR/warned.tsv"   # key  epoch  (rate-limits repeating warnings)
SEEN="$STATE_DIR/seen.tsv"       # share/rel  first_seen  last_seen
LOCK="$STATE_DIR/stagehand.lock"
NOW=$(date +%s)
DRY=0; [ "$DRY_RUN" = "yes" ] && DRY=1
MARK_BEGIN="# >>> stagehand managed block - do not edit inside >>>"
MARK_END="# <<< stagehand managed block <<<"

########## logging ##########
log() {
  local lvl="$1"; shift
  local line; line="$(date '+%F %T') [$lvl]$( [ $DRY -eq 1 ] && echo ' [dry]') $*"
  if [ -n "$LOG_FILE" ] && mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; then
    echo "$line" >> "$LOG_FILE"
  fi
  [ "$SYSLOG" = "yes" ] && logger -t stagehand -- "[$lvl] $*"
  [ -t 1 ] && echo "$line"
  if [ "$lvl" = "ERROR" ] && [ "$NOTIFY" != "none" ]; then notify warning "Stagehand error" "$*"; fi
  if [ "$lvl" = "SWITCH" ] && [ "$NOTIFY" = "all" ]; then notify normal "Stagehand switch" "$*"; fi
}
notify() {
  local n=/usr/local/emhttp/webGui/scripts/notify
  [ -x "$n" ] && "$n" -e "Stagehand" -s "$2" -d "$3" -i "$1" >/dev/null 2>&1 &
}
rotate_log() {
  [ -f "$LOG_FILE" ] || return 0
  local sz; sz=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
  [ "$sz" -gt $((LOG_MAX_MB * 1024 * 1024)) ] && mv -f "$LOG_FILE" "$LOG_FILE.1"
}

########## helpers ##########
in_list() { local x="$1"; shift; local i; for i in "$@"; do [ "$i" = "$x" ] && return 0; done; return 1; }

source_roots() {
  if [ "$SOURCE_ROOTS" = "auto" ]; then
    local d; for d in /mnt/disk[0-9]*; do [ -d "$d" ] && echo "$d"; done
  else
    tr ' ' '\n' <<< "$SOURCE_ROOTS" | sed '/^$/d'
  fi
}

# First array copy of share/rel, or nothing. Direct path checks, no directory walks.
array_copy() {
  local share="$1" rel="$2" r
  while IFS= read -r r; do
    [ -f "$r/$share/$rel" ] && { echo "$r/$share/$rel"; return 0; }
  done < <(source_roots)
  return 1
}

pool_path() { echo "/mnt/$POOL/$1/$2"; }

passes_filters() {
  local rel="$1" ok=0 x ext
  ext="${rel##*.}"; ext="${ext,,}"
  in_list "$ext" $FILETYPES || return 1
  if [ -n "$SUBFOLDERS" ]; then
    for x in $SUBFOLDERS; do
      case "/$rel" in */"$x"/*) ok=1; break ;; esac
    done
    [ $ok -eq 1 ] || return 1
  fi
  for x in $EXCLUSIONS; do
    case "$rel" in *"$x"*) return 1 ;; esac
  done
  return 0
}

keep_hours_for() {
  local rel="$1" rule f h
  for rule in $KEEP_RULES; do
    f="${rule%%:*}"; h="${rule##*:}"
    case "/$rel" in */"$f"/*) echo "$h"; return ;; esac
  done
  echo "$KEEP_HOURS"
}

########## media server ##########
container_mounts() { container_mounts_of "$MEDIASERVER_CONTAINER"; }
container_mounts_of() {  # container -> "destination<TAB>source", longest destination first
  docker inspect "$1" --format '{{range .Mounts}}{{.Destination}}{{"\t"}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null \
    | sed '/^$/d' | awk -F'\t' '{print length($1) "\t" $0}' | sort -rn | cut -f2-
}

path_map_lines() {
  if [ "$PATH_MAP" = "auto" ]; then
    container_mounts
  else
    local p a b
    if [[ "$PATH_MAP" == *"=>"* ]]; then
      # New format: "server_path=>host_path; server_path=>host_path" (spaces and drive letters allowed)
      local IFS=';'
      for p in $PATH_MAP; do
        a="${p%%=>*}"; b="${p#*=>}"
        a="${a#"${a%%[![:space:]]*}"}"; a="${a%"${a##*[![:space:]]}"}"
        b="${b#"${b%%[![:space:]]*}"}"; b="${b%"${b##*[![:space:]]}"}"
        [ -n "$a" ] && [ -n "$b" ] && printf '%s\t%s\n' "${a//\\//}" "$b"
      done | awk -F'\t' '{print length($1) "\t" $0}' | sort -rn | cut -f2-
    else
      # Old format: "container_path:host_path" pairs separated by spaces
      for p in $PATH_MAP; do printf '%s\t%s\n' "${p%%:*}" "${p#*:}"; done \
        | awk -F'\t' '{print length($1) "\t" $0}' | sort -rn | cut -f2-
    fi
  fi
}

# Media-server path -> host path, using the longest matching container mount.
to_host_path() {
  local p="${1//\\//}" dst src
  while IFS=$'\t' read -r dst src; do
    dst="${dst%/}"; src="${src%/}"
    if [ "$p" = "$dst" ] || [[ "$p" == "$dst/"* ]]; then echo "$src${p#"$dst"}"; return 0; fi
  done < <(path_map_lines)
  # No mapping matched: maybe the server sees host paths directly.
  [[ "$p" == /mnt/* ]] && { echo "$p"; return 0; }
  return 1
}

# Host path -> "share<TAB>rel" for /mnt/user/<share>/..., /mnt/<pool>/<share>/... or /mnt/diskN/<share>/...
split_share() {
  local h="$1" rest
  [[ "$h" == /mnt/*/*/* ]] || return 1
  rest="${h#/mnt/}"; rest="${rest#*/}"
  printf '%s\t%s\n' "${rest%%/*}" "${rest#*/}"
}

media_token() {
  if [ "$MEDIASERVER_TOKEN" != "auto" ]; then echo "$MEDIASERVER_TOKEN"; return; fi
  [ "$MEDIASERVER_TYPE" = "plex" ] || return 1
  local cfgdir pref
  cfgdir=$(container_mounts | awk -F'\t' '$1=="/config"{print $2; exit}')
  [ -n "$cfgdir" ] || return 1
  pref="$cfgdir/Library/Application Support/Plex Media Server/Preferences.xml"
  [ -f "$pref" ] || pref=$(find "$cfgdir" -maxdepth 4 -name Preferences.xml -path '*Plex Media Server*' 2>/dev/null | head -1)
  [ -f "$pref" ] && grep -oP 'PlexOnlineToken="\K[^"]+' "$pref" | head -1
}

# Prints "state<TAB>server_path" per active session. Exit 1 on error (message on stdout).
get_sessions() {
  local tok; tok=$(media_token) || { echo "could not read media server token"; return 1; }
  SH_TYPE="$MEDIASERVER_TYPE" SH_URL="$MEDIASERVER_URL" SH_TOKEN="$tok" SH_VERBOSE="${SH_VERBOSE:-0}" php "$SCRIPT_DIR/sessions.php"
}

########## multiple media servers ##########
# Server 1 uses MEDIASERVER_*/PATH_MAP. Servers 2 and 3 use MEDIASERVER2_*/PATH_MAP2 and
# MEDIASERVER3_*/PATH_MAP3; a server is active when its TYPE is plex, jellyfin or emby.
S1_TYPE="$MEDIASERVER_TYPE" S1_URL="$MEDIASERVER_URL" S1_TOKEN="$MEDIASERVER_TOKEN"
S1_CONTAINER="$MEDIASERVER_CONTAINER" S1_MAP="$PATH_MAP"
server_ids() {
  local n t
  for n in 1 2 3; do
    if [ "$n" = 1 ]; then t="$S1_TYPE"; else t="MEDIASERVER${n}_TYPE"; t="${!t:-none}"; fi
    case "$t" in plex|jellyfin|emby) echo "$n" ;; esac
  done
}
use_server() {
  local n="$1" v
  if [ "$n" = 1 ]; then
    MEDIASERVER_TYPE="$S1_TYPE" MEDIASERVER_URL="$S1_URL" MEDIASERVER_TOKEN="$S1_TOKEN"
    MEDIASERVER_CONTAINER="$S1_CONTAINER" PATH_MAP="$S1_MAP"
  else
    v="MEDIASERVER${n}_TYPE"; MEDIASERVER_TYPE="${!v}"
    v="MEDIASERVER${n}_URL"; MEDIASERVER_URL="${!v}"
    v="MEDIASERVER${n}_TOKEN"; MEDIASERVER_TOKEN="${!v:-auto}"
    v="MEDIASERVER${n}_CONTAINER"; MEDIASERVER_CONTAINER="${!v}"
    v="PATH_MAP${n}"; PATH_MAP="${!v:-auto}"
  fi
}
# Prints "state<TAB>flag<TAB>host_path<TAB>server_number<TAB>server_path" for every server.
all_sessions() {
  local n out st fl sp host rc=0
  for n in $(server_ids); do
    use_server "$n"
    if ! out=$(get_sessions); then printf 'ERROR\t%s\n' "server $n ($MEDIASERVER_TYPE): $out"; rc=1; continue; fi
    while IFS=$'\t' read -r st fl sp; do
      [ -z "$sp" ] && continue
      # Empty fields would collapse when read back with IFS=tab, so use "-" placeholders.
      host=$(to_host_path "$sp") || host="-"
      printf '%s\t%s\t%s\t%s\t%s\n' "$st" "$fl" "$host" "$n" "$sp"
    done <<< "$out"
  done
  use_server 1
  return $rc
}

########## pool checks ##########
pool_devices() {  # short device names (sda sdc ...) backing the pool
  local fs; fs=$(findmnt -no FSTYPE "/mnt/$POOL" 2>/dev/null)
  case "$fs" in
    btrfs) btrfs filesystem show "/mnt/$POOL" 2>/dev/null | grep -oP 'path /dev/\K[a-z0-9]+' | sed -E 's/p?[0-9]+$//' ;;
    *) findmnt -no SOURCE "/mnt/$POOL" 2>/dev/null | sed -E 's#^/dev/##; s/p?[0-9]+$//' ;;
  esac
}

pool_healthy() {  # 0 = ok; prints reason when not ok. Read-only always blocks copying.
  findmnt -no OPTIONS "/mnt/$POOL" 2>/dev/null | tr ',' '\n' | grep -qx ro && { echo "pool is read-only"; return 1; }
  local fs; fs=$(findmnt -no FSTYPE "/mnt/$POOL" 2>/dev/null)
  local win=$((IO_ERROR_WINDOW_MIN * 60))
  if [ "$SKIP_ON_FS_ERRORS" = "yes" ]; then
    # Counters are lifetime totals, so old SSDs with past errors would block forever.
    # Only NEW errors (counter went up) block copying, for IO_ERROR_WINDOW_MIN minutes.
    local cur prev pts sf="$STATE_DIR/fs_errors.state"
    if [ "$fs" = "btrfs" ]; then
      cur=$(btrfs device stats "/mnt/$POOL" 2>/dev/null | awk '{s+=$2} END{print s+0}')
    elif [ "$fs" = "zfs" ]; then
      cur=$(zpool status "$POOL" 2>/dev/null | awk '$1 ~ /^(sd|nvme|ata|wwn)/ {s+=$3+$4+$5} END{print s+0}')
    fi
    if [ -n "$cur" ]; then
      read -r prev pts < "$sf" 2>/dev/null
      if [ -z "$prev" ]; then echo "$cur 0" > "$sf" 2>/dev/null
      elif [ "$cur" -gt "$prev" ]; then echo "$cur $NOW" > "$sf" 2>/dev/null; pts=$NOW
      elif [ "$cur" -lt "$prev" ]; then echo "$cur ${pts:-0}" > "$sf" 2>/dev/null; fi
      [ "${pts:-0}" -gt 0 ] && [ $((NOW - pts)) -lt "$win" ] && { echo "new filesystem errors on the pool in the last $IO_ERROR_WINDOW_MIN min"; return 1; }
    fi
  fi
  if [ "$SKIP_ON_IO_ERRORS" = "yes" ]; then
    local devs last ts
    devs=$(pool_devices | sort -u | paste -sd'|')
    if [ -n "$devs" ] && [ -f /var/log/syslog ]; then
      last=$(grep -aE "I/O error, dev ($devs)[, ]" /var/log/syslog | tail -1 | cut -c1-15)
      if [ -n "$last" ]; then
        ts=$(date -d "$last" +%s 2>/dev/null || echo 0)
        [ "$ts" -gt "$NOW" ] && ts=$(date -d "$last last year" +%s 2>/dev/null || echo 0)
        [ $((NOW - ts)) -lt "$win" ] && { echo "disk I/O errors on pool device(s) ($devs) at $last"; return 1; }
      fi
    fi
  fi
  return 0
}

pool_has_room() {  # $1 = bytes to add
  local avail; avail=$(df -B1 --output=avail "/mnt/$POOL" 2>/dev/null | tail -1 | tr -d ' ')
  [ -n "$avail" ] && [ $((avail - $1)) -gt $((MIN_FREE_GB * 1024 * 1024 * 1024)) ]
}

share_cfg() { tr -d '\r' 2>/dev/null < "/boot/config/shares/$1.cfg" | grep -oP "^$2=\"\\K[^\"]*"; }

# 0 = share is usable; otherwise prints the reason. Needs "pool first, array second" (shareUseCache=yes):
# with "prefer" the mover moves files onto the pool and would collide with Stagehand's copies.
share_pool_ok() {
  local share="$1" uc sp
  uc=$(share_cfg "$share" shareUseCache); sp=$(share_cfg "$share" shareCachePool)
  [ -f "/boot/config/shares/$share.cfg" ] || { echo "no share config found"; return 1; }
  case "$uc" in
    yes) ;;
    prefer) echo "share is set to array first, pool second (mover moves files onto the pool)"; return 1 ;;
    only)   echo "share is pool-only (nothing on the array to cache)"; return 1 ;;
    *)      echo "share does not use a pool (array only)"; [ "$ALLOW_OTHER_POOL" = "yes" ] || return 1 ;;
  esac
  [ "$sp" = "$POOL" ] || [ "$ALLOW_OTHER_POOL" = "yes" ] || { echo "share's primary pool is $sp, not $POOL"; return 1; }
  return 0
}

########## state ##########
state_init() { mkdir -p "$STATE_DIR" && touch "$ITEMS" "$SEEN" "$ORPHANS" "$WARNED"; }

warn_once() {  # key message : log a WARN at most once per 24 hours per key
  local key="$1"; shift
  local last tmp="$WARNED.tmp.$$"
  last=$(awk -F'\t' -v k="$key" '$1==k{print $2; exit}' "$WARNED" 2>/dev/null)
  [ -n "$last" ] && [ $((NOW - last)) -lt 86400 ] && return 0
  log WARN "$*"
  { awk -F'\t' -v k="$key" '$1!=k' "$WARNED"; printf '%s\t%s\n' "$key" "$NOW"; } > "$tmp" && mv -f "$tmp" "$WARNED"
}

item_get() { awk -F'\t' -v p="$1" '$1==p' "$ITEMS"; }

item_upsert() {  # pool share rel size copied last reason array_mtime
  local tmp="$ITEMS.tmp.$$"
  awk -F'\t' -v p="$1" '$1!=p' "$ITEMS" > "$tmp"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$tmp"
  mv -f "$tmp" "$ITEMS"
}

item_touch() {  # update last_played for pool path
  local tmp="$ITEMS.tmp.$$"
  awk -F'\t' -v OFS='\t' -v p="$1" -v t="$NOW" '$1==p{$6=t} {print}' "$ITEMS" > "$tmp" && mv -f "$tmp" "$ITEMS"
}

item_drop() {
  local tmp="$ITEMS.tmp.$$"
  awk -F'\t' -v p="$1" '$1!=p' "$ITEMS" > "$tmp" && mv -f "$tmp" "$ITEMS"
}

seen_first() {  # returns first_seen epoch for key, recording it if new; refreshes last_seen
  local key="$1" first tmp="$SEEN.tmp.$$"
  first=$(awk -F'\t' -v k="$key" '$1==k{print $2; exit}' "$SEEN")
  [ -z "$first" ] && first=$NOW
  awk -F'\t' -v k="$key" '$1!=k' "$SEEN" > "$tmp"
  printf '%s\t%s\t%s\n' "$key" "$first" "$NOW" >> "$tmp"
  mv -f "$tmp" "$SEEN"
  echo "$first"
}

seen_prune() {  # forget titles not seen for 10 minutes (a new play must wait again)
  local tmp="$SEEN.tmp.$$"
  awk -F'\t' -v n="$NOW" 'n-$3 < 600' "$SEEN" > "$tmp" && mv -f "$tmp" "$SEEN"
}

########## open files ##########
open_targets() { find /proc/[0-9]*/fd -type l -printf '%l\n' 2>/dev/null | sort -u; }

# "pid fd" of shfs file descriptors pointing at an exact path
shfs_fds_for() {
  local target="$1" pid fd
  for pid in $(pgrep -x shfs); do
    for fd in /proc/"$pid"/fd/*; do
      [ "$(readlink "$fd" 2>/dev/null)" = "$target" ] && echo "$pid ${fd##*/}"
    done
  done
}

########## copy ##########
mkdirs_like() {  # create pool dirs for share/reldir, copying owner/mode from the array dir
  local share="$1" reldir="$2" src_root="$3" cur="" part
  local IFS='/'
  for part in $reldir; do
    [ -z "$part" ] && continue
    cur="${cur:+$cur/}$part"
    if [ ! -d "/mnt/$POOL/$share/$cur" ]; then
      mkdir "/mnt/$POOL/$share/$cur" || return 1
      chown --reference="$src_root/$share/$cur" "/mnt/$POOL/$share/$cur" 2>/dev/null
      chmod --reference="$src_root/$share/$cur" "/mnt/$POOL/$share/$cur" 2>/dev/null
    fi
  done
  return 0
}

copy_to_pool() {  # src dst share rel ; rsync writes a hidden temp file and renames when complete
  local src="$1" dst="$2" share="$3" rel="$4" root bw=()
  root="${src%%/"$share"/*}"
  [ -d "/mnt/$POOL/$share" ] || { log ERROR "share folder /mnt/$POOL/$share does not exist"; return 1; }
  mkdirs_like "$share" "$(dirname "$rel")" "$root" || { log ERROR "mkdir failed for $rel"; return 1; }
  [ "$COPY_BWLIMIT_KBPS" -gt 0 ] 2>/dev/null && bw=(--bwlimit="$COPY_BWLIMIT_KBPS")
  local t0 t1
  t0=$(date +%s)
  ionice -c2 -n7 nice -n10 rsync -t -p -o -g "${bw[@]}" -- "$src" "$dst" 2>&1 | while IFS= read -r l; do log WARN "rsync: $l"; done
  t1=$(date +%s)
  if [ -f "$dst" ] && [ "$(stat -c %s "$dst")" = "$(stat -c %s "$src")" ]; then
    log COPY "$rel -> $POOL ($(( $(stat -c %s "$dst") / 1048576 )) MB in $((t1 - t0))s)"
    return 0
  fi
  log ERROR "copy failed or size mismatch: $rel"
  rm -f -- "$dst" 2>/dev/null
  return 1
}

########## switch ##########
gdb_switch() {  # pid fd new_path ; returns 0 when the fd now points at new_path
  local pid="$1" fd="$2" dst="$3" pos esc t0 t1 out rc now
  pos=$(awk '/^pos:/{print $2}' "/proc/$pid/fdinfo/$fd" 2>/dev/null); pos="${pos:-0}"
  esc="${dst//\\/\\\\}"; esc="${esc//\"/\\\"}"
  t0=$(date +%s%N)
  out=$(timeout -s TERM "$GDB_TIMEOUT_SECONDS" gdb -q -n -batch -p "$pid" \
        -ex "set \$sh_nfd = (int) open(\"$esc\", 02000)" \
        -ex "call (long) lseek(\$sh_nfd, $pos, 0)" \
        -ex "call (int) dup2(\$sh_nfd, $fd)" \
        -ex "call (int) close(\$sh_nfd)" 2>&1)
  rc=$?
  t1=$(date +%s%N)
  now=$(readlink "/proc/$pid/fd/$fd" 2>/dev/null)
  GDB_MS=$(( (t1 - t0) / 1000000 ))
  if [ "$now" = "$dst" ]; then return 0; fi
  log ERROR "gdb switch failed (rc=$rc, ${GDB_MS}ms): $(echo "$out" | tail -2 | tr '\n' ' ')"
  return 1
}

gdb_close() {  # pid fd
  timeout -s TERM "$GDB_TIMEOUT_SECONDS" gdb -q -n -batch -p "$1" -ex "call (int) close($2)" >/dev/null 2>&1
}

# Switch every shfs fd that still reads the array copy over to the pool copy.
switch_playback() {  # arr dst rel [quiet]
  local arr="$1" dst="$2" rel="$3" quiet="${4:-0}" pid fd any=0
  [ "$SWITCH_MODE" = "none" ] && return 0
  while read -r pid fd; do
    [ -z "$pid" ] && continue
    any=1
    if [ $DRY -eq 1 ]; then log SWITCH "would $SWITCH_MODE shfs pid $pid fd $fd: $rel"; continue; fi
    if [ "$SWITCH_MODE" = "close" ]; then
      gdb_close "$pid" "$fd" && log SWITCH "closed array file (player will reopen on $POOL): $rel"
    elif gdb_switch "$pid" "$fd" "$dst"; then
      log SWITCH "live-switched to $POOL in ${GDB_MS}ms: $rel"
    fi
  done < <(shfs_fds_for "$arr")
  [ $any -eq 0 ] && [ "$quiet" -eq 0 ] && log INFO "no open array file to switch (already on $POOL or not open right now): $rel"
  return 0
}

########## mover tuning ignore block ##########
update_mover_ignore() {
  [ "$MANAGE_MOVER_IGNORE" = "yes" ] || return 0
  local f="$MOVER_IGNORE_FILE" tmp
  mkdir -p "$(dirname "$f")" 2>/dev/null; touch "$f" 2>/dev/null || { log WARN "cannot write $f"; return 0; }
  tmp="$f.stagehand.$$"
  {
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1; next} $0==e{skip=0; next} !skip' "$f"
    echo "$MARK_BEGIN"
    cut -f1 "$ITEMS" | sed '/^$/d' | sort -u
    echo "$MARK_END"
  } > "$tmp"
  if cmp -s "$tmp" "$f"; then rm -f "$tmp"; else
    if [ $DRY -eq 1 ]; then rm -f "$tmp"; log INFO "would update mover ignore block in $f"
    else chmod --reference="$f" "$tmp" 2>/dev/null; mv -f "$tmp" "$f"; fi
  fi
}

mover_tuning_reads_list() {
  [ -f "$MOVER_TUNING_CFG" ] || return 2
  tr -d '\r' < "$MOVER_TUNING_CFG" | grep -qx 'filelistf="yes"'
}

########## run ##########
handle_title() {  # state flag host_path
  local st="$1" flag="$2" host="$3" share rel arr dst first size why
  IFS=$'\t' read -r share rel < <(split_share "$host") || return
  [ -n "$rel" ] || return
  in_list "$share" $SHARES || return
  passes_filters "$rel" || return
  if [[ "$host" != /mnt/user/* ]]; then
    warn_once "direct:$share" "media server reads $host directly, not through /mnt/user; live switching is impossible, skipping share $share (map its library to /mnt/user/... instead)"
    return
  fi
  dst=$(pool_path "$share" "$rel")
  arr=$(array_copy "$share" "$rel")

  if [ -z "$arr" ]; then
    # Not on the array: either only on the pool already, or unknown location. Nothing to do.
    [ -n "$(item_get "$dst")" ] && [ $DRY -eq 0 ] && item_touch "$dst"
    return
  fi

  why=$(share_pool_ok "$share") || { warn_once "pool:$share" "skipping share $share: $why"; return; }
  # Several versions of this title and Plex did not say which is playing: only act on the one being read.
  if [ "$flag" = "guess" ] && [ ! -f "$dst" ] && [ -z "$(shfs_fds_for "$arr")" ]; then return; fi

  if [ -f "$dst" ]; then
    # Already cached. Keep it alive and retry the switch if playback is still on the array.
    if [ "$(stat -c %s "$dst")" = "$(stat -c %s "$arr")" ]; then
      [ -n "$(item_get "$dst")" ] && [ $DRY -eq 0 ] && item_touch "$dst"
      switch_playback "$arr" "$dst" "$rel" 1
      # Keep filling the season/next episodes on later runs (MAX_COPY_GB_PER_RUN per run).
      pool_healthy >/dev/null && copy_next_episodes "$share" "$rel"
    fi
    return
  fi

  first=$(seen_first "$share/$rel")
  if [ $((NOW - first)) -lt "$WAIT_SECONDS" ]; then
    log INFO "seen $st, waiting ${WAIT_SECONDS}s before copy: $rel"
    return
  fi

  why=$(pool_healthy) || { log WARN "pool not healthy, not copying: $why"; return; }
  size=$(stat -c %s "$arr")
  pool_has_room "$size" || { log WARN "not enough free space on $POOL (MIN_FREE_GB=$MIN_FREE_GB): $rel"; return; }

  if [ $DRY -eq 1 ]; then
    log COPY "would copy $(( size / 1048576 )) MB: $arr -> $dst"
    switch_playback "$arr" "$dst" "$rel"
  else
    copy_to_pool "$arr" "$dst" "$share" "$rel" || return
    item_upsert "$dst" "$share" "$rel" "$size" "$NOW" "$NOW" "playing" "$(stat -c %Y "$arr")"
    switch_playback "$arr" "$dst" "$rel"
  fi
  copy_sidecars "$share" "$rel"
  copy_next_episodes "$share" "$rel"
}

copy_sidecars() {  # share rel : subtitle files named like the video (Show.S01E01.en.srt)
  local share="$1" rel="$2" dir base stem f ext arr dst size
  [ "$COPY_SIDECARS" = "yes" ] || return 0
  dir=$(dirname "$rel"); base=$(basename "$rel"); stem="${base%.*}"
  while IFS= read -r f; do
    [[ "$f" == "$stem."* ]] || continue
    ext="${f##*.}"; ext="${ext,,}"
    in_list "$ext" $SIDECAR_TYPES || continue
    dst=$(pool_path "$share" "$dir/$f")
    [ -f "$dst" ] && continue
    arr=$(array_copy "$share" "$dir/$f") || continue
    size=$(stat -c %s "$arr")
    if [ $DRY -eq 1 ]; then log COPY "would copy sidecar: $dir/$f"
    else copy_to_pool "$arr" "$dst" "$share" "$dir/$f" && item_upsert "$dst" "$share" "$dir/$f" "$size" "$NOW" "$NOW" "sidecar" "$(stat -c %Y "$arr")"; fi
  done < <(ls -1 "/mnt/user/$share/$dir" 2>/dev/null)
}

is_episode() {  # rel : true when the file looks like a TV episode
  local dir base; dir=$(dirname "$1"); base=$(basename "$1")
  [[ "$base" =~ $NEXT_EPISODE_REGEX ]] && return 0
  case "${dir,,}" in *season*|*specials*|*staffel*|*saison*|*temporada*|*stagione*|*seizoen*) return 0 ;; esac
  return 1
}

copy_next_episodes() {  # share rel
  # NEXT_EPISODES: a number = that many following episodes; "rest" = every later episode in the
  # folder; "season" = the whole folder (earlier episodes too). Limited to MAX_COPY_GB_PER_RUN per
  # run; the remainder is copied on the next runs while the title is still playing.
  local share="$1" rel="$2" dir base n=0 limit f arr dst size budget listing
  case "$NEXT_EPISODES" in
    rest|season) limit=999999 ;;
    *) [ "$NEXT_EPISODES" -gt 0 ] 2>/dev/null || return 0; limit=$NEXT_EPISODES ;;
  esac
  is_episode "$rel" || return 0
  dir=$(dirname "$rel"); base=$(basename "$rel")
  budget=$((MAX_COPY_GB_PER_RUN * 1024 * 1024 * 1024))
  if [ "$NEXT_EPISODES" = "season" ]; then
    listing=$(ls -1 "/mnt/user/$share/$dir" 2>/dev/null | LC_ALL=C sort | grep -vxF -- "$base")
  else
    listing=$(ls -1 "/mnt/user/$share/$dir" 2>/dev/null | LC_ALL=C sort | awk -v b="$base" 'f{print} $0==b{f=1}')
  fi
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ "$n" -ge "$limit" ] && break
    passes_filters "$dir/$f" || continue
    n=$((n + 1))
    dst=$(pool_path "$share" "$dir/$f")
    [ -f "$dst" ] && continue
    arr=$(array_copy "$share" "$dir/$f") || continue
    size=$(stat -c %s "$arr")
    [ "$size" -le "$budget" ] || break
    pool_has_room "$size" || { warn_once "room:$share/$dir" "not enough free space to copy more of: $dir"; break; }
    budget=$((budget - size))
    if [ $DRY -eq 1 ]; then log COPY "would copy episode $(( size / 1048576 )) MB: $dir/$f"
    else copy_to_pool "$arr" "$dst" "$share" "$dir/$f" && item_upsert "$dst" "$share" "$dir/$f" "$size" "$NOW" "$NOW" "next" "$(stat -c %Y "$arr")" && copy_sidecars "$share" "$dir/$f"; fi
  done <<< "$listing"
}

########## orphans ##########
# A tracked pool copy that vanished without Stagehand deleting it was removed or renamed
# through /mnt/user (Sonarr/Radarr upgrade or rename, Maintainerr, a manual delete) or moved
# by the mover. Unraid deletes and renames only the pool copy, so the array copy becomes
# visible again. Stagehand reports it; it never deletes array files.
check_orphans() {
  local pool share rel size copied last reason amt arr
  while IFS=$'\t' read -r pool share rel size copied last reason amt; do
    [ -z "$pool" ] && continue
    [ -f "$pool" ] && continue
    arr=$(array_copy "$share" "$rel")
    if [ -z "$arr" ]; then
      log INFO "removed from pool and array, nothing left behind: $rel"
      [ $DRY -eq 0 ] && item_drop "$pool"; continue
    fi
    log WARN "ORPHAN: pool copy disappeared but the array copy is still there and visible again: $arr (if Sonarr/Radarr/Maintainerr deleted, upgraded or renamed it, this array file is a leftover; if the mover moved it, it is the real copy)"
    notify warning "Stagehand: possible leftover file" "Array copy visible again after the pool copy disappeared: $arr"
    if [ $DRY -eq 0 ]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$arr" "$share" "$rel" "$size" "${amt:--}" "$NOW" "reported" >> "$ORPHANS"
      item_drop "$pool"
    fi
  done < <(cat "$ITEMS")
}

########## Sonarr / Radarr ##########
arr_ids() {
  local n t
  for n in 1 2 3 4 5 6; do t="ARR${n}_TYPE"; case "${!t}" in sonarr|radarr) echo "$n" ;; esac; done
}
arr_val() { local v="ARR${1}_$2"; echo "${!v}"; }
arr_key() {  # API key, read from the container's config.xml when set to auto
  local n="$1" key cfgdir
  key=$(arr_val "$n" KEY)
  [ "$key" != "auto" ] && [ -n "$key" ] && { echo "$key"; return 0; }
  cfgdir=$(container_mounts_of "$(arr_val "$n" CONTAINER)" | awk -F'\t' '$1=="/config"{print $2; exit}')
  [ -n "$cfgdir" ] && grep -oP '<ApiKey>\K[^<]+' "$cfgdir/config.xml" 2>/dev/null | head -1
}
arr_call() {  # n args... -> runs arr.php for instance n
  local n="$1"; shift
  ARR_TYPE=$(arr_val "$n" TYPE) ARR_URL=$(arr_val "$n" URL) ARR_KEY=$(arr_key "$n") \
    ARR_MOUNTS=$(container_mounts_of "$(arr_val "$n" CONTAINER)") php "$SCRIPT_DIR/arr.php" "$@"
}
arr_name() { echo "$(arr_val "$1" TYPE) #$1 ($(arr_val "$1" CONTAINER))"; }

# Ask every configured Sonarr/Radarr about an array file. Prints one verdict line:
#   owned <who>       an instance still tracks this exact file: it is a real library file
#   leftover <who>    an instance manages its folder but no longer tracks the file
#   unmanaged         no instance manages this folder (nothing to go by)
#   error <who>: ...  an instance could not be asked (never delete on an error)
#   none              no Sonarr/Radarr configured
arr_verdict() {
  local f="$1" n out owner="" left="" any=0
  for n in $(arr_ids); do
    any=1
    out=$(arr_call "$n" owns "$f" 2>&1) || { echo "error $(arr_name "$n"): ${out#error: }"; return; }
    case "$out" in
      owned) owner="$(arr_name "$n")" ;;
      not-owned) left="$(arr_name "$n")" ;;
    esac
  done
  [ $any -eq 0 ] && { echo "none"; return; }
  [ -n "$owner" ] && { echo "owned by $owner"; return; }
  [ -n "$left" ] && { echo "leftover $left no longer tracks it"; return; }
  echo "unmanaged"
}

# Safety checks before deleting a leftover array file. Prints the blocking reason, or nothing.
orphan_block_reason() {  # arr size amt det opens
  local arr="$1" size="$2" amt="$3" det="$4" opens="$5"
  [ "$MANAGE_MOVER_IGNORE" = "yes" ] && ! mover_tuning_reads_list && { echo "Mover Tuning ignore list is off, so a mover move cannot be ruled out"; return; }
  [ "$amt" = "-" ] || [ -z "$amt" ] && { echo "no record of the file from when it was cached"; return; }
  [ "$(stat -c %s "$arr")" = "$size" ] && [ "$(stat -c %Y "$arr")" = "$amt" ] || { echo "array file changed since it was cached"; return; }
  grep -qxF -- "$arr" <<< "$opens" && { echo "file is open right now"; return; }
  [ $((NOW - det)) -ge $((ORPHAN_GRACE_MIN * 60)) ] || { echo "waiting ${ORPHAN_GRACE_MIN} min after detection"; return; }
}

# True when a video named like this subtitle file still exists (share view or any array disk).
sidecar_has_video() {  # share rel
  local share="$1" rel="$2" dir sub root v vb ve
  dir=$(dirname "$rel"); sub=$(basename "$rel")
  while IFS= read -r root; do
    for v in "$root/$share/$dir"/*; do
      [ -f "$v" ] || continue
      vb=$(basename "$v"); ve="${vb##*.}"
      in_list "${ve,,}" $FILETYPES || continue
      [[ "$sub" == "${vb%.*}."* ]] && return 0
    done
  done < <(echo /mnt/user; source_roots)
  return 1
}

# Re-check every reported leftover: classify it with Sonarr/Radarr and, when ORPHAN_ACTION=delete
# and every safety check passes, delete the leftover array file. Runs from clean.
process_orphans() {
  [ -s "$ORPHANS" ] || return 0
  local arr share rel size amt det st new tmp="$ORPHANS.tmp.$$" opens verdict why ext
  opens=$(open_targets)
  : > "$tmp"
  while IFS=$'\t' read -r arr share rel size amt det st; do
    [ -z "$arr" ] && continue
    new="$st"
    case "$st" in owned|deleted|gone|cleared) printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$arr" "$share" "$rel" "$size" "$amt" "$det" "$st" >> "$tmp"; continue ;; esac
    if [ ! -f "$arr" ]; then new="gone"
    elif [ -f "$(pool_path "$share" "$rel")" ]; then new="cleared"
    else
      ext="${rel##*.}"; ext="${ext,,}"
      if in_list "$ext" $FILETYPES; then
        # Sonarr/Radarr see the share path (/mnt/user/...), not the array disk path.
        verdict=$(arr_verdict "/mnt/user/$share/$rel")
      else
        # Subtitle sidecar: a leftover once no video with the same name exists any more.
        if sidecar_has_video "$share" "$rel"; then verdict="owned (its video still exists)"
        else verdict="leftover its video is gone"; fi
      fi
      case "$verdict" in
        "owned (its video still exists)") new="reported" ;;   # re-check next run: the video may turn out to be a leftover
        owned*) new="owned"; log INFO "not a leftover, keeping: $arr ($verdict; most likely moved to the array by the mover)" ;;
        unmanaged|none) new="unmanaged"; [ "$st" != "unmanaged" ] && log INFO "leftover check: no Sonarr/Radarr manages $arr; only reporting it" ;;
        error*) new="error"; log WARN "leftover check failed, will retry: ${verdict#error }" ;;
        leftover*)
          new="leftover"
          if [ "$ORPHAN_ACTION" = "delete" ]; then
            why=$(orphan_block_reason "$arr" "$size" "$amt" "$det" "$opens")
            if [ -n "$why" ]; then log INFO "leftover not deleted yet ($why): $arr"
            elif [ $DRY -eq 1 ]; then log DELETE "would delete leftover array file (${verdict#leftover }): $arr"
            elif rm -f -- "$arr"; then new="deleted"; log DELETE "deleted leftover array file (${verdict#leftover }): $arr"
              notify normal "Stagehand: leftover deleted" "$arr"
            fi
          elif [ "$st" != "leftover" ]; then
            log WARN "LEFTOVER confirmed (${verdict#leftover }): $arr - safe to delete; ORPHAN_ACTION=report so it was left in place"
          fi ;;
      esac
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$arr" "$share" "$rel" "$size" "${amt:--}" "$det" "$new" >> "$tmp"
  done < "$ORPHANS"
  # keep finished entries for 30 days, then forget them
  awk -F'\t' -v n="$NOW" '!($7 ~ /^(owned|deleted|gone|cleared)$/ && n-$6 > 2592000)' "$tmp" > "$ORPHANS"
  rm -f "$tmp"
}

cmd_run() {
  local out st fl host n sp
  check_orphans
  out=$(all_sessions)
  while IFS=$'\t' read -r st fl host n sp; do
    [ -z "$st" ] && continue
    if [ "$st" = "ERROR" ]; then log ERROR "$fl"; continue; fi
    if [ "$host" = "-" ]; then warn_once "map:$n:${sp%/*}" "server $n: no path mapping for: $sp"; continue; fi
    handle_title "$st" "$fl" "$host"
  done <<< "$out"
  seen_prune
  update_mover_ignore
}

########## clean ##########
remove_empty_dirs() {  # share reldir : rmdir upward while empty, stop at the share root
  local share="$1" d="$2"
  while [ -n "$d" ] && [ "$d" != "." ] && [ "$d" != "/" ]; do
    rmdir "/mnt/$POOL/$share/$d" 2>/dev/null || break
    d=$(dirname "$d")
  done
}

cmd_clean() {  # [all] : "all" ignores keep time (release-all)
  local all="${1:-}" opens pool share rel size copied last reason hrs arr kept=0 rel_n=0 busy=0 mover=0
  local why="expired"
  [ "$all" = "all" ] && { why="release-all"; log INFO "release-all: releasing every pool copy now, ignoring keep time"; }
  check_orphans
  opens=$(open_targets)
  while IFS=$'\t' read -r pool share rel size copied last reason _; do
    [ -z "$pool" ] && continue
    [ -f "$pool" ] || continue   # handled by check_orphans
    hrs=$(keep_hours_for "$rel")
    if [ "$all" != "all" ] && [ $((NOW - last)) -lt $((hrs * 3600)) ]; then kept=$((kept + 1)); continue; fi
    arr=$(array_copy "$share" "$rel")
    if [ -z "$arr" ]; then
      log WARN "$why but no array copy, keeping file and releasing it to the mover: $rel"
      [ $DRY -eq 0 ] && item_drop "$pool"; mover=$((mover + 1)); continue
    fi
    if [ "$(stat -c %s "$pool")" != "$(stat -c %s "$arr")" ]; then
      log WARN "$why but pool and array sizes differ, keeping file and releasing it to the mover: $rel"
      [ $DRY -eq 0 ] && item_drop "$pool"; mover=$((mover + 1)); continue
    fi
    if [ "$RELEASE_VERIFY" = "cmp" ] && ! cmp -s "$pool" "$arr"; then
      log WARN "$why but content differs from array copy, keeping file and releasing it to the mover: $rel"
      [ $DRY -eq 0 ] && item_drop "$pool"; mover=$((mover + 1)); continue
    fi
    if grep -qxF -- "$pool" <<< "$opens"; then log INFO "$why but open right now, retry later: $rel"; busy=$((busy + 1)); continue; fi
    if [ $DRY -eq 1 ]; then log RELEASE "would delete pool copy (array twin verified on ${arr%%/"$share"/*}): $rel"
    else
      rm -f -- "$pool" && { log RELEASE "deleted pool copy (array twin verified on ${arr%%/"$share"/*}): $rel"; rel_n=$((rel_n + 1)); }
      [ "$CLEAN_EMPTY_DIRS" = "yes" ] && remove_empty_dirs "$share" "$(dirname "$rel")"
      item_drop "$pool"
    fi
  done < <(cat "$ITEMS")
  process_orphans
  if [ "$all" = "all" ]; then
    log INFO "release-all done: released=$rel_n in-use=$busy left-for-mover=$mover"
    echo "release-all done: released=$rel_n in-use (retry later)=$busy left on the pool for the mover=$mover"
  else
    log INFO "clean done: released=$rel_n still-in-keep-window=$kept"
  fi
  update_mover_ignore
}

########## check / status ##########
cmd_check() {
  local ok=1 x out
  echo "Stagehand $STAGEHAND_VERSION  config: $CFG"
  echo "ENABLED=$ENABLED DRY_RUN=$DRY_RUN SWITCH_MODE=$SWITCH_MODE POOL=$POOL"
  for x in gdb rsync php docker; do command -v "$x" >/dev/null && echo "ok   $x found" || { echo "FAIL $x missing"; ok=0; }; done
  [ -d "/mnt/$POOL" ] && echo "ok   pool /mnt/$POOL mounted" || { echo "FAIL pool /mnt/$POOL missing"; ok=0; }
  for x in $SHARES; do
    if out=$(share_pool_ok "$x"); then echo "ok   share $x uses $POOL (pool first, array second)"; else echo "WARN share $x: $out"; fi
  done
  out=$(pool_healthy) && echo "ok   pool health" || echo "WARN pool health: $out"
  echo "--   pool free: $(df -h --output=avail "/mnt/$POOL" | tail -1 | tr -d ' ') (minimum ${MIN_FREE_GB}G)"
  echo "--   source roots: $(source_roots | paste -sd' ')"
  local n fl sp
  for n in $(server_ids); do
    use_server "$n"
    echo "--   server $n: $MEDIASERVER_TYPE at $MEDIASERVER_URL, path map:"; path_map_lines | sed 's/^/       /'
    if out=$(get_sessions); then echo "ok   server $n reachable; active sessions: $(grep -c . <<< "$out")"
      while IFS=$'\t' read -r x fl sp; do [ -n "$sp" ] && echo "       $x  $sp  ->  $(to_host_path "$sp" || echo 'NO MAPPING')"; done <<< "$out"
    else echo "FAIL server $n: $out"; ok=0; fi
  done
  use_server 1
  local a info
  for a in $(arr_ids); do
    if info=$(arr_call "$a" info 2>&1); then echo "ok   $(arr_name "$a") at $(arr_val "$a" URL): ${info#ok }"
    else echo "FAIL $(arr_name "$a") at $(arr_val "$a" URL): ${info#error: }"; [ "$ORPHAN_ACTION" = "delete" ] && ok=0; fi
  done
  [ -z "$(arr_ids)" ] && echo "--   no Sonarr/Radarr configured: leftover files can only be reported, not confirmed"
  if [ "$ORPHAN_ACTION" = "delete" ]; then
    echo "--   leftover array files: AUTO-DELETE is on (after ${ORPHAN_GRACE_MIN} min, only when Sonarr/Radarr confirm)"
    mover_tuning_reads_list || echo "WARN auto-delete is blocked while Mover Tuning's ignore list is off"
  else
    echo "--   leftover array files: report only"
  fi
  if [ "$MANAGE_MOVER_IGNORE" = "yes" ]; then
    mover_tuning_reads_list; case $? in
      0) echo "ok   Mover Tuning reads its ignore list" ;;
      1) echo "WARN Mover Tuning 'ignore files listed in text file' is OFF: cached copies are not protected from the mover" ;;
      *) echo "WARN Mover Tuning config not found" ;;
    esac
  fi
  [ -f "$KILL_FILE" ] && echo "WARN kill file present: $KILL_FILE (runs are disabled)"
  [ $ok -eq 1 ] && echo "RESULT: ready" || echo "RESULT: problems found"
}

cmd_explain() {  # read-only: show how each active session would be handled and why
  local out st sp host share rel arr dst fl why n
  out=$(SH_VERBOSE=1 all_sessions)
  [ -z "$out" ] && { echo "no active sessions with a file path"; return 0; }
  while IFS=$'\t' read -r st fl host n sp; do
    [ -z "$st" ] && continue
    [ "$st" = "ERROR" ] && { echo "$fl"; continue; }
    echo "== server $n [$st${fl:+, $fl}] $sp"
    [ "$host" != "-" ] || { echo "   -> no path mapping: SKIP"; continue; }
    echo "   host path: $host"
    IFS=$'\t' read -r share rel < <(split_share "$host")
    echo "   share: $share   rel: $rel"
    in_list "$share" $SHARES || { echo "   -> share not in SHARES: SKIP"; continue; }
    passes_filters "$rel" || { echo "   -> filtered out (FILETYPES/SUBFOLDERS/EXCLUSIONS): SKIP"; continue; }
    [[ "$host" == /mnt/user/* ]] || { echo "   -> media server reads this directly, not through /mnt/user: live switch impossible, SKIP"; continue; }
    why=$(share_pool_ok "$share") || { echo "   -> share not usable: $why: SKIP"; continue; }
    arr=$(array_copy "$share" "$rel"); dst=$(pool_path "$share" "$rel")
    echo "   array copy: ${arr:-none}"
    echo "   pool copy : $( [ -f "$dst" ] && echo "$dst" || echo none)"
    if [ -n "$arr" ]; then
      echo "   shfs fds on array copy: $(shfs_fds_for "$arr" | paste -sd',' || true)"
      [ -n "$(shfs_fds_for "$arr")" ] || echo "   (none: not being read from the array right now)"
    fi
    if [ -z "$arr" ]; then echo "   -> not on the array (already on pool or elsewhere): nothing to do"
    elif [ -f "$dst" ]; then echo "   -> already cached: run would retry the switch if the array fd is still open"
    elif [ "$fl" = "guess" ] && [ -z "$(shfs_fds_for "$arr")" ]; then echo "   -> one of several versions and not the one being read: SKIP"
    else echo "   -> run would copy after ${WAIT_SECONDS}s of playback, then switch$(is_episode "$rel" && [ "$NEXT_EPISODES" != "0" ] && echo ", then episodes: $NEXT_EPISODES")"; fi
  done <<< "$out"
}

cmd_status() {
  local pool share rel size copied last reason
  printf '%-8s %-8s %8s  %s\n' "age_h" "idle_h" "MB" "item"
  while IFS=$'\t' read -r pool share rel size copied last reason _; do
    [ -z "$pool" ] && continue
    printf '%-8s %-8s %8s  %s/%s [%s]%s\n' $(( (NOW - copied) / 3600 )) $(( (NOW - last) / 3600 )) $(( size / 1048576 )) \
      "$share" "$rel" "$reason" "$( [ -f "$pool" ] || echo ' (missing)')"
  done < "$ITEMS"
  local arr amt det st n=0 label
  while IFS=$'\t' read -r arr share rel size amt det st; do
    [ -z "$arr" ] && continue
    case "$st" in owned|deleted|gone|cleared) continue ;; esac
    [ -f "$arr" ] || continue
    case "$st" in
      leftover)  label="LEFTOVER (Sonarr/Radarr no longer own it)" ;;
      unmanaged) label="unknown (no Sonarr/Radarr manages it)" ;;
      error)     label="unknown (Sonarr/Radarr check failed)" ;;
      *)         label="waiting for the next check" ;;
    esac
    [ $n -eq 0 ] && echo && echo "Leftover array files (the pool copy disappeared). Checked against Sonarr/Radarr on every clean run:"
    n=$((n + 1)); echo "  $(date -d "@$det" '+%F %R')  $label  $arr"
  done < "$ORPHANS"
}

########## plugin helpers ##########
CRON_FILE="/boot/config/plugins/stagehand/stagehand.cron"

cmd_apply() {
  local me="$SCRIPT_DIR/stagehand.sh"
  if [ "$SCHEDULE" = "yes" ] && [ "$ENABLED" = "yes" ]; then
    mkdir -p "$(dirname "$CRON_FILE")"
    {
      echo "# Stagehand schedule (generated from stagehand.cfg; edit on the plugin page)"
      echo "$RUN_CRON bash $me run >/dev/null 2>&1"
      echo "$CLEAN_CRON bash $me clean >/dev/null 2>&1"
    } > "$CRON_FILE"
    echo "schedule on: run '$RUN_CRON', clean '$CLEAN_CRON'"
  else
    rm -f "$CRON_FILE"
    echo "schedule off"
  fi
  [ -x /usr/local/sbin/update_cron ] && /usr/local/sbin/update_cron
  return 0
}

cmd_enable_mover_ignore() {
  local f="$MOVER_TUNING_CFG" bak
  [ -f "$f" ] || { echo "Mover Tuning config not found: $f"; return 1; }
  bak="$f.stagehand-bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$f" "$bak" || { echo "backup failed"; return 1; }
  touch "$MOVER_IGNORE_FILE" 2>/dev/null
  local tmp="$f.stagehand.$$"
  tr -d '\r' < "$f" | grep -vE '^(filelistf|filelistv)=' > "$tmp"
  printf 'filelistf="yes"\nfilelistv="%s"\n' "$MOVER_IGNORE_FILE" >> "$tmp"
  mv -f "$tmp" "$f"
  echo "Mover Tuning now ignores files listed in $MOVER_IGNORE_FILE (backup: $bak)"
}

cmd_uninstall_cleanup() {
  local f="$MOVER_IGNORE_FILE" tmp
  [ -f "$f" ] || return 0
  tmp="$f.stagehand.$$"
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1; next} $0==e{skip=0; next} !skip' "$f" > "$tmp" && mv -f "$tmp" "$f"
  echo "removed Stagehand entries from $f"
}

########## main ##########
case "$CMD" in
  check) cmd_check; exit 0 ;;
  apply) cmd_apply; exit 0 ;;
  enable-mover-ignore) cmd_enable_mover_ignore; exit $? ;;
  uninstall-cleanup) cmd_uninstall_cleanup; exit 0 ;;
  pause) mkdir -p "$(dirname "$KILL_FILE")" && touch "$KILL_FILE" && echo "paused: all runs stop until resumed"; exit 0 ;;
  resume) rm -f "$KILL_FILE" && echo "resumed"; exit 0 ;;
  explain) cmd_explain; exit 0 ;;
  run|clean|status|release-all) ;;
  *) echo "usage: $0 [run|clean|release-all|check|explain|status|apply|pause|resume|enable-mover-ignore|uninstall-cleanup] [-c cfg]" >&2; exit 2 ;;
esac

state_init || { echo "cannot create state dir $STATE_DIR" >&2; exit 1; }
[ "$CMD" = "status" ] && { cmd_status; exit 0; }
# release-all is a manual action: it works while disabled or paused, and waits for a running cycle.
if [ "$CMD" != "release-all" ]; then
  [ "$ENABLED" = "yes" ] || exit 0
  [ -f "$KILL_FILE" ] && exit 0
fi

exec 9>"$LOCK"
if [ "$CMD" = "release-all" ]; then
  flock -w 300 9 || { echo "another Stagehand run is still busy after 5 minutes; try again" >&2; exit 1; }
else
  flock -n 9 || exit 0
fi
rotate_log
case "$CMD" in
  run) cmd_run ;;
  clean) cmd_clean ;;
  release-all) cmd_clean all ;;
esac
