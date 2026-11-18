# Native iPhone routing

This package wraps the Valhalla Mobile 0.6.6 engine behind an opaque C interface. Its dynamic framework keeps Protobuf and Abseil private, so the app can also link Nearby's different native dependency versions. Graphs must use Valhalla 3.9.2.

On a Mac with Xcode 16.4, prepare the local framework before opening the product project:

```sh
bash tools/maps/build_ios_router.sh "$TMPDIR/trailmesh-ios-router"
```

Run that command from the repository root. CI builds the framework once and supplies its verified artifact to each native product job. Generated binaries live in the ignored `Artifacts/` directory. The build verifies the upstream archive and timezone hashes, device and simulator deployment targets, exported and imported symbols, system library dependencies, and signatures. License notices and timezone data ship inside both framework slices.

`OfflineNativeRouter` accepts a local graph configuration and returns bounded JSON bytes. Its caller must serialize construction, route calls, and close. The product adapter supplies that queue and retains the graph's storage lease until native close. No C++ string, exception, Protobuf object, or Abseil object crosses the C boundary. Responses larger than 4 MiB fail explicitly.

Actual Apple linking, offline routing, resource cancellation, and coexistence with Nearby require the native CI tests. The portable injected-engine test verifies C boundary ownership and failure handling; it does not establish those Apple runtime results.
