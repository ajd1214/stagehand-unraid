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
#
# Design credit: alturismo's Cache Mover (https://github.com/alturismo/unraid-cache-mover).

set -o pipefail
# Use a UTF-8 locale when one exists (Unraid ships en_US.UTF-8, not C.UTF-8), else plain C.
for _l in en_US.UTF-8 en_US.utf8 C.UTF-8; do
  if locale -a 2>/dev/null | grep -qix "${_l/UTF-8/utf8}\|$_l"; then export LANG="$_l" LC_ALL="$_l"; break; fi
done
[ -z "$LC_ALL" ] && export LANG=C LC_ALL=C
unset _l

STAGEHAND_VERSION="0.1.0-stage1"
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
  else CFG="$SCRIPT_DIR/stagehand.cfg"; fi
fi
[ -f "$CFG" ] || { echo "config not found: $CFG" >&2; exit 2; }
# shellcheck source=stagehand.cfg
source <(tr -d '\r' < "$CFG")

: "${ENABLED:=no}" "${DRY_RUN:=yes}" "${KILL_FILE:=/boot/config/plugins/stagehand/DISABLE}"
: "${STATE_DIR:=/mnt/user/appdata/stagehand}" "${LOG_FILE:=$STATE_DIR/stagehand.log}" "${LOG_MAX_MB:=5}"
: "${SYSLOG:=yes}" "${NOTIFY:=errors}" "${POOL:=}" "${SHARES:=}" "${SUBFOLDERS:=}" "${EXCLUSIONS:=}"
: "${FILETYPES:=mkv mp4}" "${WAIT_SECONDS:=60}" "${NEXT_EPISODES:=0}" "${SWITCH_MODE:=switch}"
: "${GDB_TIMEOUT_SECONDS:=10}" "${KEEP_HOURS:=24}" "${KEEP_RULES:=}" "${RELEASE_VERIFY:=size}"
: "${MIN_FREE_GB:=100}" "${HEALTH_CHECK:=yes}" "${HEALTH_IO_ERROR_WINDOW_MIN:=60}"
: "${MAX_COPY_GB_PER_RUN:=60}" "${COPY_BWLIMIT_KBPS:=0}"
: "${MEDIASERVER_TYPE:=plex}" "${MEDIASERVER_URL:=http://127.0.0.1:32400}" "${MEDIASERVER_TOKEN:=auto}"
: "${MEDIASERVER_CONTAINER:=plex}" "${PATH_MAP:=auto}" "${MANAGE_MOVER_IGNORE:=no}"
: "${MOVER_IGNORE_FILE:=/mnt/user/system/mover/mover_ignore.txt}"
: "${MOVER_TUNING_CFG:=/boot/config/plugins/ca.mover.tuning/ca.mover.tuning.cfg}"
: "${SOURCE_ROOTS:=auto}" "${ALLOW_OTHER_POOL:=no}" "${ORPHAN_ACTION:=report}"

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
container_mounts() {  # prints "destination<TAB>source", longest destination first
  docker inspect "$MEDIASERVER_CONTAINER" --format '{{range .Mounts}}{{.Destination}}{{"\t"}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null \
    | sed '/^$/d' | awk -F'\t' '{print length($1) "\t" $0}' | sort -rn | cut -f2-
}

path_map_lines() {
  if [ "$PATH_MAP" = "auto" ]; then
    container_mounts
  else
    local p; for p in $PATH_MAP; do printf '%s\t%s\n' "${p%%:*}" "${p#*:}"; done \
      | awk -F'\t' '{print length($1) "\t" $0}' | sort -rn | cut -f2-
  fi
}

