# CHANGELOG â€” OpenCode Cross-Talk (protocol history)

Version history, discoveries, and pitfalls of the Cross-Talk protocol.
The **current rules** are in `CROSS_TALK.md`; this file is history only.
Split from `CROSS_TALK.md` on 2026-08-11 (external review: the document
mixed current specification with changelog and PowerShell pitfalls).

---

## Versions

### v2.2.0 (2026-10-28) - Fase 2: wait-idle, HMAC envelope signature, docs

- `Wait-CrossSessionIdle`: server-side `POST /api/experimental/session/{id}/wait`
  (HTTP 204 = idle) + polling fallback (`time.idle >= updated` / quiet 3000 ms).
  Mockable (`SleepFn`, `WaitEndpointFn`, `StateFn`). Tests: T-wait-idle (8/0).
- HMAC (`sig`): `Get-CrossHmacSecret` (env `CROSS_HMAC_SECRET` > file
  `cross/cross.hmac.secret`), `Get-CrossHmacSignature` (canonical
  `"v2\n{type}\n{msg_id}\n{token}\n{timestamp}\n{payloadText}"`),
  `Test-CrossEnvelopeSignature`, `Parse-CrossEnvelope` exposes `.sig`.
  `New-CrossEnvelope` / `New-CrossAckJson` / `New-CrossNackJson` / `Format-CrossEnvelopeV2`
  accept `-Secret`. Tests: T-hmac (12/0).
- CLI handlers: `wait-idle` (`--session`, `--timeout`, `--interval`);
  `verify` (`--envelope`, `--secret`). Flags: `envelope`, `secret`.
- Integration: `New-CrossDelivery`, `Send-CrossAck`, `Send-CrossNack` propagate
  `-Secret`.
- Docs: `AGENTS.md` (verify + wait-idle), `CROSS_TALK.md` (4d.1 HMAC + 4c wait-idle
  + URLs `/session/` -> `/api/session/`), `.gitignore`: `cross/cross.hmac.secret`.
- Fixture cleaner (`fixture-clean.psm1`) for pre-existing test contamination
  (`T-ack`, `T-nack`, `T-dlq`, `T-escalate`, `T-ipc`).
- Pre-existing test failures annotated in commit (`T-ack` 3, `T-nack` 2, `T-dlq` 2,
  `T-escalate` 1, `T-race` timeout, `T-ipc` error — not caused by Fase 2).

### v2.1.1 (2026-10-19) - Install & ACK hardening (found in a real installation)

Origin: full setup by a fresh LLM session (MUSE) coordinating 3 peer sessions.

- **Import order bug:** `cross-action.psm1` imported `cross-envelope` only when
  `ConvertTo-AsciiSafe` was missing. `cross.ps1` loads `cross-format` first, so
  `New-CrossAckJson` stayed undefined and `cross ack` failed at the CLI. The
  guard now checks `New-CrossAckJson` explicitly (+ `Resolve-CrossEndpoint`
  guard). Regression: T-ack mirrors the CLI import order.
- **Silent ACK/NACK no-op:** with `--port` omitted, `Send-CrossAck`/`Send-CrossNack`
  returned `ok:true, sent:false`. Both now resolve the endpoint and return
  `SEND_FAILED` on HTTP errors.
- **cwd-dependent paths:** `whiteboard_dir`/`diario_dir`/`log_path` resolved
  against the caller's cwd (`OUTBOX_MSG_NOT_FOUND` outside `cross/`).
  `Import-CrossConfig` resolves relative values against the config file and
  keeps `%ENV%` expansion. Regression: T-transport.
- **Outbox auto-create:** `send --msg X --dest Y --text Z` without a prior outbox
  entry failed with `OUTBOX_MSG_NOT_FOUND`; it now creates the entry (`EN_VUELO`,
  token defaults to the msg id) and reports `auto_created`.
- **API-derived model:** `whoami` only read `my_model` from the config. It now
  falls back to `GET /session/:id` (`model.id`) and reports `model_source`
  (config/override/api). `Get-CrossSessionState` extracts `model.id` from the
  object returned by current builds (previously `[object]`).
- **Self-ACK / emitter mismatch warnings:** `ack`/`nack` now warn when the
  envelope emitter equals the destination (`SELF_ACK`), and `send` warns when
  the ACK emitter differs from the destination (`ACK_EMITTER_MISMATCH`). This
  detects shared `cross.config.local.json` setups that silently "confirm"
  messages with the wrong identity.
- **Safe install:** `install.ps1` guessed the session by title (`leader|lider`)
  and otherwise took `sessions[0]` (caused stale configs). Rewritten with
  `-SessionId/-Model/-Role/-NonInteractive`, API validation, candidate listing
  and exit code 2 when ambiguous, API model written, health/whoami verification,
  existing role preserved and an ACK recipe.
- **Test hygiene:** T-send no longer dies on CLI stderr warnings under
  `$ErrorActionPreference='Stop'` (PS 5.1 NativeCommandError); T-transport uses
  `-NoCache` so a stale port hint cannot make the suite order-dependent.
- **Docs:** README (setup, troubleshooting table, v2 handshake), QUICKSTART,
  AGENTS.md, llms.txt, USER_GUIDE, CROSS_WINDOWS (pitfalls 9-13), CROSS_TALK
  (handshake/ACK/NACK v2, CLI section, config paths). CLI `--help` updated.
  `protocol_version` stays 1.8 (config marker); wire format is unchanged.

### v2.1.0 (2026-08-23) - RLock + QUICKSTART

- **B1 (NEMOTRON):** Get-CrossMutex RLock reentrant with MutexCache (CrossFileLock + ReentrantMutex) — T-idempotencia-race 8/8, T-race 5×9/9.
- **B2 (HY3):** QUICKSTART.md 1 usage removed in v2.0 + Get-CrossCurlCommand docs; CROSS_TALK.md Parts I-IV already in v1.20.
- **F3 (v1.20):** cross-transport.psm1 5 empty catch {} → Write-CrossDiag debug (higiene).

### v2.0.0 (2026-08-23) - Envelope v2 Exclusive (BREAKING)

Origin: leader MUSE SPARK 1.2; advisor council (MIMO, HY3, NEMOTRON, BIG PICKLE, OX ALPHA).

- **BREAKING:** v1 legacy ACK:/NACK: free-text formats REMOVED. Only `ENVELOPE-V2: {json}` /
  pure JSON accepted. `Parse-CrossEnvelope` is the sole parser (v2-only; legacy v1 regexes
  removed in v1.17, v1 parser fully deleted in v2.0).
- **B1 (MIMO):** removed `ConvertTo-CrossV1` (cross-envelope.psm1) and the 6+ legacy
  ACK:/NACK: regexes in cross-delivery.psm1; `Parse-CrossEnvelope` v2-only, no v1 fallback.
  `T-contract.ps1` inverted regression (v1 rejected) verified 0 v1 refs.
- **B2 (HY3):** docs â€” `CROSS_TALK.md` Fase 3 marked COMPLETED + v2-only (no v1 fallback);
  `QUICKSTART.md` breaking-change note; this CHANGELOG v2.0.0 entry.
- **B3 (NEMOTRON):** suite 7098 (no v1); `T-contract`/`T-fuzz`/`T-ack` v2; `T-cli` 47/0,
  `T-transport` 29/0; CI windows+ubuntu green; tag v2.0.0.

### v1.17.0 (2026-08-23) - Reliability hardening + multiplatform CI

Origin: Claude diagnosis validated by GLM-5.3, implemented by leader OX ALPHA,
verified by advisor council (MIMO, HY3, BIG PICKLE, NEMOTRON, MUSE SPARK).

- **D1**: Parse-CrossAckText (v1 ACK parser) REMOVED. Find-AckInList and all
  emitters now use envelope v2 JSON exclusively. Breaking change: v1 free-text
  ACK/NACK formats are rejected by design.
- **D2**: Structured API-first failure diagnosis. CONFIG_ERROR via local
  validation, PROVIDER_DOWN via /global/health, AGENT_SLEEPING via new
  Get-CrossSessionState (GET /session/:id). Zero third-party log scraping.
- **D4**: ubuntu-latest CI job validating cross-platform layer (advisory file
  lock, curl resolution) with 5 server-independent suites.
- **Racefix**: Write-CrossDeliveryLog routes through mutexed Add-CrossLogLine
  (prevents lost lines under concurrent sends).
- **Onboarding**: AGENTS.md, llms.txt, QUICKSTART.md added for LLM agents.
### v1.16.0 (2026-08-21) - F1-F5 reliability hardening (wire protocol unchanged)

Origin: Claude diagnosis validated by GLM-5.3, implemented by leader OX ALPHA,
verified 5/5 CORRECTO by the advisor council (MIMO, HY3, BIG PICKLE, NEMOTRON,
MUSE SPARK) on the canonical repo. Plan: whiteboard/14 + 18 (CROSS workspace).

- **F1 TOCTOU**: `New-CrossClaim` / `New-CrossRelease` / `New-CrossDone` now wrap
  read->verify->write in the state-file global mutex (`WaitOne(30000)` +
  try/finally release). New error `LOCK_TIMEOUT`. Two concurrent claims of the
  same msg_id now yield exactly one winner (test `T-idempotencia-race.ps1`,
  cross-process via Start-Job, 8/8).
- **F2 Port discovery**: both `server ready.*url:` regexes hardened to
  `[^\r\n]*` (no line crossing) taking the LAST match (most recent start);
  all 9 `Resolve-CrossEndpoint` returns now include `source` and
  `degraded = (regex|scan)`.
- **F3 Portability**: new exported `Get-CrossCurlCommand` resolves curl.exe/curl
  per platform with actionable CURL_NOT_FOUND; replaced at all call-sites
  (Import-CrossConfig, Test-CrossHealthRaw netrc/no-netrc, Invoke-CrossApi).
- **F4 v1 deprecation**: `Parse-CrossAckText` emits a once-per-process DEPRECATED
  warning and counts usage (`Get-CrossV1Usage`, exposed as `v1_ack_parse_count`
  in metrics and a `v1_deprecation` check in doctor). Removal planned v1.17.
- **F5 Hard total cap**: `New-CrossDelivery -MaxTotalWaitSec 600` (absolute
  deadline; lease renewals count toward it). On exhaustion: outbox ESTADO=DLQ,
  DLQ file line with flag TOTAL_TIMEOUT, result err=TOTAL_TIMEOUT.
  `TOTAL_TIMEOUT` added to valid dlq flags.
- **Docs**: QUICKSTART.md added; CROSS_TALK.md intro de-changelogged (history
  lives here); README/llms.txt point LLM agents to AGENTS.md bootstrap.

Tests: suite 7098 pass / 0 fail across 35 suites, including new
T-idempotencia-race.ps1 (8 checks) and T-v1-deprecation.ps1 (5 checks);
T-doctor updated to expect the new doctor check (7 checks).
### v1.14.0 (2026-08-20) â€” Prometheus export + netrc + diagrama README (compatible)

Design origin: external review (GLM-5.3), improvements #6 "ExportaciÃ³n de
mÃ©tricas", #7 "Seguridad: manejo de credenciales" y #8 "Diagrama de
arquitectura para README". Plan 45 approved 3/3 CON CAMBIOS by advisors
(MIMO APROBADO, NEMOTRON APROBADO CON CAMBIOS, BIG PICKLE APROBADO);
result verified 3/3 APROBADO.

**Principle:** metrics export only reuses existing sources
(`Get-CrossMetrics` + `Get-CrossStatus`); credentials never appear on the
CLI (netrc temp file, restrictive ACL); README gains a versioned
architecture diagram.

- **#6 Prometheus export** â€” `Export-CrossMetrics` in
  `cross-diagnostic.psm1` (`-Since/-Until/-ByAgent/-LogPath/-OutputPath/
  -OutboxPath`), Prometheus text format 0.0.4: counters
  `cross_messages_total/acked_total/nacked_total/timeout_total/
  error_total/noack_total` (from real `by_outcome`), summary
  `cross_delivery_latency_ms{quantile="0.5"|"0.95"}` (repo P50/P95, no
  invented P99), gauges `cross_outbox_pending` (EN_VUELO),
  `cross_messages_dlq`, `cross_messages_quarantine`. HELP documents that
  metrics only reflect `delivery_log.jsonl` (NEMOTRON-N1), not
  advisor/reactivation activity (audit_log). `-OutputPath` writes UTF8
  no-BOM file and returns no `text`; without it returns `text`.
  CLI `cross metrics --prometheus` emits ONLY the Prometheus text on
  stdout (scrapeable) and exits 0; `--prometheus-output PATH` (N4 alias)
  returns JSON with `prometheus_file`. Without `--prometheus` the JSON
  output is unchanged.
