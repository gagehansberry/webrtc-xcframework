#!/bin/bash
# Builds LiveKitWebRTC.xcframework from the same source and recipe as
# LiveKit's published 150.7871.02, plus one patch, so the framework imports
# no stat-family function (Apple's File Timestamp required-reason category)
# and its privacy manifest sits where Apple's tools look for it on macOS.
#
# Pinned inputs:
#   source  webrtc-sdk/webrtc        ba469aa2093ba950066258ca0a59a6fbd1295582
#   recipe  webrtc-sdk/webrtc-build  66ed9c7b07b2ad6ad624df0317e408dca562f91b
#           (build/apple/xcframework.sh: the GN args below are its COMMON_ARGS)
#   patches patches/apple_prefix.patch        webrtc-build's, unchanged (LK prefix)
#           patches/no-file-timestamp.patch   see its header
#
# Usage: ./build.sh [work-dir]   (default ~/Builds; ~25 GB checkout +
# ~1.5 GB per slice). Produces <work-dir>/dist/LiveKitWebRTC.xcframework.zip
# and prints its SwiftPM checksum. Fails if any slice can import stat,
# fstat, fstatat or lstat, or if a privacy manifest is missing or misplaced.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$HOME/Builds}"
WEBRTC_COMMIT=ba469aa2093ba950066258ca0a59a6fbd1295582
NAME=LiveKitWebRTC
SRC="$WORK/webrtc/src"
OUT="$WORK/out-release"
DIST="$WORK/dist"

export PATH="$WORK/depot_tools:$PATH"
# depot_tools updates itself on every run otherwise; the build should not
# change under us between slices.
export DEPOT_TOOLS_UPDATE=0

say() { echo "build-webrtc: $*"; }

# --- Source ---------------------------------------------------------------
if [ ! -d "$WORK/depot_tools" ]; then
  git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$WORK/depot_tools"
fi
[ -f "$WORK/depot_tools/python3_bin_reldir.txt" ] || "$WORK/depot_tools/ensure_bootstrap"

if [ ! -d "$SRC" ]; then
  mkdir -p "$WORK/webrtc"
  cat > "$WORK/webrtc/.gclient" <<'EOF'
solutions = [
  {
    "name": "src",
    "url": "https://github.com/webrtc-sdk/webrtc.git",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": {},
  },
]
EOF
  git clone https://github.com/webrtc-sdk/webrtc.git "$SRC"
  git -C "$SRC" checkout -f "$WEBRTC_COMMIT"
  (cd "$SRC" && gclient sync -D --force --reset --with_branch_heads --jobs=8)
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$WEBRTC_COMMIT" ] || { say "checkout is not at $WEBRTC_COMMIT"; exit 1; }

# Patches go onto pristine files every run, so a rerun never double-applies.
PATCHED=(sdk/BUILD.gn sdk/objc/Info.plist sdk/objc/base/RTCMacros.h webrtc.gni
         tools_webrtc/apple/copy_framework_header.py tools_webrtc/apple/generate_privacy_manifest.py
         tools_webrtc/ios/build_ios_libs.py tools_webrtc/ios/generate_umbrella_header.py)
git -C "$SRC" checkout -- "${PATCHED[@]}"
for p in apple_prefix.patch no-file-timestamp.patch; do
  (cd "$SRC" && patch -p1 --no-backup-if-mismatch --quiet < "$REPO/patches/$p")
done
say "source at $WEBRTC_COMMIT, patches applied"

# --- Slices ---------------------------------------------------------------
COMMON_ARGS='enable_dsyms = false enable_libaom = true enable_stripping = true
  ios_enable_code_signing = false is_component_build = false is_debug = false
  rtc_build_examples = false rtc_enable_protobuf = false rtc_enable_symbol_export = true
  rtc_include_dav1d_in_internal_decoder_factory = true rtc_include_tests = false
  rtc_libvpx_build_vp9 = true rtc_use_h264 = false treat_warnings_as_errors = true use_rtti = true'
