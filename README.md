# Stagehand for Unraid

Live-switch playing media from Unraid array disks to an SSD pool. Plex, Jellyfin and Emby. Never touches array files.

When someone starts watching a title that lives on a spinning array disk, Stagehand copies that file to an SSD pool and switches the running playback over to the SSD copy without interrupting it. Seeks and resumes then come from the SSD, and the array disk can spin down. Later, once the copy has not been played for a set time, Stagehand deletes the pool copy, but only after proving an identical copy is still on the array.

> **Status: early plugin release.** Dry-run is the default and the schedule is off until you turn it on. Plex is the primary target; Jellyfin and Emby are experimental.

## How it works

1. **Detect.** Asks the media server which files are playing (Plex `/status/sessions`, Jellyfin/Emby `/Sessions`).
2. **Locate.** Maps the server's path to the host path using the container's volume mounts, then checks `/mnt/diskN/<share>/<path>` directly. No directory walks.
3. **Wait.** A title must be seen playing for `WAIT_SECONDS` before it is copied, so previews and browsing are ignored.
4. **Copy.** Copies the playing file to `/mnt/<pool>/<share>/<path>` (rsync writes a hidden temp file and renames it only when complete), then verifies the size.
5. **Switch.** Finds the Unraid user-share process (`shfs`) file handle that is reading the array copy and swaps it to the SSD copy with `gdb`, keeping the read position. Retried every run until it succeeds or playback ends.
6. **More episodes.** `NEXT_EPISODES` copies the next N episodes, every later episode (`rest`) or the whole season folder (`season`), up to `MAX_COPY_GB_PER_RUN` per run, so the array disk can stay asleep for the rest of the season.
7. **Release.** `clean` deletes a pool copy only when its keep time has passed, an array copy with the same name and size exists (or byte-identical with `RELEASE_VERIFY="cmp"`), and nothing has it open.

## Keeping array disks asleep

- A title that already plays from the SSD never touches the array: Stagehand compares against the size it recorded at copy time and finds open array handles in `/proc`.
- Next episodes are topped up only when nothing later of that season is on the SSD yet, and at most once per 6 hours per title. With `NEXT_EPISODES="3"` that means about one short disk wake-up every three episodes; `season` means one per season.
- `ARRAY_WAKE_HOURS` (for example `"4"`, the hour the mover runs) limits releasing expired copies and checking leftover files to those hours. Expired copies stay on the SSD until then. **Release all now** ignores it.
- Disk wake-ups from other tools (library scans in Plex, Sonarr/Radarr refreshes, Tdarr, Bazarr) are outside Stagehand; the Dynamix Cache Directories plugin keeps folder listings in RAM for those.

## Safety rules

- Never writes to, moves or deletes anything on array disks.
- Never deletes a pool copy without a verified array twin. If the pool copy changed (for example a re-encode), it is kept and left for the mover.
- Never copies to a read-only pool. Optionally pauses copying after new filesystem errors or disk I/O errors (`SKIP_ON_FS_ERRORS`, `SKIP_ON_IO_ERRORS`, `IO_ERROR_WINDOW_MIN`). Never lets the pool drop below `MIN_FREE_GB`.
- Only works on shares listed in `SHARES`, and by default only when the target pool is that share's own primary pool.
- One run at a time (lock file). `run` and `clean` never overlap.
- Kill switch: create the file in `KILL_FILE` and every run exits immediately.

## Requirements

- Unraid 7.x with the media files in user shares that use the SSD pool as primary storage and the array as secondary.
- The media server must read media through `/mnt/user/...` paths (the default for Docker templates).
- `gdb` for the live switch. The plugin installs it when it is missing. Everything else (`php`, `rsync`, `docker`) is part of Unraid.

## Library layouts

Stagehand does not care how shares are organized. Set `SHARES` to the user shares holding media and `SUBFOLDERS` to the folder names inside them, for example:

| Layout | Settings |
|---|---|
| Separate shares `tv`, `movies` | `SHARES="tv movies"`, `SUBFOLDERS="shows films ..."` |
| One `media` share with `tv/` and `movies/` | `SHARES="media"`, `SUBFOLDERS="tv movies"` |
| TRaSH-style `data` share (`data/media/tv`) | `SHARES="data"`, `SUBFOLDERS="tv movies"` |

Requirements and limits:

- Each share must be set to **pool first, array second**. Shares set to array first, pool second ("prefer"), pool-only or array-only are skipped with a warning.
- The media server must read through `/mnt/user/...`. If it reads `/mnt/diskN` or a pool directly, live switching is impossible and Stagehand skips that share with a warning.
- Episodes are recognized by an `S01E02`-style name or a season folder (Season, Specials, Staffel, Saison, Temporada, Stagione, Seizoen). Anything else gets no next-episode copy.
- When Plex lists several versions of a title without saying which is playing, only the version actually being read is copied.
- Media servers on another machine or a VM need a manual `PATH_MAP`, for example `PATH_MAP="Z:\TV Shows=>/mnt/user/tv"`.
- Up to three media servers at once (any mix of Plex, Jellyfin and Emby). mergerfs setups are not supported yet.

## Install

From the Unraid web UI: **Plugins → Install Plugin**, paste the `stagehand.plg` URL, **Install**.

From the command line, or while the repository is private, copy `stagehand.plg` and the two files in `packages/` to the server first, then:

```bash
mkdir -p /boot/config/plugins/stagehand
cp packages/*.txz /boot/config/plugins/stagehand/
plugin install /path/to/stagehand.plg
```

The plugin page is **Utilities → Stagehand**, with three tabs:

