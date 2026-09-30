# Foreground exchange feasibility gate

Issue #2 establishes the smallest transport contract before report storage or routing is added. A platform adapter supplies discovery, consent/authentication, and byte transfer; the shared coordinator bounds the application object at 16 KiB, validates its SHA-256 digest, and records redacted lifecycle evidence.

Run the local contract tests from the repository root:

```text
python -m unittest discover -s tools/transport -p "test_*.py"
```

The local loopback transport is a deterministic development check. It does not prove radio interoperability. Physical Gate A evidence must be recorded in [`evidence-template-v1.json`](../../experiments/foreground_exchange/evidence-template-v1.json) using the selected iPhone and Android devices, with internet disabled while the required local radios remain enabled.

Each physical attempt must record the direction, payload size, adapter and strategy, permission/radio state, consent and authentication results, lifecycle timing, expected and received SHA-256 values, and a structured failure reason. The initial acceptance rule is at least 18 matching 2 KiB exchanges out of 20 in **each direction**. Do not record message contents, private keys, personal routes, or raw contact exports.

## Device probe

The paired native probe is under [`experiments/foreground_exchange`](../../experiments/foreground_exchange/). It is a disposable feasibility client, not the TrailMesh app. The iOS target uses Swift; the Android target uses Kotlin and Google Nearby Connections 19.5.0. The iOS package is pinned to a source revision in the Xcode project. Both targets use the point-to-point strategy and the same service ID.

The probe starts in the foreground on both phones. Each phone selects a payload role and the same pairing mode. **Role-based** mode preserves the original behavior: the sender discovers and the receiver advertises. **Cross-platform** mode uses the radio direction that worked in the no-network iPhone-to-Android test: Android advertises and iPhone discovers, regardless of which phone is the payload sender. Once connected, either phone can send the generated test bytes. This mode tests whether reversing the discovery direction also fixes Android-to-iPhone payload delivery; it does not change the production architecture decision by itself.

The selected sender automatically sends a batch of 20 framed payloads and waits for a receiver checksum acknowledgement after each one. In cross-platform mode, turn Wi-Fi off in Settings, disable mobile data, keep Bluetooth on, and turn off hotspots to isolate the radio path. The probe can also run batches of 256-byte and 8-KiB payloads; the 2-KiB batch is the stated acceptance gate.

If Android advertising or discovery fails to start, the status and redacted test log show the Google Play Services status code and name when available, plus the exception type. Share the test log so the failure can be diagnosed; it omits raw exception messages and test payload bytes.

Compatibility observation: on Android 13, this probe first received Google Nearby status `8034` (`MISSING_PERMISSION_ACCESS_COARSE_LOCATION`) at discovery start even though Nearby devices permission was enabled. After approximate Location was granted, the same device returned `8036` (`MISSING_PERMISSION_ACCESS_FINE_LOCATION`). Normal Android 13 startup therefore requests Nearby permissions only; the probe requests coarse or precise Location and retries only when discovery returns the matching missing-permission status. These are observed SDK/device behaviors, not claims that all Android 13 devices require Location for Nearby Connections. The probe itself does not read or log coordinates. See Google's [status code reference](https://developers.google.com/android/reference/com/google/android/gms/nearby/connection/ConnectionsStatusCodes) for both codes.

Connection requests and Nearby's verification callback are automatically accepted only after the user starts this test session. This deliberately avoids a per-encounter tap in the probe. Google warns that automatically accepting the short verification token does not authenticate the peer, so the probe must carry generated test bytes only. This is not the production security policy.

### Build and install

For Android, open `experiments/foreground_exchange/android` in Android Studio, use JDK 17 for Gradle, sync the project, and install the `app` debug configuration. The command-line build and unit tests are:

```powershell
cd experiments/foreground_exchange/android
.\gradlew.bat testDebugUnitTest assembleDebug
```

For iOS, open `experiments/foreground_exchange/ios/TrailMeshTransportProbe.xcodeproj` in Xcode, select the `TrailMeshTransportProbe` scheme and the iPhone, then build and run it. Allow Bluetooth and Local Network access when iOS asks. The iOS frame tests run in CI on an iPhone simulator.

#### Windows and AltStore Classic test path

The Quality workflow also builds an **unsigned iPhone-device IPA** and uploads it as the `TrailMeshTransportProbe-unsigned-iphoneos` Actions artifact. This is a test package, not an app release or proof that sideloading works on the target iPhone. Its `SHA256SUMS.txt` file identifies the exact package to test. A simulator `.app` cannot be substituted for this package.

1. Install [iTunes and iCloud directly from Apple](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows), then install [AltServer for Windows](https://altstore.io/). Use **AltStore Classic** for IPA files; AltStore PAL does not import arbitrary IPA files.
2. Connect and unlock the iPhone, trust the computer when prompted, and use AltServer to install AltStore Classic. Complete Apple ID sign-in on your own device and PC. Enable Wi-Fi sync if using wireless refresh. Complete the iPhone's trust and Developer Mode steps in the [AltStore Windows guide](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows).
3. Download and extract the artifact from the successful GitHub Actions run. Verify the IPA's SHA-256 against `SHA256SUMS.txt`. Import the IPA into AltStore Classic on the iPhone, or use AltServer's **Shift-click → Sideload .ipa** option on Windows. AltStore/AltServer signs it for the test phone; never commit Apple credentials or signing material to this repository.
4. Open the probe and allow the Bluetooth and Local Network prompts. If the install or first launch fails, record the exact error and iOS version. The first successful install and iPhone-to-Android transfer are still required evidence for Issue #2.

With a free Apple ID, sideloaded apps expire after seven days. Keep AltServer reachable from the iPhone and refresh in AltStore Classic before expiry; a USB connection also works. AltStore attempts background refresh, but it is not guaranteed. [AltStore refresh instructions](https://faq.altstore.io/altstore-classic/your-altstore), [AltServer connection instructions](https://faq.altstore.io/altstore-classic/altserver).

### Run the physical gate

1. Install the debug probe on the target iPhone and Android phone. Keep both apps open and unlocked.
2. For the role-based runs, disable mobile data and disconnect each device from internet-connected Wi-Fi. Leave Bluetooth and Wi-Fi enabled. Record the exact method in the evidence file.
3. With **Role-based** pairing mode selected on both phones, run one 20-transfer batch at each size (256 bytes, 2 KiB, and 8 KiB) in both payload directions. Export both redacted logs after each batch; starting a new iOS session clears its previous log. Stop both sessions before changing size.
4. Select **Cross-platform** pairing mode on both phones and repeat the 2-KiB batch in both payload directions. Disable Wi-Fi in Settings, disable mobile data, keep Bluetooth on, and turn off hotspots. Save both device logs after every batch. This isolates the Android-advertiser/iPhone-discoverer path from the failing Android-discoverer/iPhone-advertiser path.
5. Enter the exact device models, OS versions, builds, permission state, radio state, consent/authentication behavior, and all attempts in `evidence-template-v1.json`. The apps cannot verify that internet access was disabled, so record that manually. Do not add payload bytes or authentication tokens.
6. Issue #2's gate passes only if the 2-KiB batch has at least 18 matching SHA-256 results out of 20 in each direction and the receiver logs corroborate those results. The 256-byte and 8-KiB batches characterize the transport. Foreground results do not establish lock-screen or background behavior.

If the phones cannot discover or connect, preserve the failed logs and reasons. Do not substitute loopback, simulator, or LAN results for this physical test.
