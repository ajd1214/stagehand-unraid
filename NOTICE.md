# Notices

## Stagehand

Stagehand for Unraid is Copyright (c) 2026 ajd1214 and released under the MIT License (see [LICENSE](LICENSE)).

## Acknowledgment: Cache Mover by alturismo

Stagehand was inspired by [Cache Mover (Media Caching)](https://github.com/alturismo/unraid-cache-mover), Copyright (c) 2024 alturismo, released under the MIT License. The idea of copying the playing file to a pool and live-switching the open file with `gdb` comes from that project. Stagehand is an independent rewrite and does not contain Cache Mover source code.

## Third-party software included in this repository

### GNU gdb 15.2 (`packages/gdb-15.2-x86_64-3.txz`)

- What it is: a Slackware binary package of the GNU Project Debugger, used by Stagehand for the live switch. It is installed only when `gdb` is not already present.
- License: GNU General Public License, version 3 or later (GPLv3+). It is not covered by Stagehand's MIT License.
- Source code: <https://ftp.gnu.org/gnu/gdb/gdb-15.2.tar.xz> (GNU), with the Slackware build scripts at <https://slackware.osuosl.org/slackware64-current/source/d/gdb/>.
- Where this copy came from: the package distributed in the Cache Mover repository (`packages/gdb-15.2-x86_64-3.txz`, SHA256 `88f0417bb73d1fc6c0f6a955f0ff6b3667a17698162ba0340079c1cf9628c4a1`). It is redistributed unmodified.
