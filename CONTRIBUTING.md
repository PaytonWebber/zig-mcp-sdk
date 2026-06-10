# Contributing

## Setup

Zig 0.16.0 (stable) is the only requirement.

```bash
zig build check        # tests + format checks + compile examples
zig build examples     # install example binaries to zig-out/bin
./scripts/conformance.sh       # stdio conformance (needs examples)
./scripts/conformance_http.sh  # HTTP conformance (needs examples, curl)
```

CI runs all of the above on every push and pull request. A green `zig build check` plus both conformance scripts locally means CI will pass.

## Guidelines

- Run `zig fmt` on changed files (`zig build check` verifies formatting).
- Add or update tests next to the code they cover; tests are inline in each source file. Use `testing.allocator` so the leak checker runs.
- Behavior visible on the wire (new methods, status codes, headers) should also be covered by a conformance script assertion.
- Update `CHANGELOG.md` under an `Unreleased` heading or the upcoming version.
- Keep commits focused; describe what changed and why in the body.

## Architecture notes

Module layout, key patterns, and known gotchas are documented in the doc
comments of `src/server.zig`, `src/http_transport.zig`, and `src/tool_pack.zig`.
The design rules in short: comptime over runtime reflection, request-scoped
arenas for all per-request memory, zero-copy slices into arena memory, and
Zig-native idioms rather than patterns ported from other SDKs.

## Releases

Maintainer-driven: version bump in `build.zig.zon`, `CHANGELOG.md` entry,
annotated tag, GitHub release. Until 1.0.0, minor versions may break.
