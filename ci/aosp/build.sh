#!/usr/bin/env bash
# Syncs AOSP and builds the FreeOS Android TV image. Runs on the build VM.
# The source tree, out/ and ccache live on the persistent /aosp disk, so
# repeat runs only fetch and rebuild what changed.
#
# Log format:
#   [LOG] started compilation <date>
#   [HH:MM:SS, info|warn|error] ...      (see logfilter.py for the throttling)
#   [LOG] compilation finished (2,35 hours)
# The unfiltered output goes to dist/build.log.gz.
set -euo pipefail

: "${AOSP_ROOT:=/aosp/src}"
: "${AOSP_MANIFEST_URL:=https://android.googlesource.com/platform/manifest}"
: "${AOSP_MANIFEST_REF:=refs/tags/android-14.0.0_r75}"
: "${LUNCH_PRODUCT:=sdk_atv_x86}"
: "${LUNCH_VARIANT:=userdebug}"
: "${AOSP_RELEASE:=}"          # release config, only needed if lunch asks for one
: "${SYNC_JOBS:=6}"            # googlesource.com rate-limits aggressive syncs
: "${FREEOS_CLEAN:=0}"

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
DIST_DIR=${DIST_DIR:-$REPO_DIR/dist}
FILTER="$REPO_DIR/ci/aosp/logfilter.py"
RAW_LOG="$DIST_DIR/build.log"
START_TS=$(date +%s)

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
: > "$RAW_LOG"

# --- logging ------------------------------------------------------------------
log() { local level=$1; shift; printf '[%s, %s] %s\n' "$(date +%H:%M:%S)" "$level" "$*"; }

human_duration() {   # 8460 -> "2,35 hours", 754 -> "12,57 min"
  local s=$1
  if (( s >= 3600 )); then
    awk -v s="$s" 'BEGIN { printf "%.2f hours", s / 3600 }' | tr . ,
  else
    awk -v s="$s" 'BEGIN { printf "%.2f min", s / 60 }' | tr . ,
  fi
}

finish() {
  local rc=$? took
  took=$(human_duration $(( $(date +%s) - START_TS )))
  gzip -f "$RAW_LOG" 2>/dev/null || true
  if [ "$rc" = 0 ]; then
    echo "[LOG] compilation finished ($took)"
  else
    echo "[LOG] compilation FAILED after $took (exit code $rc), full output in build.log.gz"
  fi
}
trap finish EXIT

# run PHASE command... : output is filtered into the log format, raw copy kept.
run() {
  local phase=$1; shift
  "$@" 2>&1 | python3 -u "$FILTER" "$phase" "$RAW_LOG"
}

echo "[LOG] started compilation $(date '+%Y-%m-%d %H:%M:%S %Z')"
log info "host $(hostname): $(nproc) CPUs, $(free -g | awk '/^Mem:/ {print $2}') GB RAM, $(df -h /aosp | awk 'NR==2 {print $4}') free on /aosp"
log info "target $LUNCH_PRODUCT-$LUNCH_VARIANT from $AOSP_MANIFEST_REF"

export USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache CCACHE_DIR=/aosp/ccache
ccache -M 50G >/dev/null
log info "ccache: $(ccache -s | grep -iE 'cache size|hits' | head -n 2 | tr -s ' ' | paste -sd ';' -)"

mkdir -p "$AOSP_ROOT"
cd "$AOSP_ROOT"

# --- sync -------------------------------------------------------------------
if [ "$(cat .repo/freeos-ref 2>/dev/null || true)" != "$AOSP_MANIFEST_REF" ]; then
  log info "initialising source tree at $AOSP_MANIFEST_REF (first run: this downloads ~80 GB)"
  run repo-init repo init -u "$AOSP_MANIFEST_URL" -b "$AOSP_MANIFEST_REF" \
    --depth=1 -g default,-darwin,-mips --no-clone-bundle
  echo "$AOSP_MANIFEST_REF" > .repo/freeos-ref
