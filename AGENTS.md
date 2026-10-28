# AGENTS.md - Bootstrap for LLM sessions participating in Cross-Talk

You are an LLM agent (OpenCode session) that has landed on this repository.
This file gives you everything you need to USE Cross-Talk without reading
anything else. Follow it top to bottom.

## What Cross-Talk is

Durable, verifiable messaging between OpenCode sessions: an outbox with ACK/NACK
handshakes, retries, idempotency and a dead-letter queue. The CLI is
`cross/cross.ps1`. Wire format is **ENVELOPE-V2 JSON only** (v1 free-text
`ACK:`/`NACK:`/`TOKEN:` lines are rejected on the wire since v2.0, but the codebase keeps v1 compatibility in historical sections). Full spec: `CROSS_TALK.md`.

> **Compatible v1 + v2:** this repo extends `opencode-crosstalk` locally (Fase 2: `wait-idle`, HMAC `sig`) without deprecating upstream V1 (`valledemena/opencode-crosstalk-v2`). `v2.0.0` made ENVELOPE-V2 exclusive; `v2.2.0` adds Fase 2.

## Step 1 - Identify yourself

Your session ID looks like `ses_xxxxxxxxxxxx...`. Do NOT guess it and do NOT
pick `sessions[0]` from a list. Run the setup helper from the repo root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