# Two slices: iPhone (device) and Apple Silicon Macs. No Simulator, Intel,
# Catalyst, tvOS or visionOS slices. Deployment targets are the fork's.
# iOS links with Apple's ld (macOS already does by default): the lld at this
# commit cannot read the iOS 27 SDK's stubs ("unknown architecture" on
# arm64e.x1, Xcode 27.0, 2026-10-11). Cost: no identical-code folding, so the
# iOS binary is ~4.5% larger than the fork's.
IOS_LINK='use_apple_linker = true'
SLICES=(
  "iOS-arm64-device:target_os=\"ios\" target_environment=\"device\" target_cpu=\"arm64\" ios_deployment_target=\"13.0\" $IOS_LINK"
  "macOS-arm64:target_os=\"mac\" target_cpu=\"arm64\" mac_deployment_target=\"10.15\""
)
# An Intel Mac slice would be a "macOS-x64" entry (target_cpu="x64") and a
# lipo into macOS-lib below.

# Every stat-family spelling, including the x86_64 $INODE64 variants.
STAT_RE='^_(f|l)?stat(at)?(\$INODE64)?$'

for entry in "${SLICES[@]}"; do
  slice="${entry%%:*}"
  args="${entry#*:}"
  dir="$OUT/$slice"
  if [ -f "$dir/.done" ]; then say "$slice: already built"; continue; fi
  # Always from clean: a reused tree can keep files the patch removed.
  if [ -d "$dir" ]; then mv "$dir" "$dir.stale.$$"; fi
  say "$slice: building"
  (cd "$SRC" && gn gen "$dir" --args="$COMMON_ARGS $args")
  if [[ $slice == macOS* ]]; then target=mac_framework_bundle; else target=ios_framework_bundle; fi
  nice -n 5 "$SRC/third_party/ninja/ninja" -C "$dir" "$target" --quiet
  bin="$dir/$NAME.framework/$NAME"
  [[ $slice == macOS* ]] && bin="$dir/$NAME.framework/Versions/A/$NAME"
  if nm -u "$bin" | grep -Eq "$STAT_RE"; then
    say "$slice: imports $(nm -u "$bin" | grep -E "$STAT_RE" | tr '\n' ' ')"; exit 1
  fi
  touch "$dir/.done"
  say "$slice: no stat-family imports"
done

# --- XCFramework ----------------------------------------------------------
rm -rf "$OUT/macOS-lib" "$DIST"
mkdir -p "$OUT/macOS-lib" "$DIST"
cp -R "$OUT/macOS-arm64/$NAME.framework" "$OUT/macOS-lib/"
xcodebuild -create-xcframework \
  -framework "$OUT/iOS-arm64-device/$NAME.framework" \
  -framework "$OUT/macOS-lib/$NAME.framework" \
  -output "$DIST/$NAME.xcframework" >/dev/null
cp "$SRC/LICENSE" "$DIST/$NAME.xcframework/"

# Each framework carries its own manifest, where Apple's tools read it:
# the bundle root on iOS, Versions/A/Resources on macOS; nowhere else.
X="$DIST/$NAME.xcframework"
want=("$X/ios-arm64/$NAME.framework/PrivacyInfo.xcprivacy"
      "$X/macos-arm64/$NAME.framework/Versions/A/Resources/PrivacyInfo.xcprivacy")
for f in "${want[@]}"; do [ -f "$f" ] || { say "missing manifest: ${f#$X/}"; exit 1; }; done
found=$(find "$X" -name PrivacyInfo.xcprivacy | wc -l | tr -d ' ')
[ "$found" = "${#want[@]}" ] || { say "unexpected manifests:"; find "$X" -name PrivacyInfo.xcprivacy; exit 1; }
if grep -rq "FileTimestamp" "$X" --include=PrivacyInfo.xcprivacy; then say "a manifest still declares File Timestamp"; exit 1; fi

# Deterministic zip: fixed timestamps and sorted entries, so the checksum
# depends on the bytes of the build alone.
find "$X" -exec touch -h -t 202601010000 {} +
(cd "$DIST" && find "$NAME.xcframework" | LC_ALL=C sort | zip -q -X --symlinks -9 "$NAME.xcframework.zip" -@)
say "wrote $DIST/$NAME.xcframework.zip"
say "checksum $(swift package compute-checksum "$DIST/$NAME.xcframework.zip")"
