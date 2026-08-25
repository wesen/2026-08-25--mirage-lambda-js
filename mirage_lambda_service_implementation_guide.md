---
title: "Mirage Lambda Service"
subtitle: "Theory, architecture, and implementation guide for a JavaScript function-as-a-service built from MirageOS unikernels"
author: "Technical design and implementation plan"
date: "Status date: 2026-08-25"
lang: en-US
documentclass: report
classoption:
  - oneside
fontsize: 10pt
geometry:
  - margin=0.78in
mainfont: "Lato"
sansfont: "Lato"
monofont: "DejaVu Sans Mono"
colorlinks: true
linkcolor: "linkblue"
urlcolor: "urlblue"
linestretch: 1.06
header-includes:
  - |
    \usepackage{microtype}
    \usepackage{booktabs}
    \usepackage{longtable}
    \usepackage{array}
    \usepackage{float}
    \usepackage{fvextra}
    \usepackage{needspace}
    \usepackage{fancyhdr}
    \usepackage{xcolor}
    \definecolor{linkblue}{HTML}{243B53}
    \definecolor{urlblue}{HTML}{1F5D8F}
    \usepackage{enumitem}
    \usepackage{caption}
    \captionsetup{font=small,labelfont=bf}
    \DefineVerbatimEnvironment{Highlighting}{Verbatim}{breaklines,breakanywhere,commandchars=\\\{\}}
    \DefineVerbatimEnvironment{verbatim}{Verbatim}{breaklines,breakanywhere}
    \pagestyle{fancy}
    \fancyhf{}
    \fancyhead[L]{Mirage Lambda Service}
    \fancyhead[R]{Implementation Guide}
    \fancyfoot[C]{\thepage}
    \setlength{\headheight}{14pt}
    \setlist[itemize]{topsep=3pt,itemsep=2pt,parsep=1pt}
    \setlist[enumerate]{topsep=3pt,itemsep=2pt,parsep=1pt}
---

> **Document status.** This is a design and implementation guide, not a claim that the complete system already exists. Project-version statements and upstream API references were checked on 2026-08-25. Exact package constraints must be locked and compiled during Phase 0 because MirageOS, Solo5, OCaml, and their libraries evolve independently.
>
> **Audience.** The primary reader is a new engineering intern who knows basic systems programming, HTTP, and one typed programming language, but may be new to OCaml, MirageOS, unikernels, capability security, embedded JavaScript engines, and function-as-a-service systems.
>
> **Security scope.** A QuickJS `JSRuntime` is a useful language-level containment and accounting unit, but it is not a native memory-protection boundary. Hostile tenants require separate Solo5 HVT worker guests, or an equivalently strong boundary. This document makes that distinction explicit throughout.

# Abstract

This document specifies a complete JavaScript lambda service whose service plane and execution workers are built as MirageOS unikernels. Users deploy small ECMAScript modules, assign explicit capabilities and resource limits, and invoke named function revisions through an authenticated HTTPS API. MirageOS supplies the network stack, TLS, persistence interfaces, clocks, entropy, and application-specific composition. QuickJS supplies the JavaScript language runtime. Solo5 HVT supplies a narrow hardware-virtualized guest boundary. A minimal host-side launcher, preferably Albatross or an adapter compatible with it, creates, destroys, and supervises worker unikernels because Solo5 intentionally does not provide orchestration.

The system is deliberately not Node.js in a small VM. User code receives no ambient filesystem, process, socket, environment-variable, dynamic-library, or package-manager authority. Instead, a function receives a typed object-capability environment such as read-only access to one key-value namespace, append access to one log, HTTPS access to a constrained host allowlist, cryptographic randomness, or permission to invoke another function. Every host operation is authorized, metered, traced, cancelable, and represented as an asynchronous Promise mediated by OCaml.

The recommended implementation proceeds in layers. First, construct and test the semantics as a normal Unix OCaml program. Second, port only the QuickJS engine core to the freestanding C environment used by MirageOS/Solo5, rather than porting the QuickJS command-line interpreter or `quickjs-libc.c`. Third, build a single-appliance Mirage image for trusted and development workloads. Fourth, split the system into a control-plane unikernel and a worker unikernel fleet for hostile multi-tenant execution. The hard isolation unit is then a worker VM, normally one tenant per VM and one active compute-bound invocation per worker. The implementation plan includes repository structure, module signatures, external and internal APIs, storage schema, scheduler semantics, failure recovery, threat modeling, build and deployment commands, tests, stage gates, and an intern-oriented work breakdown.

# Executive judgment

## What is being built

The proposed system is a small function cloud with the following contract:

```text
function revision
    = immutable JavaScript module bundle
    + manifest
    + capability policy
    + resource budget

invocation
    = revision digest
    + input bytes
    + caller identity
    + absolute deadline
    + idempotency policy
```

A successful synchronous invocation returns a bounded response. An asynchronous invocation records a durable work item and exposes a status/result handle. The service owns deployment, revision publication, admission, scheduling, isolation, execution, host operations, metering, logging, and recovery.

The architecture has three deployment modes:

| Mode | Shape | Suitable for | Security meaning |
|---|---|---|---|
| Unix development | Normal OCaml process with embedded QuickJS | Debugging, tests, sanitizers, rapid iteration | No unikernel or tenant isolation |
| Single appliance | One Mirage unikernel containing API, state, scheduler, and multiple fresh `JSRuntime`s | Trusted code, single-tenant edge appliance, functional prototype | QuickJS heaps are separate; a native engine bug compromises the whole guest |
| Fleet mode | Control-plane unikernel plus HVT worker unikernels and a minimal host launcher | Hostile or mutually distrusting tenants | Hardware virtualization separates worker guests; the host launcher is privileged but narrow |

The production recommendation is the third mode. The second mode remains valuable because it exercises almost all service semantics without making VM orchestration the first dependency.

## Core architectural decision

The system separates **control authority** from **guest computation**:

```text
Control plane owns:
    identity, policy, deployment metadata, artifact integrity,
    admission, queueing, worker assignment, durable status,
    public TLS, internal credentials, and audit records.

Worker owns temporarily:
    one immutable function revision, one invocation input,
    one bounded QuickJS runtime, and capability tokens that expire
    with the invocation or worker lease.
```

The worker does not receive the service database, tenant signing keys, unrestricted network access, or a general administrative interface. A compromised worker should be disposable.

![System context](mirage_lambda_guide_assets/01_system_context.png)

*Figure 1. The complete service includes unikernel control and worker images, plus a minimal host-side orchestration boundary.*

## Non-negotiable constraints

The first production version should enforce all of the following:

- No Node.js compatibility promise.
- No `require`, `fs`, `child_process`, native add-ons, `dlopen`, shell, or package manager.
- ECMAScript modules are bundled outside the unikernel and uploaded as source.
- User-supplied QuickJS bytecode is rejected. QuickJS documents its serialized bytecode as version-specific and not security-checked before execution. [QJS-DOC]
- Every invocation uses a fresh `JSRuntime` unless a later design explicitly proves safe reuse.
- `JS_SetMemoryLimit`, a bounded custom allocator, `JS_SetMaxStackSize`, `JS_SetInterruptHandler`, `JS_SetCanBlock(rt, false)`, a module loader, and a Promise rejection tracker are installed before user code runs. [QJS-H]
- Host operations are represented as OCaml-owned requests, not arbitrary callbacks into OCaml from a foreign thread.
- Unknown manifest fields are rejected in schema version 1.
- All sizes, counts, deadlines, redirects, queue lengths, logs, and error messages are bounded.
- Tenant isolation is not claimed from `JSContext` or `JSRuntime`; HVT is the production tenant boundary.
- A Solo5 worker is treated as one effective execution lane. Solo5's TLS support permits OCaml 5/pthread requirements but explicitly does not make a unikernel multicore; the current API allows at most one thread. [SOLO5-CHANGES]
- Exactly-once execution is not claimed. Synchronous and asynchronous retry semantics are specified explicitly.
- The control plane never trusts function-provided log fields, result metadata, module paths, DNS answers, or redirect targets without validation.

## Recommended technology baseline

The status-date baseline is:

| Component | Baseline | Reason |
|---|---:|---|
| OCaml | 5.5.0 | Current release on the status date; use a locked switch and verify Mirage package compatibility. [OCAML-550] |
| MirageOS | 4.11.2 | Current Mirage release on the status date. [MIRAGE-CHANGES] |
| Solo5 | 0.12.1 | Current Solo5 release on the status date. [SOLO5-CHANGES] |
| QuickJS | 2026-06-04 | Current upstream release; small embedded engine with an explicit C API. [QJS-HOME] |
| Execution target | Solo5 HVT on Linux/KVM | Production Solo5 target with hardware virtualization. [SOLO5-BUILD] |
| Orchestration | Albatross adapter initially | Existing Solo5-oriented lifecycle, TAP, memory, CPU, TLS-control, and restart machinery. [ALBATROSS] |
| Async model | Lwt inside Mirage | Current Mirage networking, TLS, KV, and common HTTP stacks are Lwt-oriented. |
| Persistent service state | `Mirage_kv.RW`, initially Chamelon over block | Native Mirage interface with a Unix development implementation and a freestanding block-backed path. [MIRAGE-API] [MIRAGE-KV] |

These are starting constraints, not permanent architecture. Version pinning and a build spike precede feature work.

# How to use this guide

A new contributor should read the document in this order:

1. **Part I** explains the abstractions and the reasons behind them.
2. **Part II** specifies the service as a distributed system.
3. **Part III** maps that design to OCaml, MirageOS, Solo5, QuickJS, C stubs, files, APIs, and build commands.
4. **Part IV** defines implementation phases and acceptance gates.
5. The appendices provide schemas, pseudocode, file references, terminology, and upstream source links.

A design statement uses one of four labels:

- **Required**: needed for the first secure end-to-end system.
- **Recommended**: the default choice unless a benchmark or integration spike disproves it.
- **Optional**: useful after the basic system works.
- **Research extension**: deliberately beyond the first production objective.

# Part I - Theory and operating-system model

# 1. From a Unix function runtime to a lambda machine

A conventional function platform is usually layered on a general-purpose operating system:

```text
user function
  -> language runtime
  -> process/container abstraction
  -> libc and syscalls
  -> general-purpose kernel
  -> container or VM orchestration
```

This stack is successful because it reuses mature tools and compatibility. It also means that the application is expressed through generic abstractions: processes, file descriptors, pathnames, sockets, environment variables, user IDs, signals, and virtual memory. The kernel cannot distinguish a database durability barrier from an ordinary file write, a tenant-scoped network request from an unrestricted socket, or a function deadline from a generic timer.

A Mirage lambda service can instead make the execution abstraction explicit:

```text
invocation
  -> capability environment
  -> resource budget
  -> JavaScript computation
  -> OCaml policy handlers
  -> selected Mirage libraries
  -> Solo5 devices
```

The key move is not merely removing Linux. It is replacing ambient, generic OS authority with an application-specific contract.

## 1.1 The invocation as the process replacement

The traditional process bundles an address space, threads, credentials, file descriptors, signal state, and an executable. The proposed service defines a smaller semantic unit:

```ocaml
module Invocation : sig
  type id
  type t = {
    id : id;
    tenant : Tenant_id.t;
    function_name : Function_name.t;
    revision : Digest.t;
    input : Bounded_bytes.t;
    capabilities : Capability_set.t;
    budget : Budget.t;
    deadline : Mtime.t;
    trace : Trace_context.t;
  }
end
```

An invocation does not inherit a working directory, environment, host network namespace, or arbitrary handles. Its authority is the capability set in the record. Its lifetime is a state machine owned by the scheduler.

## 1.2 The capability as the file descriptor replacement

A Unix file descriptor is an integer that indirectly names a kernel object. The API is intentionally generic. In this service, JavaScript receives domain-specific objects:

```javascript
export default async function handler(event, env, context) {
  const order = await env.kv.orders.get(event.orderId);
  await env.logs.audit.append({
    kind: "order-read",
    orderId: event.orderId
  });
  return { ok: true, order };
}
```

The corresponding manifest grants exactly those operations:

```json
{
  "capabilities": {
    "kv": [
      { "binding": "orders", "store": "orders", "access": "read" }
    ],
    "logs": [
      { "binding": "audit", "stream": "tenant-audit", "access": "append" }
    ]
  }
}
```

There is no global `open()` or `connect()`. The JavaScript object exists only if the deployment policy grants it. This is object-capability security applied at the function boundary.

## 1.3 The budget as the cgroup replacement

A cgroup constrains an external process after the process abstraction has already been chosen. Here, the budget is part of the invocation itself:

```ocaml
module Budget : sig
  type t = {
    js_heap_bytes : int;
    native_overhead_bytes : int;
    stack_bytes : int;
    cpu_ns : int64;
    wall_deadline : Mtime.t;
    input_bytes : int;
    output_bytes : int;
    log_bytes : int;
    host_calls : int;
    kv_reads : int;
    kv_writes : int;
    outbound_bytes : int;
    redirects : int;
    child_invocations : int;
  }
end
```

Each resource has an accounting owner and an exhaustion behavior. A budget is not merely documentation. The runtime must decrement counters or reject allocations at every relevant boundary.

## 1.4 The worker VM as the protection domain

QuickJS runtimes have separate heaps, but QuickJS is native C linked into the same address space as the OCaml runtime and the Mirage libraries. A memory-safety defect in the engine or C stubs can escape language-level limits. For hostile code, the protection domain is therefore the Solo5 HVT guest:

```text
Tenant A JS
  -> QuickJS C
  -> Worker A Mirage guest
  ---- HVT/KVM boundary ----
Tenant B worker, control plane, host
```

Solo5 describes itself as a thin, legacy-free sandbox interface and identifies fast boot as suitable for function-as-a-service use cases. [SOLO5-ARCH] That property is useful, but the security argument still depends on the configured HVT/KVM boundary, host hardening, minimal device assignment, and the absence of shared mutable guest state.

![Architecture modes](mirage_lambda_guide_assets/02_architecture_modes.png)

*Figure 2. The single-appliance mode is an implementation milestone; fleet mode is the hostile multi-tenant architecture.*

# 2. MirageOS as the construction language

MirageOS is a library operating system and a metaprogramming compiler. Its upstream API describes three central ideas: OS functions are libraries, typed module signatures ensure composition, and `config.ml` describes how the build tool generates a specialized executable for a target. Mirage explicitly does not attempt to emulate a full POSIX environment. [MIRAGE-API]

For this project, that means the service is assembled from typed implementations rather than installed into a preexisting guest distribution:

```text
control-plane unikernel =
    application modules
  + HTTP/TLS libraries
  + TCP/IP stack
  + KV implementation
  + entropy, time, logging
  + OCaml runtime
  + Solo5 bindings
```

The build graph is also a partial authority graph. A worker image with no block device and no public network listener cannot accidentally acquire those resources through an unmodeled pathname or process API.

## 2.1 `config.ml` and `unikernel.ml`

A Mirage project normally separates composition from behavior:

- `config.ml` declares devices, package dependencies, functor types, build-time options, and registration.
- `unikernel.ml` implements the application functor and its `start` function.

The current network skeleton illustrates the pattern:

```ocaml
(* config.ml *)
open Mirage

let main = main "Unikernel.Main" (stackv4v6 @-> job)
let stack = generic_stackv4v6 default_network
let () = register "network" [ main $ stack ]
```

```ocaml
(* unikernel.ml *)
module Main (S : Tcpip.Stack.V4V6) = struct
  let start stack =
    (* install listeners and then enter the stack loop *)
    S.listen stack
end
```

The exact sample is maintained in `mirage-skeleton/device-usage/network/`. [MIRAGE-NET-CONFIG] [MIRAGE-NET-UNIKERNEL]

## 2.2 Development and deployment implementations

The same application-facing module type should have multiple implementations:

```text
ARTIFACT_STORE
  Unix development: direct files or in-memory KV
  HVT appliance: Chamelon over a Solo5 block device
  Fleet worker: read-only remote artifact cache

LAUNCHER
  Unit tests: deterministic fake
  Local Unix: child process adapter
  HVT host: Albatross adapter
```

This is essential for intern productivity. Most logic should be debuggable as a Unix process with sanitizers, coverage, ordinary profilers, and deterministic fake dependencies before it is cross-compiled into a freestanding target.

## 2.3 What Mirage does not solve

MirageOS does not automatically provide:

- tenant identity and authorization;
- a function registry;
- package validation;
- a scheduler;
- quotas and billing-style meters;
- worker lifecycle orchestration;
- JavaScript sandbox semantics;
- retries and idempotency;
- a durable service metadata protocol;
- operational dashboards;
- a supply-chain process.

These are the bulk of the lambda service. Embedding QuickJS is only one subsystem.

# 3. Function semantics

A function platform needs a precise programming model before it needs a fast runtime.

## 3.1 Source contract

Version 1 supports one ECMAScript-module entry point:

```javascript
export default async function handler(event, env, context) {
  // Return a JSON-compatible value or a Uint8Array response wrapper.
}
```

The arguments are:

- `event`: the decoded invocation input. JSON is the first supported format.
- `env`: an object containing only granted capabilities.
- `context`: immutable invocation metadata and safe utility methods.

A minimal `context` is:

```javascript
{
  requestId: "01J...",
  tenantId: "tenant-a",
  functionName: "order-lookup",
  revision: "sha256:...",
  deadlineUnixMs: 1787697600123,
  remainingTimeMs(): 87
}
```

`remainingTimeMs()` is implemented by the host. It is advisory; the interrupt handler remains authoritative.

## 3.2 Purity and external effects

JavaScript computation is not required to be pure, but all external effects must pass through capabilities. This gives the service a semantic boundary:

```text
JavaScript-visible computation
    pure language operations
    + host calls through env

not visible
    raw sockets
    filesystem paths
    process creation
    environment variables
    wall clock unless granted
    host secrets unless granted
```

This boundary supports policy checks, metering, tracing, deterministic testing, and potential record/replay.

## 3.3 Invocation completion

A function completes when its returned value or Promise is fulfilled. It fails when:

- the entry module does not load;
- the default export is missing or not callable;
- JavaScript throws or rejects;
- serialization fails;
- output exceeds its limit;
- the CPU, wall, memory, host-call, log, I/O, or child-invocation budget is exhausted;
- cancellation arrives;
- the worker crashes or loses its lease;
- a capability operation returns an unrecoverable error.

The external API normalizes these into stable error classes. Raw engine messages may be retained in privileged diagnostics but must be length-limited and sanitized before returning to the caller.

## 3.4 State across invocations

Version 1 promises no mutable JavaScript global state across invocations. A fresh runtime prevents accidental leakage and makes teardown the primary cleanup mechanism.

Persistent state must live behind a capability such as KV, object storage, or a future database service. This makes persistence explicit and avoids relying on warm-worker behavior.

# 4. Isolation, authority, and the trusted computing base

The system contains nested boundaries. They must not be conflated.

![Trust boundaries](mirage_lambda_guide_assets/03_trust_boundaries.png)

*Figure 3. A language runtime constrains normal JavaScript behavior; HVT contains native-engine compromise to the worker guest.*

## 4.1 Boundary table

| Boundary | Protects against | Does not protect against |
|---|---|---|
| JavaScript lexical/module scope | Accidental name collisions | Malicious code, engine defects |
| `JSContext` | Separate global objects/realms | Shared-runtime object access, engine compromise |
| `JSRuntime` | Independent JS heap and useful accounting | Native C memory corruption, OCaml/C-stub bugs |
| Capability object graph | Ordinary JS attempts to use absent authority | Bugs in host callbacks or policy matching |
| Worker Mirage guest | Other worker guests and control plane, subject to HVT/KVM security | Compromise of the worker itself |
| HVT/KVM + host controls | Guest escape and host resource mediation | Host compromise, hypervisor vulnerability, launcher misconfiguration |
| Control-plane authorization | Cross-tenant API access | Stolen credentials, implementation bugs, privileged operator abuse |

## 4.2 Recommended tenant placement

Use these defaults:

- Trusted first-party functions: multiple fresh runtimes in one appliance are acceptable for development and low-risk edge deployment.
- Mutually distrusting tenants: one HVT worker VM per tenant, with at most one active compute-bound invocation per worker.
- Extremely sensitive or one-shot work: one HVT worker per invocation.
- Multiple functions owned by one tenant: may share a tenant worker after the worker model is stable, but function capability sets remain independent.

The one-active-invocation rule is not because QuickJS cannot create multiple runtimes. It is because Solo5 workers are effectively single-lane today, and QuickJS's interrupt mechanism is an abort mechanism rather than a resumable preemption primitive. A compute-bound function cannot be safely paused and resumed at arbitrary bytecode boundaries using the public API.

## 4.3 Minimum worker authority

A worker should receive only:

- one private network interface or one tightly scoped service path;
- no persistent block device in the initial fleet design;
- an ephemeral memory allocation chosen by policy;
- a control-plane client certificate or bootstrap token with a short lease;
- access to fetch immutable bundles by digest;
- outbound access only through a broker or a validated egress capability;
- console output treated as untrusted telemetry.

The control plane should not share writable storage with workers. Shared read-only artifact images are possible later, but an authenticated content-addressed fetch is simpler to reason about initially.

# 5. Resource semantics and scheduling theory

A lambda system is a resource allocator. Correctness includes preventing one tenant from monopolizing CPU, memory, queue space, host operations, or downstream services.

## 5.1 Admission versus execution enforcement

Use two enforcement layers:

1. **Admission control** rejects work that cannot be scheduled under current quotas or that has an impossible deadline.
2. **Execution enforcement** terminates or fails work that exceeds its runtime budget.

Admission cannot replace execution enforcement because a function may behave adversarially. Execution enforcement cannot replace admission because accepting unbounded work can exhaust queue memory before any function runs.

## 5.2 Queue hierarchy

Recommended queue hierarchy:

