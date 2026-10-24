#!/bin/bash
# Build packages/stagehand-<version>.txz from src/ and write its SHA256 into stagehand.plg.
# Usage: ./build.sh            (version taken from stagehand.plg)
set -euo pipefail
cd "$(dirname "$0")"
V=$(grep -oP '<!ENTITY version\s+"\K[^"]+' stagehand.plg)
SRC=src/usr/local/emhttp/plugins/stagehand
grep -q "STAGEHAND_VERSION=\"$V\"" "$SRC/stagehand.sh" || sed -i "s/^STAGEHAND_VERSION=.*/STAGEHAND_VERSION=\"$V\"/" "$SRC/stagehand.sh"
bash -n "$SRC/stagehand.sh"
php -l "$SRC/sessions.php" >/dev/null
chmod 755 "$SRC/stagehand.sh"; chmod 644 "$SRC"/*.page "$SRC"/*.php "$SRC"/*.cfg "$SRC"/*.png
mkdir -p packages
rm -f packages/stagehand-*.txz
tar --owner=0 --group=0 --sort=name --mtime='2026-01-01 00:00Z' -cJf "packages/stagehand-$V.txz" -C src .
SHA=$(sha256sum "packages/stagehand-$V.txz" | cut -d' ' -f1)
sed -i -E "s#(<!ENTITY pkgSHA\s+\")[^\"]*#\1$SHA#" stagehand.plg
echo "built packages/stagehand-$V.txz  sha256=$SHA"
