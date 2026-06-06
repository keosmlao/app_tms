#!/usr/bin/env bash
#
# Build the driver APK and upload it to the server's public folder (where the
# Next.js app serves it for in-app downloads). APKs are intentionally NOT in git
# (too large for GitHub), so this is how a new build reaches production.
#
# Usage:
#   SSH_USER=youruser ./scripts/deploy-apk.sh
#
# Env (all optional except SSH_USER):
#   SSH_USER    SSH login on the server                      (required)
#   SERVER      target host                                  (default 10.0.40.9)
#   REMOTE_DIR  public folder on the server                  (default /tms/public)
#   APK_NAME    filename to write on the server              (default tms-debug.apk)
#   BUILD       "debug" | "release" | "skip"                 (default debug)
#
# Examples:
#   SSH_USER=ubuntu ./scripts/deploy-apk.sh
#   SSH_USER=root APK_NAME=tms.apk BUILD=release ./scripts/deploy-apk.sh
#
set -euo pipefail

SERVER="${SERVER:-10.0.40.9}"
REMOTE_DIR="${REMOTE_DIR:-/tms/public}"
APK_NAME="${APK_NAME:-tms-debug.apk}"
BUILD="${BUILD:-debug}"
SSH_USER="${SSH_USER:?set SSH_USER, e.g. SSH_USER=ubuntu ./scripts/deploy-apk.sh}"

cd "$(dirname "$0")/.."

case "$BUILD" in
  debug)
    echo "▶ flutter build apk --debug"
    flutter build apk --debug
    SRC="build/app/outputs/flutter-apk/app-debug.apk"
    ;;
  release)
    echo "▶ flutter build apk --release"
    flutter build apk --release
    SRC="build/app/outputs/flutter-apk/app-release.apk"
    ;;
  skip)
    SRC="build/app/outputs/flutter-apk/app-${APK_NAME%.apk}.apk"
    [ -f "$SRC" ] || SRC="build/app/outputs/flutter-apk/app-debug.apk"
    ;;
  *)
    echo "Unknown BUILD=$BUILD (use debug|release|skip)" >&2; exit 1 ;;
esac

[ -f "$SRC" ] || { echo "APK not found: $SRC" >&2; exit 1; }
SIZE=$(du -h "$SRC" | cut -f1)
echo "▶ uploading $SRC ($SIZE) → $SSH_USER@$SERVER:$REMOTE_DIR/$APK_NAME"

# --partial/--inplace so a dropped LAN transfer can resume; -z is pointless on
# an already-compressed APK so it's omitted.
rsync -h --progress --partial --inplace \
  "$SRC" "$SSH_USER@$SERVER:$REMOTE_DIR/$APK_NAME"

echo "✓ done → http://$SERVER/$APK_NAME (verify the app's update URL points here)"
