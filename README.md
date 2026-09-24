# TrailMesh

TrailMesh is an iPhone-first, Android-compatible outdoor application for sharing fresh trail information without depending on internet access at the moment of exchange.

Phones store signed reports and encrypted messages, carry them while people move, and exchange selected data during later encounters. The project studies opportunistic networking, store-carry-forward routing, freshness, evidence, privacy, and the practical limits imposed by mobile operating systems.

> TrailMesh is a diploma research prototype. It is not an emergency communication or rescue system, and it does not promise unlimited silent background connectivity on iOS.

## Project specification

Read [TrailMesh.md](TrailMesh.md) for the complete product, protocol, security, testing, evaluation, and nine-month delivery plan.

The current map-first screen hierarchy, accessibility direction, and trail-session interaction are in [docs/UI_UX.md](docs/UI_UX.md). The milestone and GitHub project workflow is in [docs/PROJECT_PLAN.md](docs/PROJECT_PLAN.md).

## Current phase

The repository is in foundation implementation. The protocol v1 canonical fixture and a bounded local exchange contract are frozen and tested; the next technical gate is physical iPhone-to-Android validation with internet disabled. The local loopback harness is not physical radio evidence. The updated product direction keeps the Explore map as home and targets a single user-started public-report trail session, with no approval at each encounter; background and transport behavior remain subject to device validation.

## Repository layout

```text
docs/       Project plan, UI/UX brief, and feasibility notes
protocol/   Versioned wire-format and cross-platform fixtures
tools/      Python protocol reference and local transport contract tests
experiments/ Device evidence templates and native foreground transport probes
TrailMesh.md  Product, protocol, security, testing, and diploma specification
```

## Development principles

- Work through short-lived feature branches and pull requests.
- Keep `main` releasable and use `develop` as the integration branch.
- Record platform behavior as measured evidence, not assumptions.
- Keep public reports immutable and private messages end-to-end encrypted.
- Label simulations, physical tests, and unverified claims clearly.
- Do not commit credentials, private keys, personal routes, or raw contact exports.

## Starting sequence

1. Prove the iPhone build, install, update, and redacted diagnostics export cycle described in `TrailMesh.md`.
2. Validate the foreground iPhone-to-Android exchange described in Issue #2.
3. Implement durable local storage and a foreground exchange vertical slice.
4. Add the first three-device relay test.
5. Build the simulator and compare routing policies before adding stretch features.

## License

The initial project code and documentation are licensed under the MIT License. Map data, icons, and third-party dependencies retain their own licenses.
