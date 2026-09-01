# Vendored h11 (ingress parser)

The hostile-ingress HTTP/1.1 parser for the Silo GitHub proxy is a vendored copy
of `h11` at `lib/vendor/h11/` — a pure-Python tree, pinned and hash-verified,
never installed from PyPI at runtime. The proxy imports it **only** from the
vendored tree via `sys.path` insertion; site-packages is never consulted.

## Pin

- **Version:** `0.16.0`
- **HARD FLOOR:** `>= 0.16.0` — version-lowering changes are refused.
- **sdist URL:**
  `https://files.pythonhosted.org/packages/01/ee/02a2c011bdab74c6fb3c75474d40b3052059d95df7e73351460c8588d963/h11-0.16.0.tar.gz`
- **sdist SHA-256:**
  `4e35b956cf45792e4caa5885e69fba00bdbc6ffafbfa020300e549b208ee5ff1`

The floor constant lives in `verify_vendored_h11` in `bin/silo`; it must never be
lowered. Per-file SHA-256 entries for every vendored file are appended to
`MANIFEST.txt` under a `# Vendored h11 0.16.0` block and are enforced by
`verify_vendored_h11` at install time (and by the proxy before it starts).

## Advisory gate (required before pinning or bumping)

Before choosing a pin (or before any bump), query OSV for PyPI h11 **and** the
GitHub Security Advisory:

```sh
curl -sS -X POST https://api.osv.dev/v1/query \
  -H 'Content-Type: application/json' \
  -d '{"package": {"name": "h11", "ecosystem": "PyPI"}}'
```

Record the resulting table and the check date here. Decision rule: the pin must
be `>=` the `fixed` version of **every** published h11 advisory; an unfixed
advisory blocks the pin pending a recorded triage (fail-closed — do not proceed
with a vulnerable or unassessed version).

### Advisory table — checked 2026-08-21

| Advisory ID | Aliases | Affected | Fixed in | Notes |
| --- | --- | --- | --- | --- |
| GHSA-vqfr-h8mv-ghfj | CVE-2025-43859, PYSEC-2026-348 | < 0.16.0 (introduced 0) | 0.16.0 | CRITICAL (CWE-444). Lenient line-terminator parsing in chunked bodies enables request smuggling. |

Only one advisory is published for PyPI h11; the pin `0.16.0` satisfies the
decision rule (`0.16.0 >= 0.16.0`), with no unfixed advisory outstanding.

## WARNING: 0.15.0 is still vulnerable

`0.15.0` is **NOT** fixed. The GHSA-vqfr-h8mv-ghfj narrative contains a stray
line — "Fixed in h11 0.15.0." — that is **wrong**. The authoritative
`affected.ranges[].events[].fixed` field (and the release itself) say
**0.16.0**. Never lower the pin below 0.16.0, regardless of what prose in the
advisory narrative appears to say. A pin of 0.15.0 or lower fails
`verify_vendored_h11` (floor `>= 0.16.0`) and must fail the proxy start.

## Bump procedure

1. **Advisory gate:** re-run the OSV/GHSA query above (plus GHSA directly:
   `curl -sS https://api.osv.dev/v1/vulns/GHSA-vqfr-h8mv-ghfj`), update the
   advisory table + check date, and confirm the candidate version is `>=` the
   `fixed` version of every advisory. Unfixed advisory => blocked.
2. **Vendor:** download the chosen sdist from PyPI, replace the tree at
   `lib/vendor/h11/` (pure-Python files only; strip `__pycache__`, `tests/`,
   examples; keep `LICENSE.txt` and `NOTICE` if present), and verify the sdist
   SHA-256 against the PyPI-recorded digest.
3. **Update hashes:** recompute per-file SHA-256, replace the
   `# Vendored h11 <version>` block in `MANIFEST.txt`, and update this file
   (version, sdist URL + SHA-256, advisory table).
4. **Floor assertion:** the floor constant in `verify_vendored_h11`
   (`bin/silo`) stays `0.16.0`; the bump is refused if the new version is lower.
5. **Verification:** run `verify_vendored_h11` (must pass), run the full
   framing/smuggling matrix (REGRESS-1, SMUGGLE), and re-run the h11 parse
   smoke (well-formed chunked request accepted; malformed post-chunk CRLF
   payload rejected).

Version-lowering changes are refused at every step.