```text
global ready set
  -> tenant weighted-fair queue
       -> function/revision subqueue
            -> FIFO invocations
```

Each tenant has:

- a token bucket for request rate;
- a maximum queued count and queued bytes;
- a maximum number of assigned workers;
- a maximum active invocation count;
- a weighted scheduling share;
- optional function-specific overrides.

A simple initial scheduler can use deficit round robin:

```text
for each scheduling round:
    for tenant in rotating_order:
        tenant.deficit += tenant.quantum
        while tenant has ready work and cost(head) <= tenant.deficit:
            if a compatible worker is available:
                assign head
                tenant.deficit -= cost(head)
            else:
                break
```

The cost estimate starts as 1 per invocation. Later it may incorporate declared memory class, recent CPU history, cold-start cost, or downstream resource pressure. Avoid complex prediction before instrumentation exists.

## 5.3 Deadline model

Each invocation has an absolute service deadline and an execution budget:

```text
service deadline = time by which the gateway stops waiting
queue budget     = maximum time before assignment
worker deadline  = deadline carried in the signed invocation envelope
CPU budget       = maximum time spent executing QuickJS bytecode/native engine work
I/O budget       = separate count/byte/time constraints on host calls
```

The gateway remains authoritative because a worker or host can be suspended. Solo5 clocks have target-specific behavior, so a late result is discarded if the control plane has already expired the invocation.

## 5.4 Memory model

`JS_SetMemoryLimit` is necessary but insufficient. It constrains the QuickJS allocator path, not all memory associated with an invocation. The service must charge at least:

- bundle/module source retained in OCaml;
- input and output buffers;
- QuickJS heap allocations;
- C request registry entries;
- pending Promise resolution values;
- OCaml representations of decoded JSON;
- outbound request and response buffers;
- log buffers;
- trace attributes;
- worker-level caches.

The recommended allocator uses `JS_NewRuntime2` with size-aware functions and an invocation-owned counter. The QuickJS public header exposes both the custom allocator structure and runtime memory limit APIs. [QJS-H]

## 5.5 Backpressure

Every queue has a bounded capacity and a defined overload response:

| Queue | Bound | Overload behavior |
|---|---:|---|
| Public HTTP request body | bytes per request | `413 Payload Too Large` |
| Deployment validation | concurrent jobs | `429` or `503` with retry hint |
| Tenant invocation queue | count and bytes | `429 Too Many Requests` |
| Global invocation queue | count and bytes | `503 Service Unavailable` |
| Worker host-call queue | calls and bytes per invocation | fail invocation with resource error |
| Logs | bytes per invocation | truncate with explicit marker |
| Result store | retention and bytes | expire oldest according to policy |

Backpressure is part of the API contract, not an implementation detail.

# 6. Consistency, delivery, and failure semantics

## 6.1 Function deployment consistency

A function revision is immutable and identified by a digest. An alias such as `prod` is a small mutable pointer:

```text
function order-lookup
  revision sha256:A...  immutable
  revision sha256:B...  immutable
  alias prod -> sha256:B...
```

Invocation resolution captures the revision digest before queueing. An alias update does not change already admitted invocations.

## 6.2 Synchronous invocation

Recommended version-1 semantics:

- The control plane creates one invocation record and one assignment attempt.
- It may retry assignment if a worker dies before acknowledging receipt.
- After a worker acknowledges execution start, automatic replay is disabled unless the function manifest explicitly allows retry and the request has an idempotency key.
- The caller receives a timeout when the service deadline expires; a late worker result is discarded or recorded only for diagnostics.

This is not exactly once. It is an explicit bounded-attempt protocol.

## 6.3 Asynchronous invocation

Asynchronous delivery is normally at least once:

- A durable work item is acknowledged after it is written.
- A worker lease expires if no completion arrives.
- The control plane may requeue according to retry policy.
- The function author must use an idempotency key for side effects.
- A dead-letter state records permanent exhaustion.

The platform should expose attempt number and stable invocation ID to the function context.

## 6.4 Crash recovery

Persistent state uses an append/replay or journaled metadata protocol. The simplest design is a single metadata-writer actor that serializes state-changing operations. Content-addressed bundles are written before registry pointers refer to them.

A deployment transaction is:

```text
1. Validate bundle and manifest in memory.
2. Compute digest D.
3. Write /objects/D/bundle.mlb if absent.
4. Write revision metadata to a temporary key.
5. Rename temporary key to the final revision key.
6. Append journal record declaring revision available.
7. Optionally update an alias using temp + rename.
8. Return the immutable revision ID.
```

`Mirage_kv.RW` exposes `set`, `remove`, `rename`, and related operations; its interface notes that `set` and `remove` flush the underlying storage each time, which is useful for durability reasoning but may require batching and measurement. [MIRAGE-KV]


# Part II - Complete system design

# 7. Chosen architecture

The chosen production design is a small distributed system with two unikernel images and one narrow host-side lifecycle component.

## 7.1 Control-plane unikernel

The control-plane image is responsible for:

- public TLS termination and HTTP routing;
- authentication and tenant identification;
- deployment validation and immutable artifact publication;
- function/revision/alias registry;
- invocation admission and queueing;
- quotas and weighted-fair scheduling;
- worker inventory and lease state;
- capability-policy compilation;
- internal worker authentication;
- persistent invocation status;
- structured audit records, metrics, and traces;
- result normalization and public API responses.

The control plane should not execute untrusted JavaScript in production fleet mode. That keeps its native trusted computing base smaller and ensures a QuickJS exploit does not expose service metadata or tenant credentials.

## 7.2 Worker unikernel

The worker image is responsible for:

- authenticating the private control-plane connection;
- accepting a bounded invocation envelope;
- fetching or receiving an immutable module bundle by digest;
- validating the digest and cached artifact metadata;
- constructing a fresh QuickJS runtime and context;
- installing the restricted language environment;
- enforcing per-invocation limits;
- translating JavaScript host calls into OCaml capability requests;
- returning a bounded result and telemetry;
- destroying all invocation-owned state;
- draining and exiting when its lease is revoked.

A worker in the initial fleet implementation handles one active invocation at a time. It may cache immutable bundles and parsed manifest data between invocations, but it must not retain a JavaScript heap across tenants or capability policies.

## 7.3 Host launcher and Solo5 tender

Solo5 provides execution targets and tenders, not a high-level orchestration layer; its own build documentation compares its position to `runc` and points to Albatross as a higher-level deployment system. [SOLO5-BUILD] The host layer therefore remains responsible for:

- creating and attaching TAP interfaces;
- assigning memory and CPU placement;
- starting `solo5-hvt` with the correct manifest devices;
- collecting exit status and console output;
- destroying or replacing workers;
- persisting desired worker configuration when appropriate;
- enforcing host-side limits and ownership of `/dev/kvm` and `/dev/net/tun`;
- exposing a mutually authenticated control API to the control-plane service.

Albatross already manages TAP devices, block devices, memory, CPU, remote mTLS management, console output, monitoring, and restart behavior using multiple least-privilege processes. [ALBATROSS] The first implementation should adapt to it rather than invent a new privileged daemon.

## 7.4 Why the launcher cannot simply be inside the unikernel

A guest cannot normally create peer KVM guests without receiving broad virtualization and host-network authority. Giving that authority to the public control-plane guest would enlarge the trusted boundary and make orchestration dependent on nested virtualization or a custom host hypercall protocol. A small host-side lifecycle agent is the cleaner boundary.

The product can accurately be described as a unikernel lambda service because its application service plane and execution workers are unikernels. It should not claim that every privileged lifecycle operation occurs inside a unikernel.

![Complete invocation sequence](mirage_lambda_guide_assets/04_invocation_sequence.png){height=7.75in}

*Figure 4. A public request passes through identity, admission, assignment, a fresh engine instance, capability-mediated host calls, and bounded result publication.*

# 8. Component inventory and responsibility map

The following table is the implementation-level map. Each row should eventually correspond to an OCaml module or small module family with an `.mli` contract.

| Component | Runs in | Owns | Must not own |
|---|---|---|---|
| `Ingress` | control | TLS/HTTP connection handling, body limits | function policy |
| `Auth` | control | credential verification, tenant context | worker lifecycle |
| `Admin_api` | control | deploy/get/delete/alias routes | raw KV writes |
| `Invoke_api` | control | sync/async invocation routes | scheduling policy internals |
| `Bundle` | common/control/worker | deterministic package parsing and digest validation | filesystem access |
| `Manifest` | common | strict schema and semantic validation | deployment state |
| `Artifact_store` | control | immutable bundle objects | aliases and mutable function metadata |
| `Registry` | control | revisions and aliases | arbitrary persistence calls |
| `Metadata_writer` | control | serialized durable mutations and journal | HTTP parsing |
| `Admission` | control | quotas, body/queue/deadline checks | worker process creation |
| `Scheduler` | control | tenant fairness and assignment decisions | public authentication |
| `Worker_pool` | control | worker states, leases, health | QuickJS internals |
| `Launcher` | host adapter/control client | create/stop/inspect HVT workers | function source semantics |
| `Worker_server` | worker | private invocation protocol | public internet listener |
| `Invocation` | worker | one execution state machine | persistent service registry |
| `Qjs_engine` | worker/Unix tests | C runtime lifecycle and job pumping | network or KV policy |
| `Runtime_host` | worker | JS host-call request registry | tenant authorization source of truth |
| `Capability_broker` | worker/control | token validation, operation routing, metering | ambient authority |
| `Egress` | worker or broker | DNS/TLS/HTTP policy enforcement | unrestricted TCP |
| `Telemetry` | both | structured events and metrics | unbounded function strings |
| `Recovery` | control | journal replay and invariant checks | new feature policy |

A practical review rule is: if one module starts accumulating two unrelated authority classes from this table, split it before adding more features.

# 9. External API design

Version 1 uses HTTPS with JSON for management and invocation. Binary bodies can be added later, but a small JSON surface is easier to test and document.

## 9.1 Authentication model

The API receives an authenticated principal and derives a tenant context:

```ocaml
type principal = {
  subject : string;
  tenant : Tenant_id.t;
  roles : Role.Set.t;
  credential_id : string;
}
```

Authentication mechanisms are deployment-specific. Initial choices include mTLS client certificates for administrative clients and signed bearer tokens for ordinary invokers. Authorization is performed after route parsing and before any tenant-controlled object lookup that could reveal existence.

Every request receives:

- a service request ID;
- an authenticated tenant ID;
- a maximum accepted body size;
- a deadline;
- an audit classification;
- an idempotency key where the operation permits retries.

## 9.2 Management routes

Recommended routes:

```text
POST   /v1/tenants/{tenant}/functions/{name}/versions
GET    /v1/tenants/{tenant}/functions/{name}/versions/{revision}
DELETE /v1/tenants/{tenant}/functions/{name}/versions/{revision}

PUT    /v1/tenants/{tenant}/functions/{name}/aliases/{alias}
GET    /v1/tenants/{tenant}/functions/{name}/aliases/{alias}
DELETE /v1/tenants/{tenant}/functions/{name}/aliases/{alias}

GET    /v1/tenants/{tenant}/functions/{name}
GET    /v1/tenants/{tenant}/functions
```

A deployment request contains a canonical manifest and a deterministic source bundle. On success:

```json
{
  "function": "order-lookup",
  "revision": "sha256:71be...",
  "createdAt": "2026-08-25T20:00:00Z",
  "runtime": "quickjs-2026-06-04",
  "bundleBytes": 18324,
  "warnings": []
}
```

The revision resource is immutable. Deletion removes registry reachability according to retention policy; content-addressed garbage collection is a separate process.

## 9.3 Invocation routes

```text
POST /v1/invoke/{tenant}/{function}/{qualifier}
POST /v1/invoke-async/{tenant}/{function}/{qualifier}
GET  /v1/invocations/{invocationId}
POST /v1/invocations/{invocationId}/cancel
```

`qualifier` is a revision digest or alias. The control plane resolves it once and records the digest.

Example synchronous request:

```http
POST /v1/invoke/tenant-a/order-lookup/prod HTTP/1.1
Authorization: Bearer ...
Content-Type: application/json
Idempotency-Key: 7fb3d14a-...
X-Invocation-Timeout-Ms: 250

{"orderId":"A-1842"}
```

Example success:

```json
{
  "invocationId": "01J6A6...",
  "revision": "sha256:71be...",
  "attempt": 1,
  "durationMs": 4.82,
  "result": {
    "ok": true,
    "order": {"id":"A-1842","state":"paid"}
  }
}
```

Example normalized function failure:

```json
{
  "invocationId": "01J6A6...",
  "error": {
    "code": "FUNCTION_EXCEPTION",
    "message": "function rejected",
    "details": {
      "name": "Error",
      "safeMessage": "order was not found"
    }
  }
}
```

Raw stack traces are returned only under an explicitly authorized development mode. Production traces remain in privileged telemetry and are scrubbed of secrets and oversized values.

## 9.4 Operational routes

```text
GET  /healthz       process/unikernel liveness
GET  /readyz        ability to accept new work
GET  /metrics       metrics in the selected exposition format
POST /v1/admin/drain
GET  /v1/admin/state-summary
```

`healthz` must not claim readiness. A control plane can be alive while its journal replay is incomplete or its worker pool has no capacity.

## 9.5 HTTP error classes

| HTTP | Service code | Meaning |
|---:|---|---|
| 400 | `INVALID_REQUEST` | malformed JSON, route value, or header |
| 401 | `UNAUTHENTICATED` | no valid identity |
| 403 | `FORBIDDEN` | identity lacks tenant/operation authority |
| 404 | `NOT_FOUND` | resource absent within authorized tenant scope |
| 409 | `CONFLICT` | immutable revision conflict, alias precondition, idempotency mismatch |
| 413 | `PAYLOAD_TOO_LARGE` | body or bundle limit exceeded |
| 422 | `INVALID_MANIFEST` | syntactically valid but semantically invalid deployment |
| 429 | `RATE_OR_QUOTA_EXCEEDED` | tenant rate, concurrency, or queue quota |
| 500 | `INTERNAL` | invariant or unclassified service failure |
| 502 | `WORKER_FAILURE` | worker crashed or returned invalid protocol data |
| 503 | `NO_CAPACITY` | global overload or launcher unavailable |
| 504 | `INVOCATION_TIMEOUT` | service deadline elapsed |

Every error body contains a request ID and a stable service code.

# 10. Function package and manifest

## 10.1 Why bundling happens outside the unikernel

General package managers and NPM installation require a large filesystem, decompression, scripts, network access, native build hooks, and complex trust policy. None belongs in the worker. The developer CLI should resolve dependencies and produce a deterministic ECMAScript-module bundle outside the unikernel.

The service accepts JavaScript source, not a Node package tree. The supported language environment is documented separately from Node or browser APIs.

## 10.2 Manifest example

```json
{
  "schemaVersion": 1,
  "name": "thumbnail",
  "entrypoint": "index.js",
  "export": "default",
  "runtime": "quickjs-2026-06-04",
  "input": {"format": "json", "maxBytes": 1048576},
  "output": {"format": "json", "maxBytes": 1048576},
  "limits": {
    "jsHeapBytes": 16777216,
    "nativeOverheadBytes": 4194304,
    "stackBytes": 262144,
    "timeoutMs": 100,
    "cpuMs": 50,
    "maxHostCalls": 32,
    "maxPendingPromises": 16,
    "maxLogBytes": 32768,
    "maxOutboundBytes": 262144,
    "maxRedirects": 2,
    "maxChildInvocations": 4
  },
  "capabilities": {
    "kv": [
      {
        "binding": "images",
        "store": "images",
        "access": "read-write",
        "prefix": "tenant-a/"
      }
    ],
    "http": [
      {
        "binding": "metadataApi",
        "schemes": ["https"],
        "hosts": ["api.example.com"],
        "ports": [443],
        "methods": ["GET"],
        "maxResponseBytes": 131072
      }
    ],
    "clock": "monotonic",
    "random": "cryptographic",
    "logs": true,
    "invoke": ["resize-helper@prod"]
  },
  "retry": {
    "mode": "never"
  }
}
```

## 10.3 Validation pipeline

Deployment validation is ordered from cheapest to most expensive:

```text
1. Enforce request byte limit before buffering.
2. Parse bundle container with integer-overflow checks.
3. Parse canonical manifest; reject duplicate and unknown fields.
4. Validate identifiers and normalized module paths.
5. Validate declared limits against tenant policy.
6. Compile capability declarations into an internal policy.
7. Verify every module digest and bundle footer digest.
8. Parse/compile modules in an isolated validation runtime.
9. Check entry point and default export contract where possible.
10. Store immutable bundle and revision metadata.
```

Compilation during deployment catches syntax and module-resolution errors, but the stored artifact remains source. The worker repeats digest validation and uses its own engine version.

## 10.4 Deterministic bundle format

Use a small versioned format rather than ZIP for the first implementation. ZIP introduces path and parser complexity that is unnecessary for a small module graph.

Conceptual layout:

```text
magic             4 bytes  "MLB1"
header_length      u32 big-endian
manifest_length    u32 big-endian
module_count       u32 big-endian
header_json        canonical UTF-8
manifest_json      canonical UTF-8
for each module, sorted by normalized path:
    path_length    u16
    path_bytes     UTF-8
    content_length u32
    sha256         32 bytes
    content        exact source bytes
footer_sha256      32 bytes over all preceding bytes
```

Parser requirements:

- reject lengths that exceed the containing buffer;
- reject multiplication/addition overflow;
- reject NUL, empty, absolute, backslash, `.` and `..` path segments;
- normalize UTF-8 policy explicitly; ASCII module paths are a safe version-1 choice;
- reject duplicate normalized paths;
- cap module count, per-module size, and total source size;
- require modules sorted by path so the encoding is canonical;
- compare all digests in constant time where practical;
- retain no unvalidated pointer into the request buffer.

## 10.5 Module resolution

Version 1 supports:

- relative imports beginning `./` or `../`, normalized within the bundle root;
- optional named virtual modules beginning `cap:` for host-provided APIs;
- no native `.so` modules;
- no HTTP imports;
- no filesystem lookup;
- no dynamic import unless explicitly added after the static loader is secure.

Examples:

```javascript
import { normalize } from "./lib/normalize.js";
import { version } from "cap:runtime";
```

The QuickJS module loader reads only from the already validated in-memory bundle map.

# 11. Persistent service state

## 11.1 Storage interface

The control plane depends on a small internal interface rather than on a concrete filesystem:

```ocaml
module type PERSISTENT_KV = sig
  type t
  type error

  val get : t -> Mirage_kv.Key.t -> (string, error) result Lwt.t
  val set : t -> Mirage_kv.Key.t -> string -> (unit, error) result Lwt.t
  val remove : t -> Mirage_kv.Key.t -> (unit, error) result Lwt.t
  val rename : t -> source:Mirage_kv.Key.t -> dest:Mirage_kv.Key.t ->
    (unit, error) result Lwt.t
  val list : t -> Mirage_kv.Key.t ->
    ((Mirage_kv.Key.t * [ `Value | `Dictionary ]) list, error) result Lwt.t
end
```

The concrete Mirage-facing adapter wraps `Mirage_kv.RW`. Mirage's current API includes in-memory RW storage, Unix direct RW storage, and Chamelon, an OCaml littlefs implementation over a block device; it also provides an optional AES-CCM encrypted block wrapper. [MIRAGE-API]

## 11.2 Key layout

Recommended namespace:

```text
/schema/version
/schema/last-migration

/objects/sha256/<hex>/bundle.mlb
/objects/sha256/<hex>/metadata.json

/tenants/<tenant>/functions/<name>/revisions/<revision>/manifest.json
/tenants/<tenant>/functions/<name>/revisions/<revision>/object-ref.json
/tenants/<tenant>/functions/<name>/aliases/<alias>.json

/tenants/<tenant>/quotas/current.json

/journal/<zero-padded-sequence>.json
/checkpoints/<sequence>.json

/invocations/<yyyy>/<mm>/<dd>/<invocation-id>.json
/idempotency/<tenant>/<hash>.json

/gc/candidates/<object-digest>.json
```

Identifiers are validated before they become key segments. Never concatenate a raw user string into a key without using a validated abstract type.

![Persistent storage model](mirage_lambda_guide_assets/07_storage_model.png)

*Figure 5. Immutable objects and a serialized metadata writer reduce the number of crash-consistency cases.*

## 11.3 Metadata writer actor

All mutations are submitted to one actor:

```ocaml
type mutation =
  | Publish_revision of publish_revision
  | Move_alias of move_alias
  | Delete_revision of delete_revision
  | Record_async_invocation of async_record
  | Complete_async_invocation of completion
  | Update_quota of quota_update

val submit : t -> mutation -> (mutation_result, Error.t) result Lwt.t
```

The actor provides:

- total ordering of metadata mutations;
- journal sequence numbers;
- invariant checking before and after writes;
- a single place to implement temp-key and rename patterns;
- deterministic testability;
- backpressure on state-changing requests.

Large immutable bundles are written through the artifact store before the metadata actor publishes their references.

## 11.4 Boot recovery

On boot:

```text
1. Read schema version.
2. Load latest valid checkpoint, if any.
3. List journal entries after the checkpoint sequence.
4. Parse and validate each record in order.
5. Rebuild in-memory registry, aliases, quotas, and pending async work.
6. Verify that every published revision references an existing object.
7. Move inconsistent resources to a quarantine report; do not silently guess.
8. Mark ready only after invariants and worker-pool initialization succeed.
```

The control plane should expose a read-only recovery summary before readiness so operators can diagnose a corrupted or incompatible store.

## 11.5 Garbage collection

Content-addressed objects are collected by a mark-and-sweep pass:

- Mark object digests referenced by live revisions, retained invocation records, and active deployments.
- Write a candidate timestamp for unmarked objects.
- Delete only after a safety interval and a second mark pass.
- Never delete an object while an assigned worker may still fetch it.