# Media-server path -> host path, using the longest matching container mount.
to_host_path() {
  local p="$1" dst src
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
  SH_TYPE="$MEDIASERVER_TYPE" SH_URL="$MEDIASERVER_URL" SH_TOKEN="$tok" SH_VERBOSE="${SH_VERBOSE:-0}" python3 - <<'PY'
import os, sys, json, urllib.request, xml.etree.ElementTree as ET
t = os.environ["SH_TYPE"]; u = os.environ["SH_URL"].rstrip("/"); k = os.environ["SH_TOKEN"]
verbose = os.environ.get("SH_VERBOSE") == "1"
try:
    if t == "plex":
        hdr = {"X-Plex-Token": k, "Accept": "application/xml"}
        def get(path):
            return ET.fromstring(urllib.request.urlopen(urllib.request.Request(u + path, headers=hdr), timeout=10).read())
        root = get("/status/sessions")
        for item in root:
            p = item.find("Player")
            st = p.get("state", "") if p is not None else ""
            files = [x.get("file") for x in item.iter("Part") if x.get("file")]
            how = "session"
            if not files and item.get("ratingKey"):
                # Transcoded sessions may not carry the source path; ask the library for it.
                how = "library"
                m = item.find("Media"); mid = m.get("id") if m is not None else None
                meta = get("/library/metadata/" + item.get("ratingKey"))
                allf, match = [], []
                for med in meta.iter("Media"):
                    for x in med.iter("Part"):
                        if x.get("file"):
                            allf.append(x.get("file"))
                            if mid and med.get("id") == mid:
                                match.append(x.get("file"))
                files = match or allf
            if verbose:
                sys.stderr.write("session: %s | %s | state=%s | files=%d (%s)\n" % (
                    item.tag, item.get("title", "?"), st or "?", len(files), how))
            for f in files:
                print(st + "\t" + f)
    else:
        path = "/emby/Sessions" if t == "emby" else "/Sessions"
        hdr = {"Authorization": 'MediaBrowser Token="%s"' % k, "X-Emby-Token": k, "Accept": "application/json"}
        data = json.load(urllib.request.urlopen(urllib.request.Request(u + path, headers=hdr), timeout=10))
        for s in data:
            n = s.get("NowPlayingItem")
            if n and n.get("Path"):
                st = "paused" if (s.get("PlayState") or {}).get("IsPaused") else "playing"
                print(st + "\t" + n["Path"])
except Exception as e:
    print("media server query failed: %s" % e)
    sys.exit(1)
PY
}

########## pool checks ##########
pool_devices() {  # short device names (sda sdc ...) backing the pool
  local fs; fs=$(findmnt -no FSTYPE "/mnt/$POOL" 2>/dev/null)
  case "$fs" in
    btrfs) btrfs filesystem show "/mnt/$POOL" 2>/dev/null | grep -oP 'path /dev/\K[a-z0-9]+' | sed -E 's/p?[0-9]+$//' ;;
    *) findmnt -no SOURCE "/mnt/$POOL" 2>/dev/null | sed -E 's#^/dev/##; s/p?[0-9]+$//' ;;
  esac
}

pool_healthy() {  # 0 = ok; prints reason when not ok
  findmnt -no OPTIONS "/mnt/$POOL" 2>/dev/null | tr ',' '\n' | grep -qx ro && { echo "pool is read-only"; return 1; }
  [ "$HEALTH_CHECK" = "yes" ] || return 0
  local fs; fs=$(findmnt -no FSTYPE "/mnt/$POOL" 2>/dev/null)
  if [ "$fs" = "btrfs" ]; then
    btrfs device stats -c "/mnt/$POOL" >/dev/null 2>&1 || { echo "btrfs device stats report errors"; return 1; }
  elif [ "$fs" = "zfs" ]; then
    zpool status -x "$POOL" 2>/dev/null | grep -q "is healthy" || { echo "zpool not healthy"; return 1; }
  fi
  local devs last ts
  devs=$(pool_devices | sort -u | paste -sd'|')
  if [ -n "$devs" ] && [ -f /var/log/syslog ]; then
    last=$(grep -aE "I/O error, dev ($devs)[, ]" /var/log/syslog | tail -1 | cut -c1-15)
    if [ -n "$last" ]; then
      ts=$(date -d "$last" +%s 2>/dev/null || echo 0)
      [ "$ts" -gt "$NOW" ] && ts=$(date -d "$last last year" +%s 2>/dev/null || echo 0)
      [ $((NOW - ts)) -lt $((HEALTH_IO_ERROR_WINDOW_MIN * 60)) ] && { echo "recent I/O errors on pool device(s) ($devs) at $last"; return 1; }
    fi
  fi
  return 0
}