- **#7 netrc** â€” `Get-CrossNetrcFile` in `cross-transport.psm1`: temp
  `cross_netrc_<guid>.txt` in TEMP, ASCII content
  (`machine <host>` / `login opencode` / `password`), Windows ACL via
  `icacls /inheritance:r /grant:r` (N2), Unix chmod 600.
  `Invoke-CrossApi` and `Test-CrossHealthRaw` use `--netrc-file` with
  cleanup after use; if netrc creation fails â†’ silent fallback to `-u`.
  `Invoke-CrossApi` API unchanged.
- **#8 Diagram** â€” README `## Arquitectura (v1.14.0)` (N3: versioned
  title): Mermaid `graph TB` (endpoint resolution cacheâ†’well-knownâ†’logâ†’
  scan, idempotency v1.7, JSON v2 + v1 fallback, doctor 6 checks, HTTP
  API `/session/:id/message` + prompt_async + `/global/health`, 3
  advisors). Project tree updated (33 suites, 7000+ assertions, new
  modules cross-envelope/cross-diagnostic, T-fuzz).
- **Tests:** T-transport 29/0 (+6 netrc asserts: content exact, unique
  guid name, protected ACL single rule, no leftovers after real calls);
  T-metrics 37/0 (+13 prometheus asserts: TYPE/counters/quantiles P50/P95/
  gauges/HELP/output file/LOG_NOT_FOUND/USAGE_ERROR); T-cli 47/0
  (prometheus stdout scrapeable with CRLF tolerance, `--prometheus-output`
  writes file with TYPE line, LOG_NOT_FOUND).

Suite result: **7093 pass, 0 fail** (33 suites). `cross validate` clean,
`cross doctor --human` OK. Backup before implementation:
`backup_v114_20260820_231500.zip`.

### v1.13.0 (2026-08-20) â€” contract parser fuzzing (compatible)

Design origin: external review (GLM-5.3), improvement #4 "Tests de contrato
/ fuzzing". Plan 44 approved 3/3 CON CAMBIOS by advisors (MIMO, NEMOTRON,
BIG PICKLE); result verified 3/3 APROBADO.

**Principle:** the fuzzer only OBSERVES the contract (it never changes what
is accepted); it found 4 real bugs which were fixed (defense + validation).
API unchanged: `Parse-CrossEnvelope` output schema identical, only internal
validations hardened.

- **New test `cross/tests/T-fuzz.ps1`** â€” deterministic (seed `20260820`,
  documented in the header, corpus regenerable via `Get-FuzzCorpus`),
  bounded (< 30 s): 10-valid-input corpus Ã— 8 mutators Ã— 20 mutations + one
  10 MB input per corpus (NEMOTRON-N1: memory/DoS limits) = 1610
  evaluations Ã— 2 parsers. Mutators: truncate, insert chars, JSON field
  duplication/removal, weird types (null/true/123/[]/{}/NaN/Infinity),
  broken JSON + garbage, hostile unicode (BOM, RTL, control chars â€” N4),
  multiple `ENVELOPE-V2:` per text (N3: first parseable occurrence wins),
  `ENVELOPE-V2:` without JSON / `{}` / `[]`.
- **Invariants per mutation:** `Parse-CrossEnvelope` and `Parse-CrossAckText`
  never throw; `valid`/`ack`/`nack`/`protocolo` always bool; if
  `valid=$true` â†’ `format` = v2-json, `type` âˆˆ {message,ack,nack},
  `msg_id`/`timestamp` non-empty, `requires_ack` bool; if `ack` â†’ `token`
  non-empty + `emisor`; if `nack` â†’ `token` non-empty + `razon`;
  type=message â†’ ack=false and nack=false.
- **Bugs found by the fuzzer and fixed** in `Parse-CrossEnvelope`:
  - non-int `v` (e.g. `"2x"`) threw an exception outside the try/catch â†’
    defensive try/catch + invalid.
  - empty `msg_id` was accepted (valid=true) â†’ now mandatory non-empty.
  - missing `timestamp` was accepted â†’ now mandatory with ISO format.
  - two `ENVELOPE-V2:` on the same line both failed (concatenated JSON) â†’
    iterative truncation at each `}` so the first parseable occurrence wins
    (payloads containing `}` inside strings still work: every `}` position
    is tried).
- **8 fixed regression cases** added to T-fuzz (minimal valid, empty
  msg_id rejected, missing timestamp rejected, non-int v rejected,
  duplicated JSON fields tolerated, multi-envelope first-wins, message is
  not ack, BOM before JSON tolerated).
- **N2 (NEMOTRON):** exact counts documented â€” 20 mutations Ã— 8 types =
  160 variants per corpus entry â†’ 1610 total evaluations (asserted).
- **N5 (NEMOTRON):** seed and corpus regeneration documented in the test.

Suite result: **7063 pass, 0 fail** (33 suites; T-contract 39/0 unchanged,
T-fuzz 6450/0). `cross validate` clean. Backup before implementation:
`backup_v113_20260820_221440.zip`.

### v1.12.0 (2026-08-20) â€” checksums de integridad + `cross doctor` (compatible)

Design origin: external review (GLM-5.3), improvement #5 "Idempotencia
tolerante a corrupciÃ³n (checksums)". Plan 43 approved 3/3 CON CAMBIOS by
advisors (MIMO, NEMOTRON, BIG PICKLE); result verified 3/3 APROBADO.

**Principle:** legacy lines (no checksum) are still parsed identically; only
lines WITH a checksum are verified. Nothing breaks.

- **`Get-CrossChecksum`** (cross-state) â€” full SHA256 hex of a string
  (NEMOTRON-N1: 64 hex, not truncated 16).
- **`Add-IdempotenciaLine`** â€” writes format **v1.7**:
  `msg_id | timestamp | modelo | state | sha256:<64hex>` (SHA256 over the 4
  canonical fields). Header `## Activo (formato v1.7)`; existing v1.6.1 lines
  are preserved untouched.
- **`Read-IdempotenciaLogEx`** â€” returns `{records, corrupt_lines,
  corrupt_count}`; detects v1.7 lines whose checksum doesn't match (skips
  them, lists in `corrupt_lines`), parses legacy lines without checksum.
- **`Read-IdempotenciaLog`** â€” still returns the clean records array
  (API-compatible; no exceptions on corrupt lines).
- **`Get-MsgState`** â€” returns last valid record; if ALL entries for a
  msg_id are corrupt â†’ marker `CORRUPTED_ALL` (NEMOTRON-N2, distinguished
  from `$null` = no entries); callers that compare against
  `CLAIMED_BY=`/`PROCESADO`/`SUPERSEDED_BY=` don't match and retry safely.
- **`Test-CrossConsistency`** â€” adds `checksum corrupto` warning per corrupt
  line.
- **`Repair-CrossIdempotencia`** â€” non-destructive by default (diagnose
  only); `-DryRun` reports without touching; `-Rewrite` rewrites without
  corrupt lines and creates a `.bak` backup first (NEMOTRON-N4). Never
  deletes automatically.
- **`Get-CrossDoctorReport`** (cross-diagnostic) â€” 6 checks: config, paths,
  integrity, password, server, consistencia. Server unavailable in CI
  (`$env:CI`/`$env:GITHUB_ACTIONS`) â†’ `warn` with `expected_ci=true`,
  documented as expected, not error (NEMOTRON-N3/N5).
- **`cross doctor`** (cross.ps1) â€” read-only subcommand; respects `--config`;
  JSON output `{ok, checks[], summary, error_count, warn_count}`.
- **New test `cross/tests/T-doctor.ps1`** â€” 27 assertions (round-trip v1.7
  with 64 hex, legacy parsed, corruption detected/skipped, Get-MsgState
  tolerance + CORRUPTED_ALL + null, Repair with/without -Rewrite + .bak,
  consistency warning, doctor schema 6 checks, doctor CLI with broken config).
- **`T-done.ps1`** â€” assertion updated to v1.7 PROCESADO with checksum.

Suite result: **613 pass, 0 fail** (32 suites). `cross validate` clean;
`cross doctor --human` OK. Backup before implementation:
`backup_v112_20260820_221340.zip`.

### v1.11.0 (2026-08-20) â€” improved port discovery (well-known + diag) (compatible)

Design origin: external review (GLM-5.3), improvement #3 "Descubrimiento de
puerto mejorado". Plan 42 approved 3/3 CON CAMBIOS by advisors (MIMO,
NEMOTRON, BIG PICKLE); result verified 3/3 APROBADO. Chain order (NEMOTRON-N5):
**cache â†’ well-known â†’ log â†’ scan**, health check before trusting each source.

- **`Get-CrossPortWellKnown`** â€” reads `server.port` from the config dir
  (`Get-CrossConfigDir`, v1.10). Empty/corrupt/out-of-range file â†’ `$null`
  (no throw, debug log; NEMOTRON-N2).
- **`Write-CrossPortWellKnown`** â€” best-effort write of the verified port to
  `<configdir>/server.port` (creates dir if missing); validates port 1-65535
  before writing (NEMOTRON-N1).
- **`Write-CrossDiag`** â€” non-intrusive logging to stderr, prefix
  `[cross-diag]`, levels trace/debug/info/warn gated by env `CROSS_DIAG`
  (default `warn`; trace level per NEMOTRON-N4). Used by `Resolve-CrossEndpoint`
  to record each source's verdict/descarte reason.
- **`Get-CrossPortByScan`** â€” new `ScanTimeoutMs` param (default 30000,
  config `port_scan_timeout_ms`) aborts the loop via Stopwatch; closes the
  worst case of a serial 20+ s scan.
- **`Resolve-CrossEndpoint`** â€” chain `cache â†’ well-known â†’ log â†’ scan`;
  new `detection_method='well-known'`; per-source `Write-CrossDiag` and
  effective `ScanTimeoutMs` in diagnostics (NEMOTRON-N3). API unchanged.
- **New test `cross/tests/T-port.ps1`** â€” 19 assertions: well-known
  round-trip (isolated USERPROFILE), invalid/empty/out-of-range â†’ null,
  ports 0/70000 rejected, diag levels (silent default / warn / trace),
  scan timeout aborts < 1 s, real chain â†’ `detection_method=well-known`,
  corrupt well-known falls through to regex/scan.

Suite result: **586 pass, 0 fail** (31 suites). `cross validate` clean.
Backup before implementation: `backup_v110_20260820_211843.zip`.

### v1.10.0 (2026-08-20) â€” cross-platform IPC abstraction (compatible)

Design origin: external review (GLM-5.3, shared Z.ai chat), improvement #2
"AbstracciÃ³n IPC multiplataforma" (alta prioridad). Plan 41 approved 3/3 CON
CAMBIOS by advisors (MIMO, NEMOTRON, BIG PICKLE); result verified 3/3 APROBADO.