Object GC is background maintenance with a strict work budget. It must not block the metadata actor for long scans.

# 12. Invocation state machines

The control plane and worker must agree on explicit states rather than infer lifecycle from scattered booleans.

![Invocation state machine](mirage_lambda_guide_assets/06_invocation_state_machine.png)

*Figure 6. Terminal states are explicit; host waits return to running when a Promise is resolved.*

## 12.1 Control-plane invocation state

```ocaml
type control_state =
  | Received
  | Authenticated
  | Admitted
  | Queued of { queued_at : Mtime.t }
  | Assigned of { worker : Worker_id.t; lease : Lease_id.t }
  | Started of { attempt : int; started_at : Mtime.t }
  | Completed of completion
  | Failed of failure
  | Timed_out of timeout_stage
  | Cancelled of cancellation
```

Only the owner actor may transition the state. Each transition emits a trace event and, for durable asynchronous invocations, a journal record.

## 12.2 Worker invocation state

```ocaml
type worker_state =
  | Validating_envelope
  | Fetching_bundle
  | Creating_runtime
  | Loading_modules
  | Calling_handler
  | Running_jobs
  | Waiting_for_host of Host_request.Id.Set.t
  | Serializing_result
  | Cleaning_up
  | Done
```

Cleanup runs on every terminal path. It frees resolving functions, pending JavaScript values, contexts, runtimes, module buffers, request registry entries, and invocation credentials.

## 12.3 Worker lifecycle state

```ocaml
type lifecycle =
  | Starting
  | Registering
  | Ready
  | Busy of Invocation_id.t
  | Draining
  | Unhealthy of Error.t
  | Exiting
  | Dead of Exit_reason.t
```

The control plane assigns only `Ready` workers with a valid lease and compatible runtime version.

# 13. Scheduler and worker pool

## 13.1 Worker compatibility key

A worker advertises:

```ocaml
type worker_class = {
  runtime : Runtime_version.t;
  architecture : [ `X86_64 | `Aarch64 ];
  memory_class_mib : int;
  capability_profile : Capability_profile.t;
  image_digest : Digest.t;
}
```

The scheduler maps an invocation to a compatible class. The first system should minimize class count: one runtime version, a small number of memory classes, and a single generic capability profile whose actual authority is invocation-token constrained.

## 13.2 Warm pool policy

A warm worker is a booted guest with no active JavaScript runtime. It has completed private-channel authentication and can accept an invocation.

Initial policy:

```text
minimum_ready_per_class = small fixed number
maximum_workers_per_tenant = quota
scale-out trigger = ready workers below target and queued work exists
scale-in trigger = idle workers above target for a grace interval
```

Do not snapshot a live QuickJS heap in version 1. Warmth means the Mirage worker and network/TLS channel are initialized, not that tenant JavaScript state is retained.

## 13.3 Assignment lease

An assignment includes a unique lease ID and expiration:

```json
{
  "invocationId": "01J...",
  "leaseId": "01J...",
  "attempt": 1,
  "revision": "sha256:...",
  "deadlineUnixMs": 1787697600123
}
```

The worker echoes the lease ID in start, heartbeat, host-call, result, and failure messages. Messages with a stale lease are ignored. This prevents a delayed worker from completing a reissued invocation under an obsolete assignment.

## 13.4 No false preemption claim

QuickJS's interrupt handler can request termination of JavaScript execution. It does not expose a supported mechanism for serializing an arbitrary running stack and resuming it later. Therefore:

- the scheduler may abort a running invocation;
- it cannot fairly timeslice multiple compute-bound functions within one runtime thread;
- a worker should not begin a second compute-bound invocation until the first has completed or been destroyed;
- concurrency comes from multiple workers, not from pretending the engine is preemptible.

# 14. Internal control-plane/worker protocol

## 14.1 Transport choice

Use private mTLS HTTP/1.1 with bounded JSON/CBOR bodies for the MVP. This reuses the TLS and HTTP stack already required, gives straightforward packet capture and test fixtures, and avoids inventing framing before semantics stabilize.

A later version can use a compact framed CBOR protocol if profiling shows material overhead.

## 14.2 Endpoints

```text
POST /internal/v1/register
POST /internal/v1/invoke
POST /internal/v1/cancel/{invocationId}
POST /internal/v1/drain
GET  /internal/v1/health
GET  /internal/v1/ready
```

For a control-plane-push design, the worker listens only on a private interface. For a worker-pull design, the worker long-polls for an assignment. The push design is simpler with a warm pool; the pull design traverses some network policies more easily. Pick one in Phase 0 and test reconnect behavior.

## 14.3 Invocation envelope

```json
{
  "protocolVersion": 1,
  "invocationId": "01J6A6...",
  "leaseId": "01J6A7...",
  "attempt": 1,
  "tenant": "tenant-a",
  "function": "order-lookup",
  "revision": "sha256:71be...",
  "runtime": "quickjs-2026-06-04",
  "deadlineUnixMs": 1787697600123,
  "limits": {
    "jsHeapBytes": 16777216,
    "nativeOverheadBytes": 4194304,
    "stackBytes": 262144,
    "cpuMs": 50,
    "outputBytes": 1048576,
    "logBytes": 32768,
    "hostCalls": 32
  },
  "capabilityToken": "base64url...",
  "input": {
    "contentType": "application/json",
    "bytesBase64": "eyJvcmRlcklkIjoiQS0xODQyIn0="
  },
  "trace": {
    "traceId": "...",
    "parentSpanId": "..."
  }
}
```

The capability token is signed or MACed by the control plane and binds:

- tenant, function, revision, invocation, lease, and attempt;
- expiration;
- exact operation set and resource bindings;
- byte/count limits;
- permitted child function targets;
- optional egress constraints.

The worker verifies the token locally before constructing `env`.

## 14.4 Protocol invariants

- A worker accepts at most one active lease.
- An invocation ID cannot be reused with a different revision or input digest.
- Results over the configured maximum are rejected locally, not streamed unboundedly.
- Unknown protocol fields are rejected in version 1 unless explicitly marked extension-safe.
- Worker and control-plane clocks are not assumed perfectly synchronized; expiration includes a bounded skew policy, while the gateway still owns the public deadline.
- Internal errors never include arbitrary C pointers, raw memory dumps, secrets, or full module source.

# 15. Capability system

## 15.1 Internal representation

```ocaml
type operation =
  | Kv_get of { store : Store_id.t; prefix : Key_prefix.t }
  | Kv_put of { store : Store_id.t; prefix : Key_prefix.t }
  | Log_append of { stream : Log_stream.t }
  | Http_request of Http_policy.t
  | Clock_monotonic
  | Clock_wall
  | Random_crypto
  | Invoke_function of Function_ref.t
  | Secret_operation of Secret_policy.t

type grant = {
  binding : Binding_name.t;
  operation : operation;
  limits : Operation_limits.t;
}
```

`env` is generated from this set. There is no generic catch-all host function.

## 15.2 JavaScript API surface

Version-1 bindings:

```javascript
env.log.info(message, fields?)
env.log.warn(message, fields?)

env.kv.<binding>.get(key)
env.kv.<binding>.put(key, value)
env.kv.<binding>.delete(key)
env.kv.<binding>.list(prefix, options?)

env.http.<binding>.request({ method, path, headers, body })

env.crypto.randomBytes(length)

env.functions.<binding>.invoke(input, options?)
```

All methods return Promises except small synchronous metadata operations. The API should avoid exposing arbitrary URLs when a binding already specifies scheme, host, and port. A safer HTTP binding accepts a relative path and method under a predeclared origin.

## 15.3 Capability delegation

A parent function may invoke a child only if its grant includes the child target. The child receives its own manifest-derived capability set, not the parent's full set. Optional future delegation may pass a restricted sub-capability, but version 1 should not permit arbitrary token construction in JavaScript.

## 15.4 Secret handling

Do not expose a raw secret string unless unavoidable. Prefer operation capabilities:

```javascript
const signature = await env.signing.releaseKey.sign(digest);
```

rather than:

```javascript
const key = await env.secrets.get("release-private-key");
```

Operation capabilities reduce accidental logging and exfiltration. The actual secret service may be external to the worker or implemented as a separate hardened unikernel.

# 16. Safe outbound HTTP

An unrestricted `fetch()` turns the function service into an SSRF platform. Version 1 should offer named HTTPS origins with strict policy.

## 16.1 Egress validation algorithm

```text
1. Look up the named HTTP binding from the verified capability token.
2. Construct URL from fixed scheme/host/port plus a validated relative path.
3. Reject userinfo, fragments, alternative schemes, and port overrides.
4. Resolve DNS using the service resolver.
5. Validate every returned IP against allowed CIDRs and blocked ranges.
6. Connect to one validated IP while preserving the expected TLS hostname.
7. Verify the certificate and hostname.
8. Enforce method, header, body, timeout, and byte limits.
9. On redirect, re-run the entire authorization and DNS/IP validation path.
10. Stream or stop reading once the response limit is reached.
```

Blocked-by-default destinations include loopback, link-local, multicast, unspecified, private ranges unless specifically granted, and cloud metadata addresses. DNS rebinding defenses require validating the actual connection address, not only the original hostname string.

## 16.2 Header policy

The runtime controls or strips:

- `Host`;
- `Content-Length` and transfer framing;
- hop-by-hop headers;
- internal authentication headers;
- proxy headers;
- trace headers unless deliberately propagated;
- headers exceeding count or byte limits.

The function may set only an allowlisted set for each binding.

# 17. Observability model

Unikernels remove familiar tools such as `ssh`, `lsof`, and often `strace`. Observability must be designed into semantic operations.

## 17.1 Structured event shape

```ocaml
type event = {
  timestamp : Ptime.t option;
  monotonic_ns : int64;
  severity : Logs.level;
  component : string;
  event_name : string;
  request_id : Request_id.t option;
  invocation_id : Invocation_id.t option;
  tenant_hash : string option;
  function_hash : string option;
  revision_prefix : string option;
  worker_id : Worker_id.t option;
  fields : (string * Safe_value.t) list;
}
```

Tenant and function identifiers may be hashed or redacted in global metrics. Audit streams retain authorized identities under stricter access controls.

## 17.2 Function logging

Function logs are untrusted data. The host wraps them:

```json
{
  "event": "function.log",
  "invocationId": "01J...",
  "level": "info",
  "message": "user supplied text",
  "fields": {"safeUserField":"value"},
  "truncated": false
}
```

Function fields cannot overwrite `tenant`, `revision`, `worker`, `severity`, or timestamps. Values are depth-, count-, and byte-limited.

## 17.3 Metrics

Minimum metrics:

```text
http_requests_total{route,status}
http_request_duration_seconds{route}
invocation_admission_total{decision,reason}
invocation_queue_depth{tenant_class}
invocation_queue_wait_seconds
worker_count{class,state}
worker_launch_total{result}
worker_launch_seconds{class}
invocation_total{result,error_class}
invocation_duration_seconds{phase}
quickjs_runtime_create_seconds
quickjs_heap_peak_bytes
host_calls_total{operation,result}
host_call_duration_seconds{operation}
outbound_bytes_total{binding,direction}
kv_operations_total{operation,result}
function_log_bytes_total{result}
recovery_journal_entries_total
```

High-cardinality values such as raw invocation IDs do not belong in metric labels.

## 17.4 Tracing

Trace spans should cover:

```text
public request
  auth
  registry.resolve
  admission
  queue.wait
  worker.assign
  artifact.fetch
  quickjs.create
  module.load
  handler.call
    host.kv.get
    host.http.request
  result.serialize
  cleanup
```

This produces semantic traces rather than syscall archaeology.

# 18. Failure handling and recovery behavior

## 18.1 Failure classification

```ocaml
type failure_class =
  | Client_error
  | Authentication_error
  | Authorization_error
  | Quota_error
  | Package_error
  | Function_exception
  | Function_rejection
  | Resource_exhaustion
  | Invocation_timeout
  | Invocation_cancelled
  | Capability_error
  | Downstream_error
  | Worker_protocol_error
  | Worker_crash
  | Launcher_error
  | Storage_error
  | Internal_invariant
```

Each class defines retry eligibility, public visibility, audit severity, and worker-health consequence.

## 18.2 Worker crash

On worker connection loss:

```text
1. Mark worker Unhealthy/Dead with observed reason.
2. Revoke its lease and capability token.
3. Record whether the invocation had acknowledged execution start.
4. Apply the invocation retry policy.
5. Ask launcher to destroy residual process/TAP resources.
6. Create replacement capacity if pool policy requires it.
7. Preserve bounded console tail and crash metadata.
```

A deliberate worker exit after a fatal engine invariant should be treated as a fail-stop containment mechanism, not hidden by continuing in a possibly corrupted guest.

## 18.3 Control-plane restart

The host launcher and workers may outlive a control-plane restart. On recovery, the control plane:

- replays durable state;
- obtains launcher inventory;
- rejects or drains workers whose image/protocol/version does not match;
- reestablishes private credentials or leases;
- marks in-flight synchronous invocations failed unless a durable retry contract exists;
- resumes asynchronous work from journaled state;
- does not become ready until ownership is reconciled.

## 18.4 Downstream circuit breakers

Each egress or KV binding may maintain a bounded circuit-breaker state outside JavaScript:

```text
closed -> failures exceed threshold -> open
open -> cooldown -> half-open
half-open -> success -> closed
half-open -> failure -> open
```

A function cannot disable the breaker. Breaker state is scoped by destination and tenant policy to avoid one tenant poisoning all others unnecessarily.


# Part III - Concrete implementation guide

# 19. Repository layout

Use one repository with common libraries and two Mirage entry points. Keep host-only tools outside target libraries so Unix dependencies cannot leak into HVT builds.

```text
mirage-lambda/
├── README.md
├── LICENSE
├── dune-project
├── Makefile
├── mirage-lambda.opam
├── opam.locked
│
├── docs/
│   ├── architecture.md
│   ├── threat-model.md
│   ├── operations.md
│   ├── adr/
│   │   ├── 0001-quickjs-engine.md
│   │   ├── 0002-hvt-tenant-boundary.md
│   │   ├── 0003-source-bundle-format.md
│   │   └── 0004-albatross-launcher.md
│   └── diagrams/
│
├── api/
│   ├── openapi.yaml
│   ├── function-manifest.schema.json
│   ├── invocation-envelope.schema.json
│   └── worker-protocol.md
│
├── common/
│   ├── dune
│   ├── ids.ml                 ids with validated constructors
│   ├── ids.mli
│   ├── error.ml               stable internal/public error taxonomy
│   ├── error.mli
│   ├── bounded_bytes.ml       size checked byte strings
│   ├── bounded_bytes.mli
│   ├── budget.ml              counters and exhaustion rules
│   ├── budget.mli
│   ├── capability.ml          grants and compiled policy
│   ├── capability.mli
│   ├── manifest.ml            strict JSON parser + semantic checks
│   ├── manifest.mli
│   ├── bundle.ml              MLB1 parser/writer
│   ├── bundle.mli
│   ├── protocol.ml            internal envelopes and results
│   ├── protocol.mli
│   ├── canonical_json.ml
│   └── canonical_json.mli
│
├── qjs/
│   ├── vendor/
│   │   └── quickjs-2026-06-04/
│   │       ├── LICENSE
│   │       ├── VERSION
│   │       ├── quickjs.c
│   │       ├── quickjs.h
│   │       ├── cutils.c
│   │       ├── cutils.h
│   │       ├── dtoa.c
│   │       ├── dtoa.h
│   │       ├── libregexp.c
│   │       ├── libregexp.h
│   │       ├── libregexp-opcode.h
│   │       ├── libunicode.c
│   │       ├── libunicode.h
│   │       └── generated tables/headers required by release
│   ├── c/
│   │   ├── qjs_port.h          freestanding platform boundary
│   │   ├── qjs_port_solo5.c
│   │   ├── qjs_port_unix.c
│   │   ├── qjs_allocator.c
│   │   ├── qjs_host_queue.c
│   │   ├── qjs_host_queue.h
│   │   ├── qjs_stubs.c         OCaml FFI entry points
│   │   └── qjs_stubs.h
│   ├── lib/
│   │   ├── dune
│   │   ├── qjs_handle.ml
│   │   ├── qjs_handle.mli
│   │   ├── qjs_engine.ml
│   │   ├── qjs_engine.mli
│   │   ├── qjs_module_loader.ml
│   │   ├── qjs_module_loader.mli
│   │   ├── qjs_host_request.ml
│   │   └── qjs_host_request.mli
│   └── test/
│       ├── probe.ml
│       ├── test_limits.ml
│       ├── test_promises.ml
│       ├── test_modules.ml
│       └── fuzz_bundle_to_qjs.ml
│
├── control/
│   ├── config.ml
│   ├── unikernel.ml
│   ├── dune
│   ├── ingress.ml
│   ├── ingress.mli
│   ├── auth.ml
│   ├── auth.mli
│   ├── admin_api.ml
│   ├── admin_api.mli
│   ├── invoke_api.ml
│   ├── invoke_api.mli
│   ├── artifact_store.ml
│   ├── artifact_store.mli
│   ├── registry.ml
│   ├── registry.mli
│   ├── metadata_writer.ml
│   ├── metadata_writer.mli
│   ├── admission.ml
│   ├── admission.mli
│   ├── scheduler.ml
│   ├── scheduler.mli
│   ├── worker_pool.ml
│   ├── worker_pool.mli
│   ├── launcher_client.ml
│   ├── launcher_client.mli
│   ├── recovery.ml
│   ├── recovery.mli
│   ├── telemetry.ml
│   └── telemetry.mli
│
├── worker/
│   ├── config.ml
│   ├── unikernel.ml
│   ├── dune
│   ├── worker_server.ml
│   ├── worker_server.mli
│   ├── invocation.ml
│   ├── invocation.mli
│   ├── runtime_host.ml
│   ├── runtime_host.mli
│   ├── capability_broker.ml
│   ├── capability_broker.mli
│   ├── host_kv.ml
│   ├── host_http.ml
│   ├── host_log.ml
│   ├── host_crypto.ml
│   ├── host_invoke.ml
│   ├── artifact_cache.ml
│   └── telemetry.ml
│
├── launcher/
│   ├── dune
│   ├── launcher.ml
│   ├── launcher.mli
│   ├── fake_launcher.ml
│   ├── unix_process_launcher.ml
│   └── albatross_launcher.ml
│
├── cli/
│   ├── dune
│   ├── main.ml
│   ├── bundle_cmd.ml
│   ├── deploy_cmd.ml
│   ├── invoke_cmd.ml
│   └── inspect_cmd.ml
│
├── test/
│   ├── unit/
│   ├── integration/
│   ├── e2e/
│   ├── fuzz/
│   ├── fault/
│   └── fixtures/
│
└── deploy/
    ├── albatross/
    ├── systemd/
    ├── network/
    ├── certs/
    └── scripts/
```

## 19.1 File ownership rules

- `common/` cannot depend on `Unix`, Mirage device implementations, or QuickJS C handles.
- `qjs/lib/` exposes an OCaml abstraction; callers do not include `quickjs.h` directly.
- `control/` does not link QuickJS in production fleet builds.
- `worker/` does not link the mutable service registry or host launcher.
- `launcher/` is host-side and can use Unix APIs; it is not part of HVT images.
- JSON schemas under `api/` are authoritative test inputs, not duplicated prose-only definitions.
- Every public module has an `.mli` before significant implementation is merged.

# 20. OCaml module contracts

Start from contracts. Interns should be able to implement a fake behind each interface before connecting the real device.

## 20.1 Engine interface

```ocaml
module type QJS_ENGINE = sig
  type t
  type error
  type completion =
    | Fulfilled of Bounded_bytes.t
    | Rejected of Error.Js.t

  type progress =
    | Need_host_work
    | Runnable
    | Waiting
    | Complete of completion
    | Interrupted of Error.Resource.t

  val create :
    limits:Budget.Engine_limits.t ->
    bundle:Bundle.Validated.t ->
    (t, error) result

  val start :
    t ->
    entrypoint:Module_path.t ->
    export_name:string ->
    event_json:Bounded_bytes.t ->
    context_json:Bounded_bytes.t ->
    (unit, error) result

  val take_host_requests : t -> Qjs_host_request.t list

  val resolve_host_request :
    t ->
    Qjs_host_request.Id.t ->
    (Bounded_bytes.t, Error.Host.t) result ->
    (unit, error) result

  val pump :
    t ->
    max_jobs:int ->
    (progress, error) result

  val cancel : t -> Error.Resource.t -> unit
  val memory_usage : t -> Qjs_memory.t
  val destroy : t -> unit
end
```

`pump` is intentionally bounded by `max_jobs`. A malicious Promise chain must not monopolize the event loop indefinitely without an interrupt/deadline check.

## 20.2 Capability broker

```ocaml
module type CAPABILITY_BROKER = sig
  type t
  type error

  val dispatch :
    t ->
    invocation:Invocation_context.t ->
    Qjs_host_request.t ->
    (Bounded_bytes.t, error) result Lwt.t
end
```

The broker performs authorization and accounting before calling an operation implementation. It does not trust the fact that a JavaScript binding existed; it verifies the request against the invocation's compiled policy.

## 20.3 Artifact store

```ocaml
module type ARTIFACT_STORE = sig
  type t
  type error

  val put_if_absent :
    t ->
    digest:Digest.t ->
    Bounded_bytes.t ->
    ([ `Created | `Already_present ], error) result Lwt.t

  val get :
    t ->
    Digest.t ->
    (Bounded_bytes.t, error) result Lwt.t

  val exists : t -> Digest.t -> (bool, error) result Lwt.t
  val delete : t -> Digest.t -> (unit, error) result Lwt.t
end
```

The implementation recomputes the digest when reading or when ingesting from an untrusted transport.

## 20.4 Registry

