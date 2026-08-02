# AdaptiveOpticsHIL.jl agent guidance

- Treat this package as a breaking refactor: remove superseded APIs and update callers directly. Do not add aliases, property forwarding, state views, or compatibility adapters unless explicitly requested.
- Use multiple dispatch, traits, and small helpers. Avoid OO-style inheritance and `isa` branches in package code.
- Separate immutable configuration/parameter structs from mutable runtime state. Mark mutating hot-path functions with `!`.
- Preallocate hot-path workspaces. Do not allocate, block, yield, retry without a bound, log, or invoke user callbacks in SPSC transfer loops.
- Preserve one explicit producer, one explicit consumer, and one owner for each bounded resource.
- Preserve prepared backend, compute-device, stream/context, and memory residency exactly. Do not add implicit host fallback or host-device transfers.
- Use the canonical scientific and API terminology from the pinned AdaptiveOpticsSim glossary. Define new public terms there before adding HIL APIs.
- Keep runtime code transport-neutral and free of transport package dependencies.
- Keep documentation concise and maintained in the README or existing canonical guides. Do not add one-off plan, audit, or inventory documents.
- Run focused tests first. Reserve broad CI-equivalent validation for explicit delivery work.
