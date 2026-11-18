#!/usr/bin/env bash
# Repackage the pinned engine as an isolated dynamic framework; never disable ABI guards.
set -euo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?output directory required}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
PACKAGE="$ROOT/apps/ios/NativeRouting"
BRIDGE="$PACKAGE/Bridge"
ARTIFACTS="$PACKAGE/Artifacts"
DEFAULT_CONFIG="$PACKAGE/Sources/TrailMeshNativeRouting/Resources/default.json"
SDK_URL="https://github.com/Rallista/valhalla-mobile/releases/download/0.6.6/valhalla-wrapper.xcframework.zip"
SDK_SHA=b28e73f6d314fa7fea9f27f1ce8683867f3afec920411d35dddeb8419bbc5518
TZ_URL="https://raw.githubusercontent.com/Rallista/valhalla-mobile/0.6.6/apple/Sources/Valhalla/SupportData/tzdata.tar"
TZ_SHA=0d28b24fbbe940be9e0522086358ba74a438e4d81d2da4a2d290db929b7a8649
# Vendored apple/Sources/Valhalla/SupportData/default.json from Valhalla Mobile 0.6.6.
DEFAULT_SHA=d1c1d505ac15ba180515df42639c15d310767bb9365525268beaa7836611b6a6
XCODE_VERSION="$(xcodebuild -version)"
if [[ "${XCODE_VERSION%%$'\n'*}" != "Xcode 16.4" ]]; then
    echo "The isolated SDK build requires Xcode 16.4." >&2
    exit 1
fi
printf '%s  %s\n' "$DEFAULT_SHA" "$DEFAULT_CONFIG" | shasum -a 256 -c -
[[ ! -e "$OUT/upstream" && ! -e "$ARTIFACTS/TrailMeshValhalla.xcframework" ]] || {
    echo "Use a fresh output directory and remove any previous SDK from $ARTIFACTS." >&2
    exit 1
}
curl --fail --location --retry 3 "$SDK_URL" -o "$OUT/upstream.zip"
printf '%s  %s\n' "$SDK_SHA" "$OUT/upstream.zip" | shasum -a 256 -c -
curl --fail --location --retry 3 "$TZ_URL" -o "$OUT/tzdata.tar"
printf '%s  %s\n' "$TZ_SHA" "$OUT/tzdata.tar" | shasum -a 256 -c -
mkdir -p "$OUT/upstream" "$OUT/tzdata"
unzip -q "$OUT/upstream.zip" -d "$OUT/upstream"
# Validate tar members before extraction; discard Apple metadata, never links.
python3 - "$OUT/tzdata.tar" "$OUT/tzdata" <<'PYTZ'
import pathlib,sys,tarfile
with tarfile.open(sys.argv[1]) as archive:
    members=[]
    for member in archive.getmembers():
        parts=pathlib.PurePosixPath(member.name).parts
        if member.name.startswith('/') or '..' in parts or not (member.isfile() or member.isdir()):
            raise ValueError('unsafe timezone member')
        if any(p.startswith('._') or p == '__MACOSX' for p in parts): continue
        members.append(member)
    archive.extractall(sys.argv[2], members=members, filter='data')
root = pathlib.Path(sys.argv[2])
for name in ('LICENSE', 'version', 'europe', 'northamerica'):
    if not (root / name).is_file():
        raise ValueError(f'missing timezone resource: {name}')