```ocaml
module type REGISTRY = sig
  type t
  type error

  val resolve :
    t ->
    tenant:Tenant_id.t ->
    function_name:Function_name.t ->
    qualifier:Qualifier.t ->
    (Revision.t, error) result Lwt.t

  val publish_revision :
    t ->
    Revision.t ->
    (unit, error) result Lwt.t

  val move_alias :
    t ->
    tenant:Tenant_id.t ->
    function_name:Function_name.t ->
    alias:Alias.t ->
    revision:Revision_id.t ->
    precondition:Revision_id.t option ->
    (unit, error) result Lwt.t
end
```

Alias movement supports an optional compare-and-set precondition to prevent lost administrative updates.

## 20.5 Scheduler

```ocaml
module type SCHEDULER = sig
  type t

  val enqueue : t -> Invocation.Pending.t -> (unit, Error.t) result
  val cancel : t -> Invocation_id.t -> [ `Removed | `Already_assigned | `Absent ]

  val next_assignment :
    t ->
    now:Mtime.t ->
    available:Worker_pool.Snapshot.t ->
    Assignment.t option

  val on_assignment_result :
    t ->
    Assignment.result ->
    unit
end
```

The scheduling algorithm is pure or nearly pure. Time and worker snapshots are inputs, making fairness tests deterministic.

## 20.6 Launcher

```ocaml
module type LAUNCHER = sig
  type t
  type error

  val create_worker :
    t ->
    Worker_spec.t ->
    (Worker_handle.t, error) result Lwt.t

  val stop_worker :
    t ->
    Worker_id.t ->
    (unit, error) result Lwt.t

  val list_workers :
    t ->
    (Worker_observation.t list, error) result Lwt.t

  val console_tail :
    t ->
    Worker_id.t ->
    max_bytes:int ->
    (string, error) result Lwt.t
end
```

The fake launcher supports scripted startup failure, delayed registration, crash, and stale inventory for fault tests.

# 21. QuickJS port: exact scope

QuickJS's upstream build includes the core engine plus `quickjs-libc.c`; its Makefile lists `quickjs.o`, `dtoa.o`, `libregexp.o`, `libunicode.o`, `cutils.o`, and `quickjs-libc.o` in the standard library archive. [QJS-MAKEFILE] This project should separate the engine from the POSIX-oriented convenience layer.

## 21.1 Keep

Vendor the exact release and keep the files required by the core engine:

```text
quickjs.c / quickjs.h
cutils.c / cutils.h
dtoa.c / dtoa.h
libregexp.c / libregexp.h / opcode headers
libunicode.c / libunicode.h / generated tables
release VERSION and LICENSE
```

The exact generated-header set must come from the official release archive. Do not reconstruct it from an unpinned branch.

## 21.2 Exclude

Do not link these into the worker unless a later review deliberately ports them:

```text
qjs.c                command-line interpreter
qjsc.c               compiler executable
quickjs-libc.c        std/os modules and POSIX event loop
quickjs-libc.h
repl.js / repl.c
run-test262.c         test tool only
native .so modules
os.Worker support
```

The standard QuickJS library exposes process, file, signal, environment, directory, `exec`, and worker functions. Those facilities conflict with the capability model and carry Unix assumptions. [QJS-DOC]

## 21.3 Freestanding platform audit

QuickJS is self-contained in the sense of external engine dependencies, but it is not automatically freestanding C. The public header includes standard C headers, and the core source uses math, time, floating-point environment, memory, and optional atomics/pthread facilities. [QJS-H] [QJS-C]

Create an explicit audit document in `docs/quickjs-port-audit.md` containing:

| Symbol/header class | Expected action |
|---|---|
| `memcpy`, `memmove`, `strlen`, integer helpers | use ocaml-solo5/minimal libc if provided |
| `malloc`, `free`, `realloc` | route engine allocations through `JS_NewRuntime2` custom functions; audit other direct uses |
| `snprintf`, formatting | verify minimal libc behavior and bound all buffers |
| `math.h` functions | link/test freestanding math support; add compile-time probe |
| floating-point environment | test or patch behind platform interface |
| `gettimeofday`/time | replace with explicit port function; do not grant wall time accidentally |
| `pthread`/atomics | compile atomics/worker support out; call `JS_SetCanBlock(rt, false)` |
| files, signals, `dlopen`, process APIs | absent because `quickjs-libc.c` is not linked |
| locale | force deterministic locale-independent behavior or patch assumptions |
| randomness | do not treat built-in `Math.random` as cryptographic; expose host crypto capability |

A compile/link symbol report is a Phase 0 deliverable, not guesswork embedded in the long-term design.

## 21.4 Small platform boundary

Patch or wrap all required platform operations through a narrow internal header:

```c
/* qjs_port.h */
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint64_t monotonic_ns;
    int64_t wall_time_ms;
} mlqjs_time_snapshot;

uint64_t mlqjs_monotonic_ns(void);
int64_t mlqjs_wall_time_ms(void);        /* available only when configured */
void mlqjs_random_bytes(void *dst, size_t len);
void mlqjs_abort(const char *reason);
```

Do not let QuickJS call the Mirage network or KV stack directly. The C engine sees only memory, time needed for engine semantics, and host callback registration. Application I/O crosses to OCaml through the host request queue.

## 21.5 Built-in intrinsics

`JS_NewContext()` installs the normal set of intrinsics. The public API also exposes `JS_NewContextRaw()` and individual `JS_AddIntrinsic...` functions, allowing a reduced environment. [QJS-H]

Recommended initial set:

```text
include:
    base objects
    JSON
    RegExp, if required by supported applications
    Map/Set
    TypedArrays
    Promise
    string normalization, if bundle requirements need it

exclude initially:
    Eval
    Date, unless explicitly patched and documented
    WeakRef, unless a compatibility case requires it
    blocking Atomics
    SharedArrayBuffer
```

The exact compatibility profile is versioned as `quickjs-2026-06-04-mlambda-v1`. Changing intrinsics is a runtime-version change because user-visible behavior changes.

# 22. OCaml/C FFI design

## 22.1 Main rule: OCaml drives C

Use predominantly OCaml-to-C calls:

```text
OCaml creates runtime
OCaml asks C to compile/call/pump
C queues plain host requests
C returns to OCaml
OCaml performs Lwt I/O
OCaml calls C to resolve/reject Promise
OCaml pumps pending QuickJS jobs
```

Avoid an architecture where QuickJS calls arbitrary OCaml closures during asynchronous I/O. The OCaml C-interface manual requires callbacks to hold the domain lock, and C-created threads must be registered with the runtime. It also specifies restrictions when the runtime lock is released. [OCAML-FFI] A queue boundary is simpler and easier to audit.

## 22.2 Handle representation

Use opaque handles with deterministic destruction:

```ocaml
type runtime
type request_id = int64

external create : limits_blob:bytes -> runtime = "mlqjs_create"
external eval_entry : runtime -> bundle_blob:bytes -> string -> unit =
  "mlqjs_eval_entry"
external call_handler : runtime -> event:bytes -> context:bytes -> unit =
  "mlqjs_call_handler"
external take_requests : runtime -> host_request array = "mlqjs_take_requests"
external resolve : runtime -> request_id -> bytes -> unit = "mlqjs_resolve"
external reject : runtime -> request_id -> error_blob:bytes -> unit = "mlqjs_reject"
external pump : runtime -> max_jobs:int -> pump_result = "mlqjs_pump"
external cancel : runtime -> reason:int -> unit = "mlqjs_cancel"
external destroy : runtime -> unit = "mlqjs_destroy"
```

Two safe implementation choices exist:

1. An OCaml custom block containing a `JSRuntime` wrapper pointer, with a finalizer as a last-resort leak guard.
2. An integer handle into a C-side table, with explicit `destroy` and generation counters to reject stale handles.

The second is easier to harden against accidental use-after-free from OCaml code. The first is conventional and lower overhead. Whichever is chosen, explicit destruction in `Lwt.finalize` is required; finalizers are not the normal lifecycle.

## 22.3 C wrapper state

```c
typedef struct mlqjs_runtime {
    JSRuntime *rt;
    JSContext *ctx;
    mlqjs_limits limits;
    mlqjs_usage usage;
    mlqjs_host_queue requests;
    mlqjs_promise_table promises;
    JSValue handler;
    JSValue root_promise;
    uint64_t deadline_ns;
    uint64_t cpu_budget_ns;
    uint64_t engine_start_ns;
    int cancelled;
    int terminal;
} mlqjs_runtime;
```

All JavaScript values retained across C calls are duplicated and freed according to QuickJS reference-counting rules. Each table entry has one documented owner.

## 22.4 C stub discipline

Every OCaml C primitive follows the runtime macros correctly:

```c
CAMLprim value mlqjs_create(value v_limits) {
    CAMLparam1(v_limits);
    CAMLlocal1(v_handle);

    /* Parse into C-owned data before long work. */
    mlqjs_limits limits = decode_limits(v_limits);
    mlqjs_runtime *q = mlqjs_runtime_new(&limits);
    if (q == NULL) caml_failwith("mlqjs_create");

    v_handle = alloc_runtime_handle(q);
    CAMLreturn(v_handle);
}
```

Rules:

- Never retain an OCaml heap pointer in C without registering a global/generational root.
- Prefer C-owned copies over long-lived OCaml callbacks.
- Do not mark a primitive `[@@noalloc]` unless it provably allocates no OCaml value, raises no exception, and never releases the runtime lock.
- Convert QuickJS exceptions into bounded C data, then OCaml error values.
- Make `destroy` idempotent from the OCaml side but assert internal ownership errors in debug builds.
- Compile Unix tests with AddressSanitizer and UndefinedBehaviorSanitizer where the toolchain permits.

# 23. Asynchronous JavaScript host calls

This is the most important runtime bridge.

![QuickJS/OCaml Promise bridge](mirage_lambda_guide_assets/05_quickjs_bridge.png)

*Figure 7. A JavaScript host call queues data in C, returns a Promise, and is completed later by the OCaml Lwt scheduler.*

## 23.1 C callback behavior

For `env.kv.orders.get("A-1842")`, the C host callback:

```c
static JSValue mlqjs_kv_get(
    JSContext *ctx,
    JSValueConst this_val,
    int argc,
    JSValueConst *argv)
{
    mlqjs_runtime *q = JS_GetContextOpaque(ctx);
    JSValue resolving[2] = { JS_UNDEFINED, JS_UNDEFINED };

    if (argc != 1)
        return JS_ThrowTypeError(ctx, "get expects one key");

    mlqjs_request req;
    if (decode_and_bound_kv_get(ctx, argv[0], &req) < 0)
        return JS_EXCEPTION;

    if (!budget_take_host_call(&q->usage, &q->limits))
        return JS_ThrowInternalError(ctx, "host call budget exhausted");

    JSValue promise = JS_NewPromiseCapability(ctx, resolving);
    if (JS_IsException(promise))
        return promise;

    uint64_t id = promise_table_insert(
        &q->promises,
        ctx,
        resolving[0],
        resolving[1]);

    JS_FreeValue(ctx, resolving[0]);
    JS_FreeValue(ctx, resolving[1]);

    req.id = id;
    if (!host_queue_push(&q->requests, &req)) {
        promise_table_reject_overload(q, id);
    }

    return promise;
}
```

The callback performs no network or storage I/O. It validates arguments, accounts the operation, creates a Promise, stores duplicated resolver functions, queues a bounded plain-C request, and returns.

## 23.2 OCaml dispatch loop

```ocaml
let rec drive broker invocation engine =
  match Qjs_engine.pump engine ~max_jobs:64 with
  | Error e -> Lwt.return (Error (Error.of_qjs e))
  | Ok (Complete completion) -> Lwt.return (Ok completion)
  | Ok (Interrupted why) -> Lwt.return (Error (Error.Resource why))
  | Ok Runnable ->
      if Budget.deadline_expired invocation.budget then begin
        Qjs_engine.cancel engine `Deadline;
        drive broker invocation engine
      end else
        Lwt.pause () >>= fun () ->
        drive broker invocation engine
  | Ok Need_host_work ->
      let requests = Qjs_engine.take_host_requests engine in
      dispatch_all broker invocation engine requests >>= fun () ->
      drive broker invocation engine
  | Ok Waiting ->
      Runtime_host.await_one_completion invocation.host >>= fun () ->
      Runtime_host.flush_completions engine invocation.host;
      drive broker invocation engine
```

`dispatch_all` uses bounded concurrency no greater than the manifest's pending-host-call limit. Cancellation propagates to outstanding Lwt operations where supported.

## 23.3 Promise completion

The C `resolve` primitive:

```text
1. Find request ID in promise table.
2. Reject stale, duplicate, or unknown completion.
3. Convert bounded result bytes to an approved JS value.
4. Call the stored resolve or reject function.
5. Free both resolver functions and remove table entry.
6. Return to OCaml.
7. OCaml calls `pump`, which uses `JS_ExecutePendingJob` in bounded batches.
```

QuickJS exposes `JS_NewPromiseCapability`, `JS_IsJobPending`, and `JS_ExecutePendingJob` for this model. [QJS-H]

## 23.4 Result representation

Use canonical JSON for the first implementation. The host callback protocol carries bytes plus a declared result type:

```ocaml
type host_result =
  | Json of Bounded_bytes.t
  | Bytes of Bounded_bytes.t
  | Unit
```

Avoid directly constructing arbitrary deeply nested JavaScript values from OCaml. Parse bounded JSON inside QuickJS or through a carefully audited C conversion. For byte results, use an `ArrayBuffer`/`Uint8Array` with an explicit ownership policy.

# 24. QuickJS runtime construction

## 24.1 Creation order

```text
1. Allocate wrapper and zero all fields.
2. Install custom allocator via JS_NewRuntime2.
3. Set runtime info string with version/invocation prefix.
4. Set memory limit and GC threshold.
5. Set maximum stack size.
6. Set interrupt handler.
7. Set can-block false.
8. Set Promise rejection tracker.
9. Set module normalize/loader/check-attributes callbacks.
10. Create raw context.
11. Add approved intrinsics.
12. Install context opaque pointer.
13. Construct frozen env and context host objects.
14. Load entry module and resolve imports from bundle map.
15. Obtain and retain exported handler.
```

If any step fails, unwind in reverse order.

## 24.2 Interrupt handler

```c
static int mlqjs_interrupt(JSRuntime *rt, void *opaque) {
    mlqjs_runtime *q = opaque;
    if (q->cancelled)
        return 1;

    uint64_t now = mlqjs_monotonic_ns();
    if (now >= q->deadline_ns) {
        q->interrupt_reason = MLQJS_DEADLINE;
        return 1;
    }

    uint64_t used = now - q->engine_start_ns;
    if (used >= q->cpu_budget_ns) {
        q->interrupt_reason = MLQJS_CPU;
        return 1;
    }

    return 0;
}
```

This is approximate CPU accounting because monotonic elapsed time may include some runtime overhead. Version 1 should name the metric precisely, benchmark it, and avoid claiming nanosecond-accurate CPU billing. The gateway's wall deadline remains independent.

## 24.3 Built-in time and randomness

The platform must document:

- `env.clock.monotonicNow()` uses Mirage monotonic time and may be absent if not granted.
- `env.clock.wallNow()` is a separate capability and may be absent.
- `env.crypto.randomBytes(n)` uses Mirage cryptographic entropy and has a byte limit.
- Built-in `Math.random()` is not cryptographic. It may be disabled, deterministically seeded for tests, or left with explicitly documented non-security semantics.
- `Date` should be omitted initially or patched to a clearly defined host time source.

The goal is to avoid accidentally granting wall time or cryptographic claims through standard built-ins.

## 24.4 Module loader

The normalize callback:

```text
input: base module path, requested specifier
if specifier begins "cap:":
    return exact virtual-module name after policy validation
else:
    resolve relative to base directory
    normalize segments
    reject escape above bundle root
    require exact path present in bundle map
    return canonical path allocated with QuickJS allocator
```

The loader compiles module source from the validated bundle and returns the module definition. It never performs I/O.

# 25. Worker implementation

## 25.1 Worker startup

```ocaml
module Main
    (Stack : Tcpip.Stack.V4V6)
    (Certs : Mirage_kv.RO) = struct

  let start stack certs =
    Telemetry.init ();
    Identity.load certs >>= fun identity ->
    Private_tls.create stack identity >>= fun channel ->
    Worker_server.register channel >>= function
    | Error e -> Fatal.exit e
    | Ok lease ->
        Worker_server.serve ~lease ~channel
end
```

The worker starts with no function code. It registers its image digest, runtime version, memory class, protocol version, and nonce. The control plane returns a lease and desired state.

## 25.2 Invocation handler pseudocode

```ocaml
let execute t envelope =
  let open Lwt.Syntax in
  let* () = validate_worker_is_ready t in
  let* token = Capability_token.verify t.keys envelope.capability_token in
  let* () = validate_token_binding token envelope in
  let* bundle = Artifact_cache.get_verified t.cache envelope.revision in
  let limits = Limits.intersect envelope.limits t.worker_hard_limits in
  let host = Runtime_host.create ~token ~limits in

  Lwt.finalize
    (fun () ->
       match Qjs_engine.create ~limits:limits.engine ~bundle with
       | Error e -> Lwt.return (Error (Error.Engine_create e))
       | Ok engine ->
           Invocation_registry.set_active t.registry envelope engine host;
           let context = Invocation_context.to_json envelope in
           begin match Qjs_engine.start engine
                         ~entrypoint:bundle.manifest.entrypoint
                         ~export_name:bundle.manifest.export
                         ~event_json:envelope.input
                         ~context_json:context with
           | Error e -> Lwt.return (Error (Error.Engine_start e))
           | Ok () -> Runtime_driver.drive t.broker envelope host engine
           end)
    (fun () ->
       Invocation_registry.clear_active t.registry;
       Runtime_host.cancel_all host;
       Qjs_engine.destroy_if_present (Invocation_registry.engine t.registry);
       Artifact_cache.release bundle;
       Lwt.return_unit)
```

The worker returns to `Ready` only after cleanup finishes and memory/high-water checks pass. Otherwise it drains and exits.

## 25.3 Self-recycling

Native runtimes can fragment memory or accumulate latent state. Add a worker recycle policy:

```text
exit and replace worker when any is true:
    invocation_count >= configured maximum
    resident/heap high-water mark exceeds threshold
    cleanup invariant fails
    QuickJS reports live objects unexpectedly after teardown
    protocol or token verification invariant fails
    worker image lease is superseded
```

The threshold is operational policy, not a user-controlled manifest value.

# 26. Control-plane implementation

## 26.1 Mirage composition sketch

The exact types will need adjustment against the locked package set, but the shape is:

```ocaml
(* control/config.ml *)
open Mirage

let stack = generic_stackv4v6 default_network
let certs = generic_kv_ro "certs"

let program_block_size =
  Runtime_arg.create ~pos:__POS__ "Unikernel.program_block_size"

let state_block = block_of_file "state"
let state = chamelon ~program_block_size state_block

let https = cohttp_server @@ conduit_direct ~tls:true stack

let main =
  let packages = [
    package "cohttp-mirage";
    package "tls-mirage";
    package "yojson";
    package "digestif";
    package "mirage-kv";
    package "logs";
  ] in
  main ~packages "Unikernel.Main"
    (stackv4v6 @-> kv_ro @-> kv_rw @-> http @-> job)

let () =
  register "mirage-lambda-control"
    [ main $ stack $ certs $ state $ https ]
```

Mirage's current API documents `block_of_file`, `generic_kv_ro`, `kv_rw_mem`, `chamelon`, and the corresponding device types. [MIRAGE-API] Current TLS examples compose a generic stack, a read-only certificate KV, and a Cohttp server. [MIRAGE-TLS-EXAMPLE]

## 26.2 Control startup order

```text
1. Initialize structured logging and boot identity.
2. Open/validate certificate material.
3. Open persistent KV and read schema.
4. Replay checkpoint/journal.
5. Start metadata writer.
6. Connect to launcher and reconcile workers.
7. Start worker-pool health loop.
8. Start schedulable queues.
9. Install private and public HTTP routes.
10. Mark ready.
```

Public listeners may be installed early, but all non-health routes return `503 NOT_READY` until recovery and reconciliation complete.

## 26.3 Main control loops

Run supervised Lwt loops:

```ocaml
let start components =
  Lwt_switch.with_switch @@ fun sw ->
  let loops = [
    Recovery.run components.recovery;
    Worker_pool.health_loop ~sw components.workers;
    Scheduler.assignment_loop ~sw components.scheduler;
    Metadata_writer.run ~sw components.metadata_writer;
    Telemetry.flush_loop ~sw components.telemetry;
    Maintenance.gc_loop ~sw components.gc;
    Ingress.serve ~sw components.ingress;
  ] in
  Supervision.join_fail_fast loops
```

A loop failure is classified. Some loops can restart; a metadata-writer invariant or storage corruption should fail the control-plane guest rather than continue in an unknown state.

# 27. Host launcher integration

## 27.1 Albatross adapter

The adapter maps internal operations to Albatross's deployment protocol and naming hierarchy:

```text
administrative domain:
    lambda/<cluster>/<tenant>/<worker-id>

resources:
    image = worker.hvt digest
    memory = selected class
    CPU = selected/pinned core policy
    TAP = private worker network
    block = none for initial worker
    restart = control-plane policy, not unconditional for one-shot worker
```

The adapter is responsible for idempotent create/stop behavior and for reconciling observed state after reconnect.

## 27.2 Worker boot arguments

A representative direct HVT development command is:

```bash
solo5-hvt \
  --mem=128 \
  --net:service0=tap-ml-worker-001 \
  -- worker.hvt \
  --ipv4=10.42.1.10/24 \
  --ipv4-gateway=10.42.1.1 \
  --control-uri=https://10.42.0.2:9443 \
  --worker-id=worker-001
```

Solo5's documented syntax places tender options before `--`, then the unikernel image and its arguments. All devices declared in the guest manifest must be attached. [SOLO5-BUILD]