pool_has_room() {  # $1 = bytes to add
  local avail; avail=$(df -B1 --output=avail "/mnt/$POOL" 2>/dev/null | tail -1 | tr -d ' ')
  [ -n "$avail" ] && [ $((avail - $1)) -gt $((MIN_FREE_GB * 1024 * 1024 * 1024)) ]
}

share_pool_ok() {  # target pool must be the share's primary pool unless ALLOW_OTHER_POOL=yes
  local share="$1" sp
  [ "$ALLOW_OTHER_POOL" = "yes" ] && return 0
  sp=$(tr -d '\r' 2>/dev/null < "/boot/config/shares/$share.cfg" | grep -oP '^shareCachePool="\K[^"]*')
  [ "$sp" = "$POOL" ]
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
handle_title() {  # state server_path
  local st="$1" sp="$2" host share rel arr dst first size
  host=$(to_host_path "$sp") || { log INFO "no path mapping for: $sp"; return; }
  IFS=$'\t' read -r share rel < <(split_share "$host") || return
  [ -n "$rel" ] || return
  in_list "$share" $SHARES || return
  passes_filters "$rel" || return
  dst=$(pool_path "$share" "$rel")
  arr=$(array_copy "$share" "$rel")

  if [ -z "$arr" ]; then
    # Not on the array: either only on the pool already, or unknown location. Nothing to do.
    [ -n "$(item_get "$dst")" ] && [ $DRY -eq 0 ] && item_touch "$dst"
    return
  fi

  share_pool_ok "$share" || { warn_once "pool:$share" "share $share does not use $POOL as its primary pool; skipping its titles (ALLOW_OTHER_POOL=no)"; return; }

  if [ -f "$dst" ]; then
    # Already cached. Keep it alive and retry the switch if playback is still on the array.
    if [ "$(stat -c %s "$dst")" = "$(stat -c %s "$arr")" ]; then
      [ -n "$(item_get "$dst")" ] && [ $DRY -eq 0 ] && item_touch "$dst"
      switch_playback "$arr" "$dst" "$rel" 1
    fi
    return
  fi

  first=$(seen_first "$share/$rel")
  if [ $((NOW - first)) -lt "$WAIT_SECONDS" ]; then
    log INFO "seen $st, waiting ${WAIT_SECONDS}s before copy: $rel"
    return
  fi

  local why
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
  copy_next_episodes "$share" "$rel"
}

copy_next_episodes() {  # share rel
  local share="$1" rel="$2" dir base n=0 f arr dst size budget
  [ "$NEXT_EPISODES" -gt 0 ] 2>/dev/null || return 0
  dir=$(dirname "$rel"); base=$(basename "$rel")
  case "${dir,,}" in *season*|*specials*) ;; *) return 0 ;; esac
  budget=$((MAX_COPY_GB_PER_RUN * 1024 * 1024 * 1024))
  while IFS= read -r f; do
    [ "$n" -ge "$NEXT_EPISODES" ] && break
    passes_filters "$dir/$f" || continue
    n=$((n + 1))
    dst=$(pool_path "$share" "$dir/$f")
    [ -f "$dst" ] && continue
    arr=$(array_copy "$share" "$dir/$f") || continue
    size=$(stat -c %s "$arr")
    [ "$size" -le "$budget" ] || { log INFO "next-episode copy skipped (MAX_COPY_GB_PER_RUN): $dir/$f"; break; }
    pool_has_room "$size" || { log WARN "not enough free space for next episode: $dir/$f"; break; }
    budget=$((budget - size))
    if [ $DRY -eq 1 ]; then log COPY "would copy next episode $(( size / 1048576 )) MB: $dir/$f"
    else copy_to_pool "$arr" "$dst" "$share" "$dir/$f" && item_upsert "$dst" "$share" "$dir/$f" "$size" "$NOW" "$NOW" "next" "$(stat -c %Y "$arr")"; fi
  done < <(ls -1 "/mnt/user/$share/$dir" 2>/dev/null | LC_ALL=C sort | awk -v b="$base" 'f{print} $0==b{f=1}')
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
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$arr" "$share" "$rel" "$size" "${amt:-}" "$NOW" "reported" >> "$ORPHANS"
      item_drop "$pool"
    fi
  done < <(cat "$ITEMS")
}

