# OpenCode Cross-Talk - Quick Start

Verifiable messaging between OpenCode sessions (outbox + ACK/NACK + DLQ).

## 1. Prerequisites
- OpenCode Desktop running (serves the local API).
- PowerShell 5.1+ (Windows) or pwsh.
 - `curl` available — resolved cross-platform by `Get-CrossCurlCommand` (Windows: `curl.exe`; Linux/macOS: `curl`); `cross health` validates it.
- `OPENCODE_SERVER_PASSWORD` in the environment or in `~/.config/opencode/.env`.

## 2. Set your identity (1 minute)
Edit `cross/cross.config.json`:
```json
{ "my_session_id": "ses_YOUR_ID", "my_model": "your-model", "my_role": "advisor" }
```

## 3. Verify connectivity
```powershell
cd cross
.\cross.ps1 health      # -> ok if the server answers /global/health
.\cross.ps1 sessions    # list project sessions
```

## 4. Send your first message (with ACK)
```powershell
.\cross.ps1 send --msg msg_001 --dest ses_DEST --text "Hello"
```
Outbox states (`whiteboard/outbox.md`):
EN_VUELO -> CONFIRMADO | NACKED | EXPIRADO | DLQ.

## 5. If something fails
```powershell
.\cross.ps1 status              # outbox/DLQ overview
.\cross.ps1 diagnose --msg X    # why it failed
.\cross.ps1 metrics             # ACK/NACK/timeout rates, v1 usage
```
Common errors: SERVER_NOT_FOUND (Desktop closed), AUTH_FAILED (password),
ACK_TIMEOUT (destination busy - use nudge), DEST_NOT_FOUND (unknown session).

## Next steps
- Full protocol: CROSS_TALK.md
- User guide: USER_GUIDE.md
- Windows pitfalls: CROSS_WINDOWS.md