Do not hard-code the command in application logic. Generate a `Worker_spec.t`, render it only in the host adapter, and unit-test escaping and device assignment.

## 27.3 Network topology

A simple host topology:

```text
public NIC
   |
 host firewall / optional L4 forwarding
   |
 tap-control-public ---- control-plane HVT
   |
 private bridge 10.42.0.0/16
   |        |        |
 tap-cp   tap-w1   tap-w2 ...
            |        |
          worker1  worker2
```

Workers have no host route to the public internet by default. Egress either passes through a dedicated broker service or host firewall/NAT rules generated from a coarse worker profile, with fine-grained HTTP policy still enforced in the worker capability broker.

# 28. Build and development environment

## 28.1 Host prerequisites

For Linux development:

```text
64-bit Linux with KVM support
opam 2.1 or later
OCaml 5.5.0 switch, subject to locked package compatibility
Dune and opam-monorepo through Mirage tooling
Mirage 4.11.2 baseline
Solo5 0.12.1 baseline
C11 compiler, GNU make, pkg-config, libseccomp
/dev/kvm and /dev/net/tun access for HVT networking
Graph/test tools, clang sanitizers for Unix C tests
```

Solo5's build documentation lists a C11 compiler, host headers, and on Linux `pkg-config` plus `libseccomp`; HVT is a production target on Linux/KVM for x86-64 and AArch64. [SOLO5-BUILD]

## 28.2 Initial switch

Representative setup:

```bash
opam update
opam switch create . 5.5.0 --deps-only=false
 eval "$(opam env)"
opam install mirage.4.11.2 solo5.0.12.1 \
  dune ocamlformat alcotest qcheck crowbar
```

The precise package set belongs in `opam.locked`. The first build may reveal that a library has not yet accepted the newest compiler; pin a compatible tested set rather than forcing every newest version at once.

## 28.3 Unix target loop

```bash
cd control
mirage configure -t unix
make depend
make build
./dist/mirage-lambda-control
```

Current Mirage 4 uses Dune/opam-monorepo-based cross compilation, and generated Makefiles use `make build` rather than the removed historical `mirage build` command. [MIRAGE-CHANGES] Exact generated paths should be taken from the configured project.

## 28.4 HVT build

```bash
cd control
mirage clean
mirage configure -t hvt
make depend
make build
solo5-elftool query-manifest dist/mirage-lambda-control.hvt
```

Worker:

```bash
cd worker
mirage configure -t hvt
make depend
make build
solo5-elftool query-manifest dist/mirage-lambda-worker.hvt
```

The manifest inspection is part of CI. A worker should not unexpectedly gain a block device or additional NIC.

## 28.5 Chamelon state image

Mirage's current API documents a Chamelon formatting flow over a block image. [MIRAGE-API]

```bash
dd if=/dev/zero of=lambda-state.img bs=1M count=512
chamelon format lambda-state.img 512

solo5-hvt \
  --mem=256 \
  --net:service0=tap-ml-control \
  --block:state=lambda-state.img \
  -- control.hvt \
  --program-block-size=512 \
  --ipv4=10.42.0.2/24 \
  --ipv4-gateway=10.42.0.1
```

Verify the logical block name against the generated Solo5 manifest. The `program-block-size` value must match the device and Chamelon requirements used by the locked version.

# 29. Testing strategy

Testing is organized by boundary rather than only by module.

## 29.1 Unit tests

Required unit suites:

- identifier validation and key-segment safety;
- canonical JSON and duplicate-field rejection;
- manifest schema and tenant-policy intersection;
- bundle parser integer overflow, duplicate paths, and digest checks;
- scheduler fairness under randomized tenant queues;
- budget counter monotonicity and exhaustion;
- capability matching and prefix boundaries;
- alias compare-and-set behavior;
- journal encoding and replay;
- normalized error mapping;
- worker and invocation state transition legality.

Property example:

```ocaml
QCheck.Test.make
  ~name:"scheduler never assigns more than tenant concurrency quota"
  arbitrary_scheduler_trace
  (fun trace ->
     let states = Scheduler_model.run trace in
     List.for_all quota_holds states)
```

## 29.2 QuickJS engine tests

Run on Unix first, then a representative subset in HVT:

```text
1 + 2 evaluates correctly
ES module imports resolve within bundle
path escape import is rejected
async function completion succeeds
host Promise resolves and rejects
unhandled rejection is reported
infinite loop is interrupted
recursive stack overflow is contained
heap limit rejects allocation bomb
microtask chain is bounded/interrupted
large output is rejected
runtime teardown leaves no promise entries
fresh runtime cannot observe prior invocation global state
malformed source never crashes process under fuzzer corpus
```

Build the Unix engine harness with ASan/UBSan. Run upstream QuickJS tests where the reduced intrinsic profile makes them applicable, but do not equate upstream test success with sandbox security.

## 29.3 Fuzzing

Fuzz these independent parsers:

- MLB1 bundle parser;
- manifest JSON parser;
- internal invocation envelope parser;
- QuickJS source compile/eval harness;
- host-call argument decoders;
- result serializer;
- capability token decoder;
- HTTP route/body parser boundary where possible.

Fuzzer invariants:

```text
no crash
no unbounded allocation
no hang beyond external watchdog
no accepted path escape
no accepted integer wrap
no stale request ID reuse
no leaked JSValue count after teardown in debug mode
```

## 29.4 Integration tests

Unix integration tests start fake control, fake launcher, and worker processes:

```text
deploy -> alias -> invoke -> KV host call -> result
deploy invalid bundle -> no object publication
worker fails before start ack -> reassignment policy
worker fails after start ack -> no unsafe replay by default
cancel queued invocation
cancel running infinite loop
control restart -> journal replay -> alias resolution
idempotency key with same payload -> same operation result
idempotency key with different payload -> conflict
```

## 29.5 HVT end-to-end tests

On a KVM CI runner or dedicated test host:

```text
boot control HVT with formatted state block
boot/register worker HVT through launcher
perform mTLS deployment and invocation
kill worker tender mid-invocation
kill control tender during metadata mutation
restart and verify recovery invariants
inspect manifests for expected devices
verify worker cannot reach blocked destinations
verify tenant A worker cannot address tenant B private endpoint
exercise drain and rolling image replacement
```

## 29.6 Fault injection

Provide deterministic fault points:

```ocaml
type fault_point =
  | After_object_write
  | Before_revision_rename
  | After_revision_rename
  | Before_alias_rename
  | Worker_after_bundle_fetch
  | Worker_after_runtime_create
  | Worker_during_host_call
  | Control_after_assignment
  | Launcher_after_process_start
```

Tests crash the relevant component at each point and check recovery. This is more valuable than only testing graceful errors.

## 29.7 Security tests

At minimum:

- module path traversal corpus;
- overlong UTF-8 and invalid encoding inputs;
- SSRF to loopback, link-local, private, metadata, IPv4-mapped IPv6, and redirect targets;
- DNS answer changes between authorization and connection;
- host header and redirect manipulation;
- log field spoofing and escape sequences;
- Promise/request ID reuse;
- capability token modification, replay, expiration, and tenant substitution;
- result/body decompression bomb policy if compression is added;
- malformed internal protocol from a compromised worker;
- deliberate worker `abort()` and cleanup verification;
- no secret material in public error, metric label, or console tail.

# 30. Performance methodology

Do not establish marketing targets before a baseline. Build a reproducible benchmark suite that separates phases.

## 30.1 Measurements

```text
control HTTP parse/auth latency
queue wait
worker selection
worker launch and private TLS registration
artifact fetch/cache hit
JSRuntime create
module compile/load
handler execution
host-call wait
result serialization
runtime cleanup
end-to-end p50/p95/p99
```

## 30.2 Workloads

- empty synchronous function;
- JSON transformation;
- CPU loop with fixed operation count;
- one KV read;
- one HTTPS request to a controlled local endpoint;
- Promise fan-out within allowed concurrency;
- large-but-valid input/output;
- cold worker versus warm worker;
- one tenant versus many tenants with unequal weights;
- adversarial timeout and memory exhaustion.

## 30.3 Comparisons

Compare:

```text
Unix OCaml + QuickJS worker
single-appliance Mirage HVT
fleet mode with warm HVT worker
fleet mode with cold HVT worker
reference Linux process/container implementation, if available
```

Report hardware, compiler flags, image digests, memory classes, sample counts, and error bars. QuickJS advertises very low runtime lifecycle time on a desktop, but that upstream number is not a service cold-start claim and must not be copied into system performance assertions. [QJS-DOC]

# 31. Threat model

## 31.1 Assets

- host and hypervisor integrity;
- control-plane metadata and signing keys;
- other tenants' code, inputs, outputs, and state;
- worker identity and capability tokens;
- persistent artifacts and aliases;
- network credentials and downstream services;
- availability and fair resource allocation;
- audit-log integrity.

## 31.2 Adversaries

- unauthenticated network attacker;
- authenticated tenant invoking malformed requests;
- malicious function author supplying arbitrary JavaScript source and bundle bytes;
- malicious function trying resource exhaustion or data exfiltration;
- compromised worker guest sending arbitrary internal protocol messages;
- compromised downstream service;
- supply-chain attacker modifying QuickJS, OCaml packages, or images;
- privileged operator error.

## 31.3 Threat and mitigation table

| Threat | Primary mitigation | Residual risk |
|---|---|---|
| QuickJS memory corruption | one tenant per HVT worker; minimal devices; disposable guest | hypervisor escape or shared-host side channel |
| C stub use-after-free | small FFI surface, ownership table, ASan/UBSan, fuzzing, deterministic teardown | native-code defects remain possible |
| Infinite loop | QuickJS interrupt handler and gateway deadline | interrupt granularity and native engine stalls |
| Heap exhaustion | custom allocator, engine and whole-invocation limits, worker memory class | OCaml/runtime overhead not perfectly attributable |
| Promise/microtask bomb | job batch limit, deadline, pending-Promise cap | CPU consumed before interrupt check |
| SSRF | named origins, DNS/IP validation, redirect reauthorization, blocked ranges | DNS/TLS implementation defects |
| Cross-invocation state leak | fresh runtime, zero/replace sensitive buffers where practical, worker recycle | allocator remnants inside compromised guest |
| Cross-tenant data access | tenant-bound capabilities, HVT boundary, separate worker lease | control-plane policy bug |
| Artifact tampering | content digest, canonical bundle, worker revalidation, signed images | hash implementation or key compromise |
| Bytecode exploit | reject user bytecode, compile source in pinned engine | source compiler/parser vulnerabilities still exist |
| Log injection | structured wrapper, reserved fields, byte/depth limits | misleading user message content |
| Replay of internal message | lease ID, attempt, token expiration, mTLS, nonce | clock/skew and key-management errors |
| Metadata corruption | serialized writer, journal/checkpoint, invariants, backups | storage implementation defects |
| Launcher abuse | Albatross least-privilege processes, mTLS, resource policy | host compromise remains in TCB |
| Supply-chain replacement | pinned hashes, locked dependencies, SBOM, signed artifacts, reproducible-build effort | compiler/toolchain trust |

## 31.4 Security review gates

A security review is required before:

- enabling arbitrary tenant source;
- enabling outbound HTTP;
- enabling secret operations;
- allowing multiple tenants in one worker;
- reusing a runtime or context;
- accepting a new package format;
- enabling dynamic import;
- changing QuickJS version or patch set;
- adding shared block devices or shared memory;
- claiming confidential-computing properties.

# 32. Operations and rollout

## 32.1 Immutable images

Build outputs:

```text
mirage-lambda-control-<git>-<lockdigest>.hvt
mirage-lambda-worker-<git>-<lockdigest>.hvt
manifest-control.json
manifest-worker.json
SBOM.spdx.json
checksums.txt
signatures/
```

The image digest is part of worker registration and scheduler compatibility. Upgrades create new workers; they do not patch a running guest.

![Build and delivery pipeline](mirage_lambda_guide_assets/08_delivery_pipeline.png)

*Figure 8. The delivery unit is a pinned, inspected, signed machine image rather than an in-place package update.*

## 32.2 Rolling worker update

```text
1. Add new image class to launcher inventory.
2. Launch a small canary pool.
3. Run synthetic deployments and invocations.
4. Compare error and latency metrics.
5. Direct new assignments to the new class gradually.
6. Drain old workers after active invocation completion.
7. Destroy old workers.
8. Keep rollback image and registry compatibility window.
```

A control-plane update follows an active/passive or restart-and-recover model initially. Do not run two metadata writers against one local Chamelon block image.

## 32.3 Backup

For a single-node control plane:

- periodically quiesce the metadata writer or create an application-level checkpoint;
- copy the state image through an operator-controlled process;
- store image digest and journal sequence;
- test restoration regularly;
- keep artifact objects separately exportable by digest.

A future highly available control plane likely needs an external replicated metadata service or a purpose-built replication protocol; local block storage is not a hidden distributed database.


# Part IV - Concrete implementation program

# 33. Delivery strategy and dependency graph

The service must be built in an order that separates three classes of uncertainty:

1. **Language-runtime uncertainty:** whether the chosen QuickJS release can be embedded safely and predictably through a small OCaml/C interface.
2. **Unikernel portability uncertainty:** whether the engine core and the selected Mirage libraries compile and behave correctly on the Solo5 HVT target.
3. **Distributed-service uncertainty:** whether deployment, scheduling, leases, recovery, and orchestration preserve the specified semantics under failure.

Trying to solve all three at once produces opaque failures. A crash could originate in user JavaScript, the QuickJS engine, an OCaml root-lifetime mistake, a missing freestanding-libc function, a Mirage device implementation, or the launcher. The implementation sequence therefore moves through progressively stronger environments while keeping interfaces stable.

```text
                         ┌──────────────────────┐
                         │ Phase 0: feasibility │
                         └──────────┬───────────┘
                                    │
                  ┌─────────────────┴─────────────────┐
                  │                                   │
        ┌─────────▼──────────┐              ┌─────────▼──────────┐
        │ Common contracts   │              │ QuickJS Unix port │
        │ IDs/API/bundles    │              │ FFI/limits/jobs   │
        └─────────┬──────────┘              └─────────┬──────────┘
                  └─────────────────┬─────────────────┘
                                    │
                         ┌──────────▼───────────┐
                         │ Unix worker runtime │
                         └──────────┬───────────┘
                                    │
                         ┌──────────▼───────────┐
                         │ Single-appliance MVP │
                         └──────────┬───────────┘
                                    │
              ┌─────────────────────┴────────────────────┐
              │                                          │
     ┌────────▼─────────┐                       ┌────────▼─────────┐
     │ HVT control plane│                       │ HVT worker port  │
     └────────┬─────────┘                       └────────┬─────────┘
              └─────────────────────┬────────────────────┘
                                    │
                         ┌──────────▼───────────┐
                         │ Fleet + launcher    │
                         └──────────┬───────────┘
                                    │
                         ┌──────────▼───────────┐
                         │ Security/reliability│
                         └──────────┬───────────┘
                                    │
                         ┌──────────▼───────────┐
                         │ Production readiness│
                         └──────────────────────┘
```

## 33.1 Effort notation

This plan uses relative effort rather than calendar promises:

| Class | Meaning |
|---|---|
| S | Localized change with known APIs and limited integration risk |
| M | Several modules or one meaningful integration boundary |
| L | Cross-cutting subsystem with failure semantics and substantial tests |
| XL | Research or integration uncertainty requiring a spike before commitment |

Effort class is not elapsed time. A small C change can be high risk; a large amount of mechanical OCaml code can be low risk.

## 33.2 Stage-gate rule

A phase is complete only when all of the following exist:

- merged implementation;
- automated tests covering normal and failure behavior;
- updated public interfaces and schemas;
- an architecture decision record for any changed invariant;
- an executable demonstration;
- a short evidence report containing command lines, versions, measurements, and unresolved risks.

Do not advance because a happy-path demo happened once. The point of a gate is to convert an assumption into evidence.

# 34. Phase 0 - Feasibility and toolchain lock

**Objective:** prove that the exact toolchain and the smallest required QuickJS facilities work on Unix and HVT before the service architecture accumulates around them.

**Effort:** XL because the C/freestanding compatibility surface is not known until compiled.

## 34.1 Required outputs

Create:

```text
docs/adr/0000-toolchain-baseline.md
qjs/vendor/quickjs-2026-06-04/
qjs/test/probe.ml
qjs/test/probe.js
qjs/c/qjs_port_unix.c
qjs/c/qjs_port_solo5.c
scripts/build-unix-probe.sh
scripts/build-hvt-probe.sh
docs/evidence/phase-0.md
```

Pin:

- OCaml compiler version;
- Mirage, Solo5, `ocaml-solo5`, Dune, TLS, HTTP, KV, and crypto packages;
- QuickJS release archive digest;
- C compiler and linker versions used for release builds;
- the exact HVT tender and Albatross versions used in integration tests.

`opam.locked` and the vendored QuickJS digest become release inputs. Do not track a moving QuickJS branch in production builds.

## 34.2 Feasibility probes

The probe must demonstrate all of these independently:

1. Create and destroy `JSRuntime` and `JSContext` repeatedly.
2. Evaluate `1 + 2` and extract the integer result.
3. Load a two-module ECMAScript program using the custom module loader.
4. Call an exported async handler and drain the QuickJS job queue.
5. Create a host Promise, retain its resolving functions, and settle it later from the OCaml event loop.
6. Enforce a small heap limit and observe a controlled out-of-memory error.
7. Enforce a stack limit with recursive JavaScript.
8. Interrupt `while (true) {}` using the public interrupt callback.
9. Receive an unhandled Promise rejection through the rejection tracker.
10. Build and execute the same probe on the Unix target and Solo5 HVT target.
11. Run at least 100,000 create/evaluate/destroy cycles under ASan/UBSan on Unix without leaks or invalid accesses attributable to the wrapper.

Minimal probe behavior:

```javascript
// qjs/test/probe.js
import { later } from "host:test";

export default async function main(input, env) {
  const x = await later(input.x);
  return { answer: x + 1, hasClock: Boolean(env.clock) };
}
```

Expected state trace:

```text
runtime-created
module-compiled
handler-called
host-request-created id=1
job-queue-empty waiting=1
host-request-completed id=1
promise-resolved
job-executed
handler-fulfilled
runtime-destroyed live-handles=0
```

## 34.3 Missing-symbol audit

Compile QuickJS engine objects against the target libc and record every unresolved symbol. Classify each as:

- already supplied by the Mirage/Solo5 libc;
- linkable through the target math library;
- replaceable by a small deterministic shim;
- reachable only from excluded CLI/POSIX code;
- unacceptable and requiring an engine patch or design change.

The evidence document should contain a table like:

| Symbol | Referenced by | Unix availability | HVT availability | Decision |
|---|---|---|---|---|
| `malloc_usable_size` | allocator/accounting path | platform-specific | unknown | avoid through custom allocator |
| `clock_gettime` | optional time path | yes | target-dependent | host-provided JS clock only |
| `dlopen` | standard module loader | yes | no | exclude `quickjs-libc.c` |
| `pthread_create` | QuickJS worker helper | yes | unsuitable | exclude worker API |

Do not invent shims blindly. A shim must preserve the semantics QuickJS actually depends on, or the dependent path must be removed.

## 34.4 Phase 0 exit gate

The gate passes only when:

- both target probes execute with the pinned toolchain;
- memory and stack limits fail cleanly;
- the infinite-loop interrupt terminates within the documented tolerance;
- async Promise settlement works without re-entering OCaml from a foreign thread;
- all C/OCaml ownership rules are documented beside the wrapper;
- the HVT image boots and reports its QuickJS, OCaml, Mirage, and build digests;
- no unresolved critical libc dependency remains;
- the team has an explicit go/no-go record.

A no-go does not imply abandoning the service. Fallbacks include quickjs-ng after a separate audit, a small WebAssembly guest engine, or keeping the worker on minimal Linux while the Mirage control plane work proceeds. Such a fallback requires a new ADR because it changes the trusted computing base.

# 35. Phase 1 - Domain model, schemas, and pure common library

**Objective:** define service semantics as pure OCaml types and deterministic encoders before adding devices, HTTP servers, or QuickJS handles.

**Effort:** L.

## 35.1 Work items

Implement in this order:

1. Validated identifier types in `common/ids.ml`.
2. Bounded byte/string types in `common/bounded_bytes.ml`.
3. Stable error taxonomy in `common/error.ml`.
4. Resource arithmetic in `common/budget.ml`.
5. Capability grants and compiled policy in `common/capability.ml`.
6. Strict manifest parser in `common/manifest.ml`.
7. Deterministic bundle parser/writer in `common/bundle.ml`.
8. Internal envelopes in `common/protocol.ml`.
9. Canonical JSON in `common/canonical_json.ml`.
10. JSON Schema and OpenAPI fixtures under `api/`.

The common library must not depend on `Unix`, Lwt, Mirage devices, TLS, QuickJS, or a particular JSON HTTP framework. Pure code is easier to fuzz and can be reused by CLI, control plane, worker, and test tooling.

## 35.2 Identifier example

Do not expose `string` constructors for identifiers:

```ocaml
module Function_name : sig
  type t

  val of_string : string -> (t, Error.Validation.t) result
  val to_string : t -> string
  val compare : t -> t -> int
end
```

Validation policy should be explicit:

```text
length: 1..63 bytes
alphabet: lowercase ASCII letters, digits, hyphen
first/last: alphanumeric
forbidden: slash, dot segments, percent-encoding, Unicode confusables
```

This makes path and storage-key construction reviewable.

## 35.3 Property tests

Required properties include:

```text
decode(encode(x)) = x
encode(decode(bytes)) = canonical(bytes) for valid inputs
invalid identifiers never produce a storage path
bundle parser consumes exactly the declared lengths
manifest unknown fields are rejected
budget subtraction never underflows
capability intersection never grants more authority than either operand
canonical JSON is deterministic across map insertion order
```