**Principle:** business modules (state, delivery, diagnostic, action) do NOT
change; a low-level IPC layer + path helpers is introduced. Windows behavior
is byte-identical (same SHA256 hash, same `Global\` mutex prefix, same paths);
Unix (Linux/macOS/WSL) is unlocked.

- **New module `cross/modules/cross-ipc.psm1`** â€” `CrossPlatform` enum;
  `Get-CrossPlatform` (PS 5.1 via `$PSVersionTable.PSEdition`, Core via
  `$IsWindows/$IsLinux/$IsMacOS`, WSLâ†’Unix, result cached in `$script:Platform`);
  `Get-CrossConfigDir` (Windows `USERPROFILE\.config\opencode`; Unix
  `XDG_CONFIG_HOME/opencode` else `~/.config/opencode`); `Get-CrossEnvFile`;
  `Get-CrossTempDir` (TEMP/TMP, TMPDIR, `/tmp`); `Get-CrossMutex` (Windows
  `System.Threading.Mutex` identical; Unix `CrossFileLock` class with
  `FileStream+FileShare.None+FileOptions.DeleteOnClose`, same
  `.WaitOne(ms)/.ReleaseMutex()` API, 30s retry timeout; documented advisory
  lock, not POSIX flock, and non-reentrant).
- **`cross-transport.psm1` minimal changes** â€” import of cross-ipc;
  `$script:PortCache` via `Get-CrossTempDir`; `$script:EnvFile` via
  `Get-CrossEnvFile`; `Get-CrossPortFromLog` Unix fallbacks
  (`<configdir>/desktop/logs`, `~/.local/share/opencode/log`) returning clean
  `$null` without noisy warnings.
- **`cross-state.psm1` minimal changes** â€” `Get-OutboxMutex` delegates to
  `Get-CrossMutex` (same signature/hash) and is now exported.
- **New test `cross/tests/T-ipc.ps1`** â€” 12 assertions: platform value +
  cache, config dir/env file per platform, mutex round-trip (WaitOne/
  ReleaseMutex/reacquire), cross-process contention (Start-Job blocks while
  held, acquires after release; Unix file-lock timeout semantics), regression
  `Get-OutboxMutex` + `Test-CrossConsistency`.

Suite result: **567 pass, 0 fail** (30 suites). `cross validate` clean.
Backup before implementation: `backup_v191_20260820_200820.zip`.

### v1.9.0 (2026-08-20) â€” envelope JSON v2, Fase 1 (compatible)

Design origin: external review (GLM-5.3, shared Z.ai chat "RevisiÃ³n Repositorio
GitHub"), improvement #1 "Sobre estructurado JSON" (alta prioridad). Human
approved scope: ONLY Fase 1 (v1.9). Plan 40 approved 3/3 CON CAMBIOS by
advisors; result verified 2/3 APROBADO (MIMO, NEMOTRON); ROUTER discarded
by human decision (continue without free models, verdict not retried).

**Principle:** the v1 envelope (`[msg_id=... | ...]`, section 12.1) is NOT
modified; the v2 envelope travels as an ADDITIONAL line `ENVELOPE-V2: {json}`
in the message body; the parser accepts v2 first and falls back to v1.
Backward compatible: existing tests and advisors keep working unchanged.

- **New module `cross/modules/cross-envelope.psm1`** â€” `New-CrossEnvelope`
  (JSON v2 message), `New-CrossAckJson`/`New-CrossNackJson` (structured
  ACK/NACK), `Format-CrossEnvelopeV2` (`ENVELOPE-V2: ` prefix, `ConvertTo-AsciiSafe`
  applied internally), `Parse-CrossEnvelope` (line-based `ENVELOPE-V2:` or pure
  JSON; validates `v=2`, `type` in {message,ack,nack}, soft-validates
  `requires_ack` bool and ISO8601 `timestamp`; failure â†’ `valid=$false` â†’
  v1 fallback), `ConvertTo-CrossV1` (v2 â†’ equivalent v1 text, tool for Fase 2+).
- **`cross-delivery.psm1` minimal changes** â€” import of the new module at the
  top (before use); `New-CrossDelivery` appends the v2 line to the body after
  the v1 envelope; `Parse-CrossAckText` tries v2 first (ack/nack extract
  token/emisor/modelo/razon/msg_id/run_id; `type=message` is NOT a response),
  falling back to the existing v1 logic intact.
- **New test `cross/tests/T-contract.ps1`** â€” 39 assertions: round-trip v2
  message/ack/nack, mixed body, pure JSON, `type=message` ignored, v1 fallback
  regression (E1, ACK-PROTOCOLO/NACK-PROTOCOLO, NACK 3-4/4-7 seg), invalid
  `ENVELOPE-V2:` (bad JSON, `v=1`, unknown type, non-bool `requires_ack`,
  non-ISO `timestamp`) â†’ fallback, v2 precedence over v1, `ConvertTo-CrossV1`
  round-trip.

Suite result: **554 pass, 1 fail** (29 suites; T-poll 28/1 in-suite â€” known
transient TCP scan failure, passes aislado 29/0; NOT a regression). T-delivery
66/0 no regressions. `cross validate` clean (0 errors, 0 warnings). Backup
before implementation: `backup_v184_20260820_182309.zip`.

### v1.8.4 (2026-08-20) â€” project usability (post-publication)

**Hardening (CI green, same day):** the first CI run exposed that
`T-cli.ps1` assumed a live OpenCode Desktop server; on the runner it died
without emitting `RESULT:`, crashing the workflow parser. Fixes:

- **T-cli SKIP guard** â€” `$haveServer` (logs + password) gates the 9
  server-dependent scenarios; without a server they report
  `26 pass, 0 fail, 9 skipped (server-dependent)`.
- **Robust workflow loop** â€” captures `2>&1`, parses `RESULT:` via regex,
  and on a test without RESULT prints its last 8 output lines (no more
  null-pointer crash in the runner script).
- **Transport hardening** (advised by 5 peer reviews): `Get-CrossPortByScan`
  no longer returns an unverified "trap port" when there is no password
  (returns `SERVER_NOT_FOUND` cleanly), and the `TcpClient` loop is wrapped
  in try/catch/finally (reserved-port `SocketException`).
- **T-cli config --set** â€” restore of `port_cache_ttl_s` moved to
  `finally`; `.GetType()` assert null-safe.

First release iteration:

- **`install.ps1`** â€” one-command setup: detects the OpenCode Desktop
  server (port from logs, password from env/.env), lists sessions, picks
  the leader (or first) session, and writes the identity to
  `cross/cross.config.local.json` (git-ignored), then verifies with
  `cross health`.
- **`cross.config.local.json` override** â€” `Import-CrossConfig` now merges
  a `cross.config.local.json` next to the base config when present
  (non-empty keys win). The publish template keeps its empty identity;
  contributors never commit their session IDs. New T-transport scenarios
  (4 asserts).
- **CI workflow** (`.github/workflows/test.yml`) â€” runs the full suite on
  `windows-latest` (pwsh) on every push/PR; badge added to README.
- **README** â€” install step, local-config docs, 3-session handshake
  example, updated project structure.
- **CONTRIBUTING.md + issue templates** â€” bug report / feature request /
  config, plus contribution conventions (English messages, SKIP pattern,
  tests for every change).

Suite result: **516 pass, 0 fail, 4 skip** (was 512).

### v1.8.3 (2026-08-19) â€” close BUG II + T-transport SKIP guard (pre-publication)

Third GLM review of the v1.8.2 package found 1 real bug introduced by the
translation and 1 gap:

- **BUG II (critical):** the DLQ writer emitted `STATUS=UNREAD` while the
  parser read `ESTADO=` (and doc/T-status fixture used `ESTADO=`). The
  `unread` flag was never set on parsed entries, so `cross status` reported
  `dlq_unread = 0` even with unpicked DLQ entries. Fixed: writer now emits
  `ESTADO=UNREAD` (parser + doc + fixture already used `ESTADO=`). Added a
  round-trip test in T-dlq (`Write-CrossDlq` â†’ `Read-DlqLog`: entry parsed,
  `unread=true`, `to`/`from`/`retries` correct). The test needed
  `Import-Module cross-diagnostic` and an `@()` wrapper around
  `Read-DlqLog` (PowerShell unwraps the 1-element result into the
  OrderedDictionary itself).
- **T-transport SKIP guard:** server-dependent scenarios (password, health,
  port override, errors, cache, scan) now SKIP with a clear message when
  there is no OpenCode Desktop server logs/password (publish template),
  matching the T-e2e pattern. The standalone regex fixture
  (`Get-CrossPortFromLog`) and config checks always run.

Suite result: **512 pass, 0 fail, 4 skip** (was 509 pass / 0 fail).

### v1.8.2 (2026-08-19) â€” close the 31 pre-existing test failures (pre-publication)

GLM's second review confirmed all v1.8 bugs closed and recommended fixing
the 31 pre-existing test failures before publishing (they existed before
v1.8.1, verified via stash). Three causes, all resolved:

- **(a) publish template has empty identity** (`my_session_id`/`my_model`/
  `leader_session_id` are blank in `cross.config.json`). Tests now adapt
  dynamically (expected sender `leader` fallback, model optional) or SKIP
  with a clear message instead of asserting against a hardcoded
  `ses_LEADER`/`model-b`. The code fallback to `leader` is unchanged
  (it is correct). Affected: T-ack (5), T-nack (5), T-aviso-spof (1),
  T-escalate (1).
- **(b) module messages still in Spanish.** All user-visible messages
  (`detail`/`throw`/`hint`/prompt text) translated to English across
  `cross-action.psm1`, `cross-state.psm1`, `cross-diagnostic.psm1`,
  `cross-transport.psm1`, `cross-delivery.psm1` and `cross/send_message.ps1`
  (fallback `leader`). The DLQ writer already emitted the English format
  (`to=`/`from=`/`retries=`) but the parser read the old Spanish one
  (`para=`/`de=`/`reintentos=`); parser, section 12.7 doc and T-dlq/T-status
  now align. Internal API field names (`razon`, `emisor`) and data-format
  states (`ENVIADO`, `ESCRITO`) are unchanged.
- **(c) tests requiring a live OpenCode server.** T-e2e and the
  T-transport regex scenario now SKIP cleanly when no server/identity is
  present instead of throwing/failing. T-transport fixture also fixed
  (unstable `LastWriteTime` sort). Affected: T-e2e (7), T-transport (1).

Suite result: **509 pass, 0 fail, 4 skip** (was 493 pass / 31 fail).

### v1.8.1 (2026-08-19) â€” GLM review fixes (pre-publication)

External review by GLM of the v1.8 package found 4 bugs and 3 minor
observations. All closed before publication:

- **BUG EE (critical):** `cross/send_message.ps1` (Phase 5 canonical
  wrapper) was never committed to the repo, but `whiteboard/send_message.ps1`
  (legacy shim) and `T-race.ps1` referenced it. Fixed: the file is now in
  the repo (translated to English), the shim chain works again, T-race
  passes 9/9.
- **BUG FF (critical):** Â§4e documented a direct-HTTP wrapper at
  `whiteboard/send_message.ps1` that did not match the real architecture.
  Fixed: Â§4e now documents the canonical `cross/send_message.ps1` (delegates
  to `cross send`, outbox/audit/retries; `-LegacyMode` for direct HTTP) and
  explains that `whiteboard/send_message.ps1` is a legacy shim.
- **BUG GG:** duplicate `## 3.` sections in CROSS_TALK.md (no `## 2.`).
  Fixed: "Session Discovery and Team Selection" renumbered to `## 2.`
  (recommended by GLM: breaks fewer cross-references).
- **BUG HH:** `Invoke-CrossAutoSweep -DryRun` mutated the outbox (only the
  audit was suppressed). Fixed: dry-run now reports without mutating;
  new T-sweep scenario (13/13 pass).
- **O1:** `cross send` auto-sweep is now documented in `--help` and a
  `--dry-run-sweep` flag was added to preview without mutating.
- **O2 (deferred):** no `cross heartbeat` subcommand yet; the ESTADO:
  convention stays manual. Documented in Appendix A.
- **O3:** `cross whoami` now suggests editing `cross.config.json` or using
  `--session-id/--model/--role` overrides on `NO_IDENTITY`. T-cli adapted to
  the publish template (skips environment-dependent cases with a clear
  message; 41/41 pass).

### v1.8 (2026-08-19) â€” heartbeat ESTADO: + enhanced wrapper (low-cost ops)

Two parallel tracks converge here: nemotron-3-ultra-free's failed experiment
as leader, and the leader's ESTADO-88 re-run (3/3 advisors replied via API
with `prompt_async` + ready-to-copy script in minutes â€” openrouter/free did
NOT respond in this round: it stayed paused by its provider's rate limit,
later it wrote its REVISION-89 vote only in its own chat, never via API).

nemotron reported 8 difficulties and 8 protocol improvement proposals.
The leader ran a REVISION-89 consultation round with all advisors (4 votes
received via API with verified signatures: mimo, nemotron, minimax,
big-pickle; plus openrouter/free's vote in its own chat and gemma's minimal
vote â€” 6/6 total). Result: 6/6 APROBAR (4 with changes). Of nemotron's
proposals, two were low-cost (no server changes) and were integrated in
v1.8 by leader decision; the rest were deferred as server-side
(Appendix A).

