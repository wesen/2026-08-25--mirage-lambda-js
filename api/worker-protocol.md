# Internal worker protocol

The internal control-plane/worker protocol (guide §14 and appendix C). The
OCaml types live in `common/protocol.ml`; the wire schemas are
`api/invocation-envelope.schema.json`. All cross-boundary types carry an
explicit `protocol_version` field (§35.4).

## Transport choice (§14.1)

mTLS over a private interface is the v1 choice. The control plane pushes
assignments; the worker returns completions. Framing (§C.5) is a length-prefix
at the transport layer.

## Endpoints (§14.2)

| Method | Path | Direction |
|---|---|---|
| POST | /internal/v1/register | worker -> control (start handshake) |
| POST | /internal/v1/invoke | control -> worker (assignment) |
| POST | /internal/v1/cancel/{invocationId} | control -> worker |
| POST | /internal/v1/drain | control -> worker |
| GET  | /internal/v1/health | worker |
| GET  | /internal/v1/ready | worker |

## Envelopes

- **invocation_envelope** (§14.3): `protocol_version`, `invocation_id`,
  `revision_digest`, `entrypoint`, `export_name`, `event_json`,
  `context_json`, `deadline_ms`, `attempt`, `capability_token`.
- **assignment** (§C.2): `protocol_version`, `worker_id`, `lease_id`,
  `invocation`.
- **completion_envelope** (§C.4): `protocol_version`, `invocation_id`,
  `completion`, `metering`.
- **start_handshake** (§C.3): `protocol_version`, `worker_id`, `image_digest`,
  `runtime_version`, `ocaml_version`, `mirage_version`.

## Invariants (§14.4)

- Unknown or stale `protocol_version` is rejected.
- Internal errors never include raw C pointers, memory dumps, secrets, or
  full module source.
- Lease ids, attempt counters, and token expiration prevent replay.