Fuzz the bundle and manifest parsers before either reaches QuickJS. Parsing should return structured errors, never uncaught exceptions.

## 35.4 Phase 1 exit gate

- Schemas and OCaml decoders agree on a corpus of valid and invalid fixtures.
- All types used across process/VM boundaries have explicit version fields.
- Public errors have stable codes and safe messages.
- Fuzzing finds no crash on a significant generated corpus.
- `common/` builds for Unix and the target switch without accidental Unix dependencies.

# 36. Phase 2 - QuickJS embedding on Unix

**Objective:** construct a minimal, auditable engine library with hard ownership and accounting rules while normal debugger and sanitizer tooling is available.

**Effort:** XL.

## 36.1 Wrapper layers

Use three layers rather than exposing raw QuickJS throughout the repository:

```text
QuickJS C API
    │
    ▼
qjs_stubs.c
    native ownership, callbacks, host-request queue, allocator
    │
    ▼
Qjs_handle / Qjs_engine
    OCaml abstract handles, errors, lifecycle
    │
    ▼
Runtime_host
    service semantics, capabilities, serialization, deadlines
```

Only `qjs/c/` includes `quickjs.h`. Only `qjs/lib/` uses the private foreign primitives. The worker imports the stable `QJS_ENGINE` interface.

## 36.2 Required engine features

Implement in this order:

- runtime/context creation and deterministic destruction;
- evaluation of a memory-owned source buffer;
- exception extraction without arbitrary recursive object inspection;
- module normalization and loading from the verified bundle map;
- export lookup and handler call;
- Promise result observation;
- pending-job execution with a per-turn batch bound;
- host-request enqueueing;
- Promise settlement from OCaml;
- memory, stack, deadline, and job-count enforcement;
- rejection tracking;
- per-runtime diagnostics and leak assertions.

Defer:

- inspector/debug protocol;
- snapshots or bytecode caches;
- runtime reuse;
- shared contexts;
- standard QuickJS OS module;
- NPM compatibility;
- dynamic network imports;
- native extensions.

## 36.3 Ownership table

Maintain this table in `qjs/README.md` and update it with every API addition:

| Object | Creator | Owner while live | Release action | May cross async wait? |
|---|---|---|---|---|
| `JSRuntime *` | C wrapper | `Qjs_handle.t` | `JS_FreeRuntime` | yes, invocation lifetime |
| `JSContext *` | C wrapper | runtime wrapper | `JS_FreeContext` | yes |
| handler `JSValue` | module loader | wrapper | `JS_FreeValue` | yes if duplicated/rooted |
| Promise resolving functions | QuickJS | request registry | `JS_FreeValue` each | yes |
| module source bytes | OCaml/bundle | module registry | OCaml ownership until compile done | bounded |
| host request payload | C callback | C queue, then OCaml copy | queue destructor | yes |
| OCaml callback/root | OCaml | wrapper | unregister root before free | yes |

The invariant is:

```text
on runtime destruction:
    pending_host_requests = 0
    rooted_OCaml_values = 0
    retained_JSValues = 0
    contexts = 0 before runtime free
```

## 36.4 Sanitizer configuration

For Unix test builds:

```text
CFLAGS:
  -O1 -g3
  -fno-omit-frame-pointer
  -fsanitize=address,undefined
  -Wall -Wextra -Wconversion -Wshadow

LDFLAGS:
  -fsanitize=address,undefined
```

Run engine lifecycle tests with leak detection. Also run a non-sanitized optimized build because sanitizer timing can mask or create deadline behavior.

## 36.5 Phase 2 exit gate

- The wrapper passes all Phase 0 probes through the public OCaml interface.
- Every foreign primitive documents whether it allocates, can raise, can release the OCaml runtime lock, and may call into QuickJS.
- Random invalid source and module graphs cannot crash the wrapper under sanitizers.
- The wrapper reports precise resource-exhaustion classes.
- Runtime destruction is safe after failure at every construction step.
- The test suite proves no user bytecode path exists.

# 37. Phase 3 - Unix worker runtime

**Objective:** implement the complete execution semantics in a normal process, with fake or in-memory capabilities.

**Effort:** L.

## 37.1 First JavaScript host API

Keep the initial API deliberately small:

```javascript
export default async function main(input, env, ctx) {
  env.log.info("start", { invocation: ctx.invocationId });
  const existing = await env.kv.get("counter");
  const next = Number(existing ?? 0) + 1;
  await env.kv.put("counter", String(next));
  return { next, now: env.clock.monotonicMs() };
}
```

Version 1 host surface:

```text
env.log.debug/info/warn/error
env.crypto.randomBytes
env.clock.monotonicMs
env.kv.get/put/delete/list
env.http.fetch                 disabled until security phase
env.functions.invoke          disabled until fleet semantics exist
ctx.invocationId
ctx.attempt
ctx.deadlineMs
ctx.remainingMs()
ctx.abortSignal                optional after cancellation bridge exists
```

Use plain JSON-compatible values and byte arrays. Do not initially expose arbitrary host objects with deep prototype behavior.

## 37.2 Worker event loop

The worker owns the only transition path between QuickJS and Lwt:

```ocaml
let rec drive inv =
  enforce_control_deadline inv;
  enforce_output_limits inv;

  match Qjs_engine.observe inv.engine with
  | Qjs_engine.Finished value ->
      serialize_and_finish inv value

  | Qjs_engine.Rejected js_error ->
      fail inv (Error.Js js_error)

  | Qjs_engine.Host_requests requests ->
      let tasks = List.map (dispatch_host_request inv) requests in
      Lwt.async (fun () -> settle_completed inv tasks);
      run_job_turn inv

  | Qjs_engine.Runnable ->
      run_job_turn inv

  | Qjs_engine.Waiting ->
      wait_for_host_completion_or_deadline inv
```

`run_job_turn` executes at most `max_jobs_per_turn`; this prevents one chain of microtasks from starving deadline checks and completed host operations.

## 37.3 Fake capability implementations

Provide deterministic fakes:

- `Host_kv.Memory`: namespaced map with configurable failures.
- `Host_clock.Scripted`: sequence of monotonic values.
- `Host_crypto.Deterministic`: test-only seeded output.
- `Host_log.Buffer`: bounded structured events.
- `Host_http.Scripted`: no real network; predefined responses and delays.
- `Host_invoke.Fake`: records child requests and returns scripted results.

These fakes make record/replay and fault testing possible before Mirage integration.

## 37.4 Phase 3 exit gate

- A valid async module can call KV and return a result.
- Missing capabilities fail with a stable authorization error before any device operation.
- Deadline, memory, stack, output, log, Promise, module, and host-call limits are exercised.
- Cancellation cleans every pending request and destroys the runtime.
- Two successive invocations cannot observe each other's JS globals or capability data.
- A deterministic event script reproduces the same result and trace.

# 38. Phase 4 - Single-appliance service on Unix

**Objective:** assemble deployment, registry, invocation API, scheduler, and worker runtime in one Unix-target process. This is the functional MVP, not the hostile-tenant production architecture.

**Effort:** L.

## 38.1 Scope

Implement:

- authenticated development API;
- bundle upload and strict validation;
- content-addressed artifact store using a Unix-directory implementation;
- in-memory registry with checkpoint serialization;
- alias publication;
- synchronous invocation;
- asynchronous queue and result lookup;
- tenant quotas;
- worker slots represented by in-process runtimes;
- structured logs and metrics;
- CLI commands for bundle, deploy, invoke, inspect, and tail logs.

Do not yet implement:

- cross-tenant security claims;
- real launcher integration;
- external egress;
- secrets;
- high availability;
- runtime reuse.

## 38.2 End-to-end demonstration

The demonstration script should be reproducible:

```text
1. Create tenant and development credential.
2. Build `examples/counter/` into MLB1.
3. Deploy immutable revision.
4. Move alias `prod` to the revision.
5. Invoke synchronously and inspect trace.
6. Invoke asynchronously and poll result.
7. Submit a looping function and observe deadline termination.
8. Submit an oversized result and observe bounded failure.
9. Restart process and recover registry/checkpoint.
10. Show that content digest and revision ID remain stable.
```

## 38.3 Phase 4 exit gate

- The OpenAPI contract drives integration tests.
- Deployment and invocation are usable entirely through the CLI.
- Quota overload returns the documented status and retry metadata.
- Recovery tests cover interruption after every persistence step.
- Metrics distinguish queue, engine, host-call, and serialization time.
- The documentation labels this mode as trusted/single-tenant only.

# 39. Phase 5 - Mirage control-plane unikernel

**Objective:** move the public service plane to Mirage while preserving the API, actor boundaries, and registry semantics proven on Unix.

**Effort:** XL.

## 39.1 Device composition

The initial control image needs:

```text
network stack
TLS server configuration
HTTP server
monotonic clock
wall clock only where certificate/protocol semantics require it
cryptographic entropy
Mirage_kv.RW state store
console/log sink
optional metrics export client
```

The `config.ml` must make each device explicit. Keep command-line keys limited to non-secret boot configuration; provision long-lived secrets through a designed secure path rather than casually embedding them in the image or command line.

## 39.2 Porting order

1. Boot and readiness endpoint.
2. TLS and authenticated health/admin route.
3. Read-only registry backed by Mirage KV.
4. Metadata writer and recovery.
5. Artifact upload and immutable object reads.
6. Deployment APIs.
7. Queue/admission logic with fake workers.
8. Telemetry export and backup hooks.

This sequence isolates storage and TLS issues before launcher/fleet behavior.

## 39.3 State-image tests

Use a matrix:

| Case | Expected result |
|---|---|
| Empty formatted store | initializes schema once |
| Known current schema | recovers and becomes ready |
| Older migratable schema | performs explicit migration or refuses without flag |
| Newer schema | refuses read-write startup |
| Missing object referenced by revision | quarantines revision and reports invariant failure |
| Truncated journal record | stops at last valid record; requires policy-based repair |
| Power loss between temp write and rename | no partially published revision |

## 39.4 Phase 5 exit gate

- The HVT control image serves authenticated TLS endpoints.
- State survives guest destruction and recreation on the same block image.
- Recovery and migration behavior is tested with corrupted fixtures.
- The image has no QuickJS dependency in fleet configuration.
- Device manifest and network exposure match the architecture document.

# 40. Phase 6 - Mirage QuickJS worker unikernel

**Objective:** move the proven worker runtime to an isolated HVT guest with no persistent service state.

**Effort:** XL.

## 40.1 Worker image contents

The worker image should contain only:

- private HTTP/TLS server or compact framed protocol server;
- internal authentication and lease validation;
- artifact fetch client;
- in-memory bounded artifact cache;
- QuickJS engine wrapper;
- capability broker and approved host clients;
- structured event output;
- lifecycle/recycling logic.

It should omit:

- public deployment endpoints;
- tenant credential database;
- metadata writer;
- general block filesystem;
- shell or debug daemon;
- unrestricted DNS/network access;
- package installation.

## 40.2 HVT-specific validation

Test:

- repeated runtime creation/destruction within the guest;
- behavior at guest memory pressure;
- stack-limit interaction with Solo5/OCaml stack behavior;
- monotonic deadline behavior;
- console/log volume control;
- malformed internal protocol messages;
- loss of control-plane connection;
- artifact-cache accounting;
- deterministic guest termination after recycle threshold.

## 40.3 Phase 6 exit gate

- A worker boots, registers, receives a signed assignment, fetches by digest, executes, and returns a result.
- Invalid or expired leases are rejected.
- The worker has no persistent block device.
- A killed worker cannot corrupt control-plane state.
- A deliberate QuickJS process-level abort terminates only the worker guest in the test environment.
- Worker memory and CPU class are enforced at launcher level in addition to engine budgets.

# 41. Phase 7 - Fleet orchestration and scheduling

**Objective:** turn control and worker images into a functioning multi-worker service with lease-based reconciliation.

**Effort:** XL.

## 41.1 Launcher adapter contract

Implement the `LAUNCHER` interface first against a fake, then a Unix-process adapter, then Albatross:

```ocaml
module type LAUNCHER = sig
  type t
  type error

  val ensure_class :
    t -> Worker_class.t -> (unit, error) result Lwt.t

  val launch :
    t -> Worker_spec.t -> (Worker_id.t, error) result Lwt.t

  val destroy :
    t -> Worker_id.t -> (unit, error) result Lwt.t

  val list :
    t -> (Observed_worker.t list, error) result Lwt.t

  val console_tail :
    t -> Worker_id.t -> max_bytes:int ->
    (Bounded_bytes.t, error) result Lwt.t
end
```

The control plane reconciles desired and observed state. It must tolerate launcher request timeouts by listing observed workers rather than assuming whether a launch succeeded.

## 41.2 Reconciliation loop

```ocaml
let rec reconcile t =
  let* observed = Launcher.list t.launcher in
  let now = Clock.now () in

  Worker_pool.expire_leases t.pool ~now;
  Worker_pool.merge_observed t.pool observed;
  Worker_pool.mark_missing_dead t.pool;

  let desired = Capacity.desired_workers t.capacity t.queues t.pool in
  let actions = Capacity.diff ~desired ~observed:t.pool in
  let* () = execute_bounded actions in

  Scheduler.assign_ready t.scheduler t.pool;
  Clock.sleep t.config.reconcile_interval >>= fun () ->
  reconcile t
```

Every launch request carries an idempotency token or deterministic desired-worker ID if supported. A launch whose response is lost must not cause an unbounded duplicate storm.

## 41.3 Warm-pool behavior

Start with a small static pool per compatibility class. Autoscaling inputs:

- ready queue length and age;
- warm/ready worker count;
- worker boot latency distribution;
- recent execution duration;
- configured minimum and maximum;
- launcher and host pressure.

Use hysteresis and bounded scale steps. Avoid scaling directly from a single instantaneous queue measurement.

## 41.4 Phase 7 exit gate

- At least two HVT workers execute independent invocations.
- Worker loss before and after start acknowledgment follows the documented retry rules.
- Control restart reconstructs worker observations and expires stale leases.
- Launcher timeouts and duplicate observations are idempotent.
- Tenant fairness is demonstrated under a noisy-neighbor workload.
- Rolling worker-image replacement drains old workers without losing admitted work beyond stated semantics.

# 42. Phase 8 - Capability security, egress, and secrets

**Objective:** make host operations suitable for hostile tenant code rather than merely functionally correct.

**Effort:** XL.

## 42.1 Capability compiler

Compile the function manifest and tenant policy into a compact runtime grant:

```text
requested manifest capabilities
        ∩ tenant maximum policy
        ∩ service global policy
        ∩ invocation-specific delegation
        = invocation grant
```

The grant is immutable and bound to:

```text
tenant ID
function revision digest
invocation ID
attempt
worker lease
deadline
```

A worker must not trust a free-form capability list supplied by the caller. It receives a signed or mutually authenticated control-plane envelope.

## 42.2 Egress rollout

Enable outbound HTTP only after these exist:

- named-origin capability representation;
- strict URL parser;
- scheme restriction to HTTPS by default;
- DNS answer validation against blocked ranges;
- connection target binding to the validated address;
- redirect reauthorization on every hop;
- host, path, method, header, request-byte, response-byte, and duration limits;
- TLS hostname verification;
- bounded decompression or no transparent decompression initially;
- audit event for each attempt;
- downstream circuit breaker and concurrency limit.

Tests must include IPv4, IPv6, mixed encodings, decimal/octal/hex address forms where the parser accepts them, DNS rebinding simulations, redirects, user-info fields, Unicode hostnames, link-local ranges, metadata-service addresses, and oversized compressed responses.

## 42.3 Secrets

A secret capability should expose operations, not raw broad access:

```javascript
const token = await env.secrets.get("stripe-api-token");
```

is simple but leaves secret bytes in the JS heap. Prefer narrower operations where practical:

```javascript
const response = await env.http.fetchSigned("stripe", request);
```

where the worker or a dedicated broker adds the secret. When raw secret access is required:

- limit secret names in the manifest;
- bind to revision and tenant;
- never log values;
- bound secret size;
- avoid including secret values in exceptions;
- expire worker credentials;
- destroy the runtime after invocation;
- recycle the worker more aggressively after secret-bearing invocations.

## 42.4 Phase 8 exit gate

- Negative authorization tests outnumber happy-path capability tests.
- Egress passes an SSRF-focused review and adversarial test suite.
- Secrets are absent from logs, traces, error bodies, core artifacts, and worker registration data.
- Capability grants are auditable by invocation ID.
- A compromised function cannot request a capability not present in its immutable grant through dynamic import or forged host messages.

# 43. Phase 9 - Reliability, security, and performance hardening

**Objective:** establish evidence for sustained operation and document residual risk.

**Effort:** XL.

## 43.1 Reliability campaign

Run long-lived and fault-injected tests covering:

- repeated deployments and alias changes;
- millions of runtime lifecycles;
- control-plane restarts during every state transition;
- worker termination during fetch, load, execution, host wait, and result upload;
- state-volume exhaustion;
- artifact corruption;
- launcher unavailability;
- internal TLS certificate rotation;
- DNS and downstream service failures;
- slow clients and partial uploads;
- queue overload and recovery;
- telemetry sink outage;
- wall-clock correction while monotonic deadlines continue.

Track invariant violations rather than only request success rate.

## 43.2 Security campaign

Required activities:

- independent review of the C wrapper and allocator;
- fuzzing of bundle, manifest, protocol, module resolver, result serializer, and host callback decoders;
- dependency and license inventory;
- reproducibility comparison across two clean build hosts where feasible;
- KVM/HVT/Albatross hardening review;
- public/private network reachability scan;
- malformed TLS and HTTP traffic tests;
- worker escape exercise using a deliberately injected native crash/corruption test build;
- secret and cross-tenant canary tests;
- source-to-image provenance verification.

Do not claim the system is “memory safe.” The OCaml majority reduces some classes of defects; QuickJS, cryptographic/native libraries, Solo5, the hypervisor, and C stubs remain native trusted code.

## 43.3 Performance campaign

Measure separately:

```text
public TLS + HTTP ingress
admission and queueing
worker selection
cold worker boot
artifact fetch
runtime creation
module compilation
handler execution
host-call latency
Promise/job overhead
result serialization
internal transport
cleanup/recycle
```

Report median and tail distributions, not only averages. Include offered load, concurrency, input/result sizes, function source size, warm-pool state, host CPU model, guest memory class, compiler flags, and image digests.

## 43.4 Phase 9 exit gate

- No known critical memory-lifetime defect remains in the wrapper.
- Recovery/fault suites run automatically in release qualification.
- Capacity limits and overload behavior are documented from measurements.
- Performance regressions are compared against stored baselines.
- Residual risks have named owners and operating mitigations.
- Security claims are phrased at the correct boundary.

# 44. Phase 10 - Production readiness and optional research extensions

**Objective:** make the system operable by someone other than its authors, then explore more novel architecture without destabilizing the core.

**Effort:** L for basic operations; XL for each research extension.

## 44.1 Production-readiness work

Produce:

- signed control and worker images;
- SBOM and dependency lock;
- deployment/runbook for launcher, networking, certificates, state image, and backup;
- readiness/liveness semantics;
- capacity worksheet;
- alert catalogue and dashboard definitions;
- incident procedures for worker crash loops, storage recovery, credential compromise, and bad image rollout;
- rollback procedure tested against the previous image version;
- compatibility policy for manifests, bundles, internal protocol, state schema, and worker versions;
- operator and tenant-facing documentation;
- secure development and vulnerability response process.

## 44.2 Research extension: deterministic execution log

Represent all nondeterministic observations as events:

```ocaml
type event =
  | Monotonic_now of int64
  | Random_bytes of bytes
  | Kv_result of Request_id.t * kv_result
  | Http_result of Request_id.t * http_result
  | Child_result of Request_id.t * invocation_result
  | Scheduler_yield of int
```

A recording handler appends bounded events. A replay handler refuses real device access and consumes the recorded sequence. The function digest, input, grant, engine version, and event log then define an execution replay artifact.

This is valuable for debugging, but event logs may contain secrets or personal data and require separate retention/encryption policy.

## 44.3 Research extension: movable protection boundaries

Keep the logical capability interface stable while changing its transport:

```text
same component: direct OCaml call
same guest: bounded Lwt mailbox
same host: private HVT network or shared-memory transport
remote host: mutually authenticated TLS
```

A deployment compiler could choose placement based on trust, latency, and failure isolation. This requires stable protocol semantics and is not a substitute for first implementing one transport correctly.

## 44.4 Research extension: snapshot-based cold start

Potential experiment:

```text
boot worker
initialize OCaml runtime and QuickJS engine support
load common libraries or function bundle
reach a quiescent point
snapshot guest
clone snapshot per tenant or invocation
inject fresh identity, lease, input, and entropy after restore
```

Security questions dominate this work:

- duplicated PRNG state;
- duplicated TLS state or sequence numbers;
- stale clocks and lease data;
- shared secret remnants;
- replayed object IDs;
- snapshot compatibility with image and CPU features.

Never snapshot after tenant secrets or invocation input are loaded unless the snapshot is tenant-private and lifecycle-managed accordingly.

## 44.5 Research extension: per-invocation microVM

The strongest simple boundary is one worker per invocation. Measure whether prebooted/snapshotted HVT guests make this economical. Compare:

- boot-to-register latency;
- memory footprint;
- artifact injection cost;
- throughput per host core;
- cleanup assurance;
- operational pressure on the launcher.

The likely production compromise remains one HVT guest per tenant with fresh QuickJS runtimes inside, but measurement should decide.

# 45. Intern onboarding and first contribution sequence

The intern should not begin by editing `quickjs.c` or the scheduler. The onboarding path teaches each boundary in isolation.

## 45.1 Concepts to understand first

The intern should be able to explain:

