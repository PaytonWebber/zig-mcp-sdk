# Security Policy

## Supported versions

The latest tagged release receives security fixes. Older minor versions are
not patched; upgrade to the newest release.

## Reporting a vulnerability

Report privately via [GitHub security advisories](https://github.com/PaytonWebber/zig-mcp-sdk/security/advisories/new)
or email payton@atcyrus.com. Please include a reproduction. You can expect an
initial response within a week.

Do not open public issues for vulnerabilities before a fix is released.

## Scope notes

The HTTP transport is designed for localhost and trusted-network use:

- Origin validation (localhost plus an explicit allowlist) protects against
  DNS rebinding from browsers.
- Session IDs come from the OS CSPRNG and are required on every request.
- Body size, session count, and session lifetime are bounded by configurable
  limits.

It does not provide TLS or authentication; deployments exposed beyond
localhost should sit behind a reverse proxy that does. Reports about missing
TLS/auth at the transport itself are considered out of scope, while bypasses
of the protections listed above are in scope and very welcome.
