# TrailMesh project plan

This plan turns the full specification into a reviewable starting backlog. It begins with feasibility evidence before product polish.

## First 14 days

1. Record the iPhone and Android models, OS versions, permissions, and available test devices.
2. Prove the iPhone build, signing, installation, update, and redacted diagnostics export cycle.
3. Create the first Nearby Connections or equivalent foreground transport spike.
4. Verify a 2 KiB checksummed exchange in both directions with internet disabled.
5. Freeze the first protocol fixture: canonical bytes, SHA-256 bundle ID, and Ed25519 signature verification.
6. Record a lifecycle test matrix instead of assuming background behavior.

## First month exit criteria

- The iPhone build/install/update/log-export gate passes.
- A real iPhone and Android exchange known bytes in the foreground.
- The repository has a repeatable build note and no secrets.
- A written transport decision records what was tested and what remains unknown.

## Following milestones

| Milestone | Outcome |
|---|---|
| M1 Foundation | Repository, Apple build workflow, protocol fixtures, and device inventory. |
| M2 Durable exchange | Signed report persistence, deduplication, expiry, and A→B→C relay. |
| M3 Private messaging | Verified contacts, encrypted text, opaque relaying, and delivery receipts. |
| M4 Research simulator | Deterministic traces and bounded epidemic/limited-copy baselines. |
| M5 GeoRoute | Geography/freshness/utility scheduler with ablations. |
| M6 Evaluation | Physical lifecycle measurements, held-out scenarios, and thesis figures. |
| M7 Demo/release | Tagged build, reproducible demonstration, limitations, and final documentation. |

## Working rules

Use one issue per bounded outcome. Link each pull request to an issue. Do not merge a protocol or security change without tests or a written blocked-test reason. Keep `main` stable and integrate through `develop`. Pull requests are assigned to the project owner; automated CodeRabbit review supplies an additional check.