- the difference between a Mirage library OS and a Linux process;
- why Solo5 is an execution interface rather than a fleet orchestrator;
- why QuickJS runtime isolation is not native memory isolation;
- why the service exposes capabilities instead of Node APIs;
- why source bundles are immutable and content-addressed;
- why deadlines use monotonic time;
- why a Promise bridge needs explicit ownership of resolving functions;
- why the control plane uses one metadata writer;
- why assignment leases exist;
- what at-most-once, at-least-once, and exactly-once claims mean;
- why overload behavior is part of correctness.

## 45.2 Reading order

Read these repository files before the first implementation PR:

```text
docs/architecture.md
docs/threat-model.md
docs/adr/0001-quickjs-engine.md
docs/adr/0002-hvt-tenant-boundary.md
api/function-manifest.schema.json
api/worker-protocol.md
common/error.mli
common/budget.mli
common/capability.mli
qjs/lib/qjs_engine.mli
worker/invocation.mli
control/scheduler.mli
launcher/launcher.mli
```

Then inspect the upstream files listed in Appendix E. The purpose is not to memorize APIs; it is to learn where the project's claims come from.

## 45.3 First seven pull requests

Use small, independently reviewable PRs:

1. **Build metadata endpoint:** add a pure module that renders image, OCaml, Mirage, Solo5, QuickJS, lock, and Git digests. No C changes.
2. **Validated identifier type:** implement `Function_name` and its property tests.
3. **Bounded bytes:** implement input/result limits and overflow tests.
4. **Manifest fixture:** add one valid and a thorough invalid corpus tied to the JSON Schema.
5. **QuickJS probe runner:** invoke an already provided C wrapper and report structured results; do not alter ownership yet.
6. **Fake KV capability:** implement deterministic namespaced KV with injected error cases.
7. **One end-to-end host call:** wire `env.kv.get` through fake capability, Promise bridge, and result serialization in Unix tests.

This sequence gives exposure to pure OCaml, schema discipline, the engine abstraction, asynchronous execution, and tests without assigning an intern an unbounded subsystem.

## 45.4 Development rules

- Read the `.mli` before the `.ml`.
- Add a failing test before fixing a bug where practical.
- Treat every byte length from outside the current module as untrusted.
- Never store a raw tenant/function/module identifier as a filesystem or KV path segment.
- Never retain a `JSValue` across a call without documenting duplication/ownership.
- Never call OCaml from a C thread that is not registered and under the runtime rules; the project architecture avoids such threads entirely. [OCAML-FFI]
- Never block the worker event loop on a host operation.
- Never log source, input, result, headers, secrets, or engine exception objects by default.
- Never loosen a manifest/capability schema in an implementation-only change.
- Never add a Unix dependency to a target library to make a test convenient.

## 45.5 How to debug a failed invocation

Use this order:

```text
1. Identify invocation ID, revision digest, worker ID, lease, and image digest.
2. Locate the control-plane state transition trace.
3. Determine whether failure occurred before assignment, before start, or after start.
4. Inspect worker lifecycle and bounded console tail.
5. Check engine classification: load, JS exception, resource, host, internal.
6. Check pending host requests and deadline at failure.
7. Reproduce on Unix using the exact bundle, input, manifest, and grant.
8. Run sanitizer build if native failure is suspected.
9. Use deterministic/scripted capabilities or replay artifact where available.
10. Minimize the bundle and add a regression fixture before changing code.
```

Do not begin by increasing limits or retry counts. That can hide ownership bugs and nontermination.

# 46. Engineering workflow, review, and evidence

## 46.1 Pull-request checklist

Every significant PR states:

- which invariant or API changes;
- which files are security-sensitive;
- maximum new input sizes or queue growth;
- error and cleanup behavior;
- target compatibility: Unix, HVT, or host-only;
- tests added;
- benchmark impact where relevant;
- schema/protocol compatibility impact;
- whether an ADR is required.

## 46.2 Sensitive-code ownership

Require specialist review for:

```text
qjs/vendor/ and qjs/c/
worker/capability_broker.*
worker/host_http.*
common/capability.*
common/bundle.*
common/protocol.*
control/auth.*
control/metadata_writer.*
control/launcher_client.*
state migrations
TLS and certificate code
release/build provenance scripts
```

A code owner is not a guarantee of correctness; it makes review responsibility explicit.

## 46.3 Evidence directory

Each phase adds a checked-in, concise evidence document:

```text
docs/evidence/
  phase-0-toolchain.md
  phase-1-formats.md
  phase-2-quickjs-unix.md
  phase-3-worker.md
  phase-4-single-appliance.md
  phase-5-control-hvt.md
  phase-6-worker-hvt.md
  phase-7-fleet.md
  phase-8-security.md
  phase-9-qualification.md
```

Evidence documents contain:

- exact commands;
- environment and image digests;
- links to tests and fixtures;
- summarized measurements;
- known deviations;
- gate decision and reviewers.

They should not contain secrets, tenant data, or megabytes of raw logs.

# 47. Risk register and decision triggers

| Risk | Likelihood | Impact | Early signal | Mitigation | Fallback/decision trigger |
|---|---|---|---|---|---|
| QuickJS core depends on unsupported libc behavior | Medium | High | large unresolved-symbol or semantic-shim list | compile spike; exclude libc layer; custom allocator/platform boundary | change engine or keep Linux worker if core cannot pass HVT probe |
| OCaml/C ownership defect | Medium | Critical | sanitizer crash, leaked handles, nondeterministic teardown | tiny FFI; ownership table; fuzzing; specialist review | halt feature work until lifetime invariant is proven |
| QuickJS engine vulnerability compromises worker | High over system lifetime | High | upstream security advisory or exploit | one tenant per HVT worker; rapid image rebuild; no ambient authority | emergency worker image rollout; disable untrusted execution |
| Solo5 single-lane worker limits density | High | Medium | CPU saturation with idle host cores | many small workers; capacity classes; host-level parallelism | use different worker substrate for high-density workload |
| Mirage library/version incompatibility with OCaml baseline | Medium | High | solver conflict or HVT link failure | lock early; CI matrix; minimize dependencies | pin older compatible OCaml/Mirage set with ADR |
| State-store durability or corruption defect | Medium | High | invariant failure after fault tests | serialized writer; journal; checkpoint; backups | read-only recovery mode; restore known checkpoint |
| Albatross API/operational mismatch | Medium | Medium | inability to express idempotent launch or required network policy | adapter; fake launcher; explicit observed-state reconciliation | build narrow custom host agent or alternate VMM adapter |
| Public API overpromises delivery semantics | Medium | High | duplicate side effects during worker failure | explicit attempt/idempotency model; tests; docs | disable automatic retry for affected class |
| SSRF or capability bypass | Medium | Critical | parser differential or blocked-address connection | named origins; revalidation; broker; negative tests | disable egress capability globally |
| Artifact/result/log storage exhaustion | High | Medium | rising retained bytes and failed writes | quotas; retention; GC; admission backpressure | reject deployments/invocations before state corruption |
| Worker credential leakage | Low/Medium | Critical | token observed in logs or reusable after lease | short-lived, bound credentials; no logging; mTLS | revoke class/CA and recycle all workers |
| Poor observability makes incidents unreproducible | Medium | High | generic `internal_error` without phase context | semantic traces; image/revision IDs; bounded console | block production rollout until failure localization works |
| Supply-chain compromise | Low/Medium | Critical | digest mismatch or unexpected dependency | pinned archives; SBOM; signed images; provenance | revoke signing material and rebuild from verified sources |
| Build is not reproducible enough for attestation claims | Medium | Medium | identical source gives differing image digest | normalize build metadata; controlled builder | weaken claim; attest source+builder rather than reproducible bits |
| Intern assigned unsafe scope too early | Medium | Medium | large FFI PR without tests or ownership analysis | staged PR sequence; pair review; interface-first tasks | re-scope to pure/common library work |

## 47.1 Decision triggers

The project should stop and revisit architecture when any of these occurs:

- the QuickJS port requires broad POSIX emulation;
- hard interruption cannot meet the service deadline tolerance;
- the worker requires persistent shared writable storage;
- the control plane must expose launcher privileges directly to public request handlers;
- a feature requires runtime reuse before isolation tests exist;
- egress authorization cannot bind DNS resolution to the actual connection target;
- metadata writes require multiple unsynchronized writers;
- HVT worker density makes the service economically or operationally infeasible;
- version constraints cannot be reproduced in clean CI;
- the system cannot identify whether an invocation started before retrying it.

Stopping at a trigger is disciplined engineering, not failure.

# 48. Definition of done for the first complete service

The first complete fleet release is done only when all categories below pass.

## 48.1 Functional

- [ ] A tenant can upload a validated source bundle and strict manifest.
- [ ] The service stores an immutable content-addressed revision.
- [ ] An alias can be atomically moved to a revision.
- [ ] Synchronous and asynchronous invocation APIs work.
- [ ] JavaScript can use the approved log, clock, random, KV, and bounded HTTP capabilities.
- [ ] Missing capabilities fail deterministically.
- [ ] Worker assignment, start acknowledgment, result, timeout, and cancellation states are observable.
- [ ] CLI and OpenAPI examples match actual behavior.

## 48.2 Isolation and security

- [ ] Mutually distrusting tenants are assigned to separate HVT workers.
- [ ] Every invocation uses a fresh QuickJS runtime.
- [ ] Memory, stack, deadline, job, host-call, log, input, and result limits are enforced.
- [ ] User bytecode, native modules, filesystem, process, and unrestricted socket APIs are absent.
- [ ] Capability grants are the intersection of manifest and policy.
- [ ] Egress passes SSRF and redirect tests.
- [ ] Secrets do not appear in logs, errors, traces, or result metadata.
- [ ] Internal worker assignments are authenticated and lease-bound.
- [ ] Images and vendored sources are pinned, inventoried, and signed.

## 48.3 Reliability

- [ ] Control-plane state recovers after tested interruption points.
- [ ] Worker crashes do not corrupt registry state.
- [ ] Retry behavior matches documented delivery semantics.
- [ ] Queue and storage overload return bounded errors rather than destabilizing the service.
- [ ] Worker and control image rolling updates have tested rollback.
- [ ] Backup restoration is exercised, not merely documented.
- [ ] Long-running lifecycle tests reveal no unbounded memory growth.

## 48.4 Operations

- [ ] Readiness indicates recovered state and usable dependencies, not merely a running event loop.
- [ ] Alerts exist for queue age, worker deficit, crash loops, storage errors, recovery quarantine, certificate expiry, and error-rate changes.
- [ ] Every incident-relevant event carries tenant-safe invocation, revision, worker, lease, and image identifiers.
- [ ] Capacity limits and warm-pool policy are measured and documented.
- [ ] On-call runbooks contain exact diagnostic and rollback commands.

## 48.5 Documentation and maintainability

- [ ] Public modules have reviewed `.mli` contracts.
- [ ] Schemas and protocols are versioned.
- [ ] Architecture decisions and residual risks are current.
- [ ] A new engineer can reproduce the Unix and HVT builds from a clean environment.
- [ ] The intern onboarding sequence has been exercised by someone who did not design the system.
- [ ] Upstream version/API references in Appendix E are rechecked for the release.

\appendix

# Appendix A - External API reference

This appendix defines the minimum public API shape. The checked-in `api/openapi.yaml` is authoritative once implementation begins.

## A.1 Authentication and common headers

Recommended headers:

```http
Authorization: Bearer <tenant credential>
Content-Type: application/json
X-Request-Id: optional caller-generated bounded identifier
Idempotency-Key: required for selected retriable operations
```

The gateway assigns a service request ID even when the caller does not. Do not echo arbitrary header values into logs without length and character validation.

## A.2 Deploy a revision

```http
POST /v1/tenants/{tenant}/functions/{function}/revisions
Content-Type: application/vnd.mirage-lambda-bundle

<MLB1 bytes>
```

Success:

```json
{
  "schemaVersion": 1,
  "function": "order-lookup",
  "revision": "sha256:6f...",
  "objectDigest": "sha256:6f...",
  "manifestDigest": "sha256:19...",
  "state": "available"
}
```

Validation failure:

```json
{
  "error": {
    "code": "invalid_manifest",
    "message": "manifest is not valid",
    "requestId": "req_01...",
    "details": [
      {
        "path": "/resources/memoryBytes",
        "reason": "exceeds tenant maximum"
      }
    ]
  }
}
```

Do not return parser stack traces or source excerpts by default.

## A.3 Move an alias

```http
PUT /v1/tenants/{tenant}/functions/{function}/aliases/{alias}
Content-Type: application/json
If-Match: "previous-version-or-*"

{
  "schemaVersion": 1,
  "revision": "sha256:6f..."
}
```

Use conditional updates to prevent two deployers silently overwriting each other.

## A.4 Invoke synchronously

```http
POST /v1/tenants/{tenant}/functions/{function}/invoke?qualifier=prod
Content-Type: application/json
Idempotency-Key: optional-unless-retry-policy-requires-it

{
  "input": { "orderId": "A-184" },
  "deadlineMs": 1000
}
```

Success:

```json
{
  "schemaVersion": 1,
  "invocationId": "inv_01...",
  "revision": "sha256:6f...",
  "attempt": 1,
  "result": { "found": true },
  "usage": {
    "engineCpuUs": 412,
    "wallUs": 1870,
    "peakJsBytes": 163840,
    "hostCalls": 1,
    "egressBytes": 0
  }
}
```

Function failure uses a non-2xx response chosen by API policy but preserves a stable distinction from platform failure:

```json
{
  "error": {
    "code": "function_rejected",
    "message": "function rejected its invocation",
    "invocationId": "inv_01...",
    "functionError": {
      "name": "ValidationError",
      "message": "invalid order",
      "stack": null
    }
  }
}
```

Stack return is disabled by default and, when enabled for development, is bounded and source-path sanitized.

## A.5 Invoke asynchronously

```http
POST /v1/tenants/{tenant}/functions/{function}/events?qualifier=prod
Idempotency-Key: evt-2026-08-25-A184
Content-Type: application/json

{
  "input": { "orderId": "A-184" },
  "retry": {
    "maximumAttempts": 3,
    "maximumAgeMs": 60000
  }
}
```

Accepted:

```json
{
  "schemaVersion": 1,
  "invocationId": "inv_01...",
  "state": "queued",
  "statusUrl": "/v1/invocations/inv_01..."
}
```

## A.6 Invocation status

```http
GET /v1/invocations/{invocationId}
```

Possible states:

```text
queued
assigned
started
succeeded
function_failed
platform_failed
timed_out
cancelled
dead_letter
```

The response includes attempt history only to authorized tenant principals. Internal worker addresses and raw console output are never exposed directly.

## A.7 Error taxonomy

| Code | Typical HTTP status | Meaning | Retry guidance |
|---|---:|---|---|
| `invalid_request` | 400 | malformed public request | fix request |
| `invalid_manifest` | 400 | schema or semantic violation | fix deployment |
| `unauthenticated` | 401 | no valid identity | reauthenticate |
| `forbidden` | 403 | identity lacks action | change policy |
| `not_found` | 404 | tenant-visible resource absent | do not retry blindly |
| `conflict` | 409 | alias/version/idempotency conflict | re-read state |
| `payload_too_large` | 413 | bounded bytes exceeded | reduce input |
| `quota_exceeded` | 429 | tenant capacity exhausted | retry with backoff |
| `function_rejected` | 422 or 500 policy | JavaScript handler rejected/threw | function-specific |
| `resource_exhausted` | 422 or 500 policy | function exceeded declared runtime resource | change code/budget |
| `deadline_exceeded` | 504 | queue or execution deadline elapsed | retry only if safe |
| `worker_lost` | 503 | worker failed before safe completion | service follows attempt policy |
| `temporarily_unavailable` | 503 | no capacity/dependency | backoff |
| `internal_error` | 500 | invariant or unknown platform error | use request ID; bounded retry |

# Appendix B - Function manifest schema and semantic validation

## B.1 Representative JSON Schema