else
  log info "source tree already at $AOSP_MANIFEST_REF, syncing changes only"
fi

log info "applying FreeOS local manifests: $(ls "$REPO_DIR/manifests" | paste -sd ' ' -)"
rm -rf .repo/local_manifests
cp -r "$REPO_DIR/manifests" .repo/local_manifests

for attempt in 1 2 3; do
  log info "repo sync, attempt $attempt/3 ($SYNC_JOBS parallel jobs)"
  if run repo-sync repo sync -c -j"$SYNC_JOBS" --no-tags --no-clone-bundle \
       --optimized-fetch --prune --force-sync; then
    break
  fi
  if [ "$attempt" = 3 ]; then
    log error "repo sync failed 3 times, giving up"
    exit 1
  fi
  log warn "repo sync failed, retrying in 60 s"
  sleep 60
done
log info "source size: $(du -sh --exclude=out . 2>/dev/null | cut -f1)"

# --- build ------------------------------------------------------------------
if [ "$FREEOS_CLEAN" = 1 ]; then
  log warn "clean build requested: deleting out/"
  rm -rf out
fi

log info "loading build environment (envsetup.sh)"
set +eu   # envsetup.sh is not written for strict mode
source build/envsetup.sh >>"$RAW_LOG" 2>&1

try_lunch() { log info "lunch $1"; lunch "$1" >>"$RAW_LOG" 2>&1; }

# Newer Android 14 tags expect product-RELEASE-variant; older ones product-variant.
if ! try_lunch "$LUNCH_PRODUCT-$LUNCH_VARIANT"; then
  releases="$AOSP_RELEASE $(find build/release -maxdepth 3 \( -name '*.scl' -o -name '*.textproto' \) \
               -path '*config*' -printf '%f\n' 2>/dev/null | sed 's/\.[^.]*$//' | sort -u) trunk_staging"
  ok=0
  for rel in $releases; do
    log warn "lunch needs a release config, trying '$rel'"
    try_lunch "$LUNCH_PRODUCT-$rel-$LUNCH_VARIANT" && { ok=1; break; }
  done
  if [ "$ok" != 1 ]; then
    log error "no working lunch combo for $LUNCH_PRODUCT (details in build.log.gz)"
    exit 1
  fi
fi
set -eu
log info "build target: $TARGET_PRODUCT ${TARGET_RELEASE:-} $TARGET_BUILD_VARIANT, output in $ANDROID_PRODUCT_OUT"

log info "compiling the system ($(nproc) parallel jobs)"
run build m

log info "packaging emulator system image (emu_img_zip)"
run package m emu_img_zip || log warn "emu_img_zip target not available, packaging raw images instead"

# --- package ----------------------------------------------------------------
zips=$(find "$ANDROID_PRODUCT_OUT" -maxdepth 1 -name 'sdk-repo-*system-images*.zip')
if [ -n "$zips" ]; then
  cp $zips "$DIST_DIR/"
else
  log info "compressing *.img with zstd"
  (cd "$ANDROID_PRODUCT_OUT" && tar -I 'zstd -T0 -10' -cf "$DIST_DIR/freeos-images.tar.zst" ./*.img)
fi

{
  echo "manifest: $AOSP_MANIFEST_REF"
  echo "lunch:    $TARGET_PRODUCT-${TARGET_RELEASE:-}-$TARGET_BUILD_VARIANT"
  echo "freeos:   $(git -C "$REPO_DIR" rev-parse HEAD)"
  echo "built:    $(date -u +%FT%TZ)"
} > "$DIST_DIR/build-info.txt"

log info "ccache: $(ccache -s | grep -iE 'hits' | head -n 1 | tr -s ' ')"
for f in "$DIST_DIR"/*; do
  [ "$f" = "$RAW_LOG" ] && continue
  log info "artifact: $(basename "$f") ($(du -h "$f" | cut -f1))"
done
