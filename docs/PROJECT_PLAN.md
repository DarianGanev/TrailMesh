# TrailMesh project plan

This plan keeps the diploma work tied to reviewable issues and evidence. The product's interaction baseline is in [UI_UX.md](UI_UX.md); the complete product and technical specification is [TrailMesh.md](../TrailMesh.md).

## Current gate

The repository has a frozen protocol v1 fixture and a bounded exchange contract. PR #24 added a local loopback harness and an evidence template; it did not prove physical iPhone-to-Android radio interoperability. Issue #2 remains open until the physical foreground test is recorded. Issue #25 captures the updated field UI contract and planning alignment.

## Milestones and issue sequence

| Milestone | Outcome | Current issues |
|---|---|---|
| M1 Foundation | Protocol baseline, device/build inventory, the field UI/UX brief, and measured foreground transport feasibility. | #2 physical transport gate; #25 design and planning documents. |
| M2 Durable exchange | Persistent signed reports, deduplication, expiry, multi-hop relay, and the map/report/public-session vertical slice. | #3, #4, #26, #27. |
| M3 Private messaging | Verified contacts, encrypted one-to-one messages, opaque relaying, receipts, and distinct message screens. | #5, #28. |
| M4 Research simulator | Deterministic traces and comparable flooding, Spray-and-Wait, and PRoPHET-style baselines. | #6. |
| M5 GeoRoute | Geography-, freshness-, and route-aware forwarding with ablations against the baselines. | #7. |
| M6 Evaluation | Held-out scenarios, lifecycle measurements, usability evidence, figures, limitations, and a repeatable demonstration plan. | #8. |
| M7 Demo and release | A tagged demonstration build, verified setup, final documentation, and rehearsed primary and backup demos. | Create bounded follow-up issues when M6 evidence defines the remaining work. |

Milestone sequence is a delivery order, not a promise that a transport or background behavior is already feasible. Keep the M1 physical exchange issue open until evidence from actual devices meets its acceptance criteria.

## GitHub projects

- [TrailMesh Diploma Roadmap](https://github.com/users/DarianGanev/projects/3) shows the milestone sequence and outcomes.
- [TrailMesh Development Kanban](https://github.com/users/DarianGanev/projects/5) tracks Todo, In Progress, Blocked, Review, and Done work.
- [TrailMesh Research and Experiments](https://github.com/users/DarianGanev/projects/4) tracks hypotheses, device evidence, routing comparisons, and evaluation artifacts.

Every active issue belongs to the roadmap and development Kanban, has one milestone, useful labels, and DarianGanev as its sole assignee. Research issues and physical evidence work also belong to the research board. Move work to Done only when the issue's acceptance evidence exists.

## Delivery rules

- Keep `main` releasable and integrate through `develop` using short-lived feature branches and pull requests.
- Link each pull request to its issue, assign only DarianGanev, and add relevant labels and milestone.
- Wait for CI and a requested CodeRabbit review; resolve actionable findings before merging to `develop`, then delete the feature branch.
- Make a local contract test, simulator result, and physical device result clearly distinguishable in documents and project status.
- Write one bounded issue per outcome. Split work when its implementation or acceptance evidence can be reviewed independently.
- Do not promise unattended iOS or Android behavior until the exact phone, OS, adapter, and lifecycle state have been tested.

## Diploma exit evidence

The project is complete when the cross-platform report path is demonstrated with persistent multi-hop forwarding; private message confidentiality is tested; routing baselines and GeoRoute are compared reproducibly; the core field tasks are understandable in an accessibility walkthrough; and the final report includes methods, results, failed tests, and platform limitations.
