# Changelog

All notable changes to TrailMesh are documented here.

## [Unreleased]

### Protocol fixture

- Frozen protocol v1 RFC 8785 canonicalization, SHA-256 bundle ID, and Ed25519 verification vector.
- Reference Python tooling and tests for strict Base64URL, duplicate-key rejection, and signature verification.

### Transport foundation

- Native iPhone and Android probes with one-start, bidirectional generated-byte exchange over Nearby Connections.
- Probe-v2 wire vectors, duplicate-safe progress, bounded retries, session checkpoints, and redacted log validation.
- Android foreground-service ownership and iPhone Live Activity integration with saved pause/resume behavior.
- Recorded M1 physical evidence: 20/20 exchanges in each direction for 256-byte, 2-KiB, and 8-KiB payloads with Wi-Fi and mobile data disabled; a separate 2-KiB background run also completed in both directions.

### Development workflow

- CI for shared protocol contracts, Android tests/builds, iPhone simulator tests, and unsigned device IPA packaging.
- Change-scoped native CI jobs and grouped dependency updates targeting `develop`.
- Updated README and specification for the completed M1 foundation and M2 implementation backlog.
- Removed unused Android callback/error helpers and their obsolete tests; aligned editor line endings with Git's LF policy and excluded local Kotlin compiler caches.

## [0.1.0] - 2026-09-18

### Added

- Comprehensive TrailMesh diploma specification.
- GitFlow solo-project workflow and public repository foundation.
- CodeRabbit configuration prepared for repository review.
- Initial project plan and quality workflow.

### Not yet implemented

- Mobile applications and transport adapter.
- Bundle protocol fixtures and cryptographic implementation.
- Offline map pack and routing simulator.

This is a documentation/foundation release, not a usable outdoor or messaging application.
