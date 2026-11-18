# Native iPhone routing

This package wraps the Valhalla Mobile 0.6.6 engine behind an opaque C interface. Its dynamic framework keeps Protobuf and Abseil private, so the app can also link Nearby's different native dependency versions. Graphs must use Valhalla 3.9.2.

Xcode resolves the released framework from the URL and SHA-256 in `Package.swift`. To rebuild it locally on a Mac with Xcode 16.4, run this from the repository root:

```sh
bash tools/maps/build_ios_router.sh "$TMPDIR/trailmesh-ios-router"
```

Set `TRAILMESH_LOCAL_ROUTING_SDK=1` when running `xcodebuild` against the rebuilt framework in `Artifacts/`. CI rebuilds the framework from source and tests the pinned release on simulators and in the unsigned app build. The build verifies the upstream archive and timezone hashes, device and simulator deployment targets, exported and imported symbols, system library dependencies, and signatures. License notices and timezone data ship inside both framework slices.

`OfflineNativeRouter` accepts a local graph configuration and returns bounded JSON bytes. Its caller must serialize construction, route calls, and close. The product adapter supplies that queue and retains the graph's storage lease until native close. No C++ string, exception, Protobuf object, or Abseil object crosses the C boundary. Responses larger than 4 MiB fail explicitly.

Actual Apple linking, offline routing, resource cancellation, and coexistence with Nearby require the native CI tests. The portable injected-engine test verifies C boundary ownership and failure handling; it does not establish those Apple runtime results.
