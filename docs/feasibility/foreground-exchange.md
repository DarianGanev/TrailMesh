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

The probe starts in the foreground on both phones. Choose **Find and send** on one and **Advertise and receive** on the other, then start a session on both. The sender automatically sends a batch of 20 framed payloads and waits for a receiver checksum acknowledgement after each one. Run the first direction with the iPhone sending, then stop both sessions and repeat with Android sending. The probe can also run batches of 256-byte and 8-KiB payloads; the 2-KiB batch is the stated acceptance gate.

Connection requests and Nearby's verification callback are automatically accepted only after the user starts this test session. This deliberately avoids a per-encounter tap in the probe. Google warns that automatically accepting the short verification token does not authenticate the peer, so the probe must carry generated test bytes only. This is not the production security policy.

### Build and install

For Android, open `experiments/foreground_exchange/android` in Android Studio, use JDK 17 for Gradle, sync the project, and install the `app` debug configuration. The command-line build and unit tests are:

```powershell
cd experiments/foreground_exchange/android
.\gradlew.bat testDebugUnitTest assembleDebug
```

For iOS, open `experiments/foreground_exchange/ios/TrailMeshTransportProbe.xcodeproj` in Xcode, select the `TrailMeshTransportProbe` scheme and the iPhone, then build and run it. Allow Bluetooth and Local Network access when iOS asks. The iOS frame tests run in CI on an iPhone simulator.

### Run the physical gate

1. Install the debug probe on the target iPhone and Android phone. Keep both apps open and unlocked.
2. Disable mobile data and disconnect each device from internet-connected Wi-Fi. Leave Bluetooth and Wi-Fi enabled. Record the exact method in the evidence file.
3. On the iPhone choose **Find and send**; on Android choose **Advertise and receive**. Run one 20-transfer batch at each size (256 bytes, 2 KiB, and 8 KiB), starting the same size on both phones. Export both redacted logs after each batch; starting a new iOS session clears its previous log. Stop both sessions before changing size.
4. Stop both apps' sessions, switch the roles, and repeat all three payload sizes so Android sends to iPhone. Save both device logs after every batch.
5. Enter the exact device models, OS versions, builds, permission state, radio state, consent/authentication behavior, and all attempts in `evidence-template-v1.json`. The apps cannot verify that internet access was disabled, so record that manually. Do not add payload bytes or authentication tokens.
6. Issue #2's gate passes only if the 2-KiB batch has at least 18 matching SHA-256 results out of 20 in each direction and the receiver logs corroborate those results. The 256-byte and 8-KiB batches characterize the transport. Foreground results do not establish lock-screen or background behavior.

If the phones cannot discover or connect, preserve the failed logs and reasons. Do not substitute loopback, simulator, or LAN results for this physical test.
