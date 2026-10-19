# AGENTS.md - Bootstrap for LLM sessions participating in Cross-Talk

You are an LLM agent (OpenCode session) that has landed on this repository.
This file gives you everything you need to USE Cross-Talk without reading
anything else. Follow it top to bottom.

## What Cross-Talk is

Durable, verifiable messaging between OpenCode sessions: an outbox with ACK/NACK
handshakes, retries, idempotency and a dead-letter queue. The CLI is
`cross/cross.ps1`. Wire format is **ENVELOPE-V2 JSON only** (v1 free-text
`ACK:`/`NACK:`/`TOKEN:` lines are rejected). Full spec: `CROSS_TALK.md`.

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
5. **Reply to the sender** via the API (typically POST to
   `/session/<their-id>/prompt_async`) and sign with the SAME token. Prefer the
   CLI (`send`/`ack`) over hand-built curl: it emits valid v2 JSON.
6. If you cannot or should not do it, reject explicitly:
   `.\cross.ps1 nack --token <token> --for-msg-id msg_X --reason CAPACITY --to <sender>`
   Closed reasons: CAPACITY | TOOL_MISSING | AMBIGUOUS_TASK | PROVIDER_DOWN | OTHER.

## Handshake conventions (v2)

- A task message carries `PROTOCOLO: CROSS-TALK v2`. Acknowledge within 30 s
  with `cross.ps1 ack ...` (that ACK IS the handshake).
- A v1-style `ACK-PROTOCOLO:` line does NOT count.
- Never hand-write `ACK:`/`NACK:`/`TOKEN:` lines: only `ENVELOPE-V2: {json}` or
  pure JSON is parsed.

## Shared clone with several agents

Each agent needs its own identity WITHOUT touching the local config. Use env
overrides (note the doubled `MY_`, it is intentional):

```powershell
$env:CROSS_MY_MY_SESSION_ID = 'ses_YOURS'
$env:CROSS_MY_MY_MODEL = 'your-model'
.\cross.ps1 whoami
```

## Troubleshooting

```powershell
.\cross.ps1 status              # outbox/DLQ overview
.\cross.ps1 diagnose --msg X    # why a delivery failed
.\cross.ps1 metrics             # ACK/NACK/timeout rates + latency P50/P95
```

Common errors: `SERVER_NOT_FOUND` (Desktop closed) -> `AUTH_FAILED` (password
precedence: env wins over .env) -> `ACK_TIMEOUT` (peer busy - try `nudge`) ->
`DEST_NOT_FOUND` (bad session id).

## Rules of good citizenship

- Never edit `whiteboard/outbox.md` or `idempotencia-procesados.md` by hand while
  sessions are live - always through the CLI.
- One claim per message; release with `release --force` only if the owner is dead.
- Keep replies short and reference the msg_id.