- **Stagehand:** status, Pause/Resume, the "Enable in Mover Tuning" button and every setting. **Apply** saves and updates the schedule.
- **Log:** the last 500 log lines.
- **Lists:** cached copies, leftover array files, and a **Run check** button that validates everything without changing anything.

Settings live in `/boot/config/plugins/stagehand/stagehand.cfg`. Removing the plugin keeps that file and the state folder, removes the schedule, and removes Stagehand's lines from the Mover Tuning ignore file.

Recommended first steps: leave **Dry run** on, run the check on the Lists tab, play an array-only title and read the Log tab. Turn dry run off and the schedule on only after that looks right.

## Commands

The plugin installs the script at `/usr/local/emhttp/plugins/stagehand/stagehand.sh`. Everything on the plugin page can also be run there:

| Command | What it does |
|---|---|
| `check` | Validate config and environment. Changes nothing. |
| `explain` | Show how each active playback session would be handled and why. Changes nothing. |
| `run` | One cycle: detect, copy, switch, copy next episodes. |
| `clean` | Release expired pool copies with a verified array twin. |
| `release-all` | Release every pool copy now, ignoring keep time. Same checks as `clean`; copies in use are skipped. Works while paused, so **Pause now** then **Release all now** empties the pool. |
| `status` | List tracked copies and leftover array files. |
| `apply` | Write or remove the schedule from the saved settings. |
| `pause` / `resume` | Create or remove the kill file. |
| `enable-mover-ignore` | Back up Mover Tuning's config and turn on its ignore list. |

Add `-c /path/to/stagehand.cfg` to use a different config file.

With `DRY_RUN="yes"` every action is logged as "would ..." and nothing is copied, switched, deleted or edited.

## Building

`./build.sh` packs `src/` into `packages/stagehand-<version>.txz` and writes its SHA256 into `stagehand.plg`. Bump the version entity in `stagehand.plg` first.

## Turning it off fast

Press **Pause now** on the plugin page, or:

```bash
touch /boot/config/plugins/stagehand/DISABLE     # stop all runs immediately
rm /boot/config/plugins/stagehand/DISABLE        # resume
```

Turning Stagehand off never affects playback. Plex keeps reading whichever copy it has open, and Unraid serves the pool copy on the next open while it exists.

## Logs and state

- Log: `LOG_FILE` (default `/mnt/user/appdata/stagehand/stagehand.log`), rotated at `LOG_MAX_MB`. Also syslog with tag `stagehand`.
- Tracked copies: `STATE_DIR/items.tsv`.

## Mover Tuning

With `MANAGE_MOVER_IGNORE="yes"`, Stagehand keeps a marked block of its cached files in Mover Tuning's ignore file so the mover leaves them alone until Stagehand releases them. Lines outside the block are never touched. This only works when Mover Tuning's "Ignore files and folders listed inside of a text file" option (Settings → Scheduler) is on, with the same file path. The plugin page shows whether it is on and offers an **Enable in Mover Tuning** button, which backs up Mover Tuning's config first. Stagehand never changes it without that confirmation.

## Leftover (orphan) files

When a file exists on both the pool and the array, Unraid serves the pool copy, and a delete, rename or overwrite through `/mnt/user` changes **only the pool copy** (tested on Unraid 7.3.4). So if Sonarr, Radarr or Maintainerr deletes, upgrades or renames a title while Stagehand has it cached, the old array copy becomes visible again, and Plex shows it.

Every run notices tracked pool copies that disappeared without Stagehand deleting them. Every clean run then asks each configured Sonarr/Radarr (up to six, `ARR1_*` to `ARR6_*`) about the array file:

| Answer | Meaning | What Stagehand does |
|---|---|---|
| An instance still tracks this exact file | It is the real copy; the mover moved it | Keeps it, stops listing it |
| An instance manages the folder but no longer tracks the file | Leftover | `report`: lists it and logs it. `delete`: deletes it after the checks below |
| No instance manages the folder | Unknown | Lists it. Never deleted |
| An instance did not answer | Unknown | Retries next clean run. Never deleted |

`ORPHAN_ACTION="delete"` deletes array files, so it only acts when **all** of these hold: Sonarr/Radarr confirm the leftover, Mover Tuning's ignore list is on, the array file's size and modified time match what Stagehand recorded when it cached it, nothing has it open, and `ORPHAN_GRACE_MIN` has passed. Matching subtitle files are deleted once their video is gone. Run with `report` first and check what the Lists tab shows.

A same-name replacement (for example a repack) writes the new file to the pool and leaves the old array copy. `clean` sees the size difference, keeps the pool file and stops tracking it.

## Known limits

- The live switch uses `gdb` to attach to `shfs`, the process that serves every user share. While attached, `shfs` pauses briefly. Stagehand logs the measured pause for every switch so it can be judged before scheduled use. `GDB_TIMEOUT_SECONDS` caps it.
- Target pool other than the share's own primary pool is off by default (`ALLOW_OTHER_POOL`). It is not yet confirmed that Unraid serves such a copy on later opens.
- Jellyfin and Emby session parsing is untested.

## Credits

Stagehand is inspired by and builds on the design of [Cache Mover (Media Caching)](https://github.com/alturismo/unraid-cache-mover) by **alturismo**. The core idea of copying the playing file to a pool and live-switching the open file handle with `gdb` is his. Stagehand is an independent rewrite focused on fast file lookup, retried switching and verified cleanup.

## License

MIT. See [LICENSE](LICENSE). The bundled gdb package is GPLv3+; see [NOTICE.md](NOTICE.md) for third-party licenses and the acknowledgment of Cache Mover.