It validates the session via the API, writes the git-ignored
`cross/cross.config.local.json`, reads your **model from the API**, and verifies
connectivity. If it says the session is ambiguous (exit code 2), pick yours from
the printed table:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -SessionId ses_YOUR_ID
```

If you must do it by hand, put ONLY your identity in
`cross/cross.config.local.json` (never edit the publish template):

```json
{ "my_session_id": "ses_YOUR_ID", "my_role": "advisor" }
```

`my_model` is optional: `whoami` derives it from the API when absent.

## Step 2 - Verify connectivity

```powershell
cd cross
.\cross.ps1 health      # OpenCode Desktop must be running; needs OPENCODE_SERVER_PASSWORD
.\cross.ps1 whoami      # session + model (model_source=config|override|api)
.\cross.ps1 sessions    # lists other sessions of this project (your peers)
```

If AUTH_FAILED: the password lives in the `OPENCODE_SERVER_PASSWORD` env var or
`~/.config/opencode/.env`; the env var wins when both exist.

## Step 3 - Send a message to another session

```powershell
.\cross.ps1 send --msg msg_001 --dest ses_PEER_ID --token T1 --text "your task text"
# Optional: --delivery steer|queue. Default queue: a busy peer takes the message
# when idle (never derails a turn in progress); steer shows it mid-turn.
```

- If `--dest` and `--text` are given with a new `--msg`, the outbox entry is
  auto-created (`auto_created: true`).
- Without `--msg`, a msg_id is auto-generated and tracked in `whiteboard/outbox.md`.
- The command blocks until ACK/NACK/timeout (default 120s) and handles retries.
- Final states: `CONFIRMADO` (ACK received), `NACKED`, `EXPIRADO` (timeout), `DLQ`.
- Parse the last JSON line of stdout (`ok`, `state`, `ack_id`, `ack_model`).
- Config paths resolve against the config file, so the CLI works from any cwd
  (still recommended: run it from `cross/`).

## Step 4 - When YOU receive a task message

1. **ACK FIRST** (before any work). This is a v2 JSON envelope posted to the
   sender's session; the CLI fills your id/model and resolves port/password:

   ```powershell
   cd cross
   .\cross.ps1 ack --token <token> --for-msg-id <msg_id> --to <sender_session>
   ```

2. **Claim it** (idempotency, prevents double processing):
   `.\cross.ps1 claim --msg msg_X`
   - `{ok:true, already:false}` -> you own it. Proceed.
   - `ALREADY_CLAIMED_BY_OTHER` -> do nothing; another session owns it.
3. Do the task. Write shared artifacts to `whiteboard/` as agreed.
4. **Close it**: `.\cross.ps1 done --msg msg_X`
5. **Reply to the sender** via the V2 prompt API
   (`POST /api/session/<their-id>/prompt`, body `{"text":"..."}`) and sign with
   the SAME token. Prefer the CLI (`send`/`ack`) over hand-built curl: it emits
   valid ENVELOPE-V2 JSON with the V2 endpoint and body (`prompt_async` and
   `{"parts":[...]}` are V1-only and must not be used).
6. If you cannot or should not do it, reject explicitly:
   `.\cross.ps1 nack --token <token> --for-msg-id msg_X --reason CAPACITY --to <sender>`
   Closed reasons: CAPACITY | TOOL_MISSING | AMBIGUOUS_TASK | PROVIDER_DOWN | OTHER.

## Handshake conventions (v2)

- A task message carries `PROTOCOLO: CROSS-TALK v2`. Acknowledge within 30 s
  with `cross.ps1 ack ...` (that ACK IS the handshake).
- A v1-style `ACK-PROTOCOLO:` line does NOT count.
- Never hand-write `ACK:`/`NACK:`/`TOKEN:` lines: only `ENVELOPE-V2: {json}` or
  pure JSON is parsed.
- **Verify an envelope's HMAC signature** (optional, Fase 2): if the secret
  `CROSS_HMAC_SECRET` or file `cross/cross.hmac.secret` is set, every envelope
  carries a `sig` field:
  ```powershell
  .\cross.ps1 verify --envelope '{"v":2,"type":"message","msg_id":"X","token":"T"}' [--secret S]
  ```
  The `verify` handler returns `{valid:true|false, has_sig:true|false, ...}`.
- **Wait for a session to go idle** (optional, Fase 2):
  ```powershell
  .\cross.ps1 wait-idle --session ses_X [--timeout 60] [--interval 1000]
  ```
  Primary: experimental server-side `POST /api/experimental/session/{id}/wait`
  (HTTP 204 = idle). Fallback: poll `GET /api/session/{id}` until
  `time.idle >= time.updated` or `updated` is older than 3000 ms. Returns
  `{idle:true|false, method:..., timed_out:..., elapsed_ms:...}`.

## Shared clone with several agents

Each agent needs its own identity WITHOUT touching the local config. Use env
overrides (note the doubled `MY_`, it is intentional):

```powershell
$env:CROSS_MY_MY_SESSION_ID = 'ses_YOURS'
$env:CROSS_MY_MY_MODEL = 'your-model'
.\cross.ps1 whoami
```

## Versions

- `v2.0.0` — ENVELOPE-V2 JSON only (breaking); no more v1 `ACK:`/`TOKEN:` lines.
- `v2.1.1` — install/ACK/cwd fixes; `whoami` derives model from API.
- `v2.2.0` (current, Fase 2): `wait-idle`, `verify` (HMAC `sig`), `fixture-clean`.

## Troubleshooting

```powershell
.\cross.ps1 status              # outbox/DLQ overview
.\cross.ps1 diagnose --msg X    # why a delivery failed
.\cross.ps1 metrics             # ACK/NACK/timeout rates + latency P50/P95
```

Common errors: `SERVER_NOT_FOUND` (Desktop closed) -> `AUTH_FAILED` (password
precedence: env wins over .env) -> `ACK_TIMEOUT` (peer busy - try `nudge`) ->
`DEST_NOT_FOUND` (bad session id).

- **Tests fail (`fixture-clean`):** the local `cross.config.local.json` pollutes fixtures. Use `fixture-clean.psm1` (`Start-CleanFixture` / `Stop-CleanFixture`) in test scripts; it temporarily moves `local.json` and writes a blank `cross.config.json`.
- **`verify` returns `missing_sig`:** no `CROSS_HMAC_SECRET` set and no `cross/cross.hmac.secret`. Set the env/file and rebuild the envelope with `-Secret`. Without the secret, `sig` is omitted (optional, not an error).
- **`wait-idle` times out:** endpoint `POST /api/experimental/session/{id}/wait` unavailable (server down / session not found). Check `cross health`; fallback polling uses `GET /api/session/{id}`.
- **`fixture-clean` leaves `.test-backup`/`.bak`:** interrupted test; delete manually (`cross/*.test-backup`). `fixture-clean` restores automatically on exit.

## Rules of good citizenship

- Never edit `whiteboard/outbox.md` or `idempotencia-procesados.md` by hand while
  sessions are live - always through the CLI.
- One claim per message; release with `release --force` only if the owner is dead.
- Keep replies short and reference the msg_id.