- **Â§10.3 Heartbeat `ESTADO:` convention:** each advisor publishes
  `ESTADO:sesion:modelo|DISPONIBLE|capacidad=...` in its own history every
  5 min or on state change; the leader builds a dashboard from
  `GET /session/:id/message` filtering `^ESTADO:` (estado_equipo.md,
  single writer). > 15 min without ESTADO â†’ NO RESPONDE â†’ standard
  diagnosis (6.1) before declaring down. **Replaces the ad-hoc STATUS CHECK
  round** (which nemotron ran as leader with `noReply=true`, which never woke
  the advisors â€” their finding #1). The heartbeat mechanism makes
  availability known BEFORE any task dispatch, eliminating the need for a
  separate status-check round.
- **Â§4e.2 `Send-CrossMessage.ps1` enhanced wrapper:** adds retry with
  exponential backoff (2s, 4s, 8s, capped 30s â€” no more failed-command
  streaks, Â§11.6) and optional delivery verification polling the
  DESTINATION history for a token (`-Token`/`-VerifWait`): HTTP 200/204 is
  only "accepted", not "processed" (nemotron case). Keeps mandatory
  auto-detection (RULE v1.4) and ASCII no-BOM payload write.

Rejected/deferred (require server-side changes, out of scope for the
API-only protocol): `/session/{id}/ping`, `deliveryMode` async_callback,
automatic ACK header, `/session/{id}/lease`, webhooks, `sessions.json`
discovery, versioned payload schema, idempotency key with 409. Documented
for future work (Appendix A).

Corrections applied in `CROSS_TALK.md`:

- **Version header:** v1.7.1 â†’ v1.8, describing both improvements.
- **Â§4d/Â§4f handshake:** `ACK-PROTOCOLO:1.6.1` â†’ `ACK-PROTOCOLO:1.8`
  (mimo's REVISION-89 note: the handshake examples still said v1.6.1 while
  the header was already v1.8).
- **Â§4e.2 new:** `Send-CrossMessage.ps1` enhanced wrapper (note: `-Token`
  is mandatory for `-VerifWait` to have effect â€” nemotron's REVISION-89 note).
- **Â§10.3 new:** heartbeat `ESTADO:` convention + dashboard (single writer =
  the leader; `HEARTBEAT_INTERVAL_MIN`=5, `STALE_THRESHOLD_MIN`=15 as
  named constants; UTC `Z` mandatory â€” nemotron/minimax/big-pickle notes).
- **Â§11 item 3:** v1.8 findings (noReply=true never wakes; curl without
  `-m` hung the shell and truncated delivery to 1/3). **Â§11 item 10 new:**
  hardcoded port `10844` pitfall (minimax/big-pickle note).
- **CHANGELOG:** this entry.

### v1.7.1 (2026-08-19) â€” pre-built JSON fallback (second E2E test TEST-E2E-86)

Re-run of the E2E test applying the v1.7 rule (ready-to-copy script in the
task message). Result: 4/4 confirmed again, with improvements and a new
finding:

- **big-pickle, mimo-v2.5-free, nemotron-3-ultra-free:** replied via API in
  round 1 (nemotron went from 4 rounds in TEST-E2E-85 to 1 round â€” the v1.7
  script rule works).
- **openrouter/free:** STILL failed with the script. Diagnosis from its
  reasoning: (a) context contaminated by the previous round (verified
  TEST-E2E-85/ACK-PROTOCOLO:1.6.1 while on round 86); (b) it did NOT
  execute the script â€” it copied the SOURCE LINE `$text = "..."` as the
  payload text, so the signature arrived with literal `` `n `` and
  `$(Get-Date ...)` unexpanded; (c) it rebuilt the text by hand instead of
  copying it exactly (`ACK-PROTOCOLO / 1.7` with spaces).

Fix: **pre-built JSON fallback** â€” the leader writes the complete payload
file itself (ASCII, no BOM, no interpolation, already signed) in a shared
path and the advisor runs ONLY the credential-detection lines plus a single
`curl --data-binary "@archivo"` line. Worked in 1 nudge.

Corrections applied in `CROSS_TALK.md`:

- **Version header:** v1.7 â†’ v1.7.1, describing the new fallback.
- **Â§4d new RULE (pre-built JSON fallback):** the last fallback before
  declaring an advisor incapable of API delivery: leader builds the payload
  file, advisor runs one curl line.
- **Â§11 item 3:** v1.7.1 finding added; escalation guideline
  script â†’ pre-built JSON.
- **CHANGELOG:** this entry.

### v1.7 (2026-08-18) â€” ready-to-copy script rule (E2E test TEST-E2E-85)

End-to-end protocol test with the 4 operative advisors (big-pickle,
mimo-v2.5-free, openrouter/free, nemotron-3-ultra-free): send â†’ ACK-PROTOCOLO
â†’ signed reply via API â†’ leader verifies the token in its history. Result:
4/4 confirmed, but with the following findings:

- **big-pickle and mimo-v2.5-free:** replied via API in round 1 without help.
- **openrouter/free:** broke the PowerShell command syntax (missing `)`
  parser errors) when building the send command itself; needed the
  ready-to-copy script verbatim (2 rounds).
- **nemotron-3-ultra-free:** wrote its complete signed reply in its OWN chat
  but NEVER sent it via API, even after 3 nudges describing the method;
  only worked when the leader embedded the ready-to-copy script (4 rounds).

Corrections applied in `CROSS_TALK.md`:

- **Â§4d new RULE (ready-to-copy script):** the leader's task message MUST
  include the complete send script (auto-detect credentials, ASCII no BOM,
  `prompt_async`) with the advisor's signed reply already embedded, ready to
  copy into the bash tool and execute WITHOUT EDITING, plus the
  verification instruction. Reference script included in the document.
- **Â§5 rule 1 (v1.7 note):** if the task message includes the ready-to-copy
  script, copy it verbatim; do not rebuild the command from memory.
- **Â§11 items 3 and 6 (v1.7 E2E finding):** documented the
  nemotron/openrouter cases and the guideline "from v1.7 on, the leader
  always embeds the script in the task message".
- Version header updated: v1.6.1 â†’ v1.7.

### Correction 2026-08-18 â€” delivery claim and mandatory verification (v1.6.1 patch)

Real incident (task PRESENTACION-84): all 6 advisors answered the task but
wrote their replies ONLY in their own chat; the leader never received them
(no API send). The protocol already said "reply via API" (section 5 rule 1),
but it was not enforced by the leader in the task message nor verified by the
advisors. Corrections applied in `CROSS_TALK.md`:

- **Â§4d (delivery claim):** the leader's task message ALWAYS includes the
  explicit claim of the correct reply method: reply via API
  (`prompt_async` WITHOUT `noReply`) to the leader's session, NEVER only in
  the own chat, and VERIFY delivery by reading the leader's history.
  Added to the canonical message template.
- **Â§5 rule 5 (mandatory verification):** the advisor, upon finishing, MUST
  ask itself whether the way it is sending the reply is the correct one
  (API to the origin session, NOT its own chat) and MUST VERIFY that the
  leader received it (read leader's history searching for its token, or
  check the log / `audit_log.md`). If it cannot confirm arrival, it must NOT
  assume it arrived: resend via API or notify the leader in its own chat.
- Rule added as a `> RULE` note after Â§4d and as new rule 5 in Â§5.

### System review - fix F4-F7 (2026-08-13)

Tolerance for historical formats in delivery_log and outbox (minor findings from
the review with the 4 advisors). See `whiteboard/38_sintesis_revision_sistema.md`:

- **F4/F6 (metrics, delivery_log):** `Get-CrossMetrics` (cross-diagnostic.psm1)
  classified by the `ack` flag of each line; historical lines
  `CONFIRMADO` with `ack=false`/`attempt=0` (old experimental test format,
  dest=ses_X) fell into OTHER and distorted the rates. Fix: classify
  by `state` (all `CONFIRMADO` counts as ACK, including fire-and-forget and the
  experimental format) and tolerant access to optional properties
  (`nack`/`reason_code`/`err`/`ack_latency_ms`/`attempt`/`session_growing`/
  `cmd` via `PSObject.Properties`, necessary under strict mode). Non-JSON lines
  are ignored without breaking metrics. Verified live: total=91, ACK=20
  (previously 2 fell into OTHER), OTHER=2 (only lines with empty state).
- **F7 (validate, outbox):** historical entries T9 and TESTD
  (2026-08-11) lived in the "## Active (v1.6 format)" section with the previous
  format (`lease=...@UTC+3min EXPIRED|successor=...`), and `cross validate`
  failed (code 2, "PROCESADO sin CONFIRMADO en outbox" for TESTD) plus the
  warning "lease sin deadline UTC". Fix: moved to the "## Historical
  (format prior to v1.6; do not parse as v1.6)" section. `cross validate` passes
  cleanly (0 errors, 0 warnings).
- **F5 (audit, no code change):** verified that the audit did record the ACK/ENV
  entries for phases 4-5; the date gap in the dump was historical. No action
  required.
- Tests: new T-metrics (19 assertions: reclassification by state, NACK by
  reason_code, EXPIRADOâ†’TIMEOUT, EN_VUELOâ†’NO_ACK, broken lines ignored,
  by-agent/since/until filters, empty destâ†’'(sin dest)', invalid since/untilâ†’
  USAGE_ERROR [covers D1], LOG_NOT_FOUND); T-validate +2 assertions (F7 section:
  historical entries with mixed format outside Active do not generate errors or
  warnings); T-cli +5 assertions (CLI wiring for metrics with --log-path,
  USAGE_ERROR code 64, LOG_NOT_FOUND).
- **BUG E2 (metrics, delivery_log):** `Write-CrossDeliveryLog`
  (cross-delivery.psm1) accessed `$Result.attempt`/`ack_latency_ms`/etc.
  directly; if the `Result` hashtable didn't carry all keys (partial
  Result), under `Set-StrictMode 2.0` it threw PropertyNotFoundException and
  broke send mid-log. Fix: helper `Get-ResultVal` that tolerates
  hashtables and PSCustomObject (same pattern as F4/F6). Covered by T-delivery.
- Tests: T-delivery +8 (Write-CrossDeliveryLog: JSONL format, audit,
  partial Result); T-transport +7 (Get-CrossPortFromLog with log directory
  fixture, Get-CrossPortByScan finds healthy port); T-poll +10 (table
  Get-PollDiagnostic in direct branches: EXPIRADO/TRANSFERIDOâ†’TERMINAL,
  AckDetected/NackDetected, LeaseVencido, UNKNOWN, PROVIDER_DOWN,
  CRECE_SIN_ACK, QUIETA_SIN_ACK); T-validate +4 (malformed outboxâ†’warn,
  non-v1.6.1 state in Activeâ†’warn). `Get-PollDiagnostic` is now an exported
  function from the cross-diagnostic module.
- Regression: **28 suites / 520 assertions / 0 failures** (1 transient failure
  from TCP scan due to real server state; isolated 19/0). CROSS practice closed.

### System review - fix F1/F2 (2026-08-13)

Field review with 4 advisors (model-a, model-d, model-f, model-b) in an
end-to-end practice run (see `whiteboard/38_sintesis_revision_sistema.md`). The 2
actionable findings were corrected:

- **F1 (diagnose):** the classification matrix of `Get-CrossDiagnose`
  (cross-action.psm1) classified `message="stream error"` without 5xx code
  (e.g. `AI_APICallError: Upstream request failed: Endpoint is unavailable`)
  as `CONFIG_ERROR` â†’ risk of false QUARANTINE/DLQ for agents with
  transient provider errors. Fix: new matrix with 2 branches:
  `CONFIG_ERROR` (auth/model only: `model not found`, `invalid model`,
  `unauthori[sz]ed`, `invalid api key`, `authentication failed`, `401`/`403`)
  before `PROVIDER_DOWN` (expanded to `AI_APICallError`, `Upstream request
  failed`, `Endpoint is unavailable`, `stream error`, `[5xx]`, timeouts,
  `ENOTFOUND`, `ECONNREFUSED`, `ETIMEDOUT`, `Rate limit exceeded`).
  Validated against model-d's real event log (12:20Z): now
  `PROVIDER_DOWN / renew lease and wait (12.10)`.
- **F2 (auto-sweep of expired):** EN_VUELO entries with expired lease stayed
  stuck until a manual `scan`. Fix: `Invoke-CrossAutoSweep`
  (cross-state.psm1) marks EXPIRADO + audit (`Tipo=SCAN`) and fires at the
  start of `cross send` (excluding the in-progress msg via `-ExcludeMsgId`).
  The `swept_expired`/`swept_count` field is exposed in the send result.
- Tests: T-diagnose 28 assertions (provider-without-5xx cases, auth/modelâ†’
  CONFIG_ERROR) and new T-sweep (9 assertions: expired only, exclusion of
  in-flight msg, no mutation if none expired).
- Regression: 24 suites / 408 assertions / 0 failures.

### System review - fix E1 (2026-08-13)

E2E test with real responses from all 4 advisors (task 39_tarea_e2e.md):
model-d confirmed with the canonical envelope (`ack_latency_ms=65733`) but
model-a, model-f and model-b responded to the leader in alternative formats
(`Firma: TOKEN:MSG-...`, `token MSG-...` mid-text, `TAREA-E2E:ACK:...`)
and the engine marked them NACK_TIMEOUT even though the response arrived.

- **E1 (strict ACK):** `Parse-CrossAckText` (cross-delivery.psm1) now
  recognizes real-world ACK variants without breaking the canonical format: the
  MSG-token declared as `TOKEN:MSG-...`, `token MSG-...` or bare prevails and
  extracts sender/model from the `:sender:model` suffix; `:ACK:...` preceded by
  colons counts as ACK; and a `TOKEN:MSG-...` declaration without ACK prefix
  is already ACK. Validated with the 3 real E2E cases.
- Tests: T-delivery +5 assertions (E1 section).
- Regression: 24 suites / 413 assertions / 0 failures.
- F2 validated live: model-d's send swept the 3 historical expired
  EN_VUELO entries (D89796, F88299, BF5936) â†’ EXPIRADO (`swept_count=3`).

### System review - fix F3 (2026-08-13)

- **F3 (whoami by config):** `cross whoami` always reported the leader's
  identity because the config is shared. Fix: explicit overrides
  `--session-id` / `--model` / `--role` (`identity_source=override`), detection
  of `shared_config` (my_session_id == leader_session_id), and auto-detection
  of real identities via `cross sessions` (GET /session with title/model/id).
- Tests: new T-whoami (17 assertions).
- Regression: 25 suites / 430 assertions / 0 failures.

### cross.ps1 Phase 5 - wrapper + scan retry-auto + metrics + race test (2026-08-13)

Implemented the 4 items from the Phase 5 plan (external-reviewer recommendation in
33_sintesis): legacy wrapper `send_message.ps1`, `cross scan --retry-auto`,
`cross metrics` and the multi-sender race test on outbox.md. See
`whiteboard/34_sintesis_fase5.md`.

- **Wrapper `send_message.ps1` (legacy signature):** `-Destino -Texto [-NoReply]
  [-Puerto] [-Password] [-LegacyMode]`. Normal mode: auto-generates
  `msg_<emisor>_<yyyyMMdd-HHmmss>-<rand6>`, inserts the OUTBOX line after
  `## Active` (v1.6.1 format) and delegates to `cross send --msg ... --dest ...
  --text ... [--no-wait]`. `-LegacyMode` = direct HTTP (v1.6.1 behavior).
  The NOTE for the agent goes to **stderr** (the stdout JSON is not corrupted);
  `exit $LASTEXITCODE`. `whiteboard/send_message.ps1` remains as a delegating
  shim.
- **`cross scan --retry-auto [--apply] [--max-attempts N]`:** diagnosis by
  default (dry-run); `--apply` executes. Classifies each expired EN_VUELO with
  `Get-CrossDiagnose`: PROVIDER_DOWNâ†’RENEW_LEASE, AGENT_SLEEPING/NO_DATAâ†’
  RESTART_TASK, CONFIG_ERRORâ†’QUARANTINE (--check-log), NO_ERRORâ†’NOTIFY_LEADER.
  `Restart-CrossTask` validates `MAX_RETRIES_EXCEEDED` (reports in `err` of the
  plan, no blind loop). With `PortArg=0` it updates state/attempt but does not
  send.
- **`cross metrics [--since|--until] [--by-agent]`:** delivery metrics from
  `delivery_log.jsonl` (total, by agent and by outcome, ack/nack/error/
  timeout rates, p50/p95 of ack_latency_ms, top NACK reasons, attempts).
- **BUG DD (critical, concurrency):** the wrapper's OUTBOX line insertion
  was a non-atomic read-modify-write. With 2+ concurrent processes, the last
  write won â†’ lines were lost â†’ `OUTBOX_MSG_NOT_FOUND` in `cross send`.
  Fix: **named mutex based on outbox path hash** (`Get-OutboxMutex`)
  that serializes insertion (`Add-OutboxEntry`, exported, with backoff
  100..1200 ms and post-write verification) and in-place updates
  (`Update-OutboxLine`); additionally `Get-OutboxEntry` (consistent read under
  the mutex) used by `Set-OutboxEstado`/`Renew-CrossLease`/`Set-OutboxAttempt` and
  by `cross send` (previously read without lock and could see the file truncated
  mid-write). Result: **80/80 unique msg_id** in the race test.
- **T-race.ps1:** 4 jobs Ã— 20 wrapper calls = 80 concurrent sends,
  isolated via `$env:CROSS_WHITEBOARD_DIR` (Import-CrossConfig respects it).
  Verifies 0 OUTBOX_LOCKED, 80 unique OUTBOX lines, no corruption, with ESTADO,
  80 valid JSONs and unique msg_id in delivery_log, audit â‰¥80. **9/9 PASS.**
- **Verified:** full suite **23 suites, 386 assertions, 0 failures**
  (new: T-race 9; T-cli unchanged 36; total regression of the 22 prior
  including real E2E 8/8). `cross metrics` validated by CLI against the
  real delivery_log (total=51, rates and latencies coherent; --by-agent/
  --since/--until filters OK).
- **External-reviewer review of the Phase 5 ZIP (2026-08-13) â€” verdict:** "Phase 5
  delivered and validated". BUG DD confirmed (root cause + fix correct). 3 quality
  observations (O1/O2 non-urgent, documented) and 2 minor details + 1
  observation, closed in v2:
  - **D1 (minor, metrics):** `--since`/`--until` with invalid format were
    silently ignored (`Parse` in empty try/catch â†’ filter not applied).
    Now returns `USAGE_ERROR` code 64 with detail (use ISO8601).
  - **D2 (minor, metrics):** `top_nack` returned ALL reasons sorted;
    now limited to the top 10.
  - **O3 (observation, metrics):** added `source: 'delivery_log.jsonl'` to
    the output to make explicit that metrics measure sends via `cross send`
    (not receiver activity/reactivations, which only go to audit_log).
  - **O1/O2 (deferred to backlog):** `Add-CrossLogLine` (audit) and
    `Add-IdempotenciaLine` (idempotency) don't use mutex (atomic append +
    retry cover current volume; apply mutex if losses appear). Mutex
    contention by path is acceptable for 3-5 agents.
- **Verified (external-reviewer review):** 23 suites, **386 assertions, 0 failures**
  (T-cli 36 no regression after D1/D2/O3); `cross metrics` revalidated by CLI
  (`source=delivery_log.jsonl`, `--since "yesterday"` â†’ USAGE_ERROR 64).



Implemented the 9 action subcommands in `cross/modules/cross-action.psm1`,
integrated into the CLI (`cross.ps1`, `ack`/`nack`/`resume`/`restart-task`/`nudge`/
`escalate`/`dlq`/`quarantine`/`diagnose`). They complement the READ layer from
Phase 4a (poll/status/reconcile/aviso-spof) with operations that mutate outbox,
escalated, DLQ and audit. See CROSS_TALK.md Â§7.5 and Â§12.6/12.7/12.10.

- **`cross ack --token T --for-msg-id X [--to] [--model]`:** emits
  `ACK:<token>:<id>[:model]` (3-4 segments, 7.1) to the destination and logs it
  in audit as `ACK|ENVIADO`.
- **`cross nack --token T --for-msg-id X --reason R [--note] [--for-run-id]`**:
  emits `NACK:<token>:<id>[:model]:<reason>` (4-5 segments) with closed reasons
  (7.5); the enriched v1.7 format (`NACK:...:msg_id:run_id`, 7 segments) only
  travels on the wire when `--for-run-id` is passed (msg_id+run_id together), so
  the parser can distinguish the enriched from the generic version.
- **`cross resume --to ses_X --task-id TX [--from] [--text]`:** executable
  continuation instruction (Â§12.10). Does NOT create a new msg_id, does NOT touch
  the outbox and does NOT increment attempt (Â§12.1).
- **`cross restart-task --msg-id X [--to] [--text]`:** RETRY with the SAME msg_id,
  attempt+1 persisted in the outbox; `OUTBOX_MSG_NOT_FOUND` /
  `MAX_RETRIES_EXCEEDED` (max `max_retries` from config).
- **`cross nudge --to ses_X --task "..." [--token]`:** firm prompt that ignores
  `Continue`/previous guidance (antidote Â§11 auto-continuation pitfall).
- **`cross escalate --msg-id X --to ses_Y --reason "..." [--run-id] [--apply]`:**
  canonical `URGENTE` line in `escalated.md` (Â§12.6); without `--apply` does NOT
  notify (dry-run); with `--apply` sends wake-on-write to the destination.
- **`cross dlq --msg-id X [--flag F] [--summary]`:** DLQ line in
  `dlq-messages.md` with closed flags `HUMAN_REVIEW|NACK_ORIGINATED|QUARANTINE|
  PROVIDER_DOWN` (Â§12.7) and marks outbox `ESTADO=DLQ`.
- **`cross quarantine --msg-id X --reason "..." [--check-log]`:** DLQ with
  `flag=HUMAN_REVIEW` + outbox `QUARANTINE`; `--check-log` diagnoses via
  `opencode.log` and appends `log=<classification>` to the summary.
- **`cross diagnose --msg X [--minutes N]`:** classifies the msg's destination from
  `opencode.log` within the N-minute window: `PROVIDER_DOWN` (504/524/connect
  timeout/ENOTFOUND/Rate limit) / `AGENT_SLEEPING` (exiting loop) /
  `CONFIG_ERROR` (other stream error) / `NO_DATA`.
- **Bugs closed during development:**
  - **BUG S (critical, audit):** `Write-AuditEntry` collided parameter
    `$Nota` with local variable `$nota` (PowerShell case-insensitive): the note
    came out duplicated (`msg=x; msg=x`) and its own text was lost. Renamed the
    local to `$notaLine`.
  - **BUG T (critical, tests):** scriptblocks `-SendFn { param($d,$t)
    Fake-Send }` received the arguments but did NOT forward them to `Fake-Send`
    (dest/text empty). Now `Fake-Send $d $t`.
  - **BUG U (medium, binding):** `[Parameter(Mandatory=$true)][string]` rejects
    `''` in binding (`ParameterArgumentValidationErrorEmptyStringNotAllowed`)
    before the manual validation that returns `USAGE_ERROR`. Manual `[string]`
    validation uses `[AllowEmptyString()]` (the CLI already casts to
    `[string]`, empty included).
  - **BUG V (medium, diagnose):** the timestamp regex discarded the `Z`
    (`timestamp=(\d{4}-...:\d{2}:\d{2})`); `[datetime]::Parse(...).ToUniversalTime()`
    treated the value as local and on UTC+2 machines shifted -2h â†’ lines
    outside the window â†’ false `NO_DATA`. The regex now captures `(?:\.\d+)?Z` and
    the parse uses `RoundtripKind`.
  - **BUG W (medium, classification):** the `PROVIDER_DOWN` regex was
    `\[504\]|\[524\]` and didn't match `stream error 524` (without brackets) â†’
    false `CONFIG_ERROR`. Added `stream error (504|524)`.
  - **BUG X (minor, segments):** `segments` reported `$segs.Count` (4) but the
    tests counted the wire text segments (`ACK:T1:sub:ses:model-b` = 5).
    Now `@($text -split ':').Count`.
  - **Test fixes:** T-nack aligned to the v1.7 spec (msg_id without run_id does
    NOT enrich the frame; enriched = 7 segments); T-quarantine `--check-log`
    uses timestamps relative to `$now` (fixed 2026-08-12 ones fell outside
    the window â†’ NO_DATA).
- **Verified:** 22 suites, **354 assertions, 0 failures** (new: ack 14, nack
  21, resume 13, restart-task 14, nudge 10, escalate 15, dlq 15, quarantine 13,
  diagnose 15; T-cli 36; real E2E 8/8 against the OpenCode Desktop server).
- **External-reviewer review of ZIP 4b (2026-08-13) â€” verdict:** "Phase 4b functionally
  complete; 1 critical bug (BUG Y) must be closed before Phase 5". Closed 5 bugs:
  - **BUG Y (critical, wire NACK):** `Send-CrossNack` with `--for-run-id` but WITHOUT
    `--model` emitted 6 segments (`NACK:token:id:reason:msg_id:run_id`), which the
    parser read from the generic `-ge 4` branch and mixed up reason/model/sender
    (total misparse). Fix (Option B recommended by external-reviewer): `Get-CrossMyModel`
    auto-derives the model from `config.my_model` when `--model` is not passed,
    in both `Send-CrossNack` and `Send-CrossAck`; if the enriched format
    still has no model â†’ `USAGE_ERROR`. Now basic ACK/NACK always carry a model
    (4/5 segments, Â§7.1/7.5 canonical) and the enriched version never emits 6 segments.
    New test in T-nack: enriched without `--model` â†’ 7 parseable segments.
  - **BUG Z (medium, DLQ):** `Write-CrossDlq` used `entry.attempt` as
    `reintentos`; attempt counts deliveries (attempt=1 â†’ 0 retries). Now
    `reintentos = max(0, attempt - 1)` (also in the `quarantine` call).
  - **BUG AA (medium, audit):** `Write-CrossDeliveryLog` wrote audit with
    direct `AppendAllText`, bypassing the retry of `Write-AuditEntry` (audit is
    multi-writer). Refactored to `Write-AuditEntry` (note built by
    parts, no duplicated `msg=`).
  - **BUG BB (minor, escalated):** `Write-CrossEscalated` emitted `msg_id`
    bare (`| msg_x |`); `Read-EscalatedLog` only recognized it if it started with
    `msg_`. Now emits explicit `msg_id=$MsgId` â†’ any msg_id format
    parses. New test in T-escalate.
  - **BUG CC (minor, restart-task):** spec v0.2 Â§7.10 requires
    `cross restart-task --max-attempts N`; the CLI dispatch didn't pass it.
    Added `[int]$MaxAttempts` to `Restart-CrossTask` (default config.max_retries)
    and the flag in `cross.ps1`. New test in T-restart-task.
- **Verified (external-reviewer review):** 22 suites, **377 assertions, 0 failures** (new:
  ack 14, nack 25 [BUG Y], resume 13, restart-task 17 [BUG CC], nudge 10,
  escalate 18 [BUG BB], dlq 17 [BUG Z], quarantine 13, diagnose 15; T-cli 36;
  T-delivery 53 [BUG AA]; real E2E 8/8 with wire confirming the model:
  `ACK:...:leader-model` / `NACK:...:leader-model:CAPACITY`).

### cross.ps1 Phase 4a - external-reviewer review v2 (2026-08-12)

External review of the Phase 4a ZIP by external-reviewer: verdict "Phase 4a validated",
conditional green light. Closed 1 critical bug + 2 medium + 2 minor and 2
design observations:

- **BUG M (critical):** regex `msg=$MsgId` without delimiters in
  `Find-AuditOutcome` (`cross poll`) and in the lifecycle of `Get-CrossStatus`.
  Same pattern as BUG B (Phase 3): `msg_123` matched the line for `msg_1234`.
  Now `msg=<id>` requires `(\s|;|\||$)` after it (plus `[regex]::Escape`).
- **BUG P (medium):** `Get-SessionState` only does growth-check if
  `status='busy'` or there's no status (previously always, 15 s by default). `cross
  status` with 5 agents goes from ~75 s to ~25 s.
- **BUG Q (medium):** `aviso-spof` notified `$MySessionId` (my own
  session). Added `leader_session_id` to `cross.config.json`; the notification
  goes to the leader's session (falls back to `$MySessionId` if not defined).
- **BUG O (minor):** the inter-iteration sleep of `poll` respects `$SleepFn`
  (previously hardcoded `Start-Sleep`, untestable with real IntervalMs).
- **BUG R (minor):** `dlq_by_flag` groups unclosed flags (Â§12.7) under
  `UNKNOWN` (previously counted any string).
- **O2 (observation):** `claimed_orphaned` adds `claimer_status` (session status
  or `unreachable`), distinguishing "claimer is quiet (real problem)" from
  "couldn't verify (network)".
- **reconcile improvement:** existing but empty check-file â†’ `AMBIGUOUS` with
  `retry` recommendation (previously `investigate`, indistinguishable from "there
  is content without a token").
- **ACKED_QUIETA message:** clarified to "agent is busy without growth,
  possible stuck".
- **Verified:** 13 suites, **235 assertions, 0 failures** (poll 19, status 21,
  reconcile 14, aviso-spof 18; T-cli 36).

### cross.ps1 Phase 4a - unified diagnostics (2026-08-12)

Implemented `poll`, `status`, `reconcile` and `aviso-spof` in the new module
`cross/modules/cross-diagnostic.psm1`, integrated into the CLI (`cross.ps1`).
All are READ-ONLY (they don't mutate outbox except `poll` marking detected NACKED
in audit, and `aviso-spof --apply` appending AVISO-SPOF). See CROSS_TALK.md Â§12.14.

- **`cross poll --msg X [--timeout S] [--interval MS]`:** per-message
  diagnosis with the primary signal `session.status` + growth (12.4/12.9):
  ACKED/NACKED/WORKING/ACKED_QUIETA/QUIETA_SIN_ACK/PROVIDER_DOWN/EXPIRED/
  TERMINAL/UNKNOWN, according to the decision table. Loop until deadline.
- **`cross status [--msg|--run-id|--agent]`:** outbox summary (by state and
  by agent with session status), `expired_unmanaged`, idempotency by
  state, `claimed_orphaned`, `escalated_pending`, `aviso_spof`, `dlq_unread`/
  `by_flag` and `lifecycle` (with `--msg`).
- **`cross reconcile --msg X --check-file PATH [--expected-token T]`:**
  automatic RECONCILE from 12.10: `CONFIRMED` (token in check-file) /
  `AMBIGUOUS` / `NOT_FOUND`, with the line where the token appears.
- **`cross aviso-spof [--apply] [--for ses_X]`:** passive SPOF detection
  (12.13): own expired EN_VUELO + quiet session â†’ `AVISO-SPOF` in escalated
  (only with `--apply`); other's â†’ notice to the leader. Dry-run by default.
- **Fix during development:** `Get-CrossStatus` filtered idempotency by
  `run_id`, a property that doesn't exist in `idempotencia-procesados.md` â†’ filter
  removed (the log doesn't carry run_id; the outbox does).
- **Verified:** 13 suites, **223 assertions, 0 failures** (new: poll 16,
  status 17, reconcile 12, aviso-spof 15; T-cli rises to 36 with 4a wiring).

### cross.ps1 Phase 3 - external-reviewer review v2 (2026-08-12)

External review of `CROSS_cross_fase3_20260812.zip` by external-reviewer (8
validation points): verdict "engine functionally complete and validated", 7 bugs.
All closed + 2 design observations:

- **BUG A (critical, parser):** `Parse-CrossAckText` now recognizes the enriched
  6-segment NACK (v0.2 Â§3.4 Finding #4 model-d)
  `NACK:<token>:<id>:<model>:<reason>:<msg_id>:<run_id>` and propagates
  `nack_msg_id`/`nack_run_id` in the engine result. 4-5 segments remain
  valid (superset). Specified in CROSS_TALK.md Â§7.5.
- **BUG B (critical, outbox):** msg_id lookup in `Update-OutboxLine` with
  delimiters `OUTBOX | <msg_id> |` (previously substring: `msg_123` touched the
  line for `msg_1234`). Applies to Set-OutboxEstado/Renew-CrossLease (they delegate).
- **BUG C (medium):** "destination is growing" check used `WaitMs=15000` by
  default (previously 2000, false negatives), configurable via `session_growing_check_ms`.
- **BUG D (medium):** `$renewed` was reset between attempts (each attempt can
  renew the lease 1Ã— if the destination keeps growing).
- **BUG L (medium):** `attempt` persisted on the outbox line
  (`Set-OutboxAttempt`, `attempt=N`) before each send; `cross send` resumes
  after a crash from the actual attempt. `Set-OutboxAttempt` exported.
- **BUG F (minor):** `Write-CrossDeliveryLog` creates `audit_log.md` (and its dir)
  if it doesn't exist, same as `delivery_log.jsonl`.
- **BUG K (minor):** `cross scan --apply/--quarantine` reports write failures
  (OUTBOX_LOCKED) in the `failed` field (previously they were silently dropped).
- **External-reviewer improvement (reason_codes):** added `NACK_SERVER_ERROR` (5xx exhausted),
  `NACK_HTTP_4XX`, `NACK_NETWORK` to the `Reason-Code` classification.
- **Cleanup:** removed redundant `Set-OutboxEstado EN_VUELO` in the
  `--no-wait` path; documented `--ack-timeout 0` (no ACK â†’ CONFIRMADO) in the help.
- **Verified:** 9 suites, **156 assertions, 0 failures** (delivery rose from 43
  to 53 with the BUG A/B/L tests).

### cross.ps1 Phase 3 - delivery engine + real E2E (2026-08-12)

Phase 3 implemented and validated end-to-end (consensus in
whiteboard/29f_sintesis_delivery.md, decisions D1-D4).

- **`cross send`:** delivery via `POST /session/<dest>/prompt_async` with
  envelope 12.1 (`Format-CrossEnvelope`) and ACK wait in the sender's session
  (window `default_ack_timeout_s=120`, polling 3s). Options: `--no-wait`
  (fire-and-forget, outbox stays EN_VUELO), `--ack-timeout`, `--max-attempts`.
- **ACK/NACK:** `Parse-CrossAckText` validates `ACK:<token>:<id>:<model>` (7.1)
  and `NACK:<token>:<id>:<model>:<reason>` (7.5); also handshake
  `ACK-PROTOCOLO`/`NACK-PROTOCOLO`. NACK â†’ outbox `NACKED` with reason.
- **Retries (table 12.9):** retry only HTTP 0/408/429/5xx, max 2 attempts,
  linear 2s backoff. 404 â†’ `DEST_NOT_FOUND` no retry; 401/403 â†’
  `AUTH_FAILED` (config). No ACK after max attempts â†’ `EXPIRADO` with
  `ACK_TIMEOUT` and `reason_code` NACK_TIMEOUT.
- **Lease:** renewed 1Ã— if the destination "grows" during the wait (heuristic
  12.4a). `cross scan` lists expired EN_VUELO; `--apply` renews lease,
  `--quarantine` marks QUARANTINE.
- **Traceability:** `whiteboard/delivery_log.jsonl` (structured log by
  msg_id) + `audit_log.md` + `ack_latency_ms` as a basic metric.
- **Real E2E (D4):** `tests/T-e2e.ps1` against the OpenCode Desktop server
  (auto-detected credentials): happy ACK â†’ CONFIRMADO, NACK â†’ NACKED,
  404 â†’ DEST_NOT_FOUND, and observability. 8/8 PASS.
- **Verified:** 9 suites, 146 assertions, 0 failures.
- **Pitfall corrected:** `"$var:`"` inside a double-quoted string is parsed
  as a PowerShell unit reference â†’ use `${var}` (recurring BUG
  1/external-reviewer, now also fixed in tests).

### cross.ps1 Phase 1 - external-reviewer review (2026-08-12)

Review of the ZIP `CROSS_cross_fase1_20260812.zip` by external-reviewer: network
contract correct on 7/7 validation points. 9 bugs reported; the 3
blockers (BUG 1-3) were closed before Phase 2 and the remaining 6 (BUG 4-9).
Verified: 45/45 tests (T-cli 29/29, T-transport 16/16).

- **BUG 1 (blocker):** removed hardcoded port `13537` in
  `Get-CrossPortByScan`. The scan now verifies EACH candidate with
  `/global/health` (no false positives) and no longer depends on the leader-model
  environment. Verified: range containing the real port finds it; empty range
  returns nothing.
- **BUG 2 (blocker):** `config --set` infers type from the existing value
  (int/long â†’ `[long]::TryParse`, bool â†’ true/false/1/0/yes/no, array â†’ error
  64). `port_cache_ttl_s=45` is saved as a number, not a string.
- **BUG 3 (blocker):** `config --set` validates against the v0.1 Â§4.1 spec:
  `my_session_id` must start with `ses_`; `default_ack_timeout_s` integer
  30-600; `default_lease_minutes` 1-30; `max_retries` 0-5; `max_saltos` 0-5;
  `protocol_version` must be `1.6.1` (warn, no block). Violations â†’ code 64.
- **BUG 4:** `duration_ms` now measures the real command (Stopwatch in each
  subcommand, `Out-Result -Watch`); removed the logic that calculated it from `ts`.
- **BUG 5:** HTTP errors classified: 5xx â†’ `HTTP_5XX`, 401 â†’ `AUTH_FAILED`,
  404 â†’ `NOT_FOUND`, rest â†’ `HTTP_4XX`. `read` with non-existent session returns
  `NOT_FOUND` with code 64 (usage), not 3 (transport).
- **BUG 6:** tests without hardcoded paths or session_ids; they read
  `cross.config.json` and derive the CROSS root (portable across environments).
- **BUG 7:** unknown flags emit WARN to stderr (`--jsno` no longer passes
  silently).
- **BUG 8:** `--role` is now case-insensitive (`--role=USER` filters the same).
- **BUG 9:** the module checks for `curl.exe` in PATH (`Import-CrossConfig`
  throws `CURL_NOT_FOUND` if not present).
- **Pitfall corrected:** `$key:` inside a double-quoted string is interpreted
  as a drive reference (`$key: foo`); use `${key}`.
- **Pitfall corrected:** `Split-Path -Parent` doesn't resolve `..` in tests; use
  `[System.IO.Path]::GetFullPath`.

### cross.ps1 Phase 1 - transport (2026-08-12)

First phase of the `cross.ps1` CLI implemented (external-reviewer spec contract v0.1, consensus
4/4 advisors in whiteboard/28f_sintesis_cli.md). Location: `CROSS\cross\`
(OUTSIDE the whiteboard, per consensus). Modular structure: entry
(`cross.ps1`) + transport module (`modules/cross-transport.psm1`) + format
library (`lib/cross-format.psm1`) + tests (`tests/`). Verified: 39/39 tests.

- **Utility subcommands:** `health`, `whoami`, `sessions [--directory]`,
  `read --session ... [--limit] [--since] [--role]`, `config [--get|--set]`,
  `--help`.
- **Auto-detection D3:** order env â†’ .env â†’ cache TTL 60s (password hash)
  â†’ regex in main.log â†’ TCP scan â†’ error. `--no-cache`, `--health-skip`,
  `--port`, `--password` as overrides.
- **Output D5:** JSON by default (single line), `--human` and `--quiet`
  alternatives. ASCII-safe in all outputs.
- **Return codes:** 0 ok, 3 transport/API failure, 64 usage/config,
  70 internal error.
- **Pitfall corrected:** `switch -Regex` in PowerShell executes ALL matching
  branches; `break` per branch is mandatory (the `--directory` flag was
  being overwritten with `$true` by the generic branch).
- **Pitfall corrected:** `-f` inside `[Console]::WriteLine("..." -f $a,...)`
  decomposes in argument mode; wrap in parentheses.
- **Pitfall corrected:** `Set-StrictMode 2.0` in modules breaks `$obj.$key` if the
  key doesn't exist; use `$obj.Contains($key)` + indexer.

### v1.1 (2026-08-10)

Consensus of 3 advisors (model-c, model-b, model-d) after 3 rounds of improvement. Contributions
integrated: section 7 (ACK), section 8 (renumbered, coordination), section 9
(audit), section 10 (monitoring), section 11 (known issues expanded),
appendix A (future improvements) and optional wrapper `send_message.ps1` (4e). The
previous improvements remain in effect; the version bump is due to insertion of
new sections.

### v1.2 (2026-08-10)

Changes requested by the human user after v1.1: (a) the token signature
includes the **model name** (`TOKEN:<SESSION_ID>:<MODEL>`,
sections 4d, 5, 7.1, 9.1) so the user can identify the model at a glance, and
(b) agents know that the leader can **review their session from outside** to
detect stuck situations and, if they cannot complete the task, they write a notice
in their own chat (section 6.1e).

### v1.3 (2026-08-10)

Minor refinements agreed by the 3 advisors when validating v1.2:
clarification of ACK with the sender's model at the end (7.1), MODEL column in
the log (9.1), concrete signed token example in 4d, exact HTTP error in the
chat notice (6.1e) and `--aviso-atasco` for the wrapper as a future improvement
(appendix A). Token parsing tolerates 3 or 4 segments (`TOKEN:ID` or
`TOKEN:ID:MODEL`).

### v1.4 (2026-08-10)

Mandatory auto-detection of credentials before EVERY send. After a
real incident (model-b used an old port and password and its vote didn't arrive even though
the script reported success), the rule was established to never hardcode
port/password (section 1), the wrapper `send_message.ps1` always auto-detects
and ignores fixed values (4e), and the case is documented in known issues
(11, item 9).

### v1.5 (2026-08-10)

Lessons from the Bugs TXBridge task + contributions from the 3 advisors. Pitfalls
documented: BOM in JSON â†’ HTTP 500 (section 4, with ASCII preference â€” contribution
model-c), derailment by auto-continuation "Continue if you have next
steps..." (6.1c), sender identity in the leader's message (4d, 5, pitfall
model-d) and **main channel = API** (responding only in the chat is a delivery
failure; 5, user request). `prompt_async` remains the STANDARD method
(4c, contribution model-d), responding with the same received token (5, contribution
model-c) and new section 8.1 "Large project analysis" (contribution model-c). New
section 8.2 "Tool location" (python/Windows Store pitfall,
user request). The 3-round flow
analysisâ†’verificationâ†’consensus was validated (item 27). Changes are additive only, no
rule changes.

#### v1.5 Extension (2026-08-11, riddle competition)

Empirically proven pitfall â€” `noReply: true` stores the message but does NOT
wake the destination agent (section 5.1). Rule reinforced: always respond
with `prompt_async` without `noReply`.

### v1.6 (2026-08-11)

Anti-sleep protocol and wakeup guarantee. Consensus of 4 advisors (model-c,
model-d, model-b, model-a) after 3 rounds of improvement. New section 12: standard
message envelope with `msg_id`, durable outbox before send, ACK on turn
boundary, passive presence (no PING/PONG), lease with successor, escalation
channel, DLQ, idempotency, circuit breaker A/B/C and recovery scan
RETRY/RESUME/RECONCILE/QUARANTINE. Central principle (user request): NO
message should stay asleep and every agent must be able to wake up. Integrated
adjustments from model-d (ACK timeout 120s, default successor = next in
turns, msg_id with sender prefix, outbox updated only by sender,
RECONCILE with output file verification) and from model-a (ACK with full
7.1 format, lease with explicit successor in envelope). Sections 1-11 and
appendix A remain in effect; changes are additive.

#### Subsequent v1.6 adjustments (2026-08-11, test campaign)

- **Â§12.3 fixed at 120s WITHOUT backoff** with decision based on two signals (session
  is growing â†’ renew lease; quiet â†’ circuit breaker). Â§7.3 (30s/backoff
  30/60/120) is subordinate to Â§12.3 for messages with `requiere_ack=true`
  (precedence documented in 7.3).
- **Â§12.8 and Â§12.12:** terminology corrected from "exactly-once" to **at-least-once
  with deduplication by `msg_id`** (effectively-once), after external review.
- **Â§12.13 (new):** accepted trade-offs â€” leader SPOF documented as an
  explicit limitation (no leader election in v1.6; mitigated by human-readable
  files and human supervision). Leader election added to Appendix A.

#### Restructuring (2026-08-11, after external-reviewer + external-reviewer-2 review)

- **Document split:** the version history and "Summary of findings" (32
  findings) were moved from `CROSS_TALK.md` to this file
  (`CHANGELOG.md`). `CROSS_TALK.md` now contains only current rules
  (1180 â†’ 1054 lines).
- **Appendix B (new):** consolidated PowerShell 5.1/Windows pitfalls
  (JSON/BOM, mojibake, paths, `&&`, `${var}`, concurrent Add-Content,
  python/Windows Store), isolated from the protocol rules. Section 11
  retains items 1, 2, 7, 8 with delegation to Appendix B (the 11.x
  numbering is unchanged to avoid breaking references).
- **Format drift corrected:** `whiteboard/outbox.md` rewritten with the
  v1.6 canonical grammar (old stress lines moved to the "Historical"
  section); entry T9 was marked CONFIRMADO (it was EN_VUELO
  with a spurious duplicate with leading space). `whiteboard/escalated.md` without
  BOM. Normalized CRLF â†’ LF in operational files.
- **Diary moved out of whiteboard:** `whiteboard/15_charla_conciencia.md` (93 KB)
  moved to `diario/15_charla_conciencia.md`; references in CROSS_TALK.md
  (12.10), 16_diario_conversaciones.md and 26_informe_maestro.md updated.

### v1.6.1 (2026-08-11)

Semantic corrections after external review (external-reviewer + 4 advisors) on
v1.6. These are NOT new protocol changes, but clarifications and cleanup; the
real v1.7 will come when the backlog is implemented and tested. Applied in
CROSS_TALK.md:

- **RESUME â‰  RETRY (main correction from external review):** `sigue` is
  RESUME (same session + context + implicit task_id), it does NOT retransmit the
  logical message and carries no `msg_id`. RETRY is retransmission of the SAME `msg_id`
  (idempotent). Corrected in Â§6.1c and Â§12.5(b), which mixed both.
- **Formal identities (new Â§12.1):** `task_id`, `run_id`, `msg_id`,
  `attempt`, `session_id` defined as independent identities.
- **Â§12.3 terminology:** "ACK timeout" â†’ "ACK decision window of 120s" (if the
  session is growing another window is expected; it's not a failure at 120s).
- **Â§6.1d simplified:** partition rule â€” messages with ACK â†’ Â§12.3
  governs; messages without ACK â†’ Â§6.1d governs. No dual interpretation.
- **Â§12.6:** the claim of "innovation without equivalent" is softened to
  "shared-state coordination pattern developed for CROSS" (without claiming
  absence of equivalents in A2A/MCP).
- **Â§12.13 AVISO-SPOF:** passive detection by advisors at end of turn
  (light scan of outbox for expired EN_VUELO belonging to their ID â†’ notice in
  `escalated.md`), no leader re-election or task takeover (consensus of the 4).
- **Document cleanup:** Appendix B (PowerShell/Windows pitfalls) moved to
  **`CROSS_WINDOWS.md`**; the "Discovery History" and "Appendix B" sections removed
  from CROSS_TALK.md (section 11 references updated to
  `CROSS_WINDOWS.md`); CROSS_TALK.md now contains ONLY current rules (~1147
  lines).
- **Appendix A:** prioritized backlog for the real v1.7 â€” SQLite (HIGH/low) and
  `session.status` (HIGH/low) first; SSE conditional on the backend (test
  `GET /event` experimentally first); SDK low; `session.abort` opt-in/soft.
  Pending decision: SQLite is an architectural improvement, not an urgent fix
  (the single-writer rule already eliminates the T10 protocol concurrency issue).

#### Final v1.6.1 adjustment (2026-08-11, second external-reviewer review)

- **Bounded effectively-once (Â§12.8 and Â§12.13):** deduplication by `msg_id`
  achieves effectively-once ONLY for idempotent operations; for non-idempotent
  ones, RECONCILE or effect confirmation is required. The excess
  "effectively-once by construction" was removed.
- **`attempt` semantics (Â§12.1):** RETRY â†’ +1, TRANSFER â†’ +1, RESUME â†’
  no increment (it's not a new delivery).
- **Executable RESUME (Â§12.10):** specification of how it works: `prompt_async`
  on the same `session_id` with a continuation instruction based on the
  checkpoint; no reuse of `msg_id`.
- **Complete document cleanup:** removed traces of history/
  appendices from CROSS_TALK.md (only current rules remain).

#### Format corrections for the CLI (2026-08-11, external-reviewer contribution)

external-reviewer (third external review) fixed the EXACT formats that the future CLI
`cross.ps1` will have to parse, eliminating tolerated variations:

- **CLAIMED (Â§12.8):** new state in the idempotency state machine
  (`CLAIMED` â†’ `PROCESADO`) that covers the 30-90 s window of LLM
  processing and prevents the double-processing race. EXACT format:
  `msg_id | timestamp_claim | modelo_claimer | CLAIMED_BY=ses_X` (no extra
  spaces, no variations). Retry only if there's no line or if the claimer is
  quiet (double-read 12.4). Applied to `CROSS_TALK.md` and
  `whiteboard/idempotencia-procesados.md`.
- **Protocol handshake (Â§4d):** the task message carries
  `PROTOCOLO: CROSS-TALK v1.6.1`; the advisor responds `ACK-PROTOCOLO:1.6.1`
  (EXACT three segments, no `v`, no prefix) within 30 s. Different version â†’
  leader sends inline critical rules summary; agent without protocol â†’
  summary + retry; response `NACK-PROTOCOLO:version_no_soportada:<version>`
  â†’ leader decides whether to continue or exclude. Repeated at the start of
  each task.
- **Explicit NACK (new Â§7.5):** the advisor that cannot process declares
  `NACK:<token>:<ID>:<MODEL>:<REASON>` instead of processing blindly or staying
  silent. Closed reasons: `CAPACITY | TOOL_MISSING | AMBIGUOUS_TASK |
  PROVIDER_DOWN | OTHER` (no free text). Reassign, abort or escalate;
  do not penalize the NACK sender. (The old Â§7.5 "Relationship" became Â§7.6.)

#### external-reviewer format corrections F1-F4 + O1-O2 (2026-08-11)

After external-reviewer verification of the ZIP with the 3 corrections, 4
minor format failures and 2 design observations are closed before the
test campaign:

- **F1:** `outbox.md` declares the new `NACKED` state in the canonical
  list (`EN_VUELO / CONFIRMADO / EXPIRADO / TRANSFERIDO / NACKED`).
- **F2:** `dlq-messages.md` and Â§12.7 add the `flag` field to the DLQ
  format (`... | ESTADO=NOT PENDING PICKUP | flag=HUMAN_REVIEW | "summary"`),
  with closed values `HUMAN_REVIEW | NACK_ORIGINATED | QUARANTINE |
  PROVIDER_DOWN`. Â§7.5 no longer mentions "flag" as an idea: it is now specified.
- **F3:** Â§7.5 adds the leader's recommended action table for each NACK
  reason (`CAPACITY` reassign without +1 attempt; `TOOL_MISSING` provide
  path/tool or reassign; `AMBIGUOUS_TASK` rephrase + new msg_id;
  `PROVIDER_DOWN` wait/exclude; `OTHER` DLQ with `flag=HUMAN_REVIEW`).
- **F4:** Â§9.1 expands valid TIPO values in audit_log with `ACK-PROTOCOLO`, `NACK`,
  `NACK-PROTOCOLO`, `CLAIM`, `DONE`, `RELEASE`.
- **O1:** `idempotencia-procesados.md` becomes an **append-only log** (like the
  outbox): the `CLAIMED â†’ PROCESADO` transition and the `release` are appended as
  NEW lines (`PROCESADO` / `SUPERSEDED_BY=ses_Y`), never rewritten.
  The CLI parser reads the LAST line of each `msg_id` as the current state.
  Eliminates the in-place editing race in PowerShell (Get-Content â†’
  Set-Content is not atomic) without SQLite.
- **O2:** new Â§4f "Minimal critical rules (handshake fallback)": a canonical
  8-line copyable block that the leader sends when the advisor doesn't
  respond `ACK-PROTOCOLO`; Â§4d references Â§4f instead of an improvised
  "summary".

#### Cleanup D1-D2 + seeded examples (2026-08-11, external-reviewer #2 verification)

External-reviewer verification of the F1-F4 ZIP: the 6 corrections properly integrated.
2 cleanup details closed and examples seeded for the CLI parser:

- **D1:** Â§12.8 consolidated into a SINGLE rule block (CLAIM/PROCESADO/
  Release/Retry/parser). The second block with different wording that could
  confuse which was the norm was removed; the retry rule with double-read
  (12.4) was merged into the single block.
- **D2:** Â§12.12 aligned â€” `outbox.md` lists `NACKED` in the states; the
  `idempotencia-procesados.md` line becomes "append-only log of the lifecycle
  of each msg_id (CLAIMED â†’ PROCESADO / SUPERSEDED_BY); dedupe by last
  line"; `dlq-messages.md` mentions the `flag`.
- **Seeded examples:** `idempotencia-procesados.md` adds an
  "State examples (v1.6.1 format â€” DO NOT delete)" section with `CLAIMED_BY` and a
  `CLAIMED_BY` â†’ `SUPERSEDED_BY` pair so that future CLI tests can
  validate the "last line wins" logic on real data (not just
  `PROCESADO`).

With this, the ZIP serves as the **baseline for the short validation campaign**
(T-HS, T-CLAIM, T-RELEASE, T-NACK) and the subsequent `cross.ps1` specification.

---

## Summary of findings (proof of concept)

History of findings by version (moved from CROSS_TALK.md on 2026-08-11).

1. The desktop server is at `http://127.0.0.1:PORT` with basic auth
   `opencode:$env:OPENCODE_SERVER_PASSWORD`.
2. `POST /session/:id/message` with `parts[].type = "text"` delivers the message
   to that session and persists it in its history.
3. Without `noReply`, the call waits and returns the destination agent's response.
4. `POST /session/:id/prompt_async` delivers the message and lets the destination
   agent process it in the background (returns `HTTP 204`).
5. Messages are stored: either session can read them
   with `GET /session/:id/message`.
6. To confirm bidirectional crosstalk: send a message with a unique
   token, the destination agent responds to the source session using the same
   mechanism, and the source session verifies the token in its history.
7. Fails with `HTTP 500` only if the body arrives corrupted due to PowerShell
   quoting; the fix is to send it from a file with `--data-binary`.
8. When the app restarts the port changes (and the password may change):
   redetect and verify credentials at the start of each task with
   `/global/health`.
9. For collaborative tasks, use rounds with tokens and request an explicit
   contribution if you want the other session to work on your proposal.
10. Accents/special characters may arrive as `?` (mojibake):
    send in plain ASCII and fix when integrating responses.
11. "Wakeup" is automatic: sending WITHOUT `noReply` (or with `prompt_async`)
    makes the destination agent process the message on its own, without polling.
    `noReply: true` just leaves it in the chat with no reaction.
12. **Main pitfall:** an agent may respond in ITS OWN conversation without
    sending it to the source session. Verify the response with its token in YOUR
    history; if it doesn't appear, demand that it be sent via API (section 5).
13. **Identify votes:** with N advisors, a fixed token arrives multiple times and
    it's unknown who responded. Each sender must sign with its ID and model:
    `TOKEN:ses_XXXXXX:model` (e.g. `ACUERDO-FINAL-C1:ses_XXXXXXXX:model-b-v2.5-free`).
    This way one agreement/change is counted per agent, the author is identified and
    the human user reads at a glance which model responded (v1.2).
    **The leader communicates each member's own ID and model in the task
    message (section 4d); advisors must NOT guess their ID by deducing it
    from the session list** (real pitfall: two agents from the same directory
    confused their IDs and signed tokens with other agents' IDs).
14. **Stuck agents:** you can read any session with
    `GET /session/:id/message` to diagnose what happened (6.1a). Before
    intervening, verify that the session is NOT growing between two reads (6.1b): if
    it's growing, it's still working and nothing needs to be done. Only if it's
    quiet, wake it by sending `sigue` with `prompt_async` (6.1c).
15. **Validated with 4 advisors (2026-08-10, Buda task):** with the leader
    communicating each advisor's own ID (section 4d), the 4
    `MI-CONTRIBUCION-B2` tokens and the 4 `ACUERDO-FINAL-B2` tokens arrived signed with the
    correct ID of each one and 4/4 agreements were counted without ambiguity. One
    advisor got stuck twice and recovered with `sigue` (6.1c), responding
    correctly at the end.
16. **ACK (v1.1):** the token `ACK:<token>:<SENDER_SESSION_ID>:<SENDER_MODEL>`
    confirms processing (section 7). Originally 30 s timeout with
    backoff (30/60/120 s) and `sigue` fallback. **SUPERSEDED for
    `requiere_ack=true` by Â§12.3 (fixed 120s, no backoff), v1.6.**
17. **Audit (v1.1):** `whiteboard/audit_log.md` records sends/receives
    in pipe format `| timestamp | origin | destination | token | type | status | note |`.
18. **Monitoring (v1.1):** `GET /session/:id` is the lightweight presence method;
    `whiteboard/task_status.md` is the global dashboard per round. `heartbeat.json`
    was discarded due to race conditions.
19. **Detecting provider outage (v1.1):** the last empty `assistant` created in
    milliseconds after the `user` + frozen `time.updated` reveal a provider
    failure, not a stuck situation. Documented in 11.5.
20. **3-round consensus (v1.1):** protocol improvements were agreed with
    3 advisors (model-c, model-b, model-d) using tokens `MEJORA-R1/R2/R3:<ID>`;
    a down provider (north-mini-code) was excluded without blocking the task, and
    one agent (model-d) required explicit help to send its vote (11.6).
21. **Signed with model (v1.2):** the token carries the `:<MODEL>` suffix in addition
    to `:<SESSION_ID>` so the human user can identify the model at a glance
    (sections 4d, 5, 7.1). The session ID remains the canonical identifier.
22. **External monitoring by the leader (v1.2):** the leader can read any member's
    session (`GET /session/:id/message`, 6.1a) and check their status
    (`GET /session/:id`, 10.1). Agents know this and, if they cannot complete the
    task, **write a notice in their own chat** in plain text; the leader sees
    it and sends them help (6.1e, 11.6).
23. **v1.2 consensus validated (3/3):** the 3 advisors agreed on v1.2 (tokens
    `ACUERDO-V12:<ID>:<MODEL>`). They contributed minor refinements integrated in
    v1.3: ACK with sender's model at the end (7.1), MODEL column in the log
    (9.1), concrete example in 4d, exact HTTP error in the chat notice (6.1e)
    and `--aviso-atasco` as a future improvement (appendix A).
24. **Incomplete signature pitfall (v1.3):** model-b signed `ACUERDO-V12:-v2.5-free`,
    omitting its session ID despite being informed. The message was identified
    by the model, but the ID was incomplete. Token parsing must tolerate
    3 or 4 segments (`TOKEN:ID` or `TOKEN:ID:MODEL`), as model-b requested.
25. **BOM in JSON pitfall (v1.5, tested 2026-08-10):** generating the payload with
    `[System.Text.Encoding]::UTF8` (with BOM) causes `HTTP 500 Unexpected
    server error`. Use UTF-8 without BOM or ASCII (see section 4). Two sends to
    model-d failed due to this before detection.
26. **Derailment by auto-continuation (v1.5, tested 2026-08-10):** automatic
    "Continue if you have next steps..." messages cause some
    advisors (model-d) to summarize or change topic instead of delivering their report.
    Antidote: explicit and firm nudge with `prompt_async` specifying what to deliver
    and what to ignore (see 6.1c).
27. **Round 2 verification validated (v1.5, Bugs TXBridge task):** the flow
    analysis (R1) â†’ verification (R2, each advisor responds CONFIRMO/RECHAZO/
    AJUSTO to the leader's consolidated list) â†’ consensus (R3, vote ACEPTO/
    AJUSTO) closed a list of 15 bugs + 4 candidates with 3/3 OK signatures in
    each round and without reopening false positives. The R2 phase detected an
    inconsistency from the leader itself (outputAtten listed as "functional" in
    discarded when Bug B4 marked it as dead code) â†’ the leader corrected it.
    Guideline: the leader also verifies the advisors' claims against the
    code before consolidating.
28. **Sender identity in the message (v1.5, tested 2026-08-10):** model-d
    got blocked not knowing which session to respond to because the task
    message didn't identify the sending leader. Since v1.5, the leader includes
    its own ID and model in the message in addition to the recipients' (4d) and
    advisors request confirmation if the sender is not identified (5, rule 2).
29. **Main channel = API (v1.5, human user request):** the response
    MUST be sent to the source session via API (`prompt_async` or
    `/message`). Writing only in your own chat is a delivery failure: the
    sender doesn't see it and must demand it (tested with model-b in v1.5). Respond in the
    chat only when there is no other way to send (external failure, no
    network tools) and ALWAYS notifying the leader. See section 5, rule 1.
30. **Advisor contributions v1.5 (integrated):** model-c (ASCII preferred over
    UTF-8 without BOM for sends; respond with the same received token; section 8.1
    large project analysis), model-d (`prompt_async` as standard,
    noReply redundant). Confirmed by model-b, model-c and model-d with
    `TOKEN:PROTOCOLO-V15:<ID>:<MODEL>`.
31. **Tools with full paths (v1.5, pitfall tested):** `python` in
    the PATH is the Windows Store stub and does NOT execute; the real one is in
    `AppData\Local\Python\pythoncore-3.11-64`. The leader must specify full tool
    paths in the task (section 8.2).
32. **Anti-sleep protocol v1.6 (2026-08-11):** consensus of 4 advisors
    (model-c, model-d, model-b, model-a) after 3 rounds. The wakeup guarantee doesn't
    come from better waking the sleeper but from work in flight having
    an owner with an expirable lease, durable registry in an outbox and a recovery
    scan that classifies (RETRY/RESUME/RECONCILE/QUARANTINE) instead of
    blindly retransmitting. `prompt_async` remains the ONLY primitive that
    wakes; files (outbox, escalated, DLQ) are visible backup.
    Implemented in section 12.
