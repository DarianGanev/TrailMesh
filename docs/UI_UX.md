# TrailMesh UI and interaction brief

## Visual and accessibility direction

- Use the platform system font and system text scaling. Keep sentence case for normal labels and use familiar words before technical terms.
- Favor a restrained, daylight-readable palette with strong text/background contrast and one clear primary action per screen. Do not rely on color alone to communicate freshness, hazard, selection, or delivery.
- Avoid decorative map-like backgrounds, made-up contour patterns, oversized cards, ornamental badges, neon effects, and unnecessary gradients. The real map should provide the visual detail.
- Use a real basemap from a selected provider or permitted dataset. Show the provider's required attribution and verify download and redistribution rights before implementation. Never present a generated or illustrative image as operational cartography.
- Keep controls large and plainly labeled; target at least 44 pt on iOS and 48 dp on Android where practical. Support VoiceOver, TalkBack, large text, and strong contrast.
- Keep radio, protocol, routing, and raw diagnostic details off ordinary hiker screens. Put them in the separate research diagnostics area.

## Navigation and required screens

Use five plainly named primary destinations: **Map**, **Reports**, **Nearby**, **Messages**, and **Settings**. Do not replace the map home with a connection dashboard.

| Screen | Main job | Required content and behavior |
|---|---|---|
| Explore map (home) | Understand the area and nearby observations | Real topographic basemap, optional route and current location, restrained report markers, map controls, offline-map status, and a compact selected-report preview. |
| Reports | Browse observations without relying on the map | Readable report list, freshness/provenance, category, and clear empty/offline states. |
| Report detail | Decide how much to trust and whether it is useful | Observation time, receipt time, approximate location accuracy, note, expiry, and conflicting or supporting reports. Never turn a valid signature into a safety claim. |
| New report | Save a useful observation quickly | Obvious category choices, location and time, short note, public visibility explanation, and confirmation that it is saved locally. |
| Nearby session | Start, inspect, or stop public-report sharing | One start/stop action for a trail session, plain-language explanation, current capability, and clear permission/radio/lifecycle recovery. |
| Messages | Contact a known person privately | Verified contacts, inbox, conversation, compose, and honest pending/relayed/delivered/unknown/expired states. Keep this separate from public-report exchange. |
| Offline maps | Prepare for an area without internet | Available regions, size estimate, progress, verification, storage, removal, and empty/error states. This can be opened from Map or Settings rather than taking a primary navigation tab. |
| Settings | Change privacy and app behavior | Public relay consent, route sharing, permissions, storage, battery, gateway sync, and data deletion. |
| Research diagnostics | Inspect measured behavior | Separate developer/research entry; redacted, user-initiated export. Never include message content, private keys, contact exports, or complete routes. |

The current approved designs include the Explore map, report list/detail, new report, Nearby ready/active/error states, messages/contact flows, offline-map states, and settings/diagnostics. Do not add placeholder screens that repeat these jobs.

## Public-report trail session

The target hiking flow is:

1. Before setting off, the hiker opens Nearby, reads what public information can be shared, and starts one trail session.
2. While the session is active, TrailMesh selects fresh reports that are near the hiker or relevant to an optionally selected route and exchanges them when a compatible device is encountered.
3. Neither hiker has to hold the phone or approve each public-report encounter. The hiker can see that a session is active and can stop it at any time.
4. TrailMesh confirms only what it can prove: received, validated, and durably saved are distinct from attempted or transmitted.

The initial relevance rule must be deterministic, privacy-preserving, and testable. Do not transmit a precise route merely to filter reports. Explain which user settings affect public relaying. Private messages are never included just because a public-report session is active; they remain addressed to a previously verified contact under the separate message flow.

This is the intended product behavior, not a claim that the selected transport already supports it. In particular, Google Nearby Connections has a peer acceptance flow, and mobile operating systems restrict background execution. Prototype candidate transports and lifecycle states before locking the implementation. If the transport requires per-encounter acceptance or only works while the app is open, record that as a measured limitation and revisit the adapter/product scope. Do not hide it behind an "automatic" label or imply that a running UI guarantees screen-off discovery.

## State language

Prefer short, concrete messages such as:

- "Trail session active"
- "Public reports may exchange while this session is active"
- "Open TrailMesh to continue exchanging"
- "Bluetooth is off"
- "Location access is needed for nearby reports"
- "Saved on this phone"
- "Received and saved"
- "Shared with a relay"
- "Delivered to recipient" or "Delivery unknown"

Show a clear distinction between the age of an observation and the time it reached this phone. Do not use "connected" without an active peer or "delivered" based on a transport callback.

## Acceptance checks

- A first-time or infrequent smartphone user can locate the offline map, read a report's age, submit a report, start/stop a trail session, and open a private message without a tutorial.
- Explore map is the home destination after launch and remains legible with the report preview open.
- Public reports can exchange during the intended active session without per-encounter approval in the product target; any transport limitation is shown accurately.
- Private messaging is visibly separate and remains recipient-specific.
- Denied permission, disabled radio, empty offline maps, failed downloads, expired reports, and uncertain message delivery have plain recovery guidance.
- Screen-reader names, text scaling, contrast, and target sizes are checked on both platforms.
- Production maps use a verified permitted data source with required attribution; the design prototype is not cited as map-source evidence.