PYTZ
build_slice() {
  local sdk="$1" arch="$2" target="$3" upstream_slice="$4" identifier="$5"
  local framework="$OUT/$identifier/TrailMeshValhalla.framework"
  local headers="$OUT/upstream/valhalla-wrapper.xcframework/$upstream_slice/Headers"
  mkdir -p "$framework/Headers" "$framework/Modules"
  cp "$BRIDGE/include/TrailMeshValhalla.h" "$framework/Headers/"
  printf 'framework module TrailMeshValhalla { umbrella header "TrailMeshValhalla.h" export * }\n' > "$framework/Modules/module.modulemap"
  cp -R "$OUT/tzdata" "$framework/tzdata"
  cp -R "$PACKAGE/Licenses" "$framework/Licenses"
  xcrun --sdk "$sdk" clang++ -std=c++20 -arch "$arch" -target "$target" \
    -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" -fvisibility=hidden -fvisibility-inlines-hidden -DUSE_OS_TZDB=0 -DHAS_REMOTE_API=0 -DAUTO_DOWNLOAD=0 \
    -I"$BRIDGE/include" -I"$headers" -c "$BRIDGE/router.cpp" -o "$OUT/$identifier/router.o"
  xcrun --sdk "$sdk" clang++ -dynamiclib -arch "$arch" -target "$target" \
    -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" "$OUT/$identifier/router.o" \
    "$OUT/upstream/valhalla-wrapper.xcframework/$upstream_slice/libvalhalla_all.a" \
    -Wl,-exported_symbols_list,"$BRIDGE/exports.txt" -Wl,-dead_strip -Wl,-undefined,error \
    -install_name @rpath/TrailMeshValhalla.framework/TrailMeshValhalla \
    -lz -lc++ -framework CoreFoundation \
    -o "$framework/TrailMeshValhalla"
  local platform=iPhoneOS
  [[ "$sdk" == iphonesimulator ]] && platform=iPhoneSimulator
  cat > "$framework/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.trailmesh.native-routing</string>
<key>CFBundleName</key><string>TrailMeshValhalla</string><key>CFBundleExecutable</key><string>TrailMeshValhalla</string>
<key>CFBundlePackageType</key><string>FMWK</string><key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.6.6</string><key>MinimumOSVersion</key><string>16.4</string>
<key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array></dict></plist>
PLIST
  xcrun nm -arch "$arch" -gUj "$framework/TrailMeshValhalla" | sort > "$OUT/$identifier/exports.txt"
  diff -u "$BRIDGE/exports.txt" "$OUT/$identifier/exports.txt"
  xcrun nm -arch "$arch" -m -u "$framework/TrailMeshValhalla" > "$OUT/$identifier/undefined.txt"
  if grep -Ei 'protobuf|absl|boost|valhalla|dynamically looked up' "$OUT/$identifier/undefined.txt"; then
    echo "Third-party symbols or flat lookups escaped the private image" >&2
    exit 1
  fi
  xcrun otool -arch "$arch" -hv "$framework/TrailMeshValhalla" > "$OUT/$identifier/macho.txt"
  grep -qw TWOLEVEL "$OUT/$identifier/macho.txt"
  xcrun dyld_info -exports "$framework/TrailMeshValhalla" > "$OUT/$identifier/export-trie.txt"
  python3 - "$OUT/$identifier/export-trie.txt" <<'PYEXPORTS'
import re,sys
text=open(sys.argv[1]).read()
expected = {'_tm_router_create', '_tm_router_destroy', '_tm_router_free', '_tm_router_route'}
symbols = re.findall(r'(?<!\S)_[A-Za-z0-9_.$]+(?=\s|$)', text)
assert set(symbols) == expected and len(symbols) == len(expected), text
PYEXPORTS
  xcrun vtool -show-build "$framework/TrailMeshValhalla" > "$OUT/$identifier/platform.txt"
  local expected_platform=IOS
  [[ "$sdk" == iphonesimulator ]] && expected_platform=IOSSIMULATOR
  python3 - "$OUT/$identifier/platform.txt" "$expected_platform" <<'PYPLATFORM'
import re,sys
text=open(sys.argv[1]).read()
assert re.search(r'platform\s+'+sys.argv[2]+r'\s',text), text
assert re.search(r'minos\s+16\.4(?:\.0)?\s',text), text
PYPLATFORM
  xcrun otool -arch "$arch" -L "$framework/TrailMeshValhalla" > "$OUT/$identifier/dependencies.txt"
  python3 - "$OUT/$identifier/dependencies.txt" <<'PYDEPS'
import sys
allowed = {
    '@rpath/TrailMeshValhalla.framework/TrailMeshValhalla',
    '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
    '/usr/lib/libc++.1.dylib',
    '/usr/lib/libSystem.B.dylib',
    '/usr/lib/libz.1.dylib',
}
dependencies = {line.strip().split(' (')[0] for line in open(sys.argv[1]).read().splitlines()[1:]}
assert dependencies <= allowed, dependencies - allowed
PYDEPS
}
build_slice iphoneos arm64 arm64-apple-ios16.4 ios-arm64 device
build_slice iphonesimulator arm64 arm64-apple-ios16.4-simulator ios-arm64_x86_64-simulator sim-arm64
build_slice iphonesimulator x86_64 x86_64-apple-ios16.4-simulator ios-arm64_x86_64-simulator sim-x86_64
mkdir -p "$OUT/simulator"
cp -R "$OUT/sim-arm64/TrailMeshValhalla.framework" "$OUT/simulator/"
xcrun lipo -create "$OUT/sim-arm64/TrailMeshValhalla.framework/TrailMeshValhalla" "$OUT/sim-x86_64/TrailMeshValhalla.framework/TrailMeshValhalla" -output "$OUT/simulator/TrailMeshValhalla.framework/TrailMeshValhalla"
codesign --force --sign - "$OUT/device/TrailMeshValhalla.framework"
codesign --force --sign - "$OUT/simulator/TrailMeshValhalla.framework"
codesign --verify --strict --all-architectures "$OUT/device/TrailMeshValhalla.framework"
codesign --verify --strict --all-architectures "$OUT/simulator/TrailMeshValhalla.framework"
xcrun lipo -verify_arch arm64 x86_64 "$OUT/simulator/TrailMeshValhalla.framework/TrailMeshValhalla"
mkdir -p "$ARTIFACTS"
xcodebuild -create-xcframework -framework "$OUT/device/TrailMeshValhalla.framework" -framework "$OUT/simulator/TrailMeshValhalla.framework" -output "$ARTIFACTS/TrailMeshValhalla.xcframework"
(cd "$ARTIFACTS" && ditto -c -k --sequesterRsrc --keepParent TrailMeshValhalla.xcframework "$OUT/TrailMeshValhalla.xcframework.zip")
(cd "$OUT" && shasum -a 256 TrailMeshValhalla.xcframework.zip > TrailMeshValhalla.xcframework.zip.sha256)
cp "$OUT/TrailMeshValhalla.xcframework.zip" "$OUT/TrailMeshValhalla.xcframework.zip.sha256" "$ARTIFACTS/"
mkdir -p "$ARTIFACTS/Evidence"
{
  printf '%s\n' "$XCODE_VERSION"
  printf '%s\n' "Upstream SDK SHA-256: $SDK_SHA" "Timezone data SHA-256: $TZ_SHA" "Default configuration SHA-256: $DEFAULT_SHA"
} > "$ARTIFACTS/Evidence/inputs.txt"
for identifier in device sim-arm64 sim-x86_64; do
  mkdir -p "$ARTIFACTS/Evidence/$identifier"
  cp "$OUT/$identifier/"*.txt "$ARTIFACTS/Evidence/$identifier/"
done
