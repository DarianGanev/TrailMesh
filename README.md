# TrailMesh

TrailMesh is an iPhone-first, Android-compatible outdoor application for sharing fresh trail information without depending on internet access at the moment of exchange.

Phones store signed reports and encrypted messages, carry them while people move, and exchange selected data during later encounters. The project studies opportunistic networking, store-carry-forward routing, freshness, evidence, privacy, and the practical limits imposed by mobile operating systems.

> TrailMesh is a diploma research prototype. It is not an emergency communication or rescue system, and it does not promise unlimited silent background connectivity on iOS.

## Project specification

Read [TrailMesh.md](TrailMesh.md) for the complete product, protocol, security, testing, evaluation, and nine-month delivery plan.

## Current phase

The repository is in foundation setup. The first technical gate is an installable iPhone build followed by a small foreground iPhone-to-Android exchange with internet disabled.

## Repository layout

```text
docs/       Project plan and delivery milestones
protocol/   Versioned wire-format and cross-platform fixtures
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
2. Freeze protocol v1 fixtures and cross-platform hashing/signature behavior.
3. Implement durable local storage and a foreground exchange vertical slice.
4. Add the first three-device relay test.
5. Build the simulator and compare routing policies before adding stretch features.

## License

The initial project code and documentation are licensed under the MIT License. Map data, icons, and third-party dependencies retain their own licenses.
