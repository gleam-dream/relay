# Import shared validation and keep local tests behavioral

<a id="adr-0015"></a>

Accepted 2026-10-21 at the owner's request. Supersedes the local validation
machinery requirements in [0012-gate-with-one-registry-of-fast-ci-and-design-profiles.md](0012-gate-with-one-registry-of-fast-ci-and-design-profiles.md); runtime contracts remain in force.

Use Nix/treefmt, the compilers and the pinned design-layer checker directly.
Shared validation remains mandatory; repositories do not duplicate it in Python
registries, source parsers, custom inventories or checker self-tests.

Local tests exercise application behavior, including service integrations,
compiler contract fixtures and independent protocol comparisons. A small shell
script runs those commands and propagates their failures. It does not dispatch
validation profiles or wrap formatters. Private service cleanup and offline
credential isolation remain intact.

Remove README/source equality, recipe-size limits, module-documentation checks,
package inventory enforcement and custom dependency preflight. The compiler and
package manager report unavailable dependencies. Source conventions beyond the
imported tools are review responsibilities. Local test runs do not require
provenance receipts or a second CI result interpreter.

This also supersedes the custom result interpreter in
[ADR 0009](0009-use-modern-resource-errors-and-executable-fixture-hooks.md).
The pinned server CLI reports failed assertions through its exit status; the
service harness preserves that status and cleans up its server.
