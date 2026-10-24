# Stagehand for Unraid

Live-switch playing media from Unraid array disks to an SSD pool. Plex, Jellyfin and Emby. Never touches array files.

When someone starts watching a title that lives on a spinning array disk, Stagehand copies that file to an SSD pool and switches the running playback over to the SSD copy without interrupting it. Seeks and resumes then come from the SSD, and the array disk can spin down. Later, once the copy has not been played for a set time, Stagehand deletes the pool copy, but only after proving an identical copy is still on the array.

> **Status: Stage 1 (script).** Dry-run is the default. Plex is the primary target; Jellyfin and Emby are experimental. A GUI plugin (`.plg` with settings, log and list pages) is Stage 2.

## How it works

1. **Detect.** Asks the media server which files are playing (Plex `/status/sessions`, Jellyfin/Emby `/Sessions`).
2. **Locate.** Maps the server's path to the host path using the container's volume mounts, then checks `/mnt/diskN/<share>/<path>` directly. No directory walks.
3. **Wait.** A title must be seen playing for `WAIT_SECONDS` before it is copied, so previews and browsing are ignored.
4. **Copy.** Copies the playing file to `/mnt/<pool>/<share>/<path>` (rsync writes a hidden temp file and renames it only when complete), then verifies the size.
5. **Switch.** Finds the Unraid user-share process (`shfs`) file handle that is reading the array copy and swaps it to the SSD copy with `gdb`, keeping the read position. Retried every run until it succeeds or playback ends.
6. **Next episode.** Copies the next `NEXT_EPISODES` episodes of the season ahead of time.
7. **Release.** `clean` deletes a pool copy only when its keep time has passed, an array copy with the same name and size exists (or byte-identical with `RELEASE_VERIFY="cmp"`), and nothing has it open.

## Safety rules

- Never writes to, moves or deletes anything on array disks.
- Never deletes a pool copy without a verified array twin. If the pool copy changed (for example a re-encode), it is kept and left for the mover.
- Skips copying when the pool is read-only, reports filesystem errors, logged recent I/O errors, or would fall below `MIN_FREE_GB`.
- Only works on shares listed in `SHARES`, and by default only when the target pool is that share's own primary pool.
- One run at a time (lock file). `run` and `clean` never overlap.
- Kill switch: create the file in `KILL_FILE` and every run exits immediately.

## Requirements

- Unraid 7.x with the media files in user shares that use the SSD pool as primary storage and the array as secondary.
- The media server must read media through `/mnt/user/...` paths (the default for Docker templates).
- `gdb`, `python3`, `rsync`, `docker`. `gdb` and `python3` may not be part of stock Unraid; on DENNAS they currently come from the Cache Mover plugin's packages. Stage 2 will install them itself.

## Install (Stage 1, manual)

```bash
mkdir -p /boot/config/plugins/stagehand
cp stagehand.sh stagehand.cfg /boot/config/plugins/stagehand/
nano /boot/config/plugins/stagehand/stagehand.cfg   # review every setting
bash /boot/config/plugins/stagehand/stagehand.sh check
```

`check` changes nothing. It reports the tools found, pool health and free space, share pool settings, the path map, active playback sessions and how each maps to a host path, and whether Mover Tuning reads its ignore list.

## Commands

| Command | What it does |
|---|---|
| `stagehand.sh check` | Validate config and environment. Changes nothing. |
| `stagehand.sh explain` | Show how each active playback session would be handled and why. Changes nothing. |
| `stagehand.sh run` | One cycle: detect, copy, switch, copy next episodes. Schedule every minute. |
| `stagehand.sh clean` | Release expired pool copies with a verified array twin. Schedule hourly. |
| `stagehand.sh status` | List tracked copies with age and idle hours. |

Add `-c /path/to/stagehand.cfg` to use a different config file.

With `DRY_RUN="yes"` every action is logged as "would ..." and nothing is copied, switched, deleted or edited.

## Scheduling (after testing)

With the User Scripts plugin, create two scripts:

- `stagehand-run`, custom schedule `* * * * *`: `bash /boot/config/plugins/stagehand/stagehand.sh run`
- `stagehand-clean`, custom schedule `17 * * * *`: `bash /boot/config/plugins/stagehand/stagehand.sh clean`

## Turning it off fast

```bash
touch /boot/config/plugins/stagehand/DISABLE     # stop all runs immediately
rm /boot/config/plugins/stagehand/DISABLE        # resume
```

Turning Stagehand off never affects playback. Plex keeps reading whichever copy it has open, and Unraid serves the pool copy on the next open while it exists.

## Logs and state

- Log: `LOG_FILE` (default `/mnt/user/appdata/stagehand/stagehand.log`), rotated at `LOG_MAX_MB`. Also syslog with tag `stagehand`.
- Tracked copies: `STATE_DIR/items.tsv`.

## Mover Tuning

With `MANAGE_MOVER_IGNORE="yes"`, Stagehand keeps a marked block of its cached files in Mover Tuning's ignore file so the mover leaves them alone until Stagehand releases them. Lines outside the block are never touched. This only works when Mover Tuning's "ignore files listed inside of a text file" option is on; `check` warns when it is off.

## Leftover (orphan) files

When a file exists on both the pool and the array, Unraid serves the pool copy, and a delete, rename or overwrite through `/mnt/user` changes **only the pool copy** (tested on Unraid 7.3.4). So if Sonarr, Radarr or Maintainerr deletes, upgrades or renames a title while Stagehand has it cached, the old array copy becomes visible again.

Every run checks for tracked pool copies that disappeared without Stagehand deleting them. Each one is logged as `ORPHAN`, sent as an Unraid notification and listed by `stagehand.sh status`. Stagehand does not delete these array files: a mover run can produce the same picture (pool copy gone, array copy present) when the array copy is the real one. Check in Sonarr or Radarr before deleting.

A same-name replacement (for example a repack) writes the new file to the pool and leaves the old array copy. `clean` sees the size difference, keeps the pool file and stops tracking it.

## Known limits

- The live switch uses `gdb` to attach to `shfs`, the process that serves every user share. While attached, `shfs` pauses briefly. Stage 1 logs the measured pause for every switch so it can be judged before scheduled use. `GDB_TIMEOUT_SECONDS` caps it.
- Target pool other than the share's own primary pool is off by default (`ALLOW_OTHER_POOL`). It is not yet confirmed that Unraid serves such a copy on later opens.
- Jellyfin and Emby session parsing is untested.

## Credits

Stagehand is inspired by and builds on the design of [Cache Mover (Media Caching)](https://github.com/alturismo/unraid-cache-mover) by **alturismo**. The core idea of copying the playing file to a pool and live-switching the open file handle with `gdb` is his. Stagehand is an independent rewrite focused on fast file lookup, retried switching and verified cleanup.

## License

MIT. See [LICENSE](LICENSE).