cmd_run() {
  local out st sp
  check_orphans
  if ! out=$(get_sessions); then log ERROR "$out"; return 1; fi
  [ -z "$out" ] && { seen_prune; return 0; }
  while IFS=$'\t' read -r st sp; do
    [ -n "$sp" ] && handle_title "$st" "$sp"
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

cmd_clean() {
  local opens pool share rel size copied last reason hrs arr kept=0 rel_n=0
  check_orphans
  opens=$(open_targets)
  while IFS=$'\t' read -r pool share rel size copied last reason _; do
    [ -z "$pool" ] && continue
    [ -f "$pool" ] || continue   # handled by check_orphans
    hrs=$(keep_hours_for "$rel")
    if [ $((NOW - last)) -lt $((hrs * 3600)) ]; then kept=$((kept + 1)); continue; fi
    arr=$(array_copy "$share" "$rel")
    if [ -z "$arr" ]; then
      log WARN "expired but no array copy, keeping file and releasing it to the mover: $rel"
      [ $DRY -eq 0 ] && item_drop "$pool"; continue
    fi
    if [ "$(stat -c %s "$pool")" != "$(stat -c %s "$arr")" ]; then
      log WARN "expired but pool and array sizes differ, keeping file and releasing it to the mover: $rel"
      [ $DRY -eq 0 ] && item_drop "$pool"; continue
    fi
    if [ "$RELEASE_VERIFY" = "cmp" ] && ! cmp -s "$pool" "$arr"; then
      log WARN "expired but content differs from array copy, keeping file and releasing it to the mover: $rel"
      [ $DRY -eq 0 ] && item_drop "$pool"; continue
    fi
    if grep -qxF -- "$pool" <<< "$opens"; then log INFO "expired but open right now, retry later: $rel"; continue; fi
    if [ $DRY -eq 1 ]; then log RELEASE "would delete pool copy (array twin verified on ${arr%%/"$share"/*}): $rel"
    else
      rm -f -- "$pool" && { log RELEASE "deleted pool copy (array twin verified on ${arr%%/"$share"/*}): $rel"; rel_n=$((rel_n + 1)); }
      remove_empty_dirs "$share" "$(dirname "$rel")"
      item_drop "$pool"
    fi
  done < <(cat "$ITEMS")
  log INFO "clean done: released=$rel_n still-in-keep-window=$kept"
  update_mover_ignore
}

########## check / status ##########
cmd_check() {
  local ok=1 x out
  echo "Stagehand $STAGEHAND_VERSION  config: $CFG"
  echo "ENABLED=$ENABLED DRY_RUN=$DRY_RUN SWITCH_MODE=$SWITCH_MODE POOL=$POOL"
  for x in gdb rsync python3 docker; do command -v "$x" >/dev/null && echo "ok   $x found" || { echo "FAIL $x missing"; ok=0; }; done
  [ -d "/mnt/$POOL" ] && echo "ok   pool /mnt/$POOL mounted" || { echo "FAIL pool /mnt/$POOL missing"; ok=0; }
  for x in $SHARES; do
    if share_pool_ok "$x"; then echo "ok   share $x uses $POOL"; else echo "WARN share $x primary pool is not $POOL"; fi
  done
  out=$(pool_healthy) && echo "ok   pool health" || echo "WARN pool health: $out"
  echo "--   pool free: $(df -h --output=avail "/mnt/$POOL" | tail -1 | tr -d ' ') (minimum ${MIN_FREE_GB}G)"
  echo "--   source roots: $(source_roots | paste -sd' ')"
  echo "--   path map:"; path_map_lines | sed 's/^/       /'
  if out=$(get_sessions); then echo "ok   media server reachable; active sessions: $(grep -c . <<< "$out")"
    while IFS=$'\t' read -r x sp; do [ -n "$sp" ] && echo "       $x  $sp  ->  $(to_host_path "$sp" || echo 'NO MAPPING')"; done <<< "$out"
  else echo "FAIL media server: $out"; ok=0; fi
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
  local out st sp host share rel arr dst
  if ! out=$(SH_VERBOSE=1 get_sessions); then echo "media server: $out"; return 1; fi
  [ -z "$out" ] && { echo "no active sessions with a file path"; return 0; }
  while IFS=$'\t' read -r st sp; do
    [ -z "$sp" ] && continue
    echo "== [$st] $sp"
    host=$(to_host_path "$sp") || { echo "   -> no path mapping: SKIP"; continue; }
    echo "   host path: $host"
    IFS=$'\t' read -r share rel < <(split_share "$host")
    echo "   share: $share   rel: $rel"
    in_list "$share" $SHARES || { echo "   -> share not in SHARES: SKIP"; continue; }
    passes_filters "$rel" || { echo "   -> filtered out (FILETYPES/SUBFOLDERS/EXCLUSIONS): SKIP"; continue; }
    arr=$(array_copy "$share" "$rel"); dst=$(pool_path "$share" "$rel")
    echo "   array copy: ${arr:-none}"
    echo "   pool copy : $( [ -f "$dst" ] && echo "$dst" || echo none)"
    if [ -n "$arr" ]; then
      echo "   shfs fds on array copy: $(shfs_fds_for "$arr" | paste -sd',' || true)"
      [ -n "$(shfs_fds_for "$arr")" ] || echo "   (none: not being read from the array right now)"
    fi
    if [ -z "$arr" ]; then echo "   -> not on the array (already on pool or elsewhere): nothing to do"
    elif [ -f "$dst" ]; then echo "   -> already cached: run would retry the switch if the array fd is still open"
    else echo "   -> run would copy after ${WAIT_SECONDS}s of playback, then switch"; fi
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
  local arr amt det st n=0
  while IFS=$'\t' read -r arr share rel size amt det st; do
    [ -z "$arr" ] && continue
    [ "$st" = "reported" ] || continue
    if [ -f "$arr" ] && [ ! -f "$(pool_path "$share" "$rel")" ]; then
      [ $n -eq 0 ] && echo && echo "Possible leftover array files (pool copy disappeared; check in Sonarr/Radarr before deleting):"
      n=$((n + 1)); echo "  $(date -d "@$det" '+%F %R')  $arr"
    fi
  done < "$ORPHANS"
}

########## main ##########
case "$CMD" in
  check) cmd_check; exit 0 ;;
  explain) cmd_explain; exit 0 ;;
  run|clean|status) ;;
  *) echo "usage: $0 [run|clean|check|explain|status] [-c cfg]" >&2; exit 2 ;;
esac

state_init || { echo "cannot create state dir $STATE_DIR" >&2; exit 1; }
[ "$CMD" = "status" ] && { cmd_status; exit 0; }
[ "$ENABLED" = "yes" ] || exit 0
[ -f "$KILL_FILE" ] && exit 0

exec 9>"$LOCK"
flock -n 9 || exit 0
rotate_log
case "$CMD" in
  run) cmd_run ;;
  clean) cmd_clean ;;
esac
