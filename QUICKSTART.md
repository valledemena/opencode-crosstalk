# OpenCode Cross-Talk - Quick Start (v2.2.0, Fase 2)

Verifiable messaging between OpenCode sessions (outbox + ACK/NACK + DLQ + HMAC + wait-idle).

> **v2 wire format:** only `ENVELOPE-V2` JSON (`ENVELOPE-V2: {json}` or pure
> JSON) is accepted. Legacy v1 free-text `ACK:`/`NACK:`/`TOKEN:` lines are
> rejected. Use the CLI - it emits v2 and posts it for you.

## 1. Prerequisites
- OpenCode Desktop running (serves the local API).
- PowerShell 5.1+ (Windows) or pwsh.
- `curl` available - resolved cross-platform by `Get-CrossCurlCommand`
  (Windows: `curl.exe`; Linux/macOS: `curl`); `cross health` validates it.
- `OPENCODE_SERVER_PASSWORD` in the environment or in
  `~/.config/opencode/.env` (the environment variable wins if both exist).

## 2. Set your identity (1 minute)

Run the setup helper from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

It validates the session against the API, reads your **model from the API**
(never from guesses), writes the git-ignored `cross/cross.config.local.json`
and verifies `health` + `whoami`.

If it cannot determine YOUR session unambiguously it prints the candidates and
exits with code 2. Choose explicitly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -SessionId ses_YOUR_ID
```

Manual alternative: write `cross/cross.config.local.json` yourself (do NOT edit
the publish template `cross.config.json`):

```json
{ "my_session_id": "ses_YOUR_ID", "my_role": "advisor" }
```

`my_model` is optional: `whoami` derives it from the API when absent.

## 3. Verify connectivity
```powershell
cd cross
.\cross.ps1 health      # -> ok if the server answers /global/health
.\cross.ps1 whoami      # session + model (model_source=config|override|api)
.\cross.ps1 sessions    # list project sessions
```

## 4. Send your first message (with ACK)
```powershell
.\cross.ps1 send --msg msg_001 --dest ses_DEST --text "Hello"
```
The outbox entry is auto-created if it does not exist (`auto_created: true`).
Outbox states (`whiteboard/outbox.md`):
EN_VUELO -> CONFIRMADO | NACKED | EXPIRADO | DLQ.

## 5. When YOU receive a task: ACK first
```powershell
.\cross.ps1 ack --token <token> --for-msg-id <msg_id> --to <sender_session>
```
This posts a v2 JSON ACK to the sender's session and auto-resolves port/password.
Then do the work; if you cannot, use `nack --reason CAPACITY|TOOL_MISSING|...`.

## 6. Verify and idle (v2.2.0)
```powershell
.\cross.ps1 verify --envelope '{"v":2,"type":"message","msg_id":"X"}' [--secret S]
.\cross.ps1 wait-idle --session ses_DEST [--timeout 60] [--interval 1000]
```
- `verify`: checks the HMAC `sig` (optional; requires `CROSS_HMAC_SECRET` or `cross/cross.hmac.secret`).
- `wait-idle`: blocks until the session goes idle (`POST /api/experimental/session/{id}/wait` 204, or poll `time.idle` with 3000 ms quiet threshold).

## 7. If something fails
```powershell
.\cross.ps1 status              # outbox/DLQ overview
.\cross.ps1 diagnose --msg X    # why it failed
.\cross.ps1 metrics             # ACK/NACK/timeout rates
```
Common errors: SERVER_NOT_FOUND (Desktop closed), AUTH_FAILED (password
precedence), ACK_TIMEOUT (destination busy - use nudge), DEST_NOT_FOUND
(unknown session), OUTBOX_MSG_NOT_FOUND (old bug: run from any cwd now works;
paths resolve against the config file since v2.1.1).
- Fixture contamination (`fixture-clean`): `cross.config.local.json` overrides template identity. Use `fixture-clean.psm1` (`Start-CleanFixture` / `Stop-CleanFixture`) or run from `cross/`.
- Version note: `v2.2.0` (Fase 2) adds `wait-idle`, `verify` (HMAC), and `fixture-clean`.

## Next steps
- LLM bootstrap: AGENTS.md
- Full protocol: CROSS_TALK.md
- User guide: USER_GUIDE.md
- Windows pitfalls: CROSS_WINDOWS.md
