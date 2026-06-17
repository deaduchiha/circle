#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LICENSE_KEY="${MAXMIND_LICENSE_KEY:-${1:-}}"

if [[ -z "$LICENSE_KEY" ]]; then
  echo "Usage: MAXMIND_LICENSE_KEY=your_key $0" >&2
  echo "   or: $0 your_maxmind_license_key" >&2
  exit 1
fi

DEST="$ROOT/Resources/GeoLite2-Country.mmdb"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/circle-geolite2.XXXXXX")"
ARCHIVE="$TMP_DIR/GeoLite2-Country.tar.gz"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$ROOT/Resources"

URL="https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=${LICENSE_KEY}&suffix=tar.gz"
echo "Downloading GeoLite2-Country..."
curl -fsSL "$URL" -o "$ARCHIVE"

echo "Extracting database..."
tar -xzf "$ARCHIVE" -C "$TMP_DIR"

MMDB="$(find "$TMP_DIR" -name GeoLite2-Country.mmdb -print -quit)"
if [[ -z "$MMDB" ]]; then
  echo "GeoLite2-Country.mmdb not found in archive." >&2
  exit 1
fi

cp "$MMDB" "$DEST"
echo "Installed $DEST"