The complete file belongs at `api/function-manifest.schema.json`. This excerpt shows the intended strictness:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://example.invalid/mirage-lambda/function-manifest-v1.schema.json",
  "title": "Mirage Lambda function manifest",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "schemaVersion",
    "name",
    "entry",
    "handler",
    "resources",
    "capabilities"
  ],
  "properties": {
    "schemaVersion": { "const": 1 },
    "name": {
      "type": "string",
      "pattern": "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"
    },
    "entry": {
      "type": "string",
      "minLength": 1,
      "maxLength": 256,
      "pattern": "^(?!/)(?!.*(?:^|/)\\.\\.(?:/|$))[A-Za-z0-9._/-]+\\.m?js$"
    },
    "handler": {
      "type": "string",
      "minLength": 1,
      "maxLength": 64,
      "pattern": "^[A-Za-z_$][A-Za-z0-9_$]*$"
    },
    "resources": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "memoryBytes",
        "stackBytes",
        "timeoutMs",
        "maxInputBytes",
        "maxResultBytes",
        "maxLogBytes",
        "maxHostCalls"
      ],
      "properties": {
        "memoryBytes": { "type": "integer", "minimum": 1048576, "maximum": 268435456 },
        "stackBytes": { "type": "integer", "minimum": 65536, "maximum": 8388608 },
        "timeoutMs": { "type": "integer", "minimum": 1, "maximum": 30000 },
        "maxInputBytes": { "type": "integer", "minimum": 0, "maximum": 1048576 },
        "maxResultBytes": { "type": "integer", "minimum": 0, "maximum": 1048576 },
        "maxLogBytes": { "type": "integer", "minimum": 0, "maximum": 262144 },
        "maxHostCalls": { "type": "integer", "minimum": 0, "maximum": 1000 }
      }
    },
    "capabilities": {
      "type": "array",
      "maxItems": 64,
      "items": { "$ref": "#/$defs/capability" }
    },
    "retry": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "safeAfterStart": { "type": "boolean", "default": false },
        "maximumAttempts": { "type": "integer", "minimum": 1, "maximum": 10 }
      }
    }
  },
  "$defs": {
    "capability": {
      "oneOf": [
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["kind", "name", "access"],
          "properties": {
            "kind": { "const": "kv" },
            "name": { "type": "string", "pattern": "^[a-z0-9][a-z0-9-]{0,62}$" },
            "access": {
              "type": "array",
              "uniqueItems": true,
              "items": { "enum": ["get", "put", "delete", "list"] }
            },
            "keyPrefix": { "type": "string", "maxLength": 256 }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["kind", "origin", "methods"],
          "properties": {
            "kind": { "const": "https" },
            "origin": { "type": "string", "maxLength": 512 },
            "methods": {
              "type": "array",
              "uniqueItems": true,
              "items": { "enum": ["GET", "POST", "PUT", "PATCH", "DELETE"] }
            },
            "pathPrefixes": {
              "type": "array",
              "maxItems": 32,
              "items": { "type": "string", "maxLength": 256 }
            }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["kind", "level"],
          "properties": {
            "kind": { "const": "log" },
            "level": { "enum": ["debug", "info", "warn", "error"] }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["kind"],
          "properties": {
            "kind": { "const": "random" },
            "maxBytesPerCall": { "type": "integer", "minimum": 1, "maximum": 65536 }
          }
        }
      ]
    }
  }
}
```

## B.2 Semantic validation after schema validation

JSON Schema does not encode all policy. The OCaml validator must additionally check:

```text
entry exists exactly once in bundle
all module paths normalize within bundle root
handler export name is allowed
sum of module bytes <= tenant maximum
resource values fit the selected worker class
capability names exist in tenant policy
HTTPS origins are canonical and contain no credentials or fragment
path prefixes are normalized
KV prefixes do not overlap protected namespaces
retry.safeAfterStart is allowed by tenant policy
manifest name matches deployment path when policy requires it
bundle digest and manifest digest are computed canonically
```

Return all safe validation errors up to a bounded count so users can fix a manifest in one pass.

# Appendix C - Internal worker protocol

## C.1 Protocol goals

The control/worker protocol must be:

- versioned;
- bounded before allocation;
- authenticated;
- replay-resistant within the chosen lease model;
- idempotent where retries are expected;
- explicit about start acknowledgment;
- independent of internal OCaml marshaling;
- stable across a limited worker-version compatibility window.

Do not use OCaml `Marshal` across image versions or trust boundaries.

## C.2 Assignment envelope

Representative JSON form for readability; a compact canonical CBOR-like encoding may later replace it if justified:

```json
{
  "protocolVersion": 1,
  "assignmentId": "asg_01...",
  "leaseId": "lease_01...",
  "workerId": "wrk_01...",
  "tenantId": "tnt_01...",
  "invocationId": "inv_01...",
  "attempt": 1,
  "revisionDigest": "sha256:6f...",
  "bundleDigest": "sha256:6f...",
  "input": { "encoding": "json", "bytesBase64": "..." },
  "deadlineMonotonicOffsetMs": 850,
  "resourceBudget": {
    "jsMemoryBytes": 16777216,
    "jsStackBytes": 524288,
    "maxJobs": 100000,
    "maxHostCalls": 100,
    "maxResultBytes": 262144,
    "maxLogBytes": 65536
  },
  "capabilityGrant": {
    "digest": "sha256:91...",
    "entries": []
  },
  "token": "short-lived-bound-token"
}
```

Prefer a deadline duration relative to receipt plus a signed control-plane issue time/expiry policy, rather than assuming synchronized monotonic clocks across machines. The control plane remains authoritative for the client-facing deadline.

## C.3 Start handshake

```text
control -> worker: Assign(assignment)
worker validates envelope, lease, digest, capacity
worker -> control: Accepted(assignment_id)
worker fetches and validates bundle
worker creates runtime
worker -> control: Started(assignment_id, engine_version, image_digest)
worker executes
worker -> control: Completed | Failed
```

The distinction matters:

- before `Accepted`, another worker may be assigned safely;
- after `Accepted` but before `Started`, policy may allow reassignment after lease expiry;
- after `Started`, automatic replay is governed by the function retry/idempotency contract.

## C.4 Completion envelope

```ocaml
type completion = {
  protocol_version : int;
  assignment_id : Assignment_id.t;
  lease_id : Lease_id.t;
  invocation_id : Invocation_id.t;
  attempt : int;
  outcome : outcome;
  usage : Usage.t;
  log_summary : Log_summary.t;
  worker_image : Digest.t;
  engine_version : string;
  completed_at_worker_offset_us : int64;
}

and outcome =
  | Success of Bounded_bytes.t
  | Function_error of Error.Js.t
  | Resource_error of Error.Resource.t
  | Capability_error of Error.Capability.t
  | Host_error of Error.Host.t
  | Platform_error of Error.Internal_public.t
```

The control plane validates that assignment, worker, lease, invocation, attempt, revision, and image class agree with its current state before accepting a completion. Duplicate identical completions are idempotent; conflicting completions are an invariant violation and audit event.

## C.5 Framing

A simple binary frame can be:

```text
0               4               8
+---------------+---------------+
| magic "MLWP"  | version u16   |
+---------------+---------------+
| message type  | flags         |
+---------------+---------------+
| payload length u32            |
+-------------------------------+
| request/assignment id ...     |
+-------------------------------+
| canonical payload             |
+-------------------------------+
| optional MAC/signature        |
+-------------------------------+
```

Before allocating payload memory:

```text
validate magic
validate supported version
validate message type
validate declared length <= per-message maximum
validate total connection buffered bytes
read exactly length
verify authentication/integrity
parse canonical payload with depth/count limits
```

TLS can provide channel confidentiality/authentication; the lease/token still binds messages to service state and limits replay after a credential leak.

# Appendix D - File-by-file implementation map

This section tells a new contributor where a change belongs and what must not leak across the boundary.

| File/module | Responsibility | Key invariants | Primary tests |
|---|---|---|---|
| `common/ids.ml` | validated identifiers | no raw path/control characters | property corpus |
| `common/bounded_bytes.ml` | bounded allocation/copy | checked arithmetic; no silent truncation | boundary values/fuzz |
| `common/error.ml` | stable error taxonomy | public messages safe; internal cause retained separately | serialization snapshots |
| `common/budget.ml` | resource counters | monotonic consumption; no underflow | model/property tests |
| `common/capability.ml` | grants and intersection | intersection cannot widen authority | lattice/property tests |
| `common/manifest.ml` | strict manifest parsing | unknown fields rejected; semantic checks separate | valid/invalid corpus |
| `common/bundle.ml` | MLB1 parsing | canonical paths; exact lengths; digest stable | fuzz/round trip |
| `common/protocol.ml` | worker messages | explicit versions and maxima | compatibility fixtures |
| `qjs/c/qjs_allocator.c` | JS heap accounting | size-aware, overflow-safe, limit enforced | allocation stress |
| `qjs/c/qjs_host_queue.c` | callback-to-OCaml requests | bounded queue; owned payload; no OCaml callback | queue fuzz/lifecycle |
| `qjs/c/qjs_stubs.c` | foreign primitives | runtime-lock and root discipline | ASan/UBSan/stress |
| `qjs/lib/qjs_engine.ml` | safe engine abstraction | one owner; deterministic close | state-machine tests |
| `qjs/lib/qjs_module_loader.ml` | module resolution | bundle-only; no network/path escape | resolver fuzz |
| `worker/invocation.ml` | invocation state machine | one terminal state; cleanup always | fault injection |
| `worker/runtime_host.ml` | drive engine + host work | bounded job turns; deadline checks | scripted event tests |
| `worker/capability_broker.ml` | authorization and metering | immutable invocation grant | negative matrix |
| `worker/host_http.ml` | safe egress | validated origin equals connection target | SSRF suite |
| `worker/artifact_cache.ml` | immutable bundle cache | digest revalidation; bounded bytes | corruption/eviction |
| `control/auth.ml` | tenant/admin authentication | identity separated from requested tenant path | auth matrix |
| `control/admission.ml` | quotas and queue admission | no unbounded accepted state | overload tests |
| `control/scheduler.ml` | fair assignment | no assignment without compatible ready worker | model simulation |
| `control/worker_pool.ml` | observed/desired worker state | leases expire; duplicates idempotent | reconciliation tests |
| `control/metadata_writer.ml` | serialized durable mutations | ordered journal; invariant checks | crash-point tests |
| `control/recovery.ml` | boot reconstruction | no readiness before validation | corrupt-store fixtures |
| `control/artifact_store.ml` | immutable objects | write-before-publish; digest verified | interruption tests |
| `control/launcher_client.ml` | lifecycle adapter | timeout does not imply success/failure | fake launcher faults |
| `launcher/albatross_launcher.ml` | host API mapping | no public credentials; strict resource spec | integration sandbox |
| `api/openapi.yaml` | public HTTP contract | examples tested against implementation | contract tests |
| `api/*.schema.json` | external/internal schemas | versioned; no ignored fields | schema corpus |

## D.1 Change-location examples

**“Add a new JavaScript KV operation.”** Change:

```text
common/capability.*          grant semantics
worker/capability_broker.*  authorization/metering
worker/host_kv.*            implementation
qjs host binding            JS method + request encoding
api manifest schema         requested operation
unit + negative + e2e tests
```

Do not add direct Mirage KV calls inside the C callback.

**“Add a new worker lifecycle field.”** Change:

```text
common/protocol.*
api/worker-protocol.md
control/worker_pool.*
worker/worker_server.*
compatibility fixtures
upgrade/rolling-version tests
```

Do not add an unversioned ad hoc header.

**“Add a new public error detail.”** Change:

```text
common/error.*
api/openapi.yaml
control ingress mapping
safe-redaction tests
client/CLI rendering
```

Do not expose the internal OCaml exception or raw QuickJS object.

# Appendix E - Upstream API and source-file reference map

The following files are primary references for implementation decisions. Recheck them when changing pinned versions.

## E.1 QuickJS

| Reference | Relevant content | Project use |
|---|---|---|
| [QJS-HOME] | release/version and engine overview | pinned engine baseline |
| [QJS-DOC] | embedding model, runtimes/contexts, jobs, bytecode warning | design semantics |
| [QJS-H] | public C API declarations | wrapper contract |
| [QJS-C] | public API implementations and ownership behavior | source audit; not an excuse to depend on internals |
| [QJS-MAKEFILE] | engine and CLI object composition, normal link dependencies | determine which files to vendor/exclude |

Important APIs to inspect in the pinned `quickjs.h`:

```c
JSRuntime *JS_NewRuntime(void);
JSRuntime *JS_NewRuntime2(const JSMallocFunctions *mf, void *opaque);
void JS_FreeRuntime(JSRuntime *rt);
JSContext *JS_NewContext(JSRuntime *rt);
void JS_FreeContext(JSContext *s);

void JS_SetMemoryLimit(JSRuntime *rt, size_t limit);
void JS_SetMaxStackSize(JSRuntime *rt, size_t stack_size);
void JS_SetInterruptHandler(JSRuntime *rt, JSInterruptHandler *cb, void *opaque);
void JS_SetCanBlock(JSRuntime *rt, JS_BOOL can_block);
void JS_SetHostPromiseRejectionTracker(...);
void JS_SetModuleLoaderFunc(...);

JSValue JS_Eval(JSContext *ctx, const char *input, size_t input_len,
                const char *filename, int eval_flags);
int JS_ExecutePendingJob(JSRuntime *rt, JSContext **pctx);
JSValue JS_NewPromiseCapability(JSContext *ctx, JSValue *resolving_funcs);
```

Signatures can change. Compile against the vendored header; do not copy declarations manually into unrelated files.

## E.2 MirageOS

| Reference | Relevant content | Project use |
|---|---|---|
| [MIRAGE-CHANGES] | current release changes and target evolution | version/release review |
| [MIRAGE-API] | typed device signatures and Functoria composition | `config.ml` and module contracts |
| [MIRAGE-NET-CONFIG] | current skeleton network configuration | control/worker startup pattern |
| [MIRAGE-NET-UNIKERNEL] | current unikernel network module shape | intern first example |
| [MIRAGE-TLS-EXAMPLE] | TLS server composition example | public/internal TLS starting point |
| [MIRAGE-KV] | read-only/read-write KV interfaces and persistence behavior | registry/artifact implementations |

Do not assume an old blog example compiles unchanged against the pinned switch. Prefer the current repository skeleton and package APIs.

## E.3 Solo5 and orchestration

| Reference | Relevant content | Project use |
|---|---|---|
| [SOLO5-CHANGES] | release status, TLS/thread caveat, target changes | execution-lane assumption |
| [SOLO5-BUILD] | HVT/SPT build and run requirements | local/CI execution |
| [SOLO5-ARCH] | narrow interface and responsibility boundary | trust/orchestration model |
| [ALBATROSS] | Solo5 VM management, networking, block, TLS control, stats | launcher adapter |

Solo5 is not the scheduler or control plane. HVT is a guest execution boundary; worker creation, TAP devices, memory/CPU policy, image distribution, restart, and inventory belong to the launcher/orchestrator.

## E.4 OCaml foreign-function interface

[OCAML-FFI] is the authority for:

- representing OCaml values in C;
- registering roots for values retained across allocations/calls;
- callbacks from C;
- blocking sections and the runtime/domain lock;
- thread registration constraints;
- allocation and exception rules in foreign primitives.

The project simplifies these rules by ensuring QuickJS host callbacks enqueue C-owned requests and return to the OCaml-driven loop rather than invoking arbitrary OCaml code from foreign threads.

# Appendix F - Review pseudocode and algorithms

## F.1 Capability intersection

```ocaml
let compile_grant ~global ~tenant ~manifest ~delegated =
  manifest
  |> Capability_set.intersect tenant
  |> Capability_set.intersect global
  |> Capability_set.intersect delegated
  |> Capability_set.normalize
  |> Result.bind Capability_set.validate_no_ambiguity
  |> Result.map Capability_set.digest
```

Rules:

```text
read/write is not one Boolean; intersect individual operations
origin path prefix intersection chooses the narrower set
byte/count limits choose the minimum
absence in any operand means absence in result
unknown capability kind fails closed
```

## F.2 Worker selection

```ocaml
let select_worker ~revision ~grant ~budget pool =
  pool
  |> Worker_pool.ready
  |> Seq.filter (fun w -> Worker_class.supports w.class_ revision grant budget)
  |> Seq.filter Worker.has_valid_lease
  |> Seq.sort Worker.compare_preference
  |> Seq.uncons
```

Preference may consider warm artifact presence and worker age, but must not violate tenant isolation or compatibility.

## F.3 Host request dispatch

```ocaml
let dispatch_host_request inv req =
  let* op = Host_request.decode_bounded req in
  let* grant = Capability_broker.authorize inv.grant op in
  let* () = Budget.charge_host_call inv.budget op in
  let request_span = Telemetry.start_host_span inv.trace op in

  Lwt.finalize
    (fun () ->
       match op with
       | Kv_get x -> Host_kv.get inv.kv grant x
       | Kv_put x -> Host_kv.put inv.kv grant x
       | Log x -> Host_log.emit inv.log grant x
       | Random x -> Host_crypto.random inv.crypto grant x
       | Http x -> Host_http.fetch inv.http grant x
       | Invoke x -> Host_invoke.call inv.functions grant x)
    (fun () ->
       Telemetry.finish request_span;
       Lwt.return_unit)
```

The result is converted to a bounded, shallow wire representation before calling `Qjs_engine.resolve` or `reject`.

## F.4 Cleanup stack

Construction should register cleanup immediately:

```ocaml
let with_invocation resources f =
  let cleanup = Cleanup.create () in
  let* engine = Qjs_engine.create resources.engine_config in
  Cleanup.push cleanup (fun () -> Qjs_engine.close engine);

  let* bundle = Artifact_cache.acquire resources.cache resources.digest in
  Cleanup.push cleanup (fun () -> Artifact_cache.release resources.cache bundle);

  Lwt.finalize
    (fun () -> f { engine; bundle; cleanup })
    (fun () -> Cleanup.run_all cleanup)
```

Cleanup is idempotent. A failure in one cleanup action is recorded but does not skip remaining actions.

## F.5 Metadata publish transaction

```ocaml
let publish_revision t req =
  Metadata_writer.submit t.writer @@ fun txn ->
    let* () = Registry.validate_publish txn.snapshot req in
    let digest = Bundle.digest req.bundle in
    let* () = Artifact_store.ensure_object t.objects digest req.bundle in
    let tmp = Key.revision_tmp req.tenant req.function_ req.request_id in
    let final = Key.revision req.tenant req.function_ digest in
    let* () = Kv.set t.kv tmp (encode_revision req digest) in
    let* () = Kv.rename t.kv ~source:tmp ~dest:final in
    let* sequence = Journal.append t.journal (Published { req; digest }) in
    Registry.apply txn.snapshot (Published { req; digest; sequence })
```

The actual implementation must use the semantics available from the selected KV implementation and test every interruption boundary.

# Appendix G - Operational and security checklists

## G.1 New QuickJS version

- [ ] Verify upstream archive signature/digest and license.
- [ ] Read release notes and diff public header/API use.
- [ ] Re-run missing-symbol audit.
- [ ] Review changes touching allocator, parser, modules, Promise/jobs, GC, and interrupt handling.
- [ ] Rebase only documented local patches.
- [ ] Run sanitizer, fuzz, lifecycle, HVT, and workload suites.
- [ ] Compare engine behavior and performance baselines.
- [ ] Update worker compatibility key and image digest.
- [ ] Roll out to a canary worker class before general assignment.
- [ ] Preserve rollback image and protocol compatibility.

## G.2 New host capability

- [ ] Define semantic operation and why existing capabilities are insufficient.
- [ ] Add manifest/schema representation.
- [ ] Define tenant/global/delegated intersection.
- [ ] Specify input, output, count, byte, time, and concurrency limits.
- [ ] Specify cancellation and partial-side-effect behavior.
- [ ] Implement fake first.
- [ ] Add negative authorization matrix.
- [ ] Add logging/redaction policy.
- [ ] Add worker implementation and failure mapping.
- [ ] Threat-model confused-deputy and cross-tenant cases.
- [ ] Update JavaScript API documentation.

## G.3 Release qualification

- [ ] Clean locked build succeeds for Unix, control HVT, and worker HVT.
- [ ] Image manifests and SBOMs generated.
- [ ] Unit, integration, fuzz smoke, fault, and HVT E2E suites pass.
- [ ] State migration/recovery fixture passes.
- [ ] Backup restoration passes.
- [ ] Worker rolling update and rollback pass.
- [ ] Certificate-expiry window checked.
- [ ] No critical dependency advisory is unreviewed.
- [ ] Performance baseline comparison reviewed.
- [ ] Residual risks and exceptions approved.
- [ ] Artifacts signed and immutable digests published.

## G.4 Incident: suspected worker compromise

```text
1. Stop assigning the affected worker/image class.
2. Preserve bounded console, assignment, image, lease, and control-plane trace metadata.
3. Destroy affected worker guests; do not attempt in-guest cleanup.
4. Revoke worker credentials or internal CA scope as required.
5. Identify tenant/revision/invocations assigned to the image class.
6. Disable affected capability or untrusted execution globally when scope is uncertain.
7. Reproduce with sanitized artifacts in an isolated environment.
8. Patch, rebuild, qualify, sign, and canary a new image.
9. Rotate exposed secrets and assess cross-boundary evidence.
10. Publish a precise boundary-aware incident report.
```

# Appendix H - Alternatives considered

## H.1 Node.js inside a unikernel

Rejected for the first design because it imports a very large compatibility surface: libuv, filesystem/process assumptions, native add-ons, Node module semantics, and a much larger runtime. It may be useful for compatibility-oriented systems, but it obscures the object-capability experiment.

## H.2 One QuickJS context per invocation in a shared runtime

Rejected for hostile code. Contexts share a runtime and potentially objects; resource accounting and cleanup are less isolated. Fresh runtimes are cheap enough to prioritize clarity first.

## H.3 One monolithic control-and-worker unikernel in production

Retained as the trusted single-appliance mode, rejected as the hostile-tenant default. A QuickJS memory-corruption exploit would obtain control-plane authority and state.

## H.4 Linux microVM workers

A valid fallback and benchmark comparator. Linux improves engine compatibility, debugging, and operations at the cost of a larger guest and less radical OS specialization. The architecture should keep the worker protocol independent enough to permit this comparison.

## H.5 WebAssembly as the guest language boundary

A strong alternative, especially for native memory isolation within a process and multilingual guests. JavaScript-on-Wasm engines add complexity and may have different startup/performance characteristics. The capability, budget, protocol, and scheduler design should be guest-language-neutral enough to add Wasm later.

## H.6 Per-invocation worker VM from day one

Rejected as the initial dependency because orchestration and boot path would dominate the early project. It remains a research/performance mode after tenant workers are functioning.

## H.7 External distributed database for the control plane

Deferred. It simplifies some HA goals but adds a large external dependency and shifts the unikernel experiment. The metadata interfaces should permit a future implementation without changing public semantics.

# Appendix I - Glossary

**Admission control:** Decision to accept, reject, or queue work before execution based on policy and available capacity.

**Alias:** Mutable name such as `prod` that resolves to one immutable function revision.

**Artifact:** Immutable MLB1 bundle addressed by cryptographic digest.

**Capability:** Explicit, unforgeable or host-validated authority to perform a specific class of operation within limits.

**Chamelon:** A MirageOS block-backed key/value implementation suitable for initial local persistent state experiments; verify exact package/API behavior in the pinned switch.

**Control plane:** Unikernel that owns public API, identity, registry, artifacts, admission, scheduling, leases, and durable status.

**Exactly once:** A very strong delivery claim generally not provided here. The service specifies attempts and idempotency instead.

**Functoria:** Mirage's build-time component/configuration mechanism that assembles device implementations and application functors.

**HVT:** Solo5 hardware-virtualized tender/target used with KVM for a narrow guest boundary.

**Invocation:** One attempt to execute one immutable function revision with input, grant, budget, and deadline.

**Lease:** Time-bounded control-plane authorization binding a worker or assignment to current scheduler state.

**MLB1:** Proposed version-1 Mirage Lambda Bundle format containing strict manifest and source modules.

**Object capability:** Authority represented by possession of a constrained object/interface rather than ambient global permission.

**QuickJS context:** JavaScript global environment/realm associated with a runtime; not a native security boundary.

**QuickJS runtime:** Independent QuickJS heap and job queue; useful containment/accounting unit, still native C in the worker address space.

**Solo5:** Thin unikernel execution interface and tender system; not a fleet scheduler or complete cloud control plane.

**Tenant worker:** HVT guest assigned to one tenant and capable of creating fresh QuickJS runtimes for that tenant's invocations.

**Trusted computing base (TCB):** Components whose compromise can violate a stated security property. For worker isolation this includes the worker engine/runtime, Solo5/KVM boundary, host, and launcher at different scopes.

**Worker class:** Compatibility/resource identity including image digest, engine version, architecture, memory class, and enabled capability set.

# Appendix J - Source references

The links below are implementation references, not endorsements of API stability. Pin exact versions and preserve copies/digests used by the build.

- [OCAML-550] — OCaml 5.5.0 release information.
- [OCAML-FFI] — OCaml 5.5 C interface and runtime-lock/rooting rules.
- [MIRAGE-CHANGES] — MirageOS release history and current target changes.
- [MIRAGE-API] — MirageOS typed device and configuration API.
- [MIRAGE-NET-CONFIG] and [MIRAGE-NET-UNIKERNEL] — current network skeleton files.
- [MIRAGE-TLS-EXAMPLE] — current TLS unikernel configuration example.
- [MIRAGE-KV] — Mirage key/value interfaces.
- [SOLO5-CHANGES], [SOLO5-BUILD], and [SOLO5-ARCH] — Solo5 release, build, and architecture references.
- [ALBATROSS] — Solo5 VM lifecycle/orchestration project.
- [QJS-HOME] and [QJS-DOC] — official QuickJS release and embedding documentation.
- [QJS-H], [QJS-C], and [QJS-MAKEFILE] — upstream QuickJS public header, implementation, and build composition.

[OCAML-550]: https://ocaml.org/releases/5.5.0
[OCAML-FFI]: https://ocaml.org/manual/5.5/intfc.html

[MIRAGE-CHANGES]: https://github.com/mirage/mirage/blob/main/CHANGES.md
[MIRAGE-API]: https://github.com/mirage/mirage/blob/main/lib/mirage.mli
[MIRAGE-NET-CONFIG]: https://github.com/mirage/mirage-skeleton/blob/main/device-usage/network/config.ml
[MIRAGE-NET-UNIKERNEL]: https://github.com/mirage/mirage-skeleton/blob/main/device-usage/network/unikernel.ml
[MIRAGE-TLS-EXAMPLE]: https://github.com/mirage/mirage-skeleton/blob/main/applications/static_website_tls/config.ml
[MIRAGE-KV]: https://github.com/mirage/mirage-kv/blob/main/src/mirage_kv.mli

[SOLO5-CHANGES]: https://github.com/Solo5/solo5/blob/main/CHANGES.md
[SOLO5-BUILD]: https://github.com/Solo5/solo5/blob/main/docs/building.md
[SOLO5-ARCH]: https://github.com/Solo5/solo5/blob/main/docs/architecture.md
[ALBATROSS]: https://github.com/robur-coop/albatross

[QJS-HOME]: https://bellard.org/quickjs/
[QJS-DOC]: https://bellard.org/quickjs/quickjs.html
[QJS-H]: https://github.com/bellard/quickjs/blob/master/quickjs.h
[QJS-C]: https://github.com/bellard/quickjs/blob/master/quickjs.c
[QJS-MAKEFILE]: https://github.com/bellard/quickjs/blob/master/Makefile
