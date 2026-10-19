# OpenCode Cross-Talk - Pitfalls of PowerShell 5.1 / Windows

Environment-specific pitfalls (Windows + PowerShell 5.1), consolidated on
2026-08-11 after an external review (separated from `CROSS_TALK.md` on 2026-08-11
so that document contains only protocol rules). They are platform limitations,
NOT protocol limitations. Section 11 of `CROSS_TALK.md` references them
(items 1, 2, 7, 8) and delegates the details here.

1. **Corrupted JSON / HTTP 500** when using `-d '...'` inline in PowerShell: PS
   5.1 quoting corrupts the body. Use a temporary file + `--data-binary`
   (section 4) or the `send_message.ps1` wrapper (4e).
2. **Mojibake** (accents like `?`): API output is read in PS 5.1's cp850 even
   when the body is UTF-8. Send as plain ASCII and fix on integration; or read
   with `HttpClient`/`Invoke-RestMethod` which decode UTF-8 correctly.
3. **BOM in JSON -> HTTP 500** (v1.5, tested 2026-08-10): generating the payload
   with `[System.Text.Encoding]::UTF8` (which writes a BOM) causes
   `HTTP 500 Unexpected server error`. Use UTF-8 without BOM or ASCII (section 4).
4. **`/tmp/` paths:** do not exist on Windows; use `$env:TEMP`.
5. **`&&` in PowerShell 5.1:** does not exist; use `;` or separate commands.
6. **`Add-Content` with concurrent writes** (finding T10, 2026-08-11): it is
   atomic (all-or-nothing) but uses exclusive locking per call; two processes
   writing at the same time -> the second receives `IOException` and silently
   loses its line. That is why the outbox is updated ONLY by the sender (12.2);
   if real concurrent writes were needed, use append with retry and backoff or
   a lock file.
7. **`${var}:` interpolation** in PowerShell strings: `"${var}:foo"` is
   interpreted as a scoped variable `${var:}`; escape as `` `${var}`:foo ``.
8. **Windows Store Python stub:** `python` on the PATH in a normal shell is the
   Store alias and does NOT run; the real executable is at
   `AppData\Local\Python\pythoncore-3.11-64` (8.2). Specify full paths.
9. **Relative config paths (fixed in v2.1.1):** `whiteboard_dir`, `diario_dir`
   and `log_path` used to resolve against the caller's cwd, so running the CLI
   outside `cross/` silently orphaned the outbox (`OUTBOX_MSG_NOT_FOUND`).
   They now resolve against the CONFIG FILE directory (absolute paths and
   `%ENV%` expansions still win). Old versions: always `cd cross` first.
10. **Hand-written ACKs are rejected (v2.0+):** do not compose
    `ACK:<token>:<id>:<model>` / `TOKEN:` / `ACK-PROTOCOLO:` lines. Use
    `.\cross.ps1 ack --token T --for-msg-id X --to <sender>`; it emits
    `ENVELOPE-V2: {json}` and posts it to the sender. Fixed in v2.1.1: the CLI
    imports `cross-envelope` regardless of module import order (previously the
    same import order used by `cross.ps1` left `New-CrossAckJson` undefined),
    and `ack`/`nack` auto-resolve the endpoint instead of silently doing
    nothing when `--port` is omitted.
11. **Shared clone, several agents:** the local config is one file, so two
    sessions sharing it would share identity. Give each agent env overrides
    (the doubled `MY_` is intentional because the module prefixes each config
    key with `CROSS_MY_`):
    `CROSS_MY_MY_SESSION_ID` and `CROSS_MY_MY_MODEL`.
12. **Password precedence:** `OPENCODE_SERVER_PASSWORD` in the process
    environment wins over `~/.config/opencode/.env`. If a stale `.env` value
    differs from the live one, prefer the env var; `cross health` reports
    `password_source`.
13. **`install.ps1` never guesses:** in v2.1.1 it validates the session via the
    API and exits with code 2 (printing the candidates) when the identity is
    ambiguous. Do NOT fall back to `sessions[0]`; pass `-SessionId ses_...`.
