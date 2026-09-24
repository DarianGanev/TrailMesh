# TrailMesh — Comprehensive Diploma Project Specification

**Version:** 1.3 — public solo project foundation  
**Prepared:** 17 September 2026  
**Planning horizon:** nine months from project start  
**Primary platform:** iPhone  
**Secondary platform:** Android, with a smaller but interoperable application  
**Document purpose:** product specification, technical design, research plan, and handoff to an AI coding agent.

> TrailMesh lets useful information travel with people. A hiker records a dry spring, a blocked trail, or a message for a friend. Their phone stores it. When compatible phones meet, they can exchange selected information without internet. Other hikers carry those copies onward.

> **Fundamental boundary:** TrailMesh is a delay-tolerant information system, not guaranteed emergency communication. The diploma must succeed with explicit foreground exchanges. Reliable unattended iPhone discovery with the screen off is an experimental question, not a product promise.

## Contents

1. [How to use this specification](#1-how-to-use-this-specification)
2. [Vision and research contribution](#2-vision-and-research-contribution)
3. [Scope and non-goals](#3-scope-and-non-goals)
4. [Personas and user journeys](#4-personas-and-user-journeys)
5. [Product requirements and interface](#5-product-requirements-and-interface)
6. [Platform strategy and development prerequisites](#6-platform-strategy-and-development-prerequisites)
7. [Transport options and verified caveats](#7-transport-options-and-verified-caveats)
8. [Mandatory feasibility experiments](#8-mandatory-feasibility-experiments)
9. [System architecture](#9-system-architecture)
10. [Protocol and encounter lifecycle](#10-protocol-and-encounter-lifecycle)
11. [Bundle format and validation](#11-bundle-format-and-validation)
12. [Routing algorithms](#12-routing-algorithms)
13. [Freshness, evidence, and trust](#13-freshness-evidence-and-trust)
14. [Encrypted private messaging](#14-encrypted-private-messaging)
15. [Offline maps and routes](#15-offline-maps-and-routes)
16. [Data model and persistence](#16-data-model-and-persistence)
17. [Synchronization and optional gateway](#17-synchronization-and-optional-gateway)
18. [Internal interfaces and HTTP APIs](#18-internal-interfaces-and-http-apis)
19. [Security, privacy, and abuse resistance](#19-security-privacy-and-abuse-resistance)
20. [Simulator and testing strategy](#20-simulator-and-testing-strategy)
21. [Metrics and evaluation](#21-metrics-and-evaluation)
22. [Observability and diagnostics](#22-observability-and-diagnostics)
23. [Stack and repository structure](#23-stack-and-repository-structure)
24. [CI/CD and release process](#24-cicd-and-release-process)
25. [Nine-month milestones](#25-nine-month-milestones)
26. [MVP, diploma completion, and stretch scope](#26-mvp-diploma-completion-and-stretch-scope)
27. [Risks and decision register](#27-risks-and-decision-register)
28. [Diploma structure and evaluation plan](#28-diploma-structure-and-evaluation-plan)
29. [Presentation and demonstration](#29-presentation-and-demonstration)
30. [Instructions for the AI coding agent](#30-instructions-for-the-ai-coding-agent)
31. [Mentor profile and meeting brief](#31-mentor-profile-and-meeting-brief)
32. [References and evidence boundaries](#32-references-and-evidence-boundaries)

## 1. How to use this specification

This is a proposed design for a student project, not a claim that the application or its performance has already been demonstrated. All numerical limits, scores, performance thresholds, schedules, and interface contracts below are **initial engineering choices** unless explicitly attributed to a source. Measure and revise them through documented decisions.

Use these terms consistently:

| Term | Meaning |
|---|---|
| MUST | Required for the specified milestone or security invariant. |
| SHOULD | Recommended default; deviations need a recorded reason. |
| MAY | Optional implementation or experiment. |
| Feasibility gate | A question that requires device evidence before dependent work. |
| MVP | Small usable cross-platform foreground prototype. |
| Diploma completion | MVP plus routing research, evaluation, documentation, and a repeatable demonstration. |
| Stretch | Work attempted only after the diploma completion criteria are secure. |

The first coding agent must inspect the development environment, record actual phone models and OS versions, and execute the feasibility gates. It must not start by building all screens or by assuming background networking works.

The user has committed to the TrailMesh concept and to an iPhone-primary presentation. Preserve these priorities. The exact SDK, persistence wrapper, and optional gateway framework are replaceable implementation choices.

Working assumptions: one student, nine months, periodic mentor support, one iPhone, access to an Android device, and a third compatible device for a genuine physical two-hop demonstration. A simulator can supplement device tests, but must never be described as a third physical phone. All platform behavior is treated as a hypothesis until measured on the selected devices and OS versions.

### 1.1 Plain-language glossary

| Term | Plain meaning |
|---|---|
| Bundle | A small signed package containing a report or encrypted message. |
| Encounter | A period when two devices have an opportunity to communicate. |
| Relay | A phone carrying someone else's bundle onward. |
| Store-carry-forward | Save information now, physically move, and transfer it later. |
| TTL/lifetime | How long a bundle is allowed to remain useful for forwarding. |
| Geocast | Deliver information to interested people in an area, rather than one named recipient. |
| ACK | An acknowledgement; its exact meaning depends on whether it comes from a link, relay, or recipient. |
| GATT | A Bluetooth Low Energy mechanism for exposing and exchanging small pieces of data. |
| End-to-end encryption | Only intended endpoints can read the message; carriers handle ciphertext. |
| Sybil attack | One attacker creates many identities to appear to be many independent people. |
| Ablation | Remove one part of an algorithm to measure what that part contributes. |
| Goodput | Useful application bytes transferred per second after overhead and failures. |

## 2. Vision and research contribution

### 2.1 Product vision

An offline map answers “what is usually here?” TrailMesh adds “what did someone recently observe here?” It combines a prepared offline map with timestamped community observations and delayed private messages.

Examples:

- A mapped water source was dry when someone visited 40 minutes ago.
- A fallen tree blocks a trail segment.
- A hut was closed at the time of a recent observation.
- A friend receives “We are waiting at the hut” after another hiker carries the encrypted message.

Information is useful even if it arrives late, provided its age, uncertainty, and origin are clear. A message may arrive minutes later, hours later, or never. There must be a sequence of suitable encounters before it expires.

### 2.2 Technical identity

TrailMesh is an application-level **opportunistic delay-tolerant network**. Each participating phone is a store, carrier, and forwarding node. It does not require a continuous radio path from sender to recipient. It does not turn phones into general internet routers and does not implement a Bluetooth Mesh provisioning network.

```text
Time 1: Alice meets Bob          Alice --bundle--> Bob
Time 2: Bob walks elsewhere      Bob stores the bundle locally
Time 3: Bob meets Carol          Bob --bundle--> Carol

Alice and Carol never need to be near each other.
```

The transport only moves bytes between devices currently in contact. TrailMesh itself supplies persistence, expiry, forwarding decisions, duplicate suppression, and eventual delivery semantics. The application protocol takes inspiration from DTN literature but is not an implementation of Bundle Protocol Version 7 and must not claim BPv7 interoperability. [RFC 9171](https://www.rfc-editor.org/rfc/rfc9171)

### 2.3 Proposed original contribution

The diploma should investigate **geography- and route-aware scheduling and forwarding under short contacts and mobile operating-system constraints**.

Research question:

> Under equal radio, storage, and contact budgets, can a routing policy that considers coarse route relevance, report freshness, and carrier usefulness deliver more useful outdoor reports before expiry than simple flooding or limited-copy forwarding?

Supporting questions:

1. How much time is lost to discovery and setup compared with actual transfer?
2. Which reports should be transmitted first when contact may last only a few seconds?
3. How does withholding route information affect routing performance?
4. When does improved simulation performance survive measured phone limitations?
5. What is the tradeoff between delivery, resource consumption, and uncertainty?

Novelty is not “inventing mesh networking,” “inventing encryption,” or proving a universally superior routing protocol. It is a carefully defined adaptation, implementation, comparison, and honest analysis of its limits. Negative results are legitimate diploma findings.

## 3. Scope and non-goals

### 3.1 Required scope

- iPhone application with offline map preparation and report creation.
- Android companion that creates, receives, stores, and forwards the same bundles.
- Cross-platform offline transfer with both applications foregrounded.
- Persistent store-carry-forward across disconnection and process restarts.
- Signed public reports, expiry, duplicate suppression, and explainable evidence display.
- One-to-one encrypted text messages between contacts established in advance.
- A reproducible simulator comparing routing policies.
- A physical multi-hop demonstration and device feasibility report.
- Optional internet gateway designed so that removing it does not break core use.

### 3.2 Non-goals

- Guaranteed rescue, SOS delivery, emergency dispatch, or replacement for emergency equipment.
- Silent, unlimited background communication on iOS.
- Real-time tracking of strangers or live worldwide chat.
- Voice, video, large attachments, or sharing entire map packs through encounters.
- A new cryptographic primitive or an unsupported radio/background workaround.
- Per-encounter approval for public-report relaying is not part of the intended user flow. The user opts into one trail session; any transport-required peer confirmation remains an unresolved feasibility constraint until proven avoidable.
- Building a full navigation engine, social network, commercial moderation service, or global reputation authority.
- Full feature parity between the first iPhone and Android interfaces.
- Claims that offline use means Bluetooth and Wi-Fi are switched off.

An account, payment, or cloud login MUST NOT be required to use a downloaded map, create a local report, or exchange bundles with another prepared device.

## 4. Personas and user journeys

| Persona | Need | Relevant constraint |
|---|---|---|
| Day hiker | Recent water and trail information | Limited battery and intermittent signal. |
| Small hiking group | Exchange short private messages | Group members may separate and never get a timely relay path. |
| Frequent local hiker | Contribute fresh observations | Fast report entry and transparent evidence handling. |
| Hut operator or trail volunteer | Publish a time-limited status | Identity verification must be separate from self-description. |
| Student demonstrator | Show actual cross-platform relaying | Predictable foreground interaction and visible provenance. |
| Research evaluator | Compare algorithms fairly | Repeatable traces, source code, metrics, and limitations. |

### 4.1 Prepare for a hike

The user downloads one permitted map region, optionally selects a route, reviews what public reports can be shared, checks the required permissions, and starts a trail session before setting off. TrailMesh verifies that the map pack is complete and explains that public reports may be exchanged during the active session while private messages remain addressed to chosen contacts.

### 4.2 Create an observation offline

The user places a pin or uses their current location, chooses a category, selects the observation time, adds a short note, and saves. The app commits a signed bundle locally before showing “Saved on this phone.” It displays the report immediately even if no transfer has happened.

### 4.3 Exchange with another hiker

The user starts a clearly visible trail session once before the hike. While it is active, TrailMesh is intended to discover nearby compatible devices and exchange eligible public reports without asking either hiker to approve each encounter. Selection uses freshness and configured proximity or route relevance; it does not require sharing a precise route with peers. The app reports receipt and durable storage only after verification and commit. If the chosen transport requires per-encounter approval, that is a documented product limitation and an open transport decision, not behavior to disguise with UI wording.

### 4.4 Carry information onward

The first sender leaves. The receiving phone can restart, later meet a third device, and forward the original signed object unchanged. The next recipient sees the original observation time, not a fresh timestamp derived from the latest transfer.

### 4.5 Send a private message

The sender chooses a pre-established contact. The message is encrypted before entering the relay queue. Intermediate devices store opaque ciphertext. The recipient decrypts and verifies it locally. A separate encrypted receipt may eventually return to the sender.

### 4.6 Conflicting observations

One person reports a dry spring and another later reports flowing water. The application shows the observations, ages, and uncertainty. It does not silently rewrite history or turn majority votes into guaranteed truth.

### 4.7 Return to connectivity

If gateway sync is enabled, the phone uploads eligible public bundles and fetches relevant public updates. It deduplicates these against peer transfers. Private message upload requires a separate setting and is deferred beyond MVP.

## 5. Product requirements and interface

### 5.1 Main screens

1. **Explore map (home):** a real, permitted topographic map; downloaded coverage; optional route and current location; restrained report markers; and a compact report preview. The map remains the app's home screen.
2. **Reports:** a readable list and detail view showing category, observation and receipt times, location accuracy, supporting or conflicting reports, expiry, and provenance.
3. **New report:** a short, offline-safe form with a clear public-visibility explanation and a local saved confirmation.
4. **Nearby session:** one start/stop control for public-report exchange, a plain-language active state, current capability, and recovery for Bluetooth, location, or lifecycle limits. The target UX does not ask for approval on each public-report encounter.
5. **Private messages:** verified contacts, inbox, conversation, compose, and exact delivery states. This flow is separate from automatic public-report relaying.
6. **Offline maps:** available regions, download progress, verification, storage use, and removal.
7. **Settings:** sharing and route-privacy choices, permissions, storage and battery limits, gateway sync, and data deletion.
8. **Research diagnostics:** separate from ordinary hiking screens; available through a deliberate developer entry and exports redacted encounter statistics.

The iPhone interface is the presentation priority. Android initially needs a simpler map/list, report form, nearby session, message inbox/outbox, and diagnostics.

The interaction and visual direction are specified in [docs/UI_UX.md](docs/UI_UX.md). Use actual licensed cartographic data in the product and preserve its required attribution. A design prototype or generated map image is not proof of a permitted or operational map source.

### 5.2 Requirement identifiers

| ID | Requirement | Acceptance evidence |
|---|---|---|
| FR-01 | Prepared map works without internet after restart | Device walkthrough with all required resources cached. |
| FR-02 | Report creation persists without a peer | Restart and verify original signed bytes. |
| FR-03 | iPhone and Android exchange both directions | Physical transfer log and matching bundle hashes. |
| FR-04 | Relay survives disconnection | A -> B, restart B, B -> C, with A absent. |
| FR-05 | Duplicate transfers create one logical object | Repeated and concurrent ingest test. |
| FR-06 | Expired data is not forwarded as current | Controlled-clock expiry test. |
| FR-07 | Private relays cannot decrypt message content | Three-device test and cryptographic negative tests. |
| FR-08 | Recipient receipts are distinguishable from relay ACKs | Outbox state-machine test. |
| FR-09 | Users can stop exchange and revoke relay consent | Radio activity stops and UI state updates. |
| FR-10 | Interrupted transfers recover safely | Disconnect/crash tests at protocol boundaries. |
| FR-11 | Route privacy is configurable | Captured application frames contain only allowed fields. |
| FR-12 | Simulator results are reproducible | Same configuration and seed produce the same event digest. |
| FR-13 | A user-started trail session exchanges relevant public reports without per-encounter approval in the intended flow | Three-device encounter test demonstrates exchange without either hiker handling the phone; report selection matches the configured relevance rule. |
| FR-14 | UI states reflect measured transport and lifecycle capability | Permission denial, disabled radio, foreground-only, background-limited, interrupted, and active states are distinguishable; unvalidated background behavior is never promised. |

### 5.3 User-facing state language

Use plain states such as "Trail session active", "Exchange paused", "Open TrailMesh to continue", and "Bluetooth is off" based on measured capability. Explain that public reports can exchange during the active session and that no per-encounter approval is expected in the target flow. Until background behavior is verified for the exact adapter and device state, state clearly when the app must remain open. Do not display "Connected" when no active peer is known.

Use "Saved on this phone", "Shared with a relay", "Delivered to recipient", "Expired without delivery confirmation", and "Delivery unknown." Never infer recipient delivery from an SDK send callback or gateway upload.

Report information should say "Observed 47 minutes ago; received 3 minutes ago", "One unverified source", or "Conflicting observations." Do not use a green check mark that implies safety merely because a signature verified.

### 5.4 Initial nonfunctional targets

These are hypotheses to measure, not guarantees:

- Save a local text report within 500 ms at the 95th percentile on the primary phone.
- Open a downloaded region and local report list within 3 seconds in a cold-start test.
- Handle 10,000 small stored bundles without loading every object into memory.
- Keep accepted incomplete transfers inside a 2 MiB staging budget.
- Bound relay storage to 25 MiB initially; map storage has a separate user-selected budget.
- No loss of a locally acknowledged report after an ordinary process crash.
- Accessible text sizes, VoiceOver/TalkBack labels, and status indicators that do not depend only on color.

## 6. Platform strategy and development prerequisites

### 6.1 Recommended approach

Use **native Swift/SwiftUI for iOS** and **Kotlin/Jetpack Compose for Android**. Share a written protocol, test vectors, fixtures, simulator scenarios, and behavioral contracts. Keep the first routing core small enough to implement in both languages and compare against a reference simulator.

Why: the main uncertainty is platform networking and lifecycle behavior. Native applications make those issues easier to inspect. Android is a real protocol participant, not a web page or mock screen.

Alternatives:

| Approach | Advantage | Cost and decision |
|---|---|---|
| Native apps with shared contracts | Direct access to radio/lifecycle APIs; clear debugging | Some duplicated logic; recommended. |
| Kotlin Multiplatform domain core with native adapters | Shared validation and routing | Additional iOS integration/tooling risk; reconsider after basic interoperability. |
| Flutter or React Native UI with native transport modules | Shared UI | Native work remains; package availability must not be assumed; not the default for this project. |

A shared Rust core is also possible but adds FFI and build complexity. Do not introduce it solely to avoid a few hundred lines of duplicate deterministic logic.

### 6.2 Hardware and tooling gate

Before implementation, record:

- iPhone model, installed iOS version, free space, and developer-device availability.
- Android model, OS/API level, Google Play services availability, and BLE advertising support.
- A supported macOS/Xcode build environment for building, signing, automated tests, and uploading iPhone builds.
- Signing approach, test-device provisioning, and intended beta distribution.
- Third physical device for multi-hop tests.
- A permitted map source and a small demonstration region.

Windows supports editing, documentation, Android development, backend work, simulation, and analysis. Use a supported Apple build environment for iPhone compilation, signing, device installation, and TestFlight delivery. Physical radio tests run on the selected devices after installation.

### 6.3 Apple build and device validation

The iPhone deliverable requires the supported Apple build and signing toolchain. Validate the complete cycle early, record the exact toolchain and device versions, and keep the result as reproducible project evidence.

### 6.4 Build, install, and test cycle

1. Edit and commit source; synchronize it with the Apple build environment through the repository.
2. Build and run automated checks with a pinned Xcode/toolchain version.
3. Sign and upload a uniquely numbered build to App Store Connect.
4. Use **TestFlight internal testing** for the student's iPhone, with an eligible App Store Connect account/user and Apple Developer Program membership. Allow for upload and build-processing delays. External testers follow the applicable beta review process; internal testing is not an unrestricted public installation link. [TestFlight](https://developer.apple.com/testflight/), [Internal tester setup](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)
5. Install the processed build on the actual iPhone while internet is available. Install the compatible Android build locally from Windows.
6. Disable internet for the experiment while keeping the required local radios enabled; test the phones beside each other.
7. Export redacted diagnostics, retrieve them on Windows, fix problems, and repeat.

### 6.5 Debugging limitations and required diagnostics

The build environment does not automatically attach a local iPhone to a debugger or bridge Bluetooth radios. Validate the chosen device-debugging path separately.

Expect slower iterations than a locally attached device. Implement an in-app diagnostics screen and user-initiated redacted log export during the first networking spike. Include build/commit ID, protocol version, phone OS, permission state, transport stages, errors, timestamps, and byte counts. Exclude private content and keys. Preserve diagnostic records across ordinary app restarts and verify a practical share/export route for retrieving them on Windows after offline tests.

Simulator tests can verify supported UI and domain behavior, but cannot prove Bluetooth interoperability. Perform radio tests on the physical devices. Document the actual energy and profiling method.

### 6.6 Mandatory build-and-device gate

Before a long rental commitment or substantial iPhone feature work, prove:

- Source edit → Apple build/sign → TestFlight or supported device installation on the iPhone.
- A small checksummed foreground exchange with the local Android, without internet carrying the payload.
- Log export from both phones, a small code change, and installation of an updated iPhone build.

Record turnaround times, errors, and account requirements. This is an end-to-end workflow test, not evidence that background networking works.

Continue work on protocol fixtures, simulation, Android, and documentation while the device build gate is being validated. Keep iOS transport feasibility unresolved until tested on the phone. Cross-platform UI frameworks do not remove Apple build/signing requirements.

Select minimum supported OS versions after the first device inventory and SDK compatibility check. Gate iOS 26-specific experiments at runtime; do not equate that experiment with the minimum version required for all foreground functionality.

## 7. Transport options and verified caveats

This section summarizes documentation checked on 17 September 2026. Recheck relevant sources when selecting exact dependency versions.

### 7.1 Transport decision table

| Option | Role in TrailMesh | Main limitation | Decision |
|---|---|---|---|
| Google Nearby Connections | First foreground iPhone↔Android candidate | Actual device interoperability, consent, SDK behavior, and lifecycle need testing | Prototype first. |
| Custom BLE GATT | Alternative for compact cross-platform bundles | More fragmentation, reliability, and security work; iOS advertising asymmetry | Time-boxed fallback spike. |
| Local Wi-Fi with authenticated application protocol | Controlled no-internet exchange on a shared LAN | Requires a LAN/hotspot; does not prove spontaneous trail discovery | Diagnostic/fallback transport, clearly labeled. |
| Apple Wi-Fi Aware and Android Wi-Fi Aware | Potential higher-throughput direct transport | Hardware, pairing, entitlement, and cross-platform interoperability gates | Stretch experiment. |
| Apple Multipeer Connectivity | Apple-only reference or throwaway experiment | Does not provide the required Android API path; current deprecation status | Do not choose as core. |
| QR/file transfer | Contact exchange and debug bundle inspection | Manual; not opportunistic radio networking | Supporting tool only. |

### 7.2 Nearby Connections

Google documents offline nearby discovery, connection, and encrypted data exchange, including Android/iOS support. This makes Nearby a reasonable first candidate, not proof of performance on the student's phones. Its connection flow includes acceptance and authentication; use the documented verification flow for the first prototype. Do not treat link encryption as end-to-end message encryption. [Nearby overview](https://developers.google.com/nearby/connections/overview), [Swift connection management](https://developers.google.com/nearby/connections/swift/manage-connections)

Select a strategy supported by both selected SDK versions. Begin with one active peer and a point-to-point exchange. Measure discovery time, payload completion, permissions, and restart behavior. Record SDK analytics/privacy behavior in the dependency review. Never assume an underlying radio or connection mode solely from the API name.

Google announced that automatic enabling of Bluetooth/Wi-Fi by Nearby will be removed, with changes scheduled for late 2026. TrailMesh must handle disabled radios and ask the user to enable them. [Official change announcement](https://developer.android.com/blog/posts/upcoming-changes-to-the-nearby-connections-api)

Do not depend on tiny connectionless advertisements carrying application reports. Any such SDK feature requires separate documentation and interoperability evidence.

### 7.3 Core Bluetooth and the iPhone background boundary

Apple documents changed scan and advertisement behavior in the background, including service UUID overflow behavior and omitted local names. This is a particular concern for Android discovering a backgrounded iPhone. Test iPhone-as-central and iPhone-as-peripheral separately. [Apple background guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)

The current Core Bluetooth overview describes expanded privileges with an instantiated `CBManager` and a Live Activity started before backgrounding. However, an Apple engineer clarifies that a locked screen which is off changes scanning behavior even with a Live Activity. Treat foreground, background with screen on, lock screen visible, and screen off as different test states. [Core Bluetooth](https://developer.apple.com/documentation/corebluetooth/), [Apple engineer clarification](https://developer.apple.com/forums/thread/815189)

**Project policy:** no background claim without measured evidence for the exact phone/OS/adapter/state. A successful Core Bluetooth experiment does not establish equivalent behavior for the Nearby SDK. A running session also does not prove fresh discovery after suspension.

### 7.4 Wi-Fi Aware and Apple-specific frameworks

Apple describes Wi-Fi Aware as secure direct communication without an access point, with pairing, supported-device requirements, and app capabilities. Its mention of use while an app is running in the background must not be read as an unlimited execution entitlement. Android also exposes Wi-Fi Aware, but a common technology name does not prove that two particular application implementations interoperate. [Apple Wi-Fi Aware](https://developer.apple.com/documentation/WiFiAware), [Android Wi-Fi Aware](https://developer.android.com/develop/connectivity/wifi/wifi-aware)

Current Apple Multipeer documentation marks relevant APIs deprecated. In any case, selecting an Apple-only framework would not satisfy the required Android path. [Multipeer Connectivity](https://developer.apple.com/documentation/MultipeerConnectivity)

### 7.5 Android background operation

Android background work and foreground services also have restrictions. A user-started visible session may support longer operation, but process death, permissions, OS version, and vendor power management remain relevant. Choose the appropriate service type and permissions only after checking the target API level. [Android BLE background guidance](https://developer.android.com/develop/connectivity/bluetooth/ble/background), [Foreground services](https://developer.android.com/develop/background-work/services/fgs)

Do not use location, audio, accessibility, or other unrelated capabilities as a pretext to evade background rules on either platform.

## 8. Mandatory feasibility experiments

First complete the remote-workflow gate in section 6.6. Gate A requires a build installed on the actual local iPhone, not merely a successful remote simulator run.

### 8.1 Gate A — physical foreground interoperability

Build minimal apps before building the product UI. Exchange known bytes both directions with internet unavailable and required local radios enabled.

Test 256-byte, 2-KiB, and 8-KiB application objects; validate hashes. Run at least 20 deliberate 30-second contacts in each direction on the target device pair. Initial gate: at least 18/20 complete the 2-KiB exchange, with no silent corruption. Report the entire distribution and failures; passing this small sample is not a production reliability claim.

Evidence: hardware/OS/SDK versions, permission setup, strategy, per-attempt discovery/setup/transfer times, success counts, and packet/object hashes.

If Nearby fails, allow at most two additional weeks for a BLE GATT foreground spike. If neither works, document the blocking issue and agree a scope change with the project owner/mentor. A LAN demonstration is an explicitly reduced transport scope, not evidence that spontaneous cross-platform trail exchange works.

### 8.2 Gate B — lifecycle matrix

For each promising adapter, measure both directions with each phone in these states:

| State | What must be distinguished |
|---|---|
| Foreground, screen on | Baseline discovery and transfer. |
| Background behind another app | Existing connection versus fresh discovery. |
| Lock screen visible | With and without any supported active-session mechanism. |
| Screen off for 1, 5, 15, and 30 minutes | Discoverability and actual bundle completion after delay. |
| Low power/battery saver | Scan, transfer, and session behavior. |
| OS-terminated process | Documented restoration versus no restart. |
| User force-quit/stopped | Never assume automatic recovery. |
| Reboot before first unlock | Key and protected-file availability. |
| Permission revoked or radio toggled | Recovery without crash or misleading state. |

For iOS, compare Live Activity off/on only where the adapter genuinely supports the relevant path. Do not leave a debugger attached for the final measurements: debugging can change lifecycle behavior.

Initial sample: ten trials per selected state/direction, expanding the uncertain cells. Save failures and inconclusive results. The resulting capability table belongs in both the diploma and release notes.

### 8.3 Gate C — brief encounters and energy

Test 5-, 10-, and 30-second physical contact windows at measured distances, stationary and walking. Discovery can consume the entire window. Model failed discovery as failure, not as a zero-byte successful contact.

Measure an idle baseline and a 60-minute exchange session under controlled screen, map, location, and battery settings. Record thermal state and power-tool measurements where available. Battery percentage alone is coarse evidence. Establish a practical budget only after these measurements.

### 8.4 Gate D — persistence, keys, and mapping

- Save a report, kill/restart the app, and verify it can relay unchanged.
- Complete encryption/decryption and signature vectors on both platforms.
- Verify a relay cannot decrypt a contact's message.
- Restart with networking disabled and render the prepared region, labels, and route.
- Check keys and data access while locked; security defaults must not be weakened simply to improve experimental background behavior.

### 8.5 Gate E — architecture freeze

By the end of month two, produce a short architecture decision record selecting the foreground adapter, device support set, cryptographic library/profile, map source, and measured background capabilities. The default if background results are poor is **foreground exchange plus optional best-effort active session**, preserving the diploma's routing contribution.

## 9. System architecture

```text
                    iPhone / Android application
  +---------------------------------------------------------+
  | Map, report editor, nearby exchange, messages, settings   |
  +---------------------------------------------------------+
  | Use cases: create / inspect / exchange / deliver / expire |
  +----------------------+----------------------------------+
  | Domain               | Services                         |
  | Bundle validation    | Encounter coordinator             |
  | Evidence scoring     | Transfer scheduler                |
  | Routing policy       | Crypto and contact keys           |
  | Message state        | Optional gateway synchronization  |
  +----------------------+----------------------------------+
  | SQLite | Key store | Map cache | Bounded diagnostics     |
  +---------------------------------------------------------+
  | Transport adapter: Nearby / BLE / test link / local LAN  |
  +---------------------------------------------------------+
                         ↕ nearby peer

  Separate: simulator + trace analysis + optional HTTP gateway
```

Rules:

1. UI reads local state; network availability does not determine whether data exists.
2. Transport adapters move framed bytes and expose capabilities. They do not decide report truth or forwarding policy.
3. The encounter coordinator manages peer state, timeouts, cancellation, and fair transfer turns.
4. Routing receives immutable inputs and returns deterministic recommendations.
5. Crypto verification and persistence precede a durable acceptance ACK.
6. Optional cloud sync uses the same ingest validator and bundle IDs as peer sync.
7. Simulator logic cannot silently use global knowledge unavailable to real phones.

Use a single serialized state owner per encounter and a bounded worker pool for decoding/crypto. UI work remains on the platform UI thread. Cancellation closes sessions, releases staging reservations, and preserves already committed data.

## 10. Protocol and encounter lifecycle

### 10.1 State machine

```text
Disabled → Ready → Discovering → Connecting → VerifyingLink
       → Negotiating → Summarizing → Transferring → Closing → Ready
```

Any active state can transition to `Cancelled`, `PermissionBlocked`, `RadioUnavailable`, or `Backoff`. These return to a recoverable state without deleting committed bundles.

Initial defaults: one active peer, 15-second connection attempt, 5-second application negotiation deadline, 10-second idle timeout, and a 30-second deliberate exchange budget. Tune after Gate A. Discovery may continue longer while the user explicitly waits.

### 10.2 Wire messages

| Message | Purpose and bound |
|---|---|
| `HELLO` | Supported major/minor versions, session nonce, feature bits, max frame size; ≤1 KiB. |
| `CAPABILITIES` | Bundle kinds, storage allowance, optional coarse interests; ≤4 KiB. |
| `SUMMARY` | At most 64 bundle descriptors per page and ≤16 KiB encoded. |
| `REQUEST` | Requested IDs in priority order; at most 32. |
| `OFFER` | Bundle ID, total size, transfer ID, and optional forwarding-token offer. |
| `CHUNK` | Bundle fragment with transfer ID, offset, and exact total length. |
| `RECEIVED` | Durable validated local acceptance, duplicate, or structured rejection. |
| `TOKEN_COMMIT` | Idempotent limited-copy token ownership transition, where used. |
| `CLOSE` | Normal completion or bounded reason code. |
| `ERROR` | Safe machine-readable error, without private content. |

No arbitrary file paths, executable commands, or URLs to automatically open are allowed in protocol messages.

### 10.3 Encounter flow

1. Discover the application service using the transport's documented mechanism.
2. Establish the link and complete required consent/authentication.
3. Exchange `HELLO`; reject incompatible major versions before inventory processing.
4. Negotiate the smaller of local and peer size limits. Local hard limits always win.
5. Exchange bounded capabilities and optional coarse interest cells.
6. Send summary pages selected for likely relevance and recency.
7. Each side requests missing objects; the sender checks its own policy too.
8. Alternate bounded transfer turns so one device cannot monopolize the encounter.
9. Reassemble inside reserved staging space, validate, and commit atomically.
10. ACK only after durable acceptance; close when complete or the budget ends.

Use randomized reconnect backoff. Resolve simultaneous connection attempts using temporary session identifiers, not permanent public identity keys. If the SDK handles this internally, the adapter still must not expose two competing application sessions for one link.

### 10.4 Framing and transfer recovery

Use a 4-byte unsigned big-endian frame length followed by one encoded message. Reject lengths over the negotiated maximum before allocation. For message-oriented SDKs, preserve this logical framing without assuming one callback is one complete application object. The default maximum application frame is 16 KiB.

The adapter reports a safe chunk size based on the actual transport limits. BLE chunks may be far smaller than 1 KiB; never assume a fixed ATT MTU or that a large write is atomic.

For MVP, an interrupted incomplete bundle may be discarded and retried from byte zero. Completed bundles remain available. Cross-encounter partial resumption is stretch scope. Within an encounter, reject overlapping chunks with inconsistent bytes; cap active transfer count at two.

The BLE fallback must explicitly document its link-security mode. Signed public reports and end-to-end encrypted private payloads do not encrypt inventories or route hints. If a reviewed authenticated link protocol is not available within the spike, limit that fallback to deliberate foreground public-report/ciphertext exchange, disable sensitive interest sharing, and disclose visible metadata. Do not invent a custom key agreement or label bare GATT an encrypted channel. Any later authenticated channel must use an established protocol/library with cross-platform verification and a defined peer-authentication method.

### 10.5 Inventory and deduplication

Use exact bundle IDs initially. Paginate by a stable local ordering and limit inventory work per contact. Do not send the whole database before the first useful transfer. Interleave summary pages with requests and data.

Summary descriptors are untrusted hints. Only the complete signed bundle can establish its metadata. Track discrepancies as peer misbehavior. A Bloom filter may later reduce inventory bytes, but false positives must never become authoritative evidence of delivery; periodic exact reconciliation remains necessary.

## 11. Bundle format and validation

### 11.1 Immutable and mutable separation

A bundle has an **immutable signed core** and separate **local/transfer metadata**. Relays MUST forward the original core bytes unchanged. Hop history, encounter timestamps, token ownership, queue scores, and ACK state are not part of the author's signed core.

Recommended v1 serialization: canonical JSON using the JSON Canonicalization Scheme, UTF-8, integer timestamps and coordinates, no floating point in signed fields, and no duplicate keys. Freeze exact schema and cross-language fixtures before real signing. Base64url encodes byte fields without padding. The example below explains shape; it is not a valid cryptographic test vector.

Use RFC 8785 canonicalization, preserve string data without post-signing Unicode normalization, reject invalid Unicode, and restrict integers to the exactly representable range within ±(2^53−1). Test escaping and key ordering across languages; ordinary “sort JSON keys” options are not sufficient evidence of compatibility. [JSON Canonicalization Scheme](https://www.rfc-editor.org/rfc/rfc8785)

```json
{
  "core": {
    "protocol": "trailmesh",
    "version": 1,
    "kind": "report",
    "author_key": "BASE64URL_ED25519_PUBLIC_KEY",
    "nonce": "BASE64URL_16_RANDOM_BYTES",
    "created_at_ms": 1789646400000,
    "expires_at_ms": 1789732800000,
    "max_hops": 12,
    "body": {
      "event_id": "BASE64URL_16_RANDOM_BYTES",
      "category": "water",
      "status": "dry",
      "observed_at_ms": 1789646100000,
      "lat_e7": 421790000,
      "lon_e7": 235850000,
      "accuracy_m": 30,
      "note": "No flow observed at the spring.",
      "supersedes": null
    }
  },
  "signature": "BASE64URL_ED25519_SIGNATURE",
  "bundle_id": "LOWERCASE_SHA256_HEX"
}
```

Signing input is the UTF-8 domain separator `TrailMesh/core/v1\n` followed by canonical `core` bytes. `signature` is Ed25519 over that input. `bundle_id` is SHA-256 of UTF-8 `TrailMesh/id/v1\n` followed by canonical `core` bytes. The signature is verified independently. Do not hash a pretty-printed JSON representation.

The public signing key is included in the signed core. Its identifier is a SHA-256 fingerprint used only where needed. A valid signature proves control of that key, not the truth of the report or a real-world identity.

For encrypted messages, use a fresh per-bundle outer signing key so public-report identity is not automatically exposed. The trusted sender identity is verified inside the encrypted payload. The outer signature provides object integrity, not trusted sender authentication.

### 11.2 Bundle kinds

| Kind | Visible body | Purpose |
|---|---|---|
| `report` | Observation and location | Public outdoor information. |
| `evidence` | Target report ID and supporting/contradicting observation | Add evidence without editing another author's object. |
| `retraction` | Target bundle ID and reason | Author retracts their own report; copies cannot be forcibly erased. |
| `private_message` | Recipient capability tag, encryption suite, ciphertext | Opaque store-carry-forward message. |
| `private_receipt` | Same opaque addressing shape | Encrypted acknowledgement for a message. |

All object types use the same core validation pipeline. A receipt cannot request a receipt, avoiding infinite receipt chains.

### 11.3 Initial limits

| Limit | Initial v1 policy |
|---|---|
| Signed envelope size | 8 KiB maximum, including signature and ID. |
| Public note | 500 Unicode scalar values and 2 KiB UTF-8 maximum. |
| Private plaintext text | 1 KiB UTF-8 maximum, allowing room for cryptographic overhead. |
| Lifetime | Positive and at most 72 hours for any bundle. |
| Hops | Author cap 12; local policy may be lower. |
| Future clock tolerance | Five minutes for normal acceptance. |
| JSON nesting | At most eight levels. |
| Coordinate bounds | Latitude ±90° and longitude ±180° using E7 integers. |
| Evidence references | One target per evidence bundle. |

Category defaults: transient crowding two hours; water and mud observations 12 hours; obstruction/hut observations 24 hours; private messages 24 hours. These are initial relevance choices, not claims that conditions remain safe until expiry. Users can choose a shorter lifetime. A report past its relevance window can remain in a local history view labeled expired.

### 11.4 Validation order

1. Enforce byte, depth, string, collection, and staging limits.
2. Decode strict schema; reject duplicate keys, invalid enums, malformed base64, and unsupported major versions.
3. Recompute canonical bytes and bundle ID.
4. Verify the signature and key sizes.
5. Validate time order, lifetime, coordinates, kind-specific fields, and author authority for retractions.
6. Check expiry, local block rules, duplicate IDs, and admission quotas.
7. Commit core bytes, projections, and receipt state in a transaction.
8. ACK with `stored`, `duplicate`, `expired`, `invalid`, `quota`, or `unsupported`.

Unknown fields in a v1 core are rejected unless explicitly defined as optional extensions in the frozen schema. Do not silently remove fields before verification.

### 11.5 Time and hop limitations

An author chooses its clock and may lie. Use the original observation time for freshness; local receipt time never refreshes the report. Keep a local trusted-time estimate from previous reliable clock synchronization, with uncertainty, and use monotonic elapsed time during a session. If the clock jumps or uncertainty is large, label/quarantine questionable bundles instead of presenting precise freshness. Never use an untrusted peer's clock to reset local time.

Expire at the earlier of the signed expiry and the local admission time plus the permitted maximum lifetime; this bounds local retention even with a bad clock. Across offline reboots and malicious reintroduction, perfect real-time expiry is not guaranteed. Keep a bounded seen-ID cache and document the residual risk.

Hop counts are cooperative metadata. A hostile relay can reset them; they are not a security boundary. Cryptographically verified author lifetime limits, resource caps, and replay controls remain necessary.

## 12. Routing algorithms

Implement routing behind one interface. Separate **admission**, **replication permission**, **transfer priority**, and **eviction**. A high priority score does not authorize unlimited replication.

### 12.1 Baseline A — bounded epidemic flooding

Offer every valid unexpired missing bundle allowed by local resource limits. Use deterministic ordering by local class and age, with ID as tie-breaker. Track accepted transfers to avoid immediate repeated sends.

“Bounded epidemic” is the correct name because storage, expiry, and contact bandwidth prevent ideal unlimited flooding. It is simple and useful as a baseline, but can waste bandwidth on irrelevant information.

### 12.2 Baseline B — Binary Spray-and-Wait

For unicast messages, start with `L = 8` forwarding tokens. With `n > 1`, give `floor(n/2)` to a previously unserved relay and retain the rest. A holder with one token waits for the destination. Sweep L over 2, 4, 8, and 16 in experiments. This limited-copy idea follows Spray-and-Wait research. [Spyropoulos, Psounis, and Raghavendra](https://ee.usc.edu/netpd/assets/001/51985.pdf)

Token ownership is local mutable state, not a field that every relay can independently reset from the signed envelope. To avoid inventing tokens when ACKs are lost:

1. Sender durably reserves tokens under a unique transfer ID.
2. Receiver stores data and the pending grant idempotently, without forwarding rights for those tokens.
3. Sender receives durable acceptance, records the grant committed, and sends `TOKEN_COMMIT`.
4. Receiver activates that grant once. Repeated messages replay the same state.
5. After an uncertain crash/disconnect, sender does not reclaim possibly committed tokens merely because a timer expired. Reconcile with that peer or abandon the reservation.

This favors token conservation over perfect utilization. Crash and message-loss tests must demonstrate no token multiplication among cooperating implementations. Malicious devices can copy data or cheat; there is no global offline enforcement authority.

For public reports, there is no unique destination. Define a separate **limited-copy geocast adaptation**: forwarding-token splits control carrier replication, while a node whose local interest intersects the report region may consume a non-forwardable terminal copy. Report its recipient fan-out separately. Do not present it as the original unicast algorithm without qualification.

### 12.3 Baseline C — PRoPHET-style forwarding

Use an encounter-predictability baseline: strengthen a peer estimate after contact, age old estimates, and use transitive information to prefer a carrier with a better estimate for the destination. The reference protocol is RFC 6693. TrailMesh's simplified baseline must be labeled PRoPHET-style, not fully RFC-conformant. [RFC 6693](https://www.rfc-editor.org/rfc/rfc6693)

Proposed simplified simulator equations:

```text
encounter: P(a,b) ← P(a,b) + (1 − P(a,b)) × p_init
aging:     P(a,b) ← P(a,b) × gamma^k
transitive:P(a,c) ← max(P(a,c), P(a,b) × P(b,c) × beta)
```

Declare `k` as the number of elapsed 30-minute aging units; initialize `p_init=0.75`, `gamma=0.98`, and `beta=0.25`. These are chosen experiment parameters. Forward only when improvement exceeds epsilon 0.05, and use the same replication/resource caps as the compared policy.

Stable destination encounter histories conflict with privacy-preserving rotating identifiers. Therefore use stable simulated identities in the research baseline, disclose this advantage, and disable destination-history forwarding in the public app unless a consented identity mechanism exists. Regional encounter estimates are a different geography-oriented variant, not equivalent PRoPHET behavior.

### 12.4 Proposed TrailMesh GeoRoute policy

The custom policy asks two questions:

1. Is this report useful to the peer itself?
2. Is the peer a better carrier toward interested users or the report's region?

Inputs available without exact route disclosure:

- Report location, category, observation age, and local evidence score.
- Optional coarse interest/route cells shared during this encounter.
- Optional coarse travel direction and destination region, separately consented.
- Local contact history aggregated by region, where enabled.
- Remaining contact byte budget, buffer allowance, and local battery policy.
- Missing-bundle inventory and already acknowledged transfers.

Default route sharing is off. With consent, share an unordered capped set of cells along a route; do not send the full polyline, timestamps, home location, or contact list. For an initial implementation, use geohash precision 5 as a coarse bucket, while calculating actual local distance in meters for scoring. Geohash cells are not equal-area squares; the corridor width remains a separate explicit parameter.

Proposed normalized report score:

```text
F = exp(−ln(2) × age_seconds / category_half_life_seconds)
R = 1 if within peer's chosen corridor; otherwise exp(−distance_m / 3000)
C = local evidence score in [0,1]
S = locally capped category/severity weight in [0,1]
G = estimated carrier improvement in [0,1], or 0 if unknown
D = diversity bonus in [0,1] for underrepresented relevant cells

utility = F × (0.40R + 0.25S + 0.15C + 0.15G + 0.05D)
priority = utility / sqrt(max(encoded_size_bytes, 256))
```

These weights are an initial hypothesis. Tune on training scenarios only, freeze before evaluation, and include ablations. Never present the score as a probability that a report is true.

Use nonnegative age after clock validation. Initially set each category's half-life to half its default relevance lifetime. When the peer shares no area/route preference, set R to a neutral 0.5 and G to zero rather than inferring a hidden route. Use local interest for local display independently of this transfer score. Missing evidence starts from the declared evidence prior; missing inputs must not produce NaN or an accidental maximum priority.

Private messages cannot be scored from their plaintext. Prioritize direct recipient matches, then local-origin/fairness policy and limited-copy budget. Only use an optional coarse destination region if the sender explicitly authorizes that metadata disclosure. Do not infer a friend's current location from address tags.

### 12.5 Scheduler

Suggested service classes: control/valid receipts, direct-recipient messages, locally relevant reports, other private relays, other public relays. Reserve at most 10% of estimated bytes for control, then weighted round-robin across eligible data classes. Unused shares are borrowed. Give age-based service opportunities so low-scoring objects are not permanently starved.

```text
on_encounter(peer, budget):
    context = bounded_peer_context(peer)
    candidates = indexed_candidates(context)
    eligible = validate_local_policy_and_missing_ids(candidates)
    eligible = enforce_forwarding_tokens(eligible)
    while budget.has_room and contact.active:
        item = fair_queue.next_by_policy(eligible)
        result = transfer(item)
        persist_result_and_token_transition(result)
        budget.charge(actual_control_and_data_bytes)
```

Do not compute priority over an unbounded full-database scan for every received packet. Cache scores for the encounter and invalidate on relevant evidence changes.

### 12.6 Eviction

Delete expired relay payloads first, then invalid/quarantined overflow, then low-utility relays according to per-class budgets. Never silently delete the user's only undelivered outgoing message to make room for strangers' traffic. If the outbox is full, show a recoverable storage error.

A terminal copy received without forwarding rights remains readable but is not offered onward. Token state is reconstructed from durable transfer records, never from an inferred copy count.

## 13. Freshness, evidence, and trust

Maintain separate concepts:

- **Integrity:** do these bytes verify under the stated key?
- **Identity trust:** does the user recognize or verify that key?
- **Evidence:** what independent observations support or contradict this event?
- **Freshness:** how old is the original observation?
- **Relevance:** does it matter to this user's area/route?

One is not a substitute for another. Twenty relays of one observation remain one source.

### 13.1 Evidence model

An evidence bundle references a report ID, says `supports`, `contradicts`, or `no_longer_present`, and includes its own observation time and optional public note. Count at most one effective vote per author per target in the scoring window. Author self-confirmations do not add independent support. Locally blocked identities contribute no score.

MVP uses direct references. Automatic spatial clustering of independently created reports is stretch scope: nearby pins may describe different springs or trail segments. Never merge them solely because their coordinates are close.

### 13.2 Proposed explainable score

Let each eligible source contribute a bounded weight based on local trust class and age. Default unknown identity weight 0.25, verified personal contact 0.75, and explicitly enrolled local organization 1.0. Enrollment must be real; a display name such as “Park Ranger” has no authority.

```text
support = sum(decayed support weights), capped at 3
conflict = sum(decayed contradiction weights), capped at 3
evidence_score = (1 + support) / (2 + support + conflict)
```

This is a ranking heuristic, not a calibrated probability. Show descriptive labels and counts, not “92% safe.” Freshness is applied separately. Keep one unverified report visible at low confidence when relevant; low confidence should not silently hide a potentially important observation.

Sybil identities are cheap. Distinct keys are not proof of distinct people. Cap the benefit of unknown identities, flag suspicious bursts, and evaluate coordinated false reports. No purely offline scheme in this scope can guarantee truthful crowdsourcing.

### 13.3 Updates and retractions

An edit creates a new signed report with `supersedes` pointing to an earlier report by the same author and the same event. Preserve both objects. A same-author retraction suppresses the original in the normal view but does not erase remote copies or prove that the location is safe.

If an author publishes concurrent conflicting revisions, mark the event conflicted instead of choosing a universally “true” version by wall clock. Use a deterministic ID tie-break only for rendering order. Third-party disagreement remains evidence, not an unauthorized edit.

## 14. Encrypted private messaging

### 14.1 Trust establishment

MVP messaging is one-to-one text between contacts added before separation. Exchange a QR contact card in person and compare a short fingerprint. The card contains version, Ed25519 identity public key, X25519 encryption public key, random inbox capability tag, and a signature binding those fields. It contains no private keys.

A fingerprint checked in person authenticates the intended contact key. A signature on an unverified QR card alone does not prove who presented it. Key changes require a clear warning and re-verification. No server-dependent key lookup is necessary during a hike.

### 14.2 Recommended cryptographic profile

Use reviewed library operations, not hand-written encryption. Proposed MVP: libsodium-compatible X25519 sealed boxes, with an Ed25519-signed inner plaintext. Sealed boxes protect content for the recipient but do not authenticate the sender by themselves. The inner signature supplies sender authentication against the saved contact key. [libsodium sealed boxes](https://libsodium.gitbook.io/doc/public-key_cryptography/sealed_boxes)

The inner object includes sender and recipient key fingerprints, random message ID, creation and expiry times, text, a random 32-byte receipt secret, and the sender's return inbox tag for the receipt. Sign a canonical representation with a distinct domain separator, then encrypt the signed inner object to the recipient. On decryption, verify the recipient binding, sender contact key, signature, lifetime, and duplicate message ID. The return tag is inside encryption and bound by the sender signature; use the sender's previously verified encryption key for the reply.

The outer envelope uses an ephemeral signing identity, recipient capability tag, suite ID, and ciphertext. Bind outer routing/time metadata inside the encrypted object as well and reject mismatches. Do not put sender display name, text, receipt secret, or exact destination location outside encryption.

The capability tag is a random contact-shared address, not an encryption key. It is linkable across bundles until rotated. Anyone who learns it can attempt spam; the recipient still rejects messages not authenticated by an accepted contact. For MVP, keep it stable for the trip and rotate through an explicit new contact-card exchange. Per-contact tags and automated rotation are stretch work.

Generate inbox tags with 32 cryptographically random bytes. A peer may optionally announce one of its tags during an established exchange to request direct delivery; this disclosure permits correlation and must be explained. Possession or announcement of a tag is not proof of recipient identity and cannot generate a delivery receipt. Without a tag announcement, messages can still travel under normal limited-copy policy and be recognized/decrypted locally after receipt.

### 14.3 Limits and honest guarantees

- Relays and the gateway do not need plaintext or recipient private keys.
- Transport encryption protects a single connection; this layer protects stored ciphertext across relays.
- Long-term recipient-key compromise can expose recorded past sealed-box messages. **Do not claim forward secrecy or Signal-equivalent security.**
- Endpoints can copy or screenshot plaintext. A compromised unlocked phone is outside the confidentiality guarantee.
- Timing, ciphertext size, address tag, relay participation, and some routing metadata remain visible.
- A malicious relay may delete or delay messages. Encryption does not guarantee delivery.

A ratcheting protocol would require a separate design for delayed/out-of-order messages, key recovery, and library integration. It is stretch scope, not a quick replacement using a few custom cryptographic calls.

### 14.4 Delivery receipts

Receiver creates a signed, encrypted receipt to the sender containing the message ID and original receipt secret. Sender marks delivered only after decryption, recipient signature verification against the saved contact, and secret/ID match. A receipt means the recipient app accepted and decrypted the message; it is not a read receipt.

Relays cannot read the receipt and therefore do not globally delete the corresponding message. They retain it until normal expiry/eviction. A public cancellation mechanism would leak additional linkage and is deferred.

### 14.5 Key storage and local privacy

Store identity/encryption secrets using platform-protected key storage or a protected wrapping key with encrypted application storage. Verify library support and exact accessibility behavior on the target OS. Store private message plaintext only encrypted at rest; decrypt into memory for display. Suppress plaintext notifications by default.

Do not store keys in source control, logs, test screenshots, or analytics. Separate test identities from real contacts. MVP has no cloud private-key recovery; explain that losing keys can make old messages unreadable.

## 15. Offline maps and routes

Use MapLibre Native as the first renderer candidate. Both native platform documentation sets provide offline-region facilities. Pin the selected versions after a real download/restart test. [MapLibre iOS](https://maplibre.org/maplibre-native/ios/latest/documentation/maplibre/), [MapLibre Android](https://maplibre.org/maplibre-native/android/api/-map-libre%20-native%20-android/org.maplibre.android.offline/-offline-manager/index.html)

A renderer is not a map-data license. Select a provider/package that explicitly permits the intended offline downloads and redistribution, preserve attribution, and record terms and limits. Do not bulk-download standard OpenStreetMap raster tiles for offline packs; that endpoint's policy prohibits such use. [OSM tile policy](https://operations.osmfoundation.org/policies/tiles/)

### 15.1 Region preparation

- Start with one small permitted hiking region; a Rila/Musala-area example is suitable if data rights and coverage are verified.
- Download tiles, style, sprites, glyphs/fonts, and required metadata.
- Show estimated size, zoom range, coverage, provider, and data date.
- Verify completion and any available content checksums before “Ready offline.”
- Support pause/resume, failed download recovery, and explicit deletion.
- Test outside the downloaded extent and show a clear coverage boundary.

Do not assume any MBTiles or PMTiles file can be opened by every renderer/version. If using packaged archives, prove compatibility in the mapping spike before committing to that format.

### 15.2 Routes

MVP imports a bounded GPX polyline and displays it. Parse defensively: limit file size and point count, disable external entity expansion, validate coordinates, and simplify long tracks. The route remains local unless the user consents to coarse interest sharing.

Local route relevance can use minimum distance to a simplified polyline, a selectable corridor width initially 1 km, and a spatial index. Direction-of-travel estimates are optional and uncertain. Do not automatically reroute users around hazards without a validated route engine and appropriate context.

Location is optional for manual report placement. GPS position can be available without internet, but acquisition and accuracy vary. Display accuracy and allow correction. Background location recording is not required for MVP.

## 16. Data model and persistence

Use SQLite with migrations, indexed queries, transactional ingest, and platform-appropriate concurrency. iOS may use GRDB after dependency verification; Android may use Room. Keep map renderer storage separate from protocol storage.

### 16.1 Tables

| Table | Main fields and constraints |
|---|---|
| `bundles` | `bundle_id` PK, canonical core blob, signature, kind, author key, created/expiry times, size, validation status. |
| `reports` | Bundle FK, event ID, category, status, observation time, E7 coordinates, accuracy, superseded ID. |
| `evidence` | Bundle FK, target ID, author key, stance, observation time; index target and author. |
| `contacts` | Local contact ID, display label, verified public keys, inbox tag, verification date. |
| `private_messages` | Local message ID, bundle FK, direction, encrypted local content, delivery state. |
| `routes` | Local route ID, encrypted/local geometry, name, import date, sharing preference. |
| `map_regions` | Renderer region ID, bounds, style/version, state, size, licensing metadata. |
| `relay_state` | Bundle FK, admission time, expiry policy, forwarding tokens, hop estimate, queue class. |
| `transfers` | Transfer ID PK, peer/session scope, bundle ID, bytes, state, token reservation/commit. |
| `encounters` | Random local event ID, adapter, lifecycle state, coarse timing and byte counters. |
| `seen_ids` | Bundle ID, rejection/expiry reason, bounded retention deadline. |
| `sync_state` | Gateway scope, opaque cursor, retry state, last successful application. |
| `settings` | Versioned local preferences and consent flags. |

Use foreign keys where appropriate and indexes on expiry, kind, event ID, and report bounding-box lookup. Add SQLite R-tree or another spatial index when query measurements justify it. Do not store secret keys in plain SQLite columns.

### 16.2 Transaction rules

- Authoring: create immutable core and signature, insert bundle/projection/outbox state atomically, then update UI.
- Ingest: validate outside a short transaction, recheck dedup/admission inside it, insert canonical bytes and projections, then ACK.
- If a bundle already exists, verify consistency and return `duplicate`; do not update its original observation time.
- Store token reservations and transition state before sending messages that depend on them.
- Gateway batch cursor moves only after all applied items and rejection decisions are durably recorded.

Use database durability settings appropriate for the ACK promise; test crash behavior rather than assuming a commit callback proves survival under every power-loss condition.

### 16.3 Retention and deletion

Suggested defaults: relay payloads until expiry; expired public history seven days locally; redacted diagnostics seven days; seen-ID records until original expiry plus 24 hours, capped by storage. User-owned messages remain until explicit deletion or a clearly communicated retention setting.

On expiry, remove forwarding eligibility immediately even if history is retained. On user deletion, remove local data and keys as requested; explain that already distributed public observations and ciphertext copies cannot be remotely recalled. A retraction can propagate, but it is not guaranteed erasure.

## 17. Synchronization and optional gateway

### 17.1 Peer sync

Peer sync is bounded set reconciliation over immutable bundle IDs. A peer can be missing data, stale, malicious, or unable to store more. Rejections do not delete the sender's copy. A claimed inventory entry does not prove the peer actually possesses durable bytes.

Public conflict resolution is append-only evidence and author revision rules. Private messages deduplicate both outer bundle IDs and authenticated inner message IDs. No global last-write-wins document replaces original signed observations.

### 17.2 Gateway role

The optional gateway is another way to exchange public bundles when internet becomes available. It can distribute regional public updates and retain a bounded archive. It is not required for identity creation, local maps after download, or peer relaying.

Initial backend: a small Python/FastAPI service, PostgreSQL with PostGIS for regional queries, and a single deployable container. Treat this as a suggested implementation, not a mandatory platform. No Kubernetes or distributed queue is needed for the diploma.

The server uses the same schema, ID, signature, TTL, and moderation/admission rules. Uploading cannot refresh expiry or create a new author. Index trusted projections only after validating signed content.

### 17.3 Cloud-sync semantics

- Public upload is an explicit setting with a clear explanation that public reports may become more widely visible.
- Use idempotent bundle IDs and bounded batches.
- Download by coarse region and an opaque server cursor based on server ingestion order, not client timestamps.
- Cursor invalidation returns a bounded resynchronization instruction.
- Apply each page durably before advancing; retries must be safe.
- Distinguish authorization errors, throttling, offline status, and malformed content.
- Use exponential retry backoff with jitter and a maximum interval; never retry continuously in the background.

Private cloud mailboxes are stretch scope. If implemented, require separate sender consent, recipient retrieval authentication, per-mailbox quotas, encrypted payload-only storage, and traffic-metadata disclosure. Do not enable a globally enumerable open inbox API.

The gateway can withhold abuse from its own feed but cannot delete copies already circulating offline. Locally known blocking rules still apply.

## 18. Internal interfaces and HTTP APIs

### 18.1 Domain interfaces

Language-neutral contracts:

```text
TransportAdapter
  capabilities() -> AdapterCapabilities
  startDiscovery(sessionConfig) -> event stream
  connect(peerHandle) -> Link
  stop() -> completion

Link
  send(frameBytes) -> transportResult
  receive() -> bounded frame stream
  close(reason)

BundleValidator
  validate(rawBytes, clockContext, localPolicy) -> ValidatedBundle | Rejection

BundleRepository
  ingest(validatedBundle, receiptContext) -> Stored | Duplicate | Rejected
  candidates(query, limit) -> bundle descriptors
  commitTransferTransition(transferId, transition) -> durable result

RoutingPolicy
  admit(bundle, localState) -> admission decision
  rank(candidates, peerContext, contactBudget) -> ordered transfer plan
  forwardingGrant(bundle, peerContext) -> grant | denied
  evictionCandidates(localState) -> bounded ordered IDs

CryptoService
  signCore(core) -> signature
  encryptForContact(innerMessage, contact) -> ciphertext
  decryptAndVerify(ciphertext, localIdentity) -> authenticated inner object

Clock
  wallTimeEstimate() -> time with uncertainty
  monotonicElapsed() -> duration
```

Inject clock, randomness, storage, and transport so tests can control failures. Production randomness must use the operating system's cryptographic generator; seeded simulation randomness is never used for real keys or nonces.

### 18.2 Optional HTTP v1

| Endpoint | Semantics |
|---|---|
| `GET /v1/capabilities` | Supported versions, public size limits, and API policy version. |
| `POST /v1/public-bundles:batch` | At most 64 canonical signed envelopes and 256 KiB total; per-item results. |
| `GET /v1/public-bundles?cell=...&cursor=...&limit=...` | Bounded region feed; maximum 128 items with continuation cursor. |
| `GET /v1/public-bundles/{id}` | Fetch an eligible public object by ID; no private object enumeration. |
| `GET /health/live` | Process liveness without sensitive details. |
| `GET /health/ready` | Storage readiness for deployment checks. |

Reject excessive cells, large ranges, invalid cursor scopes, and expired objects. Return structured errors with safe codes: `invalid_schema`, `invalid_signature`, `expired`, `quota_exceeded`, `unsupported_version`. Do not log request bodies. Return `429` with retry guidance for quotas; use HTTPS for deployed endpoints.

Trial gateway authentication can use provisioned test-client tokens, stored securely and separate from content-signing keys. That limits abuse in a small experiment without making offline use depend on accounts. Define token issuance/revocation before any public deployment.

## 19. Security, privacy, and abuse resistance

### 19.1 Assets and adversaries

Protect private text, private keys, contact relationships, route intent, stored data integrity, battery, storage, and the distinction between observation and verified fact.

Assume attackers can run modified clients, record traffic, create many identities, lie about location/time, replay bundles, drop data, send malformed frames, and attempt resource exhaustion. The gateway may be unavailable or curious. Phones may be lost. Radio interference and platform suspension are normal failures, not necessarily attacks.

### 19.2 Threat-control matrix

| Threat | Required mitigation | Residual limitation |
|---|---|---|
| Modify a public report in transit | Author signature and content ID verification | Author can still lie. |
| Read relayed private text | End-to-end encryption and protected local keys | Metadata and compromised endpoints remain exposed. |
| Impersonate a friend | Verified contact fingerprint and inner signature | First-contact verification can be skipped or fooled. |
| Replay an object | ID deduplication, expiry, seen-ID cache | Bounded caches and bad clocks limit perfection. |
| Forge “delivered” state | Recipient-authenticated encrypted receipt | Receipt may never return. |
| Storage/CPU flood | Preallocation limits, bounded parsing, quotas, early rejection | Distributed attackers can still consume some resources. |
| False consensus | Per-author caps and limited unknown-source weight | No strong offline Sybil resistance. |
| Track hikers | Temporary encounter IDs, no automatic exact route disclosure | Public author keys, locations, and inbox tags can remain linkable. |
| Drop or selectively forward | Multiple carriers and measurable delivery uncertainty | Availability cannot be guaranteed. |
| Token cheating | Durable local conservation and tests | Malicious peers can violate cooperative replication rules. |
| Gateway compromise | Signed public objects and no plaintext private payloads | Server can censor, correlate, or replay valid objects. |
| Malicious map/GPX input | Trusted package source, checksums, bounded parsers | Provider/data mistakes remain possible. |

### 19.3 Privacy defaults

- Exchange and relaying require explicit user activation.
- Exact GPX route and precise live location stay on device by default.
- Public report location is visible to recipients; warn at composition, not in every subsequent action.
- Advertising includes no name, contact list, permanent user identifier, or private text.
- Rotate application encounter identifiers between sessions; do not claim this prevents all radio tracking.
- No content analytics, contact-list uploads, or continuous location telemetry.
- Gateway upload and diagnostics export have separate choices.
- Keep emergency-themed wording out of the UI unless clearly explaining limitations.

### 19.4 Initial abuse budgets

Suggested receiver-side defaults: 50 newly admitted bundles per peer encounter, 256 KiB admitted bytes per encounter, 20 new public objects per author per hour, at most two incomplete transfers, and a bounded signature-verification queue. Maintain separate reserved capacity for known-contact messages and user-owned content.

These limits are tunable and apply independently of peer claims. A rotating identity can bypass per-author limits, so total per-session, time-window, and storage limits are essential. Rate-limit high-priority labels; an attacker cannot claim unlimited “urgent” traffic.

Block/mute controls stop display and forwarding according to local policy. Render text as text, not HTML. Do not fetch links, load remote images, or execute embedded content from reports. Defer photographs until metadata stripping, file validation, and storage policies exist.

## 20. Simulator and testing strategy

### 20.1 Simulator responsibilities

Create a deterministic discrete-event simulator in Python. It models nodes moving along trails, opportunities to meet, discovery/setup loss, finite throughput, storage, replication, report relevance, expiry, private destinations, and optional gateways.

Inputs are versioned configuration files. Outputs are raw events, per-run metrics, aggregate tables, and charts. Every run records seed, code commit, configuration hash, policy version, and trace provenance.

```yaml
scenario: branching_trail
seed: 1042
duration_seconds: 21600
nodes: 50
mobility: trail_graph
contact_model: measured_foreground_profile_v1
buffer_bytes_per_node: 26214400
routing: georoute_v1
initial_forwarding_tokens: 8
route_sharing_fraction: 0.5
gateway_enabled: false
```

This is an intended configuration shape, not an already available command or calibrated profile.

### 20.2 Contact realism

Contact does not begin transferring application data at the instant two simulated nodes become geographically close. Apply a discovery success probability, measured setup-time distribution, and application goodput after setup. Debit inventory, framing, retransmission, and authentication costs.

Calibrate foreground and any supported background profiles separately. If only one phone pair has been measured, say so. Use sensitivity ranges rather than inventing a universal range or throughput value. Bluetooth range is not a fixed outdoor circle in reality.

Keep an optimistic ideal-contact model only as a clearly labeled upper-bound comparison. The real routing policy cannot access future encounters or other nodes' hidden routes. An offline oracle may be used as a separate bound, not as an ordinary competitor.

### 20.3 Scenario families

1. Sparse linear trail with walkers in both directions.
2. Branching trail network with destination-specific relevance.
3. Popular hut/hub producing repeated contacts and congestion.
4. Isolated groups with no temporal path between them.
5. Sparse gateway near the trailhead.
6. Unreliable discovery and predominantly short contacts.
7. Inaccurate or stale route intent.
8. No users sharing route intent.
9. Malicious flood and coordinated contradictory reports.
10. Dense population where blind replication overwhelms buffers.

Use synthetic routes first, then one permitted real trail graph. Any volunteer traces require consent, minimization, and de-identification. A real map underneath synthetic movement does not make it a real human movement dataset.

### 20.4 Test layers

| Layer | Necessary tests |
|---|---|
| Domain unit tests | Expiry, age calculations, route distance, evidence caps, ranking ties, fair scheduling. |
| Protocol conformance | Canonical serialization, IDs, signatures, malformed input, version negotiation. |
| Crypto interoperability | Swift↔Kotlin vectors, wrong key, tampered metadata, forged sender, replayed receipt. |
| Persistence integration | Duplicate concurrent ingest, migration, disk full, transactional ACK, token transitions. |
| Transport integration | Disconnect, reconnect, duplicate chunks, out-of-order delivery, timeout, cancellation. |
| Property/fuzz tests | Bounded allocation, parser robustness, token conservation, no expired forwarding. |
| Physical device tests | Real radios, no internet, lifecycle matrix, power observations. |
| Product acceptance | Map preparation, report creation, multi-hop relay, private delivery, understandable states. |

### 20.5 Failure injection

Crash sender/receiver immediately before and after durable commit, before/after ACK, and before/after token commit. Simulate low disk, wrong clock, lost response, duplicate batch, invalid signature, missing map glyphs, and revoked permissions.

Do not rely on emulators or iOS simulators to prove peer radio feasibility. They are valuable for domain/UI tests only within their supported capabilities.

## 21. Metrics and evaluation

### 21.1 Metric definitions

| Metric | Definition |
|---|---|
| Unicast delivery ratio | Unique messages decrypted by intended destination before expiry / eligible generated messages. |
| Delivery latency | Time from creation to first valid recipient acceptance, reported for delivered messages with delivery ratio alongside it. |
| Relevant report coverage | Delivered relevant `(report, user)` pairs before expiry / all predefined relevant pairs. |
| Reachable-pair coverage | Same calculation restricted to pairs with a feasible temporal path, reported separately. |
| Useful-information yield | Sum of fixed evaluation utility for first relevant deliveries / total radio bytes. |
| Transfer overhead | Control bytes + duplicate data bytes + relay bytes, with categories shown separately. |
| Duplicate ratio | Bytes for already possessed bundles / total application data bytes. |
| Expiry waste | Bytes spent on copies never consumed usefully before expiry / transmitted bytes. |
| Encounter success | Contacts delivering at least one valid new requested object / attempted contacts. |
| Setup cost | Discovery and connection time distributions, including failures/timeouts. |
| Buffer pressure | Peak bytes, eviction counts, and outbox admission failures. |
| Energy | Measured device energy or battery delta per controlled interval, plus bytes/useful deliveries. |
| Fairness | Delivery coverage by route, node cohort, and data class; include lower percentiles. |

“Eligible” and “relevant” must be defined before experiments. For public reports, one initial definition is that the user's route corridor intersects the report's area during its validity window. Compute this independently from each algorithm's ranking output. Do not define utility as “whatever GeoRoute scores highly,” which would bias the result.

The all-pairs denominator measures practical usefulness; the reachable-pairs denominator separates structural disconnection from policy failure. Report both rather than quietly excluding impossible cases.

### 21.2 Fair comparison

- Run direct-only, bounded epidemic, limited-copy, PRoPHET-style where applicable, and GeoRoute.
- Evaluate unicast and public geocast as separate workloads with explicit adaptations.
- Use identical mobility traces, generated traffic, buffer budgets, and contact capacities.
- Apply equal copy limits when isolating the priority policy's effect; also report native-policy comparisons.
- Charge metadata and history exchange to the contact budget.
- Use at least 30 seeds for key synthetic scenarios if practical.
- Tune weights on training scenarios; evaluate on held-out scenarios and seeds.
- Report median, percentiles, uncertainty intervals, and failure counts.
- Account for undelivered messages as censored/failed observations rather than giving them zero latency.
- Use paired comparisons on matched seeds and bootstrap confidence intervals where suitable.

### 21.3 Ablations and hypotheses

Compare GeoRoute without route relevance, without freshness, without carrier improvement, and without evidence scoring. Vary route-sharing participation, inaccurate routes, contact setup cost, bundle size, and replication budget.

Exploratory target: achieve 15% higher useful-information yield than bounded epidemic at a comparable relevant coverage, or materially lower bytes at comparable coverage. This is a **research hypothesis**, not an acceptance condition that justifies selective reporting. If it fails, explain where and why.

A successful diploma requires a functioning system and credible evaluation, not a predetermined win.

## 22. Observability and diagnostics

Structured local events should capture session ID, adapter/version, lifecycle state, stage durations, byte counts, bundle kind counts, rejection codes, and storage usage. Do not log message text, secret keys, complete contact cards, exact routes, or raw inbox tags.

For controlled tests, bundle IDs can be included in an explicit debug export with test identities. Normal logs should use short per-export pseudonyms so unrelated sessions cannot trivially be correlated. Exports are user-initiated, bounded, and redact sensitive data by default.

A diagnostic screen should answer: Is the radio available? Which permissions are missing? Is discovery active? What was the last failure? How many bundles were durably received? What capability is known for this lifecycle state?

Simulator telemetry is richer but must be labeled synthetic. Avoid a live map of real strangers or a global social-contact graph as a debugging convenience.

## 23. Stack and repository structure

### 23.1 Suggested stack

| Component | Starting choice | Gate |
|---|---|---|
| iOS UI/application | Swift + SwiftUI + structured concurrency | Supported Xcode and actual phone deployment. |
| Android UI/application | Kotlin + Jetpack Compose + coroutines | Actual Android permissions and SDK compatibility. |
| Foreground transport | Nearby Connections | Gate A before product integration. |
| Alternative transport | Native BLE GATT | Only if needed; independently tested. |
| Local database | SQLite with GRDB / Room candidates | Transaction and migration tests. |
| Maps | MapLibre Native with licensed offline data | Full offline render after restart. |
| Cryptography | Maintained libsodium-compatible bindings | Cross-platform vector and packaging spike. |
| Protocol | Versioned canonical JSON + exact fixtures | Canonicalization and signature tests. |
| Simulator/analysis | Python, NumPy, pandas, plotting library | Deterministic events and reproducible environment. |
| Optional gateway | Python/FastAPI + PostgreSQL/PostGIS | Deferred until peer vertical slice works. |
| Automation | GitHub Actions or equivalent | macOS iOS build runner plus Linux/Android jobs. |

Verify exact versions, licenses, maintenance, and distribution requirements at project setup; this table is a recommendation, not a claim that dependencies have already been installed or reviewed.

### 23.2 Repository

```text
trailmesh/
  README.md
  LICENSE
  SECURITY.md
  CONTRIBUTING.md
  apps/
    ios/                 # Native iPhone application and tests
    android/             # Native Android companion and tests
  protocol/
    schema/              # Frozen v1 envelope and frame schemas
    vectors/             # Valid and invalid cross-platform vectors
    examples/            # Clearly labeled human-readable examples
  simulator/
    trailmesh_sim/
    scenarios/
    tests/
  gateway/               # Optional bounded public-bundle service
  experiments/
    manifests/
    analysis/
    sample-results/      # Small reproducible sample, no private traces
  docs/
    specification.md
    architecture/
    decisions/
    feasibility/
    protocol/
    threat-model/
    evaluation/
    demo/
    diploma/
  tools/
    fixture-validation/
    demo-data/
  .github/workflows/
```

Inside each app, keep domain, persistence, transport, cryptography, features, and diagnostics separate. Do not make one global manager responsible for UI, BLE callbacks, database writes, and encryption.

Large datasets and raw device traces should be stored outside Git with checksums and retrieval instructions. Never commit provisioning secrets, credentials, private keys, or personal contact exports.

## 24. CI/CD and release process

Pull-request checks should run formatting/static analysis, schema checks, common vector validation, simulator tests, database tests, and Android compilation. A macOS runner should build and run supported iOS unit tests. Make unavailable physical checks explicit rather than pretending CI performed them.

Protocol or crypto changes require all platforms to consume the same vector set. A change to signed fields, canonicalization, or interpretation requires a version/compatibility decision. Migrations must be tested from the previous release's database fixture.

Keep protected signing credentials in the CI secret store and use least-privilege tokens. Do not expose signing material to untrusted pull requests. Pin dependencies and record build tool versions and licenses. Scan for accidentally committed secrets.

Release path: remote signed builds → TestFlight internal installation on the primary iPhone → small device-test group → signed demonstration candidate → optional external beta distribution. Make build/sign/upload repeatable, retain matching symbols for crash analysis, and record installed build numbers with device results. Check TestFlight build validity and install a current tested build before presentation day; do not depend on a last-minute upload. Public store release is not a diploma completion requirement. Recheck current platform submission and privacy requirements if publishing later.

Each tagged demonstration release includes its commit, protocol version, supported device matrix, known failures, demo reset instructions, and matching experiment manifest. Preserve a known-good build before rehearsals.

## 25. Nine-month milestones

Plan for roughly 36 weeks with variable school workload. This assumes consistent part-time effort and mentor access; it is not a guaranteed estimate. Keep 15–20% of the schedule for integration, writing, and unexpected failures.

| Month | Deliverables | Exit evidence | Scope control |
|---|---|---|---|
| 1 | Device/tooling inventory, protocol fixture, field UI/UX baseline, foreground transport spike, initial lifecycle matrix | Install/update/log-export cycle; documented map-first screen and session behavior; actual iPhone/Android foreground bytes with hashes | No background guarantee; no polished secondary flows before feasibility evidence. |
| 2 | Transport decision, durable signed report storage, report/map vertical slice, session controls, permitted offline map spike | Stored and deduplicated report survives restart; prepared map works offline; active public-report session behavior and limitations recorded | Freeze the first adapter only after physical evidence; no per-encounter prompt in the target public-report UX. |
| 3 | iPhone map/report experience, Android companion, expiry and three-device relay | A -> B -> C public report with A absent; restart B; usable field workflow on both platforms | Keep Android interface smaller; no photos or social feed. |
| 4 | Verified contacts, private message screens and encrypted envelope, delivery receipts, quotas | Relay cannot decrypt; false receipt rejected; public-report sharing remains separate | One-to-one text only. |
| 5 | Deterministic simulator, bounded epidemic and limited-copy baselines, measured contact profiles | Repeatable traces and token-conservation tests | Simulator supports research before visual animation. |
| 6 | PRoPHET-style comparison, GeoRoute, privacy controls, initial ablations | Shared-policy fixtures and preliminary held-out results | Freeze tuning procedure. |
| 7 | Field/lifecycle measurements, accessibility walkthrough, integration hardening, optional public gateway | Failure injection passes; field tasks are understandable; gateway-off core still works | Drop gateway if critical work slips. |
| 8 | Final experiments, statistical analysis, thesis draft, usability evaluation | Reproducible result package with failures, limitations, and usability findings | Feature freeze. |
| 9 | Defect fixes, thesis revision, mentor review, presentation rehearsals | Tagged build, finished report, repeatable demo and backup recording | No major new transport or crypto scheme. |

Monthly mentor review: demonstrate one working capability, inspect evidence, review risks, and decide the next bounded milestone. Begin writing background/methodology chapters early; do not leave the whole diploma document for month nine.

## 26. MVP, diploma completion, and stretch scope

### 26.1 MVP — minimum usable prototype

- One prepared offline region and GPX display on iPhone.
- Compact public reports with immutable signed envelopes.
- Android creates/receives/relays compatible bundles.
- Foreground exchange over a proven cross-platform adapter.
- Persistent deduplication, expiry, bounded storage, and recovery.
- Encrypted one-to-one text between preverified contacts, with explicit uncertain delivery.
- A three-phone two-hop test.

### 26.2 Diploma completion requirements

All MVP items plus:

- A deterministic simulator with realistic contact setup costs.
- Bounded epidemic, limited-copy, PRoPHET-style where meaningful, and GeoRoute evaluation.
- At least one substantive ablation and sensitivity analysis.
- Measured foreground/background capability matrix.
- Security/threat model and adversarial/failure tests.
- Reproducible research artifacts and a documented limitations section.
- A clear live demonstration and a labeled recorded fallback.

An optional gateway adds value but may be omitted with explanation if device networking and research require the time.

### 26.3 Stretch goals, in priority order

1. Best-effort user-started active sessions on measured supported states.
2. Optional public gateway and richer regional sync.
3. Better inventory compression and partial transfer resumption.
4. Route-aware private-message forwarding with explicit metadata consent.
5. Additional Android/iPhone models and OS versions.
6. Wi-Fi Aware experiment.
7. Contact-tag rotation and stronger messaging key evolution using an established library.
8. Carefully bounded photos, organization enrollment, or smarter report clustering.

Cut animations, large media, global identity/reputation, live tracking, sophisticated cloud services, and full navigation before cutting protocol correctness or evaluation quality.

## 27. Risks and decision register

| Risk | Likelihood/impact | Response and trigger |
|---|---|---|
| iOS screen-off discovery unreliable | High / high | Foreground baseline; Gate B evidence; no silent-background promise. |
| Apple build/sign/install pipeline not yet validated | Unresolved / high | Prove section 6.6 in month one. |
| Remote iteration delays or hosting/account costs | Medium / medium | Measure turnaround, add early log export, automate builds, and avoid a long rental commitment before the gate passes. |
| Target Android SDK/hardware incompatibility | Medium / high | Gate A on actual device; test alternative device/adapter. |
| Sparse adoption creates no paths | High / high | Controlled groups, simulation, truthful delivery states. |
| Scope exceeds one student | High / high | Android companion scope, one region, optional gateway, feature freeze. |
| Custom crypto mistake | Medium / critical | Established primitives/library, fixed profile, review and vectors. |
| Battery cost too high | Medium / high | Explicit sessions, measured duty cycles, pause controls. |
| Bad reports create misplaced confidence | High / high | Age/evidence display, no safety guarantee, conflicts visible. |
| Map rights or package incompatibility | Medium / medium | Licensed provider and full offline spike before UI investment. |
| Simulation is unrealistically optimistic | High / high | Measured setup/failure costs and sensitivity tests. |
| Copy tokens multiply after failures | Medium / high | Durable grant protocol and crash-boundary testing. |
| Protocol diverges across languages | Medium / high | Shared vectors in CI and frozen schema. |
| SDK or OS changes mid-project | Medium / high | Pin demo versions, record changes, rerun device matrix. |
| Demo venue radio interference | Medium / high | Rehearse, reduce data, use foreground, preserve recorded evidence. |

Required architecture decisions: transport selection; minimum OS versions; key/encryption profile; canonical encoding; route-sharing representation; map provider; routing parameters; gateway inclusion; background feature wording.

Each decision record contains context, alternatives, measured evidence, choice, limitations, and conditions for revisiting. Unknowns remain named experiments, never invisible assumptions.

## 28. Diploma structure and evaluation plan

Suggested title:

**TrailMesh: Geography-Aware Opportunistic Dissemination of Outdoor Reports and Encrypted Messages Across Mobile Devices**

Suggested chapters:

1. Problem and motivation: fresh information without reliable infrastructure.
2. Related work: offline maps, opportunistic networks, flooding, limited-copy routing, PRoPHET, mobile lifecycle restrictions, and encrypted relaying.
3. Requirements and scope: user needs, privacy, resources, and platform boundaries.
4. Architecture and protocol: immutable bundles, transfer state machine, persistence, and messaging.
5. Proposed GeoRoute policy: mathematical definition, privacy inputs, and complexity.
6. Implementation: iPhone-primary application and Android interoperability.
7. Methodology: simulator, contact calibration, scenarios, metrics, seeds, and fairness.
8. Results: numerical comparisons, ablations, physical measurements, and failures.
9. Threats to validity: device sample, synthetic mobility, route assumptions, key identities, clocks, and user density.
10. Conclusions and future work: supported claims and remaining questions.

Explain how this differs from a quick map-and-Bluetooth prototype: it specifies and validates a distributed persistence protocol, distinguishes link transfer from end-to-end delivery, evaluates routing choices under measured constraints, and manages security and uncertain evidence.

### 28.1 Reproducibility package

- Tagged source revision and dependency lockfiles.
- Protocol schema and valid/invalid vectors.
- Scenario configuration and random seeds.
- Raw or appropriately redacted event logs and checksums.
- Scripts/commands for producing each table and figure.
- Device/OS/SDK matrix and test setup photographs without private content.
- List of failed experiments and deviations from the original plan.
- Demonstration recording and written procedure.

Do not claim academic novelty without reviewing related work. Cite inspirations honestly. The earlier idea discussion referenced other projects; independently verify those before using their descriptions or performance in the thesis.

### 28.2 Completion rubric

The diploma should be judged on functioning cross-platform offline exchange, correctness under interruptions, protection of private content, sound experimental method, clarity of the proposed routing contribution, and candid limitations. High visual polish helps the presentation but cannot substitute for those criteria.

## 29. Presentation and demonstration

### 29.1 Main seven-minute scenario

Use three physical devices: A is the primary iPhone, B an Android relay, and C a compatible recipient phone. Prepare the region and contacts before the demonstration. Use fictional test identities and a clearly labeled synthetic report.

1. **Explain the problem:** the map shows a spring, but the map cannot say whether water is flowing today.
2. **Prove preparation:** disable internet while keeping the transport's required local radios enabled. Show the downloaded map and gateway-disabled state. Document the actual setup.
3. **Start once:** A's hiker starts the clearly labeled trail session before putting the phone away. Explain what public data can be exchanged and how to stop the session.
4. **Create:** A records "Demo: spring reported dry" and a separate private message addressed to C.
5. **First encounter:** A and B pass within range while the session is active. The intended public-report flow transfers the eligible report without per-encounter approval. B stores the separate private bundle as opaque ciphertext.
6. **Separate:** A leaves radio range. If practical, restart B to demonstrate persistence.
7. **Second encounter:** B later meets C; C receives the original report and decrypts the private message. B never displays private text.
8. **Explain delivery and evidence:** show durable relay status and report age. If the tested transport still requires a foreground screen or peer action, state that limitation and demonstrate the strongest verified behavior instead of presenting the target UX as already achieved.
9. **Show research:** display a chart comparing useful coverage and bytes under the same scenario and explain one case where GeoRoute loses or offers no benefit.

Keep the report's original observation timestamp visible to demonstrate that forwarding does not make it fresh again. Show identical bundle IDs in a researcher view if useful, without overwhelming the audience with implementation details.

### 29.2 What the demo proves

It proves offline local exchange, persistent multi-hop carriage, and recipient-only decryption on the demonstrated configuration. It does not prove unlimited range, guaranteed delivery, unrestricted background discovery, or real emergency reliability.

Two phones can prove cross-platform exchange and a relay's persistence, but cannot prove a physical three-node A→B→C chain. If only two phones are available, explicitly separate that demonstration from a simulated third node.

### 29.3 Backup plan

Preserve a screen recording of the exact physical scenario, plus redacted transfer logs and a deterministic simulator replay. Label the recording and simulation clearly. A local-LAN fallback can demonstrate application protocol behavior, but must be described as a different transport setup.

Rehearse with the same phones, OS versions, build, permissions, map data, and expected venue conditions. Keep a reset procedure that clears only test data, reinstalls test contact cards, and does not delete personal keys.

## 30. Instructions for the AI coding agent

### 30.1 Operating rules

Treat this document as the intended scope and initial design. Do not implement all sections at once. Start with evidence-producing vertical slices. Distinguish source-verified platform facts, proposed engineering choices, and measured behavior in every decision.

Do not invent successful device tests, benchmark numbers, background guarantees, working library integrations, or cryptographic vectors. If devices, the Apple build environment, credentials, or third-party access are unavailable, complete independent simulator/domain work and identify the exact blocked gate.

Keep the iPhone as the primary product. Android compatibility is required, even if its initial UI is smaller. Never quietly substitute an Apple-only transport, web prototype, or cloud chat for the core offline exchange.

### 30.2 First execution sequence

1. Inspect repository state and applicable project instructions; preserve existing work.
2. Record the actual phone models, OS versions, permissions, and supported build/signing workflow, then complete and prove the iPhone build/install/update/redacted diagnostics export cycle described in section 6.6.
3. Review the approved field UI/UX brief and preserve the map as the home screen.
4. Create a concise decision log and milestone checklist.
5. Verify current documentation and exact SDK versions for the target phones.
6. Implement the smallest foreground cross-platform byte exchange and collect Gate A evidence.
7. Add canonical envelope fixtures and cross-platform hash/signature verification.
8. Add transactional local storage, deduplication, expiry, and one durable ACK.
9. Demonstrate A -> B -> C with the original signed bytes.
10. Add the iPhone offline-map/report slice, automatic-session UX, and minimal Android equivalent. Treat unattended background behavior as unproven until device measurements support it.
11. Add preverified contacts and encrypted text using the frozen crypto profile.
12. Build the simulator and routing baselines; calibrate contact behavior.
13. Add GeoRoute and run the predeclared evaluation.
14. Add optional gateway/background/stretch features only after core milestones are secure.

### 30.3 First concrete backlog

| Ticket | Deliverable | Done when |
|---|---|---|
| TM-001 | Environment/device inventory and installation workflow | Actual versions documented; build installed and updated on the iPhone; diagnostics retrieved in the development workspace. |
| TM-002 | Nearby foreground spike | Bidirectional 2-KiB checksummed transfer demonstrated on target pair. |
| TM-003 | Lifecycle experiment sheet | Foreground/background/screen-off test protocol ready and initial results captured. |
| TM-004 | Protocol v1 fixtures | Same canonical bytes, IDs, and signature outcomes on both platforms. |
| TM-005 | Bundle repository | Durable ingest, duplicate handling, expiry and restart tests pass. |
| TM-006 | Encounter state machine | Timeout/cancel/retry work without false delivered states. |
| TM-007 | Public two-hop relay | Physical A→B→C with A absent and original timestamp unchanged. |
| TM-008 | Offline map slice | Prepared region renders after restart without internet. |
| TM-009 | Contact/message slice | C decrypts A's message; B cannot; false receipt rejected. |
| TM-010 | Simulator seed reproducibility | Same seed/config produces same event digest and metrics. |

For each ticket, include relevant tests, the observed outcome, limitations, and a small reviewable change. Prefer tests of invariants and failure cases over tests that merely mirror implementation details.

### 30.4 Definition of done for a feature

- User behavior and scope are clear.
- Necessary domain/integration tests pass.
- Cross-platform fixtures pass if protocol behavior changed.
- Failure and permission-denial behavior is implemented.
- Storage and processing remain bounded.
- No sensitive content appears in diagnostics.
- Documentation describes actual behavior and measured platform limits.
- Physical checks are completed or explicitly listed as outstanding; simulated evidence is labeled.

### 30.5 Decisions that require revisiting scope

Escalate architectural consequences rather than quietly changing the project if: no iPhone↔Android foreground adapter works; no workable Apple build/sign/install pipeline can be established; the crypto binding cannot safely meet the profile; map redistribution is not permitted; or the nine-month schedule cannot support both app correctness and evaluation.

Routine code organization, test scaffolding, and reversible implementation choices do not require repeatedly asking the user to approve work already within this specification.

## 31. Mentor profile and meeting brief

The best primary mentor is a **senior mobile engineer with strong iOS experience and practical Bluetooth/nearby networking knowledge**, ideally someone who has debugged real-device background execution and Android interoperability.

For the research portion, periodic help from a distributed-systems or computer-networking engineer/researcher would be valuable. A security reviewer should inspect the key exchange and message design before strong privacy claims. One person need not be expert in every area; a mobile lead with access to those specialists is a good fit.

Useful mentor capabilities:

- Native iOS development, signing, device debugging, and lifecycle constraints.
- BLE, peer-to-peer networking, asynchronous state machines, and failure recovery.
- Offline persistence and data synchronization.
- Experimental design, simulation, and fair performance comparison.
- Ability to review bounded student work regularly and help cut scope.

Meeting brief to adapt:

> I am building TrailMesh for my diploma: an iPhone-first app that exchanges fresh hiking reports and encrypted messages with Android phones without internet. Phones store information and carry it to later encounters. The research part compares routing methods, including a geography- and route-aware policy. I am looking for a mentor with native mobile and nearby-networking experience who can help validate iOS limitations, review the architecture, and guide realistic experiments. Occasional input from a networking or security specialist would also help.

Ask about periodic architecture/code reviews, help setting up Apple builds and TestFlight signing, additional test phones, and support designing experiments. A generic website-development mentor may help with software habits, but is unlikely to cover the project's hardest platform questions alone.

## 32. References and evidence boundaries

These are primary documentation or research sources checked during preparation. Links support platform facts and prior algorithms; the proposed TrailMesh design, numerical budgets, and scheduling formula are this document's engineering proposals. Recheck evolving APIs before implementation.

| Source | Why it matters |
|---|---|
| [Xcode host requirements](https://developer.apple.com/support/xcode/) | Apple build toolchain compatibility. |
| [Apple TestFlight](https://developer.apple.com/testflight/) | Installing remotely produced builds for local phone tests. |
| [TestFlight internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers) | Internal testing account/group setup. |
| [Google Nearby Connections overview](https://developers.google.com/nearby/connections/overview) | Offline nearby communication and SDK scope. |
| [Nearby Swift setup](https://developers.google.com/nearby/connections/swift/get-started) | iOS integration starting point; validate selected version. |
| [Nearby Swift connection management](https://developers.google.com/nearby/connections/swift/manage-connections) | Acceptance and authentication flow. |
| [Nearby radio-management changes](https://developer.android.com/blog/posts/upcoming-changes-to-the-nearby-connections-api) | Announced late-2026 behavior change. |
| [Apple Core Bluetooth](https://developer.apple.com/documentation/corebluetooth/) | Current framework and Live Activity guidance. |
| [Apple background processing guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html) | Background scanning/advertising differences; older guide, check against current SDK. |
| [Apple engineer response on screen-off scanning](https://developer.apple.com/forums/thread/815189) | Crucial qualification to broad Live Activity interpretations; not a universal device measurement. |
| [Apple Wi-Fi Aware](https://developer.apple.com/documentation/WiFiAware) | Supported direct-connect framework and pairing/capability considerations. |
| [Android Wi-Fi Aware](https://developer.android.com/develop/connectivity/wifi/wifi-aware) | Android-side capability and availability checks. |
| [Apple Multipeer Connectivity](https://developer.apple.com/documentation/MultipeerConnectivity) | Apple-specific scope and current API status. |
| [Android BLE background guidance](https://developer.android.com/develop/connectivity/bluetooth/ble/background) | Process and background connection constraints. |
| [Android foreground services](https://developer.android.com/develop/background-work/services/fgs) | User-visible long-running work requirements. |
| [RFC 9171, Bundle Protocol Version 7](https://www.rfc-editor.org/rfc/rfc9171) | DTN conceptual reference; TrailMesh does not claim conformance. |
| [RFC 8785, JSON Canonicalization Scheme](https://www.rfc-editor.org/rfc/rfc8785) | Deterministic bytes for signatures and IDs. |
| [RFC 6693, PRoPHET](https://www.rfc-editor.org/rfc/rfc6693) | Encounter-based routing reference. |
| [Efficient Routing in Intermittently Connected Mobile Networks: The Multiple-Copy Case](https://ee.usc.edu/netpd/assets/001/51985.pdf) | Spray-and-Wait family from its authors. |
| [libsodium sealed boxes](https://libsodium.gitbook.io/doc/public-key_cryptography/sealed_boxes) | Recipient encryption and lack of sender authentication by itself. |
| [MapLibre Native iOS](https://maplibre.org/maplibre-native/ios/latest/documentation/maplibre/) | Renderer and offline-region capabilities. |
| [MapLibre Native Android OfflineManager](https://maplibre.org/maplibre-native/android/api/-map-libre%20-native%20-android/org.maplibre.android.offline/-offline-manager/index.html) | Android offline-region API. |
| [OSM tile usage policy](https://operations.osmfoundation.org/policies/tiles/) | Restrictions on the standard raster tile service. |

**Final design boundary:** the intended result is a credible cross-platform offline prototype and a rigorous routing study. Any background capability must be described at the granularity actually tested. The project remains worthwhile even when iOS requires users to open the app for reliable encounters.
