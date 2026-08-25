# Architecture

The authoritative architecture is `mirage_lambda_service_implementation_guide.md`
(Part II, §7–18). This file tracks repo-specific deviations and links.

- Control-plane unikernel: §7.1 — `control/` (Phase 4 Unix, Phase 5 Mirage).
- Worker unikernel: §7.2 — `worker/` (Phase 3 Unix, Phase 6 HVT).
- Host launcher: §7.3 — `launcher/` (Phase 7).
- Capability system: §15 — `common/capability.ml` (Phase 1), `worker/capability_broker.ml` (Phase 3/8).
- Persistent state: §11 — `control/metadata_writer.ml`, `control/artifact_store.ml` (Phase 4/5).
- Scheduler: §13 — `control/scheduler.ml` (Phase 4/7).
