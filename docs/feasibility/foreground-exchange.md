# Foreground exchange feasibility gate

Issue #2 establishes the smallest transport contract before report storage or routing is added. A platform adapter supplies discovery, consent/authentication, and byte transfer; the shared coordinator bounds the application object at 16 KiB, validates its SHA-256 digest, and records redacted lifecycle evidence.

Run the local contract tests from the repository root:

```text
python -m unittest discover -s tools/transport -p "test_*.py"
```

The local loopback transport is a deterministic development check. It does not prove radio interoperability. Physical Gate A evidence must be recorded in [`evidence-template-v1.json`](../../experiments/foreground_exchange/evidence-template-v1.json) using the selected iPhone and Android devices, with internet disabled while the required local radios remain enabled.

Each physical attempt must record the direction, payload size, adapter and strategy, permission/radio state, consent and authentication results, lifecycle timing, expected and received SHA-256 values, and a structured failure reason. The initial acceptance rule is at least 18 matching 2 KiB exchanges out of 20 in **each direction**. Do not record message contents, private keys, personal routes, or raw contact exports.
