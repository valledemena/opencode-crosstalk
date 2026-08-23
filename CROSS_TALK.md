# OpenCode Cross-Talk between OpenCode Desktop sessions

Reference document so that any agent in this project can communicate
with other open chats/sessions in the same project.

> **Protocol version: 1.8** (handshake `ACK-PROTOCOLO:1.8`). Release: **v1.16.0**
> (2026-08-21): atomic idempotency CLAIM (TOCTOU), hardened port discovery with
> `source`/`degraded` metadata, cross-platform curl resolution, v1 ACK parser
> deprecation (removal in v1.17), and a hard total delivery cap (`TOTAL_TIMEOUT`
> -> DLQ). The wire protocol is unchanged.
>
> This file contains ONLY the current rules. Version history lives in
> **CHANGELOG.md**; Windows pitfalls in **CROSS_WINDOWS.md**. LLM agents:
> read **AGENTS.md** first for a 3-minute bootstrap; humans start at
> **QUICKSTART.md**.

# Part I - Setup & sending

## Contents

### Part I - Setup & sending
- [Context](#context)
- [1. Detect server credentials (MANDATORY AUTO-DETECTION)](#1-detect-server-credentials-mandatory-auto-detection)
- [2. Session Discovery and Team Selection](#2-session-discovery-and-team-selection)
- [3. Read messages from a session](#3-read-messages-from-a-session)
- [4. Send a message to another session](#4-send-a-message-to-another-session)
  - [4a. noReply: deliver without processing](#4a-deliver-a-message-without-the-destination-agent-processing-it-noreply-true)
  - [4b. Synchronous: wait for reply](#4b-send-a-message-and-wait-for-the-destination-agents-reply-synchronous)
  - [4c. Background: STANDARD method](#4c-send-a-message-and-let-the-destination-agent-process-it-in-the-background-standard-method-for-cross-talk)
  - [4d. Identity/signature](#4d-the-leader-communicates-ids-and-model-to-members-identitysignature)
  - [4e. send_message.ps1 wrapper](#4e-send_messageps1-wrapper-mandatory-auto-detection-anti-corruption-practice)
  - [4e.2. Send-CrossMessage.ps1 enhanced](#4e2-send-crossmessageps1-enhanced-wrapper-v18)
  - [4f. Minimal critical rules](#4f-minimal-critical-rules-fallback-handshake-v18)

### Part II - Replying & verifying
- [5. Complete example: replying](#5-complete-example-replying-to-a-session-that-messaged-you)
  - [5.1. Wake-up mechanism](#51-wake-up-mechanism-receiving-without-polling)
- [6. Verify that the other session replied](#6-verify-that-the-other-session-replied)
  - [6.1. Diagnosis of stuck advisor](#61-diagnosis-of-a-stuck--sigue-advisor)

### Part III - Reliability & operations
- [7. Delivery confirmation (ACK)](#7-delivery-confirmation-ack)
  - [7.1-7.6. ACK subsections](#71-ack-format)
- [8. Inter-session coordination](#8-inter-session-coordination-protocol-collaborative-tasks)
  - [8.1-8.2. Coordination subsections](#81-analysis-of-large-projects-do-not-exhaust-context)
- [9. Traceability and auditing](#9-traceability-and-auditing-audit_logmd)
  - [9.1-9.2. Audit subsections](#91-format-of-each-line)
- [10. Session and task monitoring](#10-session-and-task-monitoring)
  - [10.1-10.3. Monitoring subsections](#101-quick-status-query-with-get-sessionid)
- [11. Known issues and solutions](#11-known-issues-and-solutions)

### Part IV - Anti-sleep protocol
- [12. Anti-sleep protocol](#12-anti-sleep-protocol-v16-with-v161-corrections)
  - [12.1-12.15. Anti-sleep subsections](#121-standard-message-envelope)

## Context

OpenCode Desktop runs a local HTTP server (`http://127.0.0.1:PORT`)
that exposes the OpenCode API. Each chat open in the application is a
**session** with a unique identifier (`ses_...`). Any agent with access
to the shell (e.g. the `build` agent) can use that API to:

1. List project sessions.
2. Read messages from a session.
3. **Send a message to another session** (with or without waiting for a reply).
4. **Verify** that the other session replied (the message is stored in the history).

Communication between sessions of the same project is done directly via
HTTP: no additional plugin is needed, just knowing the server port and
credentials.

> **Verified procedure** (real tests from 2026-08-10): one session
> sent a message to another session in the same project, the second read this document,
> replied back using the same mechanism, and the message arrived and was
> persisted in the originating session.

## 1. Detect server credentials (MANDATORY AUTO-DETECTION)

> **RULE (v1.4, consensus 2026-08-10):** auto-detect the port and take the
> password from the environment **immediately before EACH send**, never from a
> previous task and **never hardcoded** in a script. If a script has
> `$port = "56678"` (or any other fixed value) or a pasted literal password,
> that script is WRONG: on application restart the port changes and the
> password is rotated, and messages sent with old values **do not arrive**
> (they are silently lost or return an error). Every model that sends messages
> is responsible for updating its snippet to always auto-detect.

On application restart the port changes, and the password may also
change. **Do not reuse credentials from a previous task or hardcode them in
a script**: detect the port and password at send time and
verify they work.

```powershell
$logDir = "$env:APPDATA\ai.opencode.desktop\logs"
$latestLog = Get-ChildItem $logDir | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$content = Get-Content "$($latestLog.FullName)\main.log" -Raw
$port = ([regex]::Match($content, "server ready.*url: 'http://127\.0\.0\.1:(\d+)'")).Groups[1].Value
$password = $env:OPENCODE_SERVER_PASSWORD
Write-Host "Port: $port"
```

- Authentication username: `opencode`
- Password: normally `$env:OPENCODE_SERVER_PASSWORD` (the current
  process's variable). Also stored in `~/.config/opencode/.env`
  under the key `OPENCODE_SERVER_PASSWORD`.
- Before continuing, verify that the credentials work:

```powershell
curl.exe -s -m 8 -u "opencode:$password" "http://127.0.0.1:$port/global/health"
# Should respond something like: {"healthy":true,"version":"..."}
```

If `health` does not respond, the app has restarted: repeat the detection from scratch.

## 2. Session Discovery and Team Selection

Before initiating any task, the Leader must perform a discovery phase to identify potential collaborators:

1. **Discovery**: The Leader calls `cross sessions --directory <project_dir>` to identify all active sessions in the current project.
2. **Presentation**: The Leader presents the list of found sessions to the human user, specifying the model and title of each session.
3. **Selection**: The Leader asks the user to:
   - Select specific sessions by ID or name.
   - Request the use of ALL available sessions.
   - Exclude specific sessions.
4. **Confirmation**: The Leader only proceeds to Step 4 (Messaging) once the user has confirmed the final list of Advisors.

This phase prevents the Leader from accidentally waking up unrelated sessions or overloading a single agent.

## 3. Read messages from a session

```powershell
curl.exe -s -u "opencode:$password" "http://127.0.0.1:$port/session/<SESSION_ID>/message?limit=20"
```

## 4. Send a message to another session

> **IMPORTANT (tested pitfall):** the JSON must be in a file and sent
> with `--data-binary "@file"`. Do NOT use `-d '...'` inline in PowerShell:
> it corrupts the JSON and the server responds `HTTP 500 Unexpected server error`.

> **Encoding:** send messages in plain ASCII (no accents or special
> characters). When reading replies, accents and smart quotes
> may arrive as `?` signs (mojibake); fix them when
> integrating the content.

> **BOM pitfall (tested 2026-08-10):** if you generate the JSON file with
> `[System.IO.File]::WriteAllText($f, $json, [System.Text.Encoding]::UTF8)`
> (or `Set-Content -Encoding utf8`), PowerShell writes a **BOM** at the start
> and the server responds `HTTP 500 Unexpected server error`
> (`err_82db6391`/`err_cb996c5b`). It must be UTF-8 **without BOM**:
> `New-Object System.Text.UTF8Encoding($false)` -- or simply ASCII
> (no accents), which is what `send_message.ps1` uses (4e).
>
> **Prefer ASCII for sending (v1.5, model-c contribution):** if the message
> text may contain non-ASCII characters (accents, n's, symbols), it is safer
> to send in plain ASCII than in UTF-8 without BOM: even with UTF-8 without BOM,
> characters like "i" or "n" may arrive as `?` (mojibake) at the destination.
> Write messages without accents or replace problematic characters.
> This applies to ALL sends between sessions (leader->advisor and advisor->leader).

### 4a. Deliver a message without the destination agent processing it (`noReply: true`)

The message instantly appears in the destination session's chat as a
user message, but the destination agent does NOT reply. Useful for notes/notices.

```powershell
$body = '{"parts":[{"type":"text","text":"YOUR_MESSAGE"}],"noReply":true}'
$body | Set-Content "$env:TEMP\msg.json" -Encoding ascii -NoNewline

curl.exe -s -X POST -u "opencode:$password" -H "Content-Type: application/json" `
  --data-binary "@$env:TEMP\msg.json" `
  "http://127.0.0.1:$port/session/<DEST_ID>/message"
```

Returns `HTTP 200` with the created message.

### 4b. Send a message and wait for the destination agent's reply (synchronous)

Without `noReply`, the destination session's agent processes the message and its
full reply (reasoning + text) is returned in the same call.

```powershell
$body = '{"parts":[{"type":"text","text":"YOUR_QUESTION"}]}'
$body | Set-Content "$env:TEMP\msg.json" -Encoding ascii -NoNewline

curl.exe -s -X POST -u "opencode:$password" -H "Content-Type: application/json" `
  --data-binary "@$env:TEMP\msg.json" `
  "http://127.0.0.1:$port/session/<DEST_ID>/message"
```

This call is synchronous: it waits for the destination agent to finish replying
(it may take over 1 minute).

### 4c. Send a message and let the destination agent process it in the background (STANDARD method for cross-talk)

`POST /session/:id/prompt_async` delivers the message and returns `HTTP 204`
immediately. The destination agent processes it in the background and may
reply to you later. **It is the standard and preferred method for all
agent communication** (v1.5, model-d contribution): it does not block, wakes up the
destination, and does not need `noReply` (which is redundant -- `prompt_async` already delivers
without waiting for a reply). Use `noReply` (4a) or synchronous `/message` (4b) only
when you have a specific reason.

```powershell
$body = '{"parts":[{"type":"text","text":"YOUR_MESSAGE"}]}'
$body | Set-Content "$env:TEMP\msg.json" -Encoding ascii -NoNewline

curl.exe -s -X POST -u "opencode:$password" -H "Content-Type: application/json" `
  --data-binary "@$env:TEMP\msg.json" `
  "http://127.0.0.1:$port/session/<DEST_ID>/prompt_async"
```

### 4d. The leader communicates IDs and model to members (identity/signature)

The **leader** (the one who initiates the task) knows its own session ID and those of
the others: it auto-detects them with `GET /session` (see note below). So that each
member signs its tokens with ITS ID and avoids confusion, the leader must
**include in the task message the ID and model of each recipient**,
explicitly telling them which ones are theirs:

```
[Your session ID is: <DEST_ID> and your model is: <DEST_MODEL>.
When replying, sign your tokens like this:
TOKEN:<DEST_ID>:<DEST_MODEL>
(for example ACUERDO-FINAL:ses_XXXXXXXX:model-b).
Your reply token will be: MEJORA-R1:<DEST_ID>:<DEST_MODEL>
(example: MEJORA-R1:ses_abc123:model-b).
The leader sending you this message is:
ID: <LEADER_ID> | model: <LEADER_MODEL>.
ALWAYS reply to that origin session via API (prompt_async WITHOUT noReply):
NEVER write the reply only in your own chat (the leader will not see it).
VERIFY delivery: after sending, read the leader's history
(GET /session/<LEADER_ID>/message) and confirm your token is there.
PROTOCOL: CROSS-TALK v1.8 -- reply ACK-PROTOCOLO:1.8 if you understand
]
```

**Protocol version handshake (v1.8, REVISION-89 consolidation 2026-08-19;**
**originally v1.6.1 external-reviewer correction 2026-08-11):** the
task message includes the line `PROTOCOLO: CROSS-TALK v1.8`. The advisor
must reply `ACK-PROTOCOLO:1.8` (EXACTLY three segments: no `v`, no
prefix) within the first 30 s, along with its first ACK if applicable. Rules:
- If the advisor replies `ACK-PROTOLO:1.8` -> compatible version.
- If it replies `ACK-PROTOCOLO:<other_version>` -> incompatibility: the leader sends
  it the **canonical critical rules block (sec 4f)** and clarifies the
  version difference before proceeding.
- If it does NOT reply within 30 s -> the leader assumes it is an agent without protocol: it
  sends the critical rules block (sec 4f) and retries the handshake.
- An agent that does not understand the handshake may also reply
  `NACK-PROTOCOLO:unsupported_version:<received_version>` (or with the version
  it does understand); the leader decides whether to continue with that version or exclude it.
- This handshake is repeated at the start of EVERY task (not per message).

Each member receives an individualized message with ITS OWN ID and model.
This way no one guesses or copies other people's IDs.

> **RULE (delivery claim, correction 2026-08-18):** the leader's task message
> ALWAYS includes the explicit claim of the correct reply method (the lines
> above: reply via API to the leader's session, WITHOUT noReply, and verify
> delivery). The advisor, upon finishing, MUST ask itself whether the way it
> is sending the reply is the correct one (API to the origin session, NOT its
> own chat) and MUST VERIFY that the leader received it: read the leader's
> history (section 6) searching for its token, or check the log / audit_log.
> If it cannot confirm arrival, it must NOT assume it arrived: resend via API
> or notify the leader in its own chat (6.1e).

> **RULE (ready-to-copy script, v1.7, tested E2E 2026-08-18 TEST-E2E-85):**
> the leader's task message MUST ALSO include the complete send script,
> ready to copy into the advisor's bash tool and execute WITHOUT EDITING.
> Real E2E results: 2/4 advisors (big-pickle, mimo) reply via API without
> help; openrouter/free breaks the PowerShell command syntax (parser
> errors) and nemotron-3-ultra-free only writes in its own chat, it never
> sends via API -- BOTH resolved only after the leader sent the script
> verbatim (took 2 and 4 rounds respectively). Therefore, the task message
> includes at least:
>
> 1. The identity block of sec 4d (IDs, model, leader, signature).
> 2. The instruction "USE YOUR BASH TOOL. Copy and run EXACTLY this script"
>    followed by the full script (see below), with the advisor's reply text
>    already embedded and signed.
> 3. The verification instruction (`GET /session/<LEADER_ID>/message`,
>    search for the token) as a final step.
>
> Reference script (auto-detects credentials, ASCII no BOM, prompt_async):
>
> ```powershell
> # (0) Run section 1 credential detection first ($port / $password now in scope).
> ```
>
> The leader replaces `TOKEN`, `ses_XXXXXXX`, `modelo`, the reply text and
> `ses_LEADER` before sending. If the advisor still fails, the leader
> diagnoses via 6.1a and nudges again with the script (6.1c).

> **RULE (pre-built JSON fallback, v1.7.1, tested E2E 2026-08-19
> TEST-E2E-86):** if the advisor STILL fails with the ready-to-copy script
> (openrouter/free case: it copies the script's SOURCE LINE
> `$text = "..."` as the payload text instead of executing it, so the
> message arrives with literal `` `n `` and `$(Get-Date ...)` unexpanded;
> it also rebuilds the text by hand, introducing typos like
> `ACK-PROTOCOLO / 1.7`), the leader switches to the **pre-built JSON**
> method: the leader writes the complete payload file itself (ASCII, no
> BOM, NO interpolation, already signed) in a shared path
> (`$env:TEMP\opencode\e2e86_listo.json` style) and sends the advisor ONLY
> the credential-detection lines plus a single `curl` line with
> `--data-binary "@<path>"`. The advisor has nothing to build: no
> JSON construction, no file writing, no interpolation. Verified: works in
> 1 nudge on openrouter/free. This is the LAST fallback before declaring
> the advisor incapable of API delivery (6.1e/NACK).
>
> **Concrete example (leader side, after writing the payload to a shared path):**
>
> ```powershell
> $payload = @{ parts = @(@{ type = "text"; text = "TAREA-R1:ses_abc:model-b  PROTOCOLO: CROSS-TALK v1.8 -- reply ACK-PROTOCOLO:1.8" }) }
> $tmp = "$env:TEMP\opencode\e2e86_listo.json"
> [System.IO.File]::WriteAllText($tmp, ($payload | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
> ```
>
> ```powershell
> # What the advisor must copy and run (ONLY these two lines, nothing to build):
> $Puerto = ([regex]::Match((Get-Content "$env:APPDATA\ai.opencode.desktop\logs\*\main.log" -Raw), "server ready.*url: 'http://127\.0\.0\.1:(\d+)'")).Groups[1].Value
> curl.exe -s -m 30 -X POST -u "opencode:$env:OPENCODE_SERVER_PASSWORD" -H "Content-Type: application/json" --data-binary "@C:\Users\unknown\AppData\Local\Temp\opencode\e2e86_listo.json" "http://127.0.0.1:$Puerto/session/ses_LEADER/prompt_async"
> ```

> **The leader also identifies itself (v1.5, tested 2026-08-10):** the leader's message
> must include its **own ID and model** in addition to the recipient's.
> Real pitfall: model-d got blocked because it did not know which session to reply to
> because the task message did not identify the sender. Without the leader's ID
> in the message, the advisor cannot direct its reply (section 5) or sign
> correctly.

> **Signature with human-readable model (v1.2, 2026-08-10):** in addition to the session ID, the
> signature includes the **model name** (`TOKEN:<SESSION_ID>:<MODEL>`). The
> human user can read at a glance which model sent each message, instead
> of deciphering a string of letters and numbers. The session ID is kept as
> the canonical identifier (machine); the model is human-readable. The leader
> gets the model from `GET /session` -> `model.id`.

> **Note on auto-detection of own ID (leader):** the leader knows its session ID
> because it is the session it is running (e.g. it appears in the
> current session's context). It gets the IDs of the others from
> `GET /session` filtered by `directory`. For a correct signature, it is
> essential that the leader assigns each member ITS real ID (the one
> that appears in the list) and communicates it as-is.

### 4e. `send_message.ps1` wrapper (mandatory auto-detection, anti-corruption practice)

> **Consensus (Improvement Rounds 2026-08-10):** the wrapper is an **OPTIONAL
> utility** that encapsulates the pattern "write JSON to file + `curl
> --data-binary`". It does not replace the manual method documented in 4a-4c: it only
> automates it to avoid quoting/encoding pitfalls. You can use the manual
> method or the wrapper interchangeably.
>
> **RULE v1.4:** the wrapper ALWAYS auto-detects the port from the most
> recent log and the password from `$env:OPENCODE_SERVER_PASSWORD`, **ignoring**
> any fixed value passed as parameter. It is the recommended version for
> all sends: it eliminates the class of bug where a model uses old
> credentials and its message does not arrive.
>
> **Architecture (v1.8, corrected after GLM review 2026-08-19):** the
> canonical wrapper is **`cross/send_message.ps1`** (Phase 5): it keeps the
> legacy signature `-Destino -Texto [-NoReply] [-Puerto -Password]`, creates
> an outbox entry (`Add-OutboxEntry`, sec 12.8) and delegates the actual send to
> the `cross send` CLI (outbox/audit/retries active). `-LegacyMode` switches
> to the old direct-HTTP path (no outbox/audit/retries). In local projects,
> `whiteboard/send_message.ps1` is a **legacy shim** that forwards to
> `cross\send_message.ps1` -- it is NOT a standalone implementation. Do not
> look for a `whiteboard/send_message.ps1` that does direct HTTP: that
> implementation lives inside `cross/send_message.ps1 -LegacyMode`.

`cross/send_message.ps1` (canonical wrapper, delegates to `cross send`):

```powershell
# (0) Run section 1 credential detection first ($port, $password in scope).
# Legacy signature: -Destino -Texto [-NoReply] [-Puerto -Password] [-LegacyMode]
  $payload = @{ parts = @(@{ type = "text"; text = $Texto }) }
  if ($NoReply) { $payload.noReply = $true }
  $json = $payload | ConvertTo-Json -Depth 4
  $file = Join-Path $env:TEMP "send_$(Get-Random).json"
  [System.IO.File]::WriteAllText($file, $json, [System.Text.Encoding]::ASCII)
  $endpoint = if ($NoReply) { "message" } else { "prompt_async" }
  curl.exe -s -m 30 -X POST -u "opencode:$Password" -H "Content-Type: application/json" `
    --data-binary "@$file" "http://127.0.0.1:$Puerto/session/$Destino/$endpoint"
  Remove-Item $file -ErrorAction SilentlyContinue
  exit 0
}

# Normal path: create outbox entry and delegate to `cross send` (outbox/audit/retries).
Import-Module (Join-Path $MyRoot 'modules\cross-transport.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $MyRoot 'modules\cross-state.psm1') -Force -DisableNameChecking
$config = Get-CrossConfig
$emisor = [string]$config.my_session_id
if (-not $emisor) { $emisor = 'lider' }
$msgId = "msg_${emisor}_$(Get-Date -Format 'yyyyMMdd-HHmmss')-" + (Get-Random -Maximum 16777215).ToString('X6')
$token = 'MSG-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 12)
$runId = 'RUN-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
$leaseMin = if ($config.default_lease_minutes) { [int]$config.default_lease_minutes } else { 3 }
$lease = "$Destino@" + (Get-Date).ToUniversalTime().AddMinutes($leaseMin).ToString('yyyy-MM-ddTHH:mm:ssZ')
$whiteboard = [Environment]::ExpandEnvironmentVariables([string]$config.whiteboard_dir)
$outbox = Join-Path $whiteboard 'outbox.md'
$ar = Add-OutboxEntry -MsgId $msgId -Dest $Destino -RunId $runId -Token $token -Lease $lease -Path $outbox
if (-not $ar.ok) { throw "$($ar.err): $($ar.detail)" }
$cliArgs = @('send', "--msg=$msgId", "--dest=$Destino", "--text=$Texto")
if ($NoReply) { $cliArgs += '--no-wait' }
if ($Puerto) { $cliArgs += "--port=$Puerto" }
if ($Password) { $cliArgs += "--password=$Password" }
$raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Cli @cliArgs 2>$null | Out-String
[Console]::WriteLine($raw.Trim())
exit $LASTEXITCODE
```

Usage:

```powershell
& ".\cross\send_message.ps1" -Destino "ses_AAAAAAAA" -Texto "YOUR_MESSAGE" -NoReply
```

Notes:
- No need to pass `-Puerto` or `-Password`: they are always auto-detected.
- `-NoReply` delivers without the destination processing it (equivalent to 4a).
- Without `-NoReply` it uses `prompt_async` (equivalent to 4c).
- **Always set `-m 30` on curl** (without it, a slow server hangs the shell and
  truncates delivery; verified v1.8, nemotron case: only 1 of 3 advisors received
  the message because the shell hung after the first send).
- The wrapper uses `[System.IO.File]::WriteAllText` with ASCII encoding and
  `ConvertTo-Json`: it avoids `-NoNewline`/encoding errors that cause HTTP 500.
- If auto-detection fails (e.g. it cannot find the port) it throws an error instead of
  sending with obsolete credentials.

### 4e.2. `Send-CrossMessage.ps1` enhanced wrapper (v1.8)

> **v1.8 (advisor consensus 2026-08-19, after nemotron's experiment as leader):**
> enhanced wrapper that adds two capabilities the basic wrapper (4e) lacks:
> **retry with exponential backoff** (a failed send is retried automatically
> instead of leaving the agent to fire repeated commands manually, sec 11.6) and
> **optional delivery verification** by polling the destination history for a
> token (the root cause of nemotron's failures: HTTP 200 ---- processed; the
> message must be READ back from the destination history, sec 6).
> It keeps the mandatory auto-detection (RULE v1.4) and the ASCII no-BOM
> payload write (CROSS_WINDOWS.md #1). Optional utility: the manual method
> (4a-4c) and the basic wrapper (4e) remain valid.

```powershell
param(
  [Parameter(Mandatory=$true)][string]$Destino,
  [Parameter(Mandatory=$true)][string]$Texto,
  [string]$Token,                 # optional: token to verify in destination history
  [switch]$NoReply,
  [int]$Retries = 3,              # attempts with backoff (2s, 4s, 8s, ...)
  [int]$VerifWait = 0             # seconds to poll for the token (0 = no verification)
)

# (0) Run section 1 credential detection first ($port, $password in scope).

# ASCII payload, no BOM, no shell interpolation (CROSS_WINDOWS.md #1)
$payload = @{ parts = @(@{ type = "text"; text = $Texto }) }
if ($NoReply) { $payload.noReply = $true }
$json = $payload | ConvertTo-Json -Depth 4
$file = Join-Path $env:TEMP ("send_" + [guid]::NewGuid().ToString("N") + ".json")
[System.IO.File]::WriteAllText($file, $json, [System.Text.Encoding]::ASCII)

$endpoint = if ($NoReply) { "message" } else { "prompt_async" }
$http = $null
for ($i = 1; $i -le $Retries; $i++) {
  $http = curl.exe -s -m 30 -w "%{http_code}" -o NUL -X POST -u "opencode:$Password" `
    -H "Content-Type: application/json" --data-binary "@$file" `
    "http://127.0.0.1:$Puerto/session/$Destino/$endpoint"
  if ($http -match "^(200|204)$") { Write-Host "SEND OK (HTTP $http), attempt $i/$Retries"; break }
  Write-Host "SEND FAILED (HTTP $http), attempt $i/$Retries; retrying in $([Math]::Min(2 -shl ($i-1), 30))s..."
  Start-Sleep -Seconds ([Math]::Min(2 -shl ($i-1), 30))
}

# Optional delivery verification: HTTP 200/204 only means "accepted", not "processed" (nemotron case)
if ($Token -and $http -match "^(200|204)$" -and $VerifWait -gt 0) {
  $deadline = (Get-Date).AddSeconds($VerifWait)
  do {
    Start-Sleep -Seconds 2
    $hist = curl.exe -s -m 15 -u "opencode:$Password" "http://127.0.0.1:$Puerto/session/$Destino/message?limit=10" | ConvertFrom-Json
    $found = $hist | ForEach-Object { ($_.parts | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "`n" } |
             Where-Object { $_ -match [regex]::Escape($Token) }
    if ($found) { Write-Host "VERIFIED: token '$Token' present in destination history"; break }
  } while ((Get-Date) -lt $deadline)
  if (-not $found) { Write-Host "NOT VERIFIED: token '$Token' not found in destination history after $VerifWait s" }
}

Remove-Item $file -ErrorAction SilentlyContinue
```

Usage:

```powershell
# Send with wake-up (prompt_async), 3 retries, verify delivery within 60 s
& ".\whiteboard\Send-CrossMessage.ps1" -Destino "ses_AAAAAAAA" -Texto "TASK..." -Token "TAREA-R1" -VerifWait 60

# Fire-and-forget notification (noReply=true), no verification
& ".\whiteboard\Send-CrossMessage.ps1" -Destino "ses_AAAAAAAA" -Texto "STATUS OK" -NoReply
```

Notes:
- `-Token` + `-VerifWait`: poll the DESTINATION history (section 6) -- the
  only proof of processing; a bare HTTP 200/204 is NOT proof (nemotron
  case, sec 11.3). **`-VerifWait` only takes effect when `-Token` is ALSO
  given** -- the token is what the poller looks for in the destination
  history; passing `-VerifWait` without `-Token` verifies nothing.
- Retries use exponential backoff (2s, 4s, 8s, ... capped at 30s): no more
  streaks of failed manual commands (sec 11.6).
- Keep this file in `whiteboard/` next to `send_message.ps1` (4e).

### 4f. Minimal critical rules (fallback handshake, v1.8)

When an advisor does not reply `ACK-PROTOCOLO:1.8` within 30 s (4d), the leader sends
it this **canonical block** to be copied verbatim, without editing or improvising. It is 8
lines sufficient for any agent to operate without having read
CROSS_TALK.md:

```
PROTOCOLO CROSS-TALK v1.8 -- CRITICAL RULES:
1. Your ID and model are communicated by the leader (do not guess them).
2. ALWAYS reply via API (prompt_async without noReply) to the leader's session.
3. ACK first, then process: ACK:<token>:<your_ID>:<your_model>.
4. If you CANNOT do the task: NACK:<token>:<your_ID>:<your_model>:<closed_reason>.
5. Before processing: CLAIM your msg_id in idempotencia-procesados.md.
6. When done: mark PROCESADO in idempotencia-procesados.md.
7. If you receive "sigue": it is RESUME, continue your context (it is not a new message).
8. Full details in CROSS_TALK.md.
```

With this, the fallback handshake is deterministic: any leader sends the same
text and any agent can operate with the minimum.

# Part II - Replying & verifying

## 5. Complete example: replying to a session that messaged you

> **MANDATORY RULES when receiving a message from another session:**
>
> 1. Your reply must **be sent to the origin session via this API**
>    (`POST /session/<ORIGIN_ID>/message` or `prompt_async`). NEVER just
>    write the reply in your own conversation: the sender will not see it.
>    **The primary channel is ALWAYS the API.** Replying only in your chat is a
>    delivery failure: the sender receives nothing and must reclaim it from you. Writing in
>    the chat without sending via API is only acceptable when there is no other way
>    to send (external environment failure, the model does not have network
>    tools, etc.) and ALWAYS notifying the leader in the chat that you could not send it.
>    **v1.7 (TEST-E2E-85):** if the task message includes the ready-to-copy
>    script (sec 4d rule), copy it into your bash tool and execute it verbatim --
>    do not rebuild the command from memory (models that do this break the
>    PowerShell syntax or send nothing).
> 2. Identify the sender by its **session ID** (e.g. `ses_AAAAAAAA`)
>    and the message will tell you the token to return (e.g. `ACUERDO-FINAL`).
>    If the message **does not identify the sender** (ID + model), request confirmation
>    or reply to the session you read the message from; the leader must include it
>    (section 4d).
> 3. If the message requests a task/consultation, after working on it reply with
>    **the SAME token you received** (if you received `BUGS-R1`, reply
>    `BUGS-R1:YOUR_ID:YOUR_MODEL`), **and your result**, directed to the session that
>    asked. Using a different token breaks traceability (v1.5, model-c contribution).
> 4. Run the script in this section, do not "improvise" a loose text.
5. **Verify delivery (mandatory, correction 2026-08-18):** once you have sent
   your reply via API, ask yourself if the way you sent it is the correct one
   and VERIFY that the leader received it: read the leader's history
   (`GET /session/<ORIGIN_ID>/message`, section 6) searching for your token,
   or check the log / `audit_log.md` (section 9). If you cannot confirm the
   arrival, do not assume it: resend via API or notify in your own chat
   (6.1e) that you could not send it.

If a session (e.g. `ses_AAAAAAAA`) sends you a message, to
**reply to that session** run the following. Include a unique token so
that the origin session can verify that your reply arrived.

> **IMPORTANT (identifying the sender):** when the origin session requests a
> fixed token (e.g. `ACUERDO-FINAL-C1`), ALL replies arrive with the
> same token and it is impossible to know who sent it. Therefore, whenever
> you reply, append **your own session ID and model** as a suffix
> to the token, in the format `TOKEN:YOUR_SESSION_ID:YOUR_MODEL`
> (e.g. `ACUERDO-FINAL-C1:ses_XXXXXXXX:model-b`).
> This way the origin session can count one vote per agent, know exactly
> who agreed or proposed changes, and show the human user which model
> replied.

> **HOW TO KNOW YOUR OWN ID AND MODEL (DO NOT GUESS):** your ID and model are
> the ones the leader communicated to you in the task message (section 4d). NEVER
> try to deduce them by filtering the session list by directory: several
> agents share the same `directory` and it is easy to get confused (real pitfall:
> an advisor signed with another's ID). If the task message does not specify
> them, reply to the origin session with the fixed token WITHOUT a suffix; the leader
> will identify you by the content.

```powershell
# (0) Run section 1 credential detection first ($port / $password now in scope).
```

Notes:
- Use `noReply: true` if you only want to deliver a notice without the destination
  having to process it.
- Use `prompt_async` at the destination when the other session needs to process your
  message and work on it in the background.
- **Verified pitfall (2026-08-10):** an agent received a query, worked
  the reply and wrote it only in ITS OWN conversation, without sending it to the
  origin session. The sender never received it and had to reclaim it. ALWAYS
  complete the reply with step 3 above: the `curl` that sends the message
  to the origin session.

## 5.1. "Wake-up" mechanism (receiving without polling)

When session A sends a message to session B **without `noReply`** (or with
`prompt_async`), session B's agent "wakes up" automatically and processes the
message in the background: B does not need to be polling. This is how
the complete chain works without polling from the sender:

1. The **leader** sends the task with `prompt_async` (section 4c) to the advisors.
2. Each **advisor** wakes up on its own, works the task and replies to the leader
   using section 5 (POST to the leader's session, also without `noReply`).
3. The **leader** is woken up again when the reply arrives and can
   process it without having polled the history.

What does NOT wake up the destination:
- `noReply: true` only leaves the message in the chat; the agent does not react.
- Writing the reply in your own conversation does not propagate to anyone.

To cleanly finish a turn: deliver your message (with `prompt_async` or
POST without `noReply`) and finish your reply; the incoming message will wake you
up when it arrives.

> **Verified pitfall (2026-08-11, riddle competition):** during
> round 2, model-b/model-c replied to the leader with `noReply: true`. The message
> was stored in the leader's session (`user` without `time.completed`) but the
> leader did NOT wake up: the server never generated `message=process`/`stream`
> for its session. Confirmed by logs and controlled test (two identical
> messages to the same session: `noReply: true` -> no response; `noReply:
> false` -> processed and replied). The messages were only seen when manually reviewing the
> history. **Reinforced rule: to reply to the leader, ALWAYS send
> with `prompt_async` (without `noReply`) or POST without `noReply`. Never use
> `noReply: true` to deliver a pending reply or result.**

To cleanly finish a turn: deliver your message (with `prompt_async` or
POST without `noReply`) and finish your reply; the incoming message will wake you
up when it arrives.

## 6. Verify that the other session replied

Read the origin session's history filtering for **new `user` type messages**
(those injected by the other agent) created after a
given moment, and search for your token:

```powershell
$mine = "ses_AAAAAAAA"   # the session where you expect to receive the reply
$token = "MY-UNIQUE-TOKEN"  # may include :ses_XXXXXX as sender suffix

# Mark the moment right before sending your message
$start = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# After sending the message, poll for up to 3 minutes:
$deadline = (Get-Date).AddMinutes(3)
while ((Get-Date) -lt $deadline) {
  $msgs = curl.exe -s -m 10 -u "opencode:$password" "http://127.0.0.1:$port/session/$mine/message?limit=10" | ConvertFrom-Json
  foreach ($m in $msgs) {
    if ($m.info.role -ne "user") { continue }
    if ($m.info.time.created -lt $start) { continue }
    foreach ($t in ($m.parts | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text })) {
      if ($t -like "*$token*") { Write-Host "REPLY RECEIVED: $t"; exit }
    }
  }
  Start-Sleep -Seconds 10
}
Write-Host "No reply received within 3 minutes."
```

## 6.1. Diagnosis of a stuck / "sigue" advisor

Do not wait indefinitely. If after the verification window some advisor's
reply is missing, **read its session** to see where it got stuck and,
if it is still stalled, **wake it up by sending `sigue`**. Here are the steps:

### a) Read an advisor's session (see what happened)

```powershell
$advisor = "ses_AAAAAAAA"   # the ID of the session that has not replied

curl.exe -s -u "opencode:$password" "http://127.0.0.1:$port/session/$advisor/message?limit=10" |
    ConvertFrom-Json | ForEach-Object {
        $text = ($_.parts | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join ' '
        "[$($_.info.role)] ($($_.info.time.created)) $($text.Substring(0, [Math]::Min(200, $text.Length)))"
    }
```

With this you can find out if:
- the task message **reached it** (last `user` message),
- the agent **started working** (there is `reasoning` or a half-done `assistant`),
- **finished and replied** (last `assistant` says "Sent...") -- if it replied
  but it did not reach your session, it is the pitfall from section 5: ask it to
  send it via API,
- or it simply **went blank / has no activity** (no `assistant` after the
  `user`): it is stuck.

### b) Check if the agent is STILL working (before intervening)

An advisor may take over 3 minutes simply because it **is still working**
(replies correctly but slowly), not because it is stuck. Before sending it
`anything`, verify that the session **is no longer growing**:

- Read its session (a) **twice, a few seconds apart** (e.g. 15 s).
- If between the two readings **new messages or parts appeared**
  (new `assistant`, `reasoning`, tool calls, or the last message's text grew),
  the agent is still active: **do NOT send it `sigue`**, wait again
  and repeat the check.
- If both readings are **identical**, the session is idle: you can now
  diagnose and, if applicable, wake it up with (c).

```powershell
$advisor = "ses_AAAAAAAA"
# Reading 1
$a1 = curl.exe -s -u "opencode:$password" "http://127.0.0.1:$port/session/$advisor/message?limit=5" |
    ConvertFrom-Json
$a1Str = ($a1 | ForEach-Object { $_.info.id + ":" + ($_.parts | ForEach-Object { $_.type + ":" + $_.text }) }) -join '|'
Start-Sleep -Seconds 15
# Reading 2
$a2 = curl.exe -s -u "opencode:$password" "http://127.0.0.1:$port/session/$advisor/message?limit=5" |
    ConvertFrom-Json
$a2Str = ($a2 | ForEach-Object { $_.info.id + ":" + ($_.parts | ForEach-Object { $_.type + ":" + $_.text }) }) -join '|'
if ($a1Str -eq $a2Str) { Write-Host "SESSION IDLE -> may be stuck" }
else                   { Write-Host "SESSION GROWING -> still working, do not intervene" }
```

> Quick alternative: the session summary also exposes the size
> (`GET /session` -> `tokens` and `summary`). If `tokens.output` or `summary`
> change between readings, the agent is active.

### c) Wake up a stuck agent with "sigue"

Only after confirming in (b) that the session **is not growing**, if the agent is
stuck or its reply was truncated, send it `sigue` with `prompt_async`
so that it resumes its turn and completes the send:

```powershell
$body = '{"parts":[{"type":"text","text":"sigue"}]}'
$body | Set-Content "$env:TEMP\msg.json" -Encoding ascii -NoNewline

curl.exe -s -X POST -u "opencode:$password" -H "Content-Type: application/json" `
  --data-binary "@$env:TEMP\msg.json" `
  "http://127.0.0.1:$port/session/$advisor/prompt_async"
```

> `sigue` without `noReply` wakes up the agent and makes it continue its work. It is
> a safe way to reactivate a stalled advisor without losing its context. **Do NOT
> send it if the session is still growing (b): it would interrupt its work.**
>
> **RULE:** it is NOT
> a retransmission of the logical message. `sigue` is an instruction directed at the
> **existing session** to continue its context; it does NOT carry `msg_id` (nor
> `run_id`, nor `token`). Therefore it does NOT participate in the idempotency of 12.8 nor in
> RECONCILE (12.10) at the message level. Identity distinction (12.1):
> - **RESUME** (`sigue`): same session + same context + implicit `task_id`
>   (the current task). The agent continues where it left off.
> - **RETRY**: retransmission of the SAME logical message with the SAME `msg_id`
>   (idempotent). Used ONLY in 12.10 (RETRY scan) when the step is
>   idempotent and the message can be resent from scratch.
>
> **Tested pitfall (2026-08-10, Buda task):** a stuck advisor (model-e)
> stalled TWICE on the same task, and after a `sigue` it ended up with an
> empty `assistant` again. The reply took ~1-2 min to complete.
> Guideline: after sending `sigue`, wait and check again (b). Do not send
> `sigue` in a rapid loop: wait ~30-60 s between retries and verify that the
> session is idle again before repeating. A new `sigue` while the agent is
> still processing (or has enqueued another) may confuse the turn.

> **Auto-continuation pitfall (tested 2026-08-10, Bugs TXBridge task):** the
> environment itself injects automatic messages like "Continue if you have next
> steps, or stop and ask for clarification" that **derail** some
> advisors: model-d interpreted them as "resume what you did" and replied with a
> summary (or asking if it should fix bugs) instead of delivering its report.
> Guideline: if an advisor replies "summarizing" without delivering the task, check if
> there was one of these automatic messages; send an **explicit and firm
> nudge** (e.g.: "DO NOT summarize or fix anything. Deliver the FINAL report
> NOW, complete, with signature `TOKEN:...`") with `prompt_async` (4c), and warn that the
> automatic "Continue..." message should be ignored.

### d) Waiting windows (do not wait indefinitely)

- **Contributions (round 1):** wait at most 3 minutes; if any are missing,
  check if the absent one is still active (b); only if its session is idle,
  send it `sigue` (c).
- **Final agreements:** same criterion, 3 minutes; advisors usually
  reply within seconds.
- **Partition rule (v1.6.1, simplification):** messages with ACK ->
  **sec 12.3 governs completely** (120s, decision by two signals, no backoff).
  Messages without ACK -> **this section governs** (3 min). There is no need to interpret
  both rules simultaneously: the ACK is the boundary.
- **Before any `sigue`:** always verify that the session is not growing between
  two readings (b). If it grows, wait and check again.
- Do not retry the entire task: diagnose first (a) and check (b).

### e) External monitoring by the leader and notice from own chat (v1.2)

> **Rule that EVERY agent must know (v1.2, 2026-08-10):**
>
> 1. **The agent that assigns the task (the leader) can read your session from
>    outside** using `GET /session/<YOUR_ID>/message` (section 6.1a) and check your
>    status with `GET /session/<YOUR_ID>` (section 10.1). You have no privacy
>    from the leader during the task: if your session goes idle or empty, they
>    will detect it.
> 2. **If you CANNOT complete the task** (provider down, error, you don't know how
>    to continue), **write it in your own chat** (your conversation, normal message,
>    no commands): the leader will see it when reading your session and will send you help
>    (instructions, a ready-to-copy script, or a `sigue`).
> 3. **Do not try to run commands blindly** to "fix" a failed
>    send: if you have several failed attempts, stop and notify in your chat with
>    plain text (see problem 11.6).
> 4. **An empty `assistant`** in your session is the signal the leader uses to
>    know something went wrong: if your reply is coming up empty, explain it in
>    text within your own conversation to avoid generating a streak of
>    empty messages.
> 5. **If the problem is CONNECTIVITY** (you cannot send to the leader's
>    session, repeated HTTP 5xx), write in your chat the **exact HTTP
>    error** (code and message, e.g. `HTTP 500 Unexpected server error`). The leader will
>    use it to diagnose whether the failure is the server's or the agent's.

# Part III - Reliability & operations

## 7. Delivery confirmation (ACK)

> **Consensus (Improvement Rounds 2026-08-10):** to guarantee that a message was
> **processed** (not just received by the server), an ACK token is used.
> The ACK complements the window verification (section 6): the window detects
> the final reply; the ACK detects the initial processing.

### 7.1. ACK format

```
ACK:<original_token>:<SENDER_SESSION_ID>:<SENDER_MODEL>
```

Example: if the leader sends the task with token `PROPUESTA-R1` and the advisor
`ses_BBBBBBBB` (model `model-b`) processes it, the advisor sends:

```
ACK:PROPUESTA-R1:ses_BBBBBBBB:model-b
```

> **Clarification (v1.3, advisor consensus 2026-08-10):** the ACK is built on
> the **full received token** (including its suffix, if any) and appends at
> the end the ID and model **of the ACK sender**:
> `ACK:<full_received_token>:<ACK_SENDER_ID>:<ACK_SENDER_MODEL>`. The model goes
> **always at the end**, separated by `:`. This way the original sender knows
> who (which model) confirmed. The parser must tolerate 3 or 4 segments
> (`ACK:token:ID` without model, or `ACK:token:ID:model`).

The model is optional but recommended: it makes it human-readable which
model confirmed the processing (section 4d). The session ID is the
canonical identifier for vote counting.

### 7.2. When to send the ACK

- The receiving agent sends the ACK as its **first step** when processing a message from
  another session, **before** its reply or contribution.
- The ACK is sent to the sender's session using `POST /session/<ORIGIN_ID>/message`
  (section 5) or the `send_message.ps1` wrapper (4e), typically with `noReply: true`.
- The ACK confirms: *"I received your message and I am processing it"*.

### 7.3. Timeout and retries (sender side)

When sending a message that requires confirmation:

1. Wait at most **30 seconds** for the ACK.
2. If it does not arrive, retry sending the original message.
3. Exponential backoff: **30s, 60s, 120s** (3 retries max).
4. After 3 failures, use the **`sigue`** mechanism (section 6.1c) as fallback and
   log the failure in `audit_log.md` (section 9).

> **Precedence v1.6 (2026-08-11):** this section describes the classic ACK
> (v1.1). For messages with `requiere_ack=true` in the anti-sleep protocol, the
> deadline and decision are set by **sec 12.3**: 120s FIXED, NO backoff -- if the
> session grows, renew lease and wait (it is not a failure); if idle, apply
> the circuit breaker (12.9). The 30/60/120 backoff in this section is
> **replaced** by sec 12.3 for those messages; this section only continues
> to apply to classic synchronous send retries (section 4b) and
> tasks without `requiere_ack`.

### 7.4. When NOT to use ACK

- In simple single-reply tasks (e.g. "describe who Buddha is"), the ACK
  is optional: the reply itself confirms processing.
- In coordinated multi-round tasks, the ACK is **recommended** to
  detect stuck agents early.
- The sender can explicitly request an ACK by including `[ACK requerido]` in
  the message. If not requested, the receiver does not send an ACK.
- **`noReply` messages do NOT require ACK** (they are *fire-and-forget*): only
  proposals, agreements, changes, and claims require confirmation.

### 7.5. Explicit NACK: the advisor CANNOT do the task (v1.6.1, external-reviewer)

An advisor that **cannot** process the message declares it with a NACK instead
of processing blindly or remaining silent. It is the canonical channel for
CAPACITY failures (not just connectivity, which is reported in the chat itself, 6.1e):

```
NACK:<original_token>:<SENDER_SESSION_ID>:<SENDER_MODEL>:<REASON>
```

**Enriched format (v1.7, external-reviewer BUG A correction -- traceability of the rejected
message):** the NACK sender can add the original `msg_id` and `run_id`
from the received envelope (12.1), so the leader correlates without ambiguity:

```
NACK:<original_token>:<SENDER_SESSION_ID>:<SENDER_MODEL>:<REASON>:<msg_id>:<run_id>
```

The engine's parser (`Parse-CrossEnvelope`) extracts `msg_id`/`run_id` from the
v2 NACK envelope; v1 free-text NACK formats (legacy segments) are **rejected**
in v2.0 (breaking).

**Closed reasons (fixed enumeration, no free text -- the leader classifies them):**

| Reason | Meaning |
|--|--|
| `CAPACITY` | I cannot complete it (context exhausted, task too large) |
| `TOOL_MISSING` | I do not have the tool/path/permission the task requires |
| `AMBIGUOUS_TASK` | The task is ambiguous and I cannot execute it safely |
| `PROVIDER_DOWN` | My provider/model is down (technical failure, not capacity) |
| `OTHER` | Any other reason (clarify in the message or in the chat) |

Rules:
- The NACK is sent via API to the sender's session (same as the ACK), with
  `noReply: true`, as soon as the impossibility is detected (do not wait for timeout).
- The sender/leader receives the NACK and decides based on the reason (table below):
  **reassign** to another advisor (same task, new `msg_id` or same per 12.5),
  **abort**, or **escalate to human** (DLQ with `flag`, see 12.7). Mark the
  outbox accordingly (`ESTADO=NACKED`).
- A NACK is not an agent failure: it is operational information. Do not penalize the
  NACK sender.
- The NACK is also used in the protocol handshake (4d):
  `NACK-PROTOCOLO:unsupported_version:<received_version>`.

**Recommended leader action by reason (v1.6.1, external-reviewer F3 correction):**

| NACK reason | Recommended leader action |
|--|--|
| `CAPACITY` | Reassign to another advisor; if reassigning, do NOT increment `attempt` (it is not a new idempotent delivery, 12.1) |
| `TOOL_MISSING` | Leader provides the path/tool in the retry (8.2) or reassigns to an advisor that has it |
| `AMBIGUOUS_TASK` | Leader reformulates the task and resends with a NEW `msg_id` (it is a new delivery, not RETRY) |
| `PROVIDER_DOWN` | Do not reassign to another provider immediately; wait (12.3, if the session grows) or exclude from this round |
| `OTHER` | Report to human in DLQ with `flag=HUMAN_REVIEW` |

### 7.6. Relationship with existing mechanism

The ACK is complementary to the window verification (section 6). The
window verification detects the final reply; the ACK detects the
initial processing. Use both in critical tasks; use only window verification
in simple tasks.

## 8. Inter-session coordination protocol (collaborative tasks)

For tasks that both sessions must resolve and agree on:

1. **Proposal:** send your draft to the other session with `prompt_async`,
   including a unique **round token** (e.g. `PROPUESTA-R1`).
2. **Contribution:** if you want the other session to CONTRIBUTE something, tell it
   EXPLICITLY in the message (what it can correct, add, or remove). If you only
   ask it to accept, it tends to reply "agreed" without working.
3. **Reply:** the other session replies to YOUR session using section 5,
   with the token and, if applicable, its revised version. **Append the sender's session
   ID to the token** (`TOKEN:ses_XXXXXX`) to count votes per agent.
   **If you do not receive its reply, it was not a valid reply: ask it to
   send it to your session via API (section 5), not to write it in its chat.**
4. **Integration:** integrate its contribution, fix any mojibake (`?`) if present,
   and send the final version requesting an explicit agreement token
   (e.g. `ACUERDO-FINAL`).
5. **Verification:** poll your session (section 6) until you receive the agreement
   token or a counter-proposal. If after 3 minutes an advisor is missing: read its
   session (6.1a), verify it is no longer growing (6.1b) and, only then, send it
   `sigue` (6.1c). Do not wait or restart without diagnosing.
6. Repeat 1-5 until you receive explicit agreement from both.

Tokens make verification unambiguous: they filter out noise
(old or duplicate messages) and confirm that the other session reached
agreement. Real verified example: proposal -> the other session contributed 3 improvements
-> integration -> `ACUERDO-FINAL`.

### 8.1. Analysis of large projects (do not exhaust context)

When the code to analyze exceeds the available context (v1.5, model-c
contribution), do NOT try to read all complete files:

1. **Prioritize key files:** main/orchestrator, public headers
   (`AudioEngine.h`, `AudioDevice.h`), and the modules that concentrate the logic.
   Large `.cpp` files (e.g. `ui/App.cpp`) are read selectively by
   section/offset depending on what you are looking for.
2. **Use search tools** (Grep/Select-String, Glob) to locate
   symbols, call sites, and patterns instead of reading entire files.
3. **The leader must specify in the task message the priority files**
   and lines/ranges to review when known (section 4d), so that the
   advisor does not waste context.
4. If a file is huge and only affects one area, verify the specific area and
   note which part was left unreviewed instead of reading the whole thing.

### 8.2. Environment tool location (tested pitfall: Python)

Sometimes models cannot find the tools or use the wrong path.
Real pitfall (2026-08-10): `python` in this system's PATH is the **Windows Store
stub** (`C:\WINDOWS\system32\python`) that does NOT execute anything (returns
empty silently). model-d could not use Python until the human user told it
the real path. Therefore:

1. **Real Python:** the full path of your Python installation (see `where python` or `py -0p`)
   -- do NOT use bare `python` or `py`. Always invoke with the full path.
2. **curl:** `C:\WINDOWS\system32\curl.exe` (works as `curl.exe`).
3. **git:** `C:\Program Files\Git\cmd\git.exe`.
4. **CMake:** `C:\Program Files\CMake\bin\cmake.exe`.
5. **GCC/G++ (MSYS2 UCRT64):** `C:\msys64\ucrt64\bin\g++.exe` / `gcc.exe`
   (real desktop build toolchain; see project AGENTS.md).
6. **Send CLI:** `cross.ps1 send` or `cross.ps1 send --text "..." --dest ses_X` (auto-detects credentials; see sec 4d).

> If the leader delivers a task that requires a tool, it must specify its
> **full path** in the message (section 4d) and not assume the advisor will
> find it. If an advisor cannot use a tool, it should notify in the chat
> (6.1e) instead of staying blocked or using an incorrect path.

## 9. Traceability and auditing (`audit_log.md`)

> **Consensus (Improvement Rounds 2026-08-10):** a single shared record provides
> traceability of who said what and when. The canonical name is
> `whiteboard/audit_log.md` (an alternative proposed, `tracking.md`, was in
> the minority). Append-only file, one per work session.

### 9.1. Format of each line

```
| YYYY-MM-DD HH:MM:SS | ORIGIN | DESTINATION | TOKEN | MODEL | TYPE | STATUS | NOTE |
```

- **MODEL** (v1.3): model of the message sender (e.g. `model-b`).
  Optional: if unknown, leave empty.
- **TYPE** (valid, v1.6.1 external-reviewer F4 correction): `PROPUESTA`, `ACUERDO`,
  `CAMBIO`, `RECLAMO`, `ACK`, `ACK-PROTOCOLO`, `NACK`, `NACK-PROTOCOLO`,
  `HEARTBEAT`, `REACTIVACION`, `ENV`, `REC`, `RESP`, `SIGUE`, `CLAIM`, `DONE`,
  `RELEASE`.
- **STATUS** (valid): `PENDIENTE`, `ENTREGADO`, `CONFIRMADO`, `FALLIDO`,
  `REINTENTANDO`.
- **NOTE**: max ~80 characters, no accents (plain ASCII).
- Separator: pipe `|`.

Example:

```
| 2026-08-10 15:30:12 | ses_AAAAAAAA | ses_BBBBBBBB | PROPUESTA-R1 | leader-model | ENV | DELIVERED | Task: workspace analysis |
| 2026-08-10 15:30:18 | ses_BBBBBBBB | ses_AAAAAAAA | ACK:PROPUESTA-R1:ses_BBBBBBBB:model-b | model-b | ACK | CONFIRMED | Received and processing |
| 2026-08-10 15:31:45 | ses_BBBBBBBB | ses_AAAAAAAA | MEJORA-R1:ses_BBBBBBBB:model-b | model-b | RESP | DELIVERED | 3 improvements proposed |
```

> **Signature with model (v1.2):** tokens carry the suffix
> `:<MODEL>` in addition to `:<SESSION_ID>` (section 4d), so that the human user
> can read the model at a glance. In the log, the MODEL column makes it explicit.

### 9.2. Rule

Each agent logs its sends and receives in `audit_log.md`. It is not a
blocking requirement, but it is the shared evidence to reconstruct the flow
of proposals and agreements if something is lost.

## 10. Session and task monitoring

> **Consensus (Improvement Rounds 2026-08-10):** three complementary mechanisms,
> each with a distinct role:

| Mechanism | Role | When to use |
|--|--|--|
| `GET /session/:id` (API, already exists) | Live technical status (active, metadata, tokens) | Fast presence polling |
| `whiteboard/task_status.md` | Global task board (which round, who replied) | Update per round, reference for new agents |
| Verification window + double reading (6.1b) | Diagnosis of stuck agents | Before sending `sigue` |

### 10.1. Quick status query with `GET /session/:id`

Verify if a session is active without loading the full history:

```powershell
curl.exe -s -u "opencode:$password" "http://127.0.0.1:$port/session/<SESSION_ID>"
```

Returns session metadata (`id`, `agent`, `model`, `time`, and if available
`tokens`/`summary`). It is the preferred method for lightweight polling
(1-2 s) instead of listing all sessions and filtering.

### 10.2. Task status board (`task_status.md`)

Global view for the leader and for new agents joining mid-task.
Updated per round, not in real time. Suggested format:

```
# Status of task <NAME>
- Round: 2 of 5
- Advisors: model-b (R2 ok), model-d (R2 ok), model-c (R2 ok), model-f (provider down)
- Pending: final consensus R3
```

> **Note (R3 consensus):** the `heartbeat.json` proposed in R1 was removed due to
> race conditions (multiple agents writing the same file) and because
> `GET /session/:id` already covers presence without overhead.

### 10.3. Heartbeat `ESTADO:` (v1.8, low-cost advisor availability)

> **v1.8 (2026-08-19, after nemotron's experiment as leader and the
> ESTADO-88 availability query, 3/3 verified via API):** convention for
> advisors to report their availability WITHOUT being asked, so the leader
> has a live dashboard and never wastes a round on a status check.

**Format** (verified in ESTADO-88, 2026-08-19 -- same as the task reply):

```
ESTADO:sesion:modelo|DISPONIBLE|capacidad=<descripcion>
```

Values for the state field: `DISPONIBLE` | `OCUPADO` | `DESCANSANDO`.

**Rules:**

1. **Each advisor publishes `ESTADO:` in its own session history**
   (via its own reply, or a self-send with `-NoReply` -- no need to wake
   anyone) **every `HEARTBEAT_INTERVAL_MIN` (5) minutes** while it is
   operative, or **immediately when its state changes** (e.g. goes OCUPADO
   with a task).
2. The leader builds the dashboard by polling each advisor session with
   `GET /session/:id/message?limit=N` (section 6) and filtering lines
   matching `^ESTADO:`; the LATEST line per session is the current state.
   **Only the leader writes `whiteboard/estado_equipo.md`** (single writer,
   rewritten on each change -- the advisors publish `ESTADO:` in their own
   history but never write the dashboard file themselves).
3. If the leader has no `ESTADO:` line for an advisor for > `STALE_THRESHOLD_MIN`
   (15) min, it is treated as `NO RESPONDE` and the leader follows the standard
   diagnosis (6.1) before declaring it down (11.5, provider vs. stuck distinction).
4. Heartbeats are LOW PRIORITY: they must never be used as the primary
   wake-up mechanism (that is `prompt_async`, golden rule sec 5.1/sec 12) and
   must not generate ACK traffic. They are a presence/readiness signal for
   the leader's dashboard, not a delivery channel.

**Dashboard suggestion** (`whiteboard/estado_equipo.md`, leader-maintained,
rewritten on each change -- single writer, avoids the R3 heartbeat.json race):

```
# Estado del equipo (actualizado: <UTC>)
| Sesion | Modelo | Estado | Capacidad | Ultimo ESTADO |
|--|--|--|--|--|
| ses_... | big-pickle | DISPONIBLE | full stack | 12:00Z |
| ses_... | mimo-v2.5-free | DISPONIBLE | verificacion/bugs | 11:58Z |
| ses_... | nemotron-3-ultra-free | OCUPADO | full | 11:55Z |
```

> **UTC MANDATORY:** the "Ultimo ESTADO" column MUST use UTC with the `Z`
> suffix (e.g. `12:00Z`, not `12:00` or local time). The leader compares
> these timestamps with its own UTC clock to determine the > 15 min threshold
> (rule 3). Without the Z suffix, time comparisons will be wrong on machines
> with non-UTC local time.

> This replaces the ad-hoc STATUS CHECK round (what nemotron ran as leader
> with `noReply=true`, which never woke the advisors -- their finding #1):
> with the heartbeat, availability is already known before any task dispatch.

## 11. Known issues and solutions

> **Expanded in v1.1** with real cases observed during the improvement
> rounds (2026-08-10). The PowerShell/Windows-specific pitfalls are
> consolidated in **`CROSS_WINDOWS.md`** (formerly Appendix B); items 1,
> 2, 7, and 8 are kept here for historical numbering (cross-references) and the
> details are delegated.

1. **Corrupted JSON / HTTP 500** when using `-d '...'` inline in PowerShell: use
   file + `--data-binary` (section 4) or the wrapper (4e). Details:
   `CROSS_WINDOWS.md` #1.
2. **Mojibake** (accents as `?`): send plain ASCII, fix when integrating.
   Details: `CROSS_WINDOWS.md` #2.
3. **Agents that reply only in THEIR chat** without sending via API (section 5):
   demand the send, not the drafting. **v1.7 E2E finding (TEST-E2E-85):**
   nemotron-3-ultra-free wrote the complete reply with its signature in its
   own chat but NEVER sent it via API, even after 3 nudges describing the
   method; it only worked when the leader sent the ready-to-copy script
   verbatim (see sec 4d rule). openrouter/free breaks the PowerShell command
   syntax (missing `)` errors) and also needs the script verbatim.
   **v1.7.1 finding (TEST-E2E-86):** openrouter/free STILL failed with the
   script (copied the source line as payload text, literal `` `n `` and
   `$(Get-Date)` unexpanded); the **pre-built JSON fallback** (sec 4d) -- leader
   writes the payload file, advisor runs one `curl --data-binary "@file"`
   line -- worked in 1 nudge.
   **Guideline: from v1.7 on, the leader always embeds the ready-to-copy
   script in the task message (sec 4d); if the advisor still fails, escalate
   to the pre-built JSON fallback (sec 4d, v1.7.1) -- do not assume the advisor
   can build the curl/PowerShell command itself.**
   **v1.8 (ESTADO-88, 2026-08-19):** nemotron as leader sent its status
   check with `noReply=true` and the advisors never woke (their finding
   #1); the re-run by the leader with `prompt_async` + ready-to-copy
   script got 3/3 replies in minutes. Also: a send loop without `-m`
   timeout in curl hung the shell and truncated delivery to 1 of 3
   advisors -- always set `-m 30` or use the wrapper (4e.2).
4. **Agents stuck with empty `assistant`:** verify with double reading (6.1b)
   and `sigue` (6.1c); do not fire `sigue` in a loop (wait ~30-60 s).
5. **Provider down (does not respond even when requested):** it is not a stuck agent, it is
   a provider failure. Detectable because the last `assistant` is **empty**
   and created **in milliseconds** after the last `user` (an LLM does not generate in
   milliseconds), and `time.updated` does not advance. Log the event (see
   `whiteboard/03_evento_north_mini.md`) and continue with the healthy agents.
6. **Agent that attempts failed commands repeatedly:** may produce a streak
   of empty `assistant` messages. Read its session, detect the streak and send it **explicit
   instructions with a ready-to-copy script** (as in the model-d case in R3).
7. **`/tmp/` paths on Windows:** they do not exist; use `$env:TEMP`. Details:
   `CROSS_WINDOWS.md` #4.
8. **`&&` in PowerShell 5.1:** it does not exist; use `;` or separate commands.
   Details: `CROSS_WINDOWS.md` #5.
9. **Hardcoded old credentials (v1.4, model-b case):** a model sent its
   vote with `$port = "56678"` and a pasted literal password; the server had
   restarted (port rotated to another and password changed) and the message
   **did not arrive** even though the script reported success. Rule: mandatory
   auto-detection before EACH send (section 1) or use the wrapper (4e), which ignores
   fixed values. Verify with `GET /global/health` after detecting.
10. **Hardcoded port in status check (v1.8, nemotron case, 2026-08-19):**
    nemotron as leader sent its status check with a hardcoded port `10844`
    (the port from a previous session); the server had restarted and the
    port was different. The sends succeeded (HTTP 200) but the messages
    went to a dead port. Additionally, `noReply=true` was used so the
    advisors never woke. **Rule: ALWAYS auto-detect the port before EACH
    send (section 1) or use the wrapper (4e/4e.2).** Never hardcode ports.
    Verify with `GET /global/health` after detecting. This is a specific
    instance of the general class documented in item 9.

# Part IV - Anti-sleep protocol

## 12. Anti-sleep protocol (v1.6, with v1.6.1 corrections)

Objective: ensure NO message goes to sleep. Inherited golden rule: ALWAYS
`prompt_async` WITHOUT `noReply` to wake up (section 5.1). Files are
RESCUE, not primary: the only primitive that wakes an agent is
`prompt_async`.

### 12.1 Standard message envelope

Every message from the leader to an advisor (and between advisors) carries this prefix:

    [msg_id=msg_<emisor_short>_<YYYYMMDD-HHMMSS-RAND6> | run_id=ACTIVIDAD |
     token=TOKEN_ESPERADO | requiere_ack=true|false |
     lease=ses_A@UTC+3min|sucesor=ses_B | timestamp=ISO8601]

**Formal identities (v1.6.1, external review correction 2026-08-11):** the
protocol distinguishes five independent identities. A single task may
have multiple runs, messages, and attempts; they are NOT interchangeable:

| Identity | Meaning | Example | Used in |
|--|--|--|--|
| `task_id` | The logical task (one objective) | `TX-DSP-042` | summary, DLQ, reports |
| `run_id` | A concrete execution of the task | `RUN-20260811-01` | envelope (correlation) |
| `msg_id` | A logical message (idempotency key) | `msg_model-d_20260811-1512-a3f9` | outbox, 12.8, RETRY |
| `attempt` | Number of send attempts for that msg | `attempt=2` | backoff, circuit breaker |
| `session_id` | The agent session (process/context) | `ses_013b...` | routing, presence |

**`attempt` semantics (v1.6.1, external review correction):** `attempt` is
the number of DELIVERIES of the logical message (`msg_id`). Rules:
- **RETRY** -> `attempt + 1` (it is a new delivery of the same `msg_id`).
- **TRANSFER** (lease to successor) -> `attempt + 1` (new delivery, even if
  `session_id` changes).
- **RESUME** (`sigue`) -> does NOT increment `attempt` (it is not a new delivery: the
  session already had the message and is only continuing its context).
- `max_hops=2` (12.5) and circuit breaker A/B/C (12.9) read this counter.

- `msg_id`: UNIQUE per logical message. Includes the sender session prefix
  (`msg_model-d_...`) to guarantee uniqueness without coordination (model-d
  adjustment, R3). Serves as idempotency key, event_id and file reference.
- `run_id`: current activity (e.g. `MEJORA-V16-R1`) for correlation.
- `token`: what the advisor must return signed (`TOKEN:...:ID:MODEL`).
- `requiere_ack`: `true` in critical tasks; `false` in simple tasks
  (rule 7.4).
- `lease`: owner + UTC deadline + **explicit successor** (not just owner and
  deadline), so the envelope is self-contained (model-a adjustment, R3).

> **IDENTITY NOTE (v1.6.1):** `sigue`/RESUME operates on `session_id` +
> `task_id` (continues the context). `RETRY`/RECONCILE/TRANSFER operate on
> `msg_id` (retransmit or reconcile the logical message). Do not mix them:
> sending `sigue` is not retransmitting, and retransmitting without context does not resume.

> **ENVELOPE-V2 (v1.9.0, Fase 1):** since v1.9.0 the engine adds a second,
> structured line to the message body -- `ENVELOPE-V2: {json}` (v2 envelope,
> see `cross/modules/cross-envelope.psm1`). The v1 envelope above is
> UNCHANGED and remains the canonical format; v2 is an additional, validated
> representation (`v=2`, `type` in {message,ack,nack}). `Parse-CrossEnvelope`
> is the only parser (v1 removed in v1.17). Fase 3 complete.

### 12.2 Durable outbox (BEFORE sending)

Before calling `prompt_async`, the **sender** writes a line in
`whiteboard/outbox.md` (append-only):

    [2026-08-11T15:42:03Z] OUTBOX | msg_id | dest=ses_X | run_id | token |
    lease=ses_A@UTC+3min|sucesor=ses_B | ESTADO=EN_VUELO

The ACK (12.3) or the result moves the line to `ESTADO=CONFIRMADO`. If it expires
without confirmation: `ESTADO=EXPIRADO`. If the lease is transferred: `ESTADO=TRANSFERIDO`.
**Only the sender updates the outbox** (knows the ACK/timeout status);
the receiver only sends ACK and processes, it does not write to the outbox (avoids
write races, model-d R3 adjustment). The leader reads the outbox, does not
guess from the chat. Survives restarts.

> **WHY ONLY THE SENDER (verified by test T10, 2026-08-11):**
> PowerShell's `Add-Content` is ATOMIC (all-or-nothing; it never interleaves or
> corrupts a line) but uses EXCLUSIVE LOCK per call. With two
> processes writing simultaneously, the second receives `IOException` ("file
> in use by another process") and LOSES its line silently if it does not
> retry it. In the test, W1 lost 25 lines to W2 (0 corrupted).
> Conclusion: sender exclusivity is not a preference, it is an
> integrity requirement. If concurrent writes were ever needed
> in the future, do append with retry with backoff on IOException (or use a
> lock file).

### 12.3 ACK at turn boundary (requiere_ack=true)

Upon waking up and processing a message with `requiere_ack=true`, the advisor first
replies with the full format from section 7.1:
`ACK:<received_token>:<ADVISOR_ID>:<MODEL>`. The ACK means "received and
starting to process", not "finished" (model-d R3 adjustment). It is asynchronous and non-
blocking: the advisor continues working after issuing it.

If the leader does not receive the ACK within **120s** (model-d R3 adjustment; 60s was insufficient
for tasks with prior research like reading news and writing vision),
**it does NOT increase the deadline**: it decides by TWO signals (12.4/12.9). Precise
term: it is a **"ACK decision window" of 120s** (decision window), not a
timeout: if the session grows, another window is waited for instead of declaring failure.

1. Is the session growing? (12.4a). If the model is generating (e.g. provider
   timeout with automatic retry, case 524 observed on 2026-08-11:
   valid ACK at 323s after [504]->retry error): renew lease and wait
   ANOTHER cycle; the ACK will arrive. This does NOT count as an escalation failure.
2. Session idle AND no ACK? -> sleeping/dead -> circuit breaker (12.9):
   A transient -> 1 idempotent retry; B recoverable -> renew lease;
   C permanent -> escalation (12.6) -> DLQ (12.7).

Finiteness rule: never more than 2 retry cycles to the same destination (12.9).
Total wait is bounded (fixed deadline -- 2 cycles); late ACK from a
slow provider is tolerated ONLY if the session grows. A model that never
replies is detected by idle session, not by "increasingly long timeout".

### 12.4 Passive presence (replaces heartbeat PING/PONG)

No PING/PONG messages (noise; R2 consensus). The leader checks presence with
two separate `GET /session/:id` readings (6.1b) and/or by looking at
`whiteboard/outbox.md`: if an `EN_VUELO` expires and the session is NOT growing ->
sleeping. If growing -> renew lease and wait.

### 12.5 Lease with successor (the task never goes without an owner)

Every task in the outbox carries a lease: owner + deadline (UTC+3min) + successor.
**Default successor = next in the turn sequence**, not always the
leader (model-d R3 adjustment: distributes handoff load; the leader remains
available as explicit successor if designated). Rules:

- (a) expired lease and `EN_VUELO`: check if the session grows (6.1b).
  If growing, renew lease and wait.
- (b) If idle: idempotent RETRY (retransmit the SAME `msg_id`,
  not a `sigue`; see RESUME/RETRY distinction in 6.1c and 12.1).
- (c) If still `EN_VUELO` after the retry: REASSIGN to successor with
  `prompt_async`, same `msg_id` and note "lease transferred". `max_hops=2`.
- (d) Exhausted: QUARANTINE -> DLQ with human report.

### 12.6 Escalation channel (whiteboard/escalated.md)

If `prompt_async` fails 3 times, an entry is written to
`whiteboard/escalated.md` (unifies escalated + wake-on-write, R2 consensus):

    URGENTE | para=<ses_ID> | msg_id | run_id | de=<ses_emisor> |
    expira=UTC | "summary"

The advisor checks `escalated.md` when waking up (after any `prompt_async`)
and after each turn; if there is an entry for it, it processes it and marks `RECIBIDO`.
NOTE: the file does NOT wake up on its own; it is backup for when the agent
is already awake by other means. Application-level "magic packet"
(Wake-on-LAN).

> **CROSS coordination pattern: stigmergic wake-on-write (v1.6.1,
> advisor consensus 2026-08-11).** This mechanism -- shared file as
> coordination channel, with writes as signals and `URGENTE|para=<ID>`
> messages parseable by each agent when waking up and after each turn -- is the
> **state-shared coordination pattern developed for CROSS**. Stigmergic
> coordination (signals in a shared space discovered by other agents) exists in the
> literature; CROSS applies it in a particular way on markdown files with the
> `URGENTE|para=<ID>` semantics described here. No equivalence is claimed nor
> absence of equivalent in other protocols (A2A, MCP, ACP/ANP): it is documented
> as the project's own pattern, with the Wake-on-LAN "magic packet" analogy
> (patent WO2007024306A1) -- binary, unidirectional, and only wakes up,
> while ours is human-readable, bidirectional (any agent writes and reads) and
> besides waking up it carries the message and its `msg_id` (idempotency).

### 12.7 DLQ (whiteboard/dlq-messages.md)

After exhausting escalation, the message is written to `whiteboard/dlq-messages.md`
(append-only, visible to all sessions and to the human):

    [date] DLQ | msg_id | to=ses_X | from=ses_Y | retries=3 |
    ESTADO=UNREAD | flag=HUMAN_REVIEW | "summary"

The `flag` field is **closed** (parseable, v1.6.1 external-reviewer F2 correction):
`HUMAN_REVIEW | NACK_ORIGINATED | QUARANTINE | PROVIDER_DOWN`. It facilitates
filtering for the human; the `"summary"` is free-form for details.

The recipient marks it `RECIBIDO` upon picking it up. Nothing is lost
silently.

### 12.8 Idempotency (whiteboard/idempotencia-procesados.md)

**State machine (v1.6.1, external-reviewer corrections 2026-08-11 + F1-F4/O1):** each
`msg_id` goes through states `CLAIMED` -> `PROCESADO`. The `CLAIMED` state
covers the window between "check that it does not exist" and "finish processing" (which
in an LLM lasts 30-90 s), avoiding the double-processing race condition:

    msg_id | timestamp_claim | modelo_claimer | CLAIMED_BY=ses_X
    msg_id | timestamp | modelo | PROCESADO
    msg_id | timestamp | modelo | SUPERSEDED_BY=ses_Y

**Append-only (v1.6.1, O1 external-reviewer):** the file is an append-only log (like the
outbox), NOT editable in-place. Editing an existing line in PowerShell
(`Get-Content` -> modify in memory -> `Set-Content`) is NOT atomic and creates
a race when two agents write simultaneously (e.g. the legitimate claimer
writing `PROCESADO` while the leader does release). Therefore:

- **CLAIM**: before processing, the receiver APPENDS
  `msg_id | timestamp_claim | modelo_claimer | CLAIMED_BY=ses_X` (EXACT
  format, no extra spaces or variations -- the CLI parser recognizes it).
  If the last line for the `msg_id` is already `CLAIMED` or `PROCESADO` and active ->
  skip (duplicate).
- **PROCESADO**: do NOT rewrite the CLAIMED line: when finished, the receiver
  APPENDS a new line `msg_id | timestamp | modelo | PROCESADO`.
- **Release (abort)**: do NOT delete the line: if the claimer aborts the
  task, it APPENDS `msg_id | timestamp | modelo | SUPERSEDED_BY=ses_Y` (the
  original claimant or another agent declares that the claim is void;
  it does not write `PROCESADO`).
- **Retry with CLAIMED (v1.6.1):** a RETRY is only triggered if the `msg_id` has NO
  line at all in the file, or if its last line is `CLAIMED_BY=ses_X`
  AND session `ses_X` is idle (12.4, double reading). If `ses_X` grows ->
  wait: the claimer is still processing. This replicates the lease at the
  receiver level.
- The CLI parser reads the **LAST line** of each `msg_id` and that determines
  the active state (`CLAIMED_BY=ses_X`, `PROCESADO` or `SUPERSEDED_BY=ses_Y`).
  Previous lines are the lifecycle history of the `msg_id`.

**At-least-once delivery with `msg_id` deduplication:** the send may
repeat (retries, retransmissions), but the receiver processes each `msg_id`
only once.

**Scope of effectively-once (v1.6.1, external review correction):**
`msg_id` deduplication gives effectively-once behavior ONLY for
idempotent operations (a second processing does not produce a different effect).
For NON-idempotent operations (e.g. the receiver modifies a file and
dies BEFORE appending `PROCESADO`), retransmission would process twice:
therefore **RECONCILE (12.10)** is required -- verify the output file or
effect before retransmitting -- or confirmation of the effect. Universal
effectively-once is not claimed "by construction" (that would only be guaranteeable
with distributed coordination which does not exist here).

### 12.9 Circuit breaker A/B/C (max 2 attempts)

Before sending "sigue", classify the failure:

- A (transient): one-off timeout/retry -> idempotent RETRY (once).
- B (recoverable): session growing but slow -> renew lease, wait.
- C (permanent): not growing / stable error -> REASSIGN successor or QUARANTINE.

Never more than 2 blind attempts to the same destination.

**Default parameters (implemented in `cross-delivery.psm1`,
`cross.config.json`):**

| Parameter | Value | Where |
|--|--|--|
| Max attempts (`MaxAttempts`) | 2 (`max_retries`) | config |
| ACK wait timeout | 120 s (`default_ack_timeout_s`) | config / `--ack-timeout` |
| Retry backoff | 2 s linear (`retry_backoff_s -- attempt`) | config |
| Lease | 3 min (`default_lease_minutes`), renewed 1-- per attempt if destination grows | config |
| "Growing" verification | 15 s (`session_growing_check_ms`), 2 message fingerprints | config |
| ACK polling | every 3 s until deadline | engine |
| Retriable HTTP | 0 (network/timeout), 408, 429, ----500 | engine |
| Non-retriable HTTP | 404 -> `DEST_NOT_FOUND`/EXPIRADO; 401/403 -> `AUTH_FAILED`/EXPIRADO | engine |

**NACK reason_code (v1.7, external-reviewer correction):** `NACK_TIMEOUT` (0/408/ACK_TIMEOUT),
`NACK_RATE_LIMITED` (429), `NACK_DEST_NOT_FOUND` (404), `NACK_CONFIG_ERROR`
(401/403), `NACK_SERVER_ERROR` (5xx exhausted), `NACK_HTTP_4XX` (other 4xx),
`NACK_NETWORK` (default). The `attempt` count is **persisted in the outbox
line** (`attempt=N`) before each send (external-reviewer BUG L correction): after a process
crash, `cross send` resumes from the attempt already made.

Delivery engine state transitions:
`EN_VUELO -> CONFIRMADO` (ACK or `--no-wait`/no ACK required), `-> NACKED`
(NACK with reason), `-> EXPIRADO` (404/401/403, non-retriable HTTP exhausted, or
no ACK after max attempts -> `ACK_TIMEOUT`). The scan (12.10) manages
expired `EXPIRADO`/`EN_VUELO` with the ladder (12.11).

### 12.10 Recovery scan (RETRY/RESUME/RECONCILE/QUARANTINE)

The leader scans the outbox at the end of each round AND automatically when
detecting expired `EN_VUELO` (the scan triggers the circuit breaker, not the other way
around; model-d R3 adjustment). Classifies each expired message:

- **RETRY**: only if the step is idempotent (msg_id), same prompt and token.
- **RESUME**: if the agent left a partial checkpoint in whiteboard (continue,
  do not repeat). **How it executes (v1.6.1):** RESUME does not retransmit the original
  message nor reuse its `msg_id`; the leader sends `prompt_async` on the SAME
  `session_id` with a continuation instruction based on the existing
  checkpoint (e.g. `"Continue from <file>:<line>. Deliver the final signed
  report"`). Who determines the continuation point: the leader, by reading
  the whiteboard checkpoint. It is the `sigue` primitive from 6.1c.
- **RECONCILE**: if the effect may have occurred but the receipt is missing: the leader
  inspects the session and/or the **output file** (e.g.
  `diario/15_charla_conciencia.md`, `whiteboard/16_diario_conversaciones.md`)
  BEFORE deciding;
  if the work is recorded there, mark CONFIRMED without resending (avoids
  duplicates, model-d R3 adjustment).
- **SERVER LOG DIAGNOSIS** (last resort before QUARANTINE,
  case 524/2026-08-11): if the session is idle AND there is no ACK after
  retries, the leader reads the server log (`%USERPROFILE%\.local\share\
  opencode\log\opencode.log`, timestamps in UTC) looking for the advisor's
  `session.id` in the timeout interval. Classifies the failure:
  - `stream error ... [504]/[524]` or `connect timeout` / `ENOTFOUND` /
    `Rate limit exceeded` -> **PROVIDER failure, healthy agent**: the server
    retries on its own; do NOT escalate, renew lease and wait (the ACK usually arrives).
  - normal `exiting loop` / no error in the interval -> **agent truly
    sleeping or dead**: follow normal escalation (12.6 -> DLQ).
  - different `stream error` (auth, nonexistent model) -> configuration
    error: report to human in DLQ.
  This step prevents false QUARANTINE from provider intermittency
  (observed: valid ACK at 323 s after 524 error with automatic retry).
- **QUARANTINE**: if safety cannot be proven -> DLQ with human report.

NEVER blindly resend a non-idempotent step that may have mutated state.

### 12.11 Complete ladder (management order)

Envelope (12.1) -> Outbox (12.2) -> ACK (12.3) -> Passive presence (12.4) ->
Circuit breaker (12.9) -> Lease+successor (12.5) -> Scan (12.10, including
server log diagnosis) -> Escalation (12.6) -> DLQ (12.7).
Idempotency (12.8) is cross-cutting. Escalation and DLQ are the last
stages of the circuit breaker (C = permanent -> escalation -> DLQ).

### 12.12 Files used by v1.6 (all in whiteboard/)

- `outbox.md`: send log BEFORE sending (EN_VUELO/CONFIRMADO/
  EXPIRADO/TRANSFERIDO/NACKED).
- `escalated.md`: escalation channel `URGENTE|para=<ID>`.
- `dlq-messages.md`: undelivered messages (UNREAD/RECIBIDO, flag).
- `idempotencia-procesados.md`: append-only lifecycle log for each
  msg_id (CLAIMED -> PROCESADO / SUPERSEDED_BY); dedupe by last line.

### 12.13 Accepted trade-offs (documented after external review, 2026-08-11)

- **Leader SPOF (accepted):** the leader (coordinating session) is a single
  point of failure: it is the one that scans the outbox (12.10), runs the ladder
  (12.11) and decides QUARANTINE/DLQ. If the leader goes to sleep or closes, the
  `EN_VUELO` messages remain unmanaged until another session or the human
  recovers them. **There is no automatic leader election/re-election in v1.6/v1.6.1.**
  Mitigation in v1.6.1 (advisor consensus 2026-08-11, no re-election):
  **AVISO-SPOF (passive detection by advisors).** Each advisor, at the end of its
  turn (and when waking up), lightly scans the outbox:
  `Get-Content whiteboard/outbox.md | Where-Object { $_ -match "EN_VUELO" }`.
  If it finds an expired `EN_VUELO` (timestamp +3 min) whose `para=` matches
  ITS OWN ID and its session is idle (6.1b), it writes to
  `whiteboard/escalated.md`:
  `AVISO-SPOF | msg_id=<ID> | para=<ses_ID> | de=<its_ID> | expira=UTC | "EN_VUELO expired, session idle"`.
  If the foreign `EN_VUELO` is NOT theirs, it can send the leader a message (without
  `noReply`) "there is a fallen message" (early visibility, model-c proposal),
  or write it in its own chat (6.1e) if it cannot send. This does NOT take over
  the task or replace the leader: it only provides early visibility and leaves management
  to the leader (or to the human via `outbox.md`/`dlq-messages.md`). Adding leader
  election or leader heartbeats remains a future improvement (Appendix A).
- **At-least-once delivery (accepted):** `msg_id` deduplication prevents
  duplicate processing, but does not guarantee "exactly-once" in the strict
  sense of distributed systems (there is no atomic transaction between the
  effect and its record). The mechanism provides **at-least-once with
  deduplication; effectively-once only when the operation is idempotent or the
  effect is reconciled before retransmission** (12.8/12.10).
- **Files = visible backup, not primary channel:** the only primitive that
  wakes a sleeping agent is `prompt_async` (12.1/5.1). Files
  (outbox, escalated, DLQ) are the durable record and escalation channel;
  they do not replace the wakeup. Assumed since v1.6.

### 12.14 Unified diagnostics (`cross poll/status/reconcile/aviso-spof`, Phase 4a)
> **NOTE:** Canonical CLI reference: `cross.ps1 --help` (this section summarizes; the help is authoritative).

Implemented in `cross/modules/cross-diagnostic.psm1` (2026-08-12). The 4
subcommands are READ-ONLY: they do not mutate the outbox (only `poll` can mark `NACKED` if
it detects a NACK in `audit_log.md` not reflected, and `aviso-spof --apply` appends to
`escalated.md`). Commands:

- **`cross poll --msg msg_X [--timeout S] [--interval MS]`:** diagnoses an
  outbox message using the primary signal `session.status` + growth
  heuristics (12.4/12.9). Loop until deadline (default
  `default_ack_timeout_s`) or terminal diagnosis. Decision table:

  | outbox | session | diagnosis | action |
  |--|--|--|--|
  | CONFIRMADO / audit ACK | -- | `ACKED` | none |
  | NACKED / audit NACK | -- | `NACKED` | manage by reason (7.5/12.10) |
  | EXPIRADO/TRANSFERIDO/QUARANTINE | -- | `TERMINAL` | ladder (12.10/12.11) |
  | EN_VUELO | lease expired | `EXPIRED` | scan (12.10) |
  | EN_VUELO | `busy` + growing | `WORKING` | wait (renew lease 12.4a) |
  | EN_VUELO | `busy` + idle | `ACKED_QUIETA` | investigate audit/outbox |
  | EN_VUELO | `idle` + idle | `QUIETA_SIN_ACK` | circuit breaker 12.9 -> escalate |
  | EN_VUELO | `error` | `PROVIDER_DOWN` | renew lease and wait |
  | EN_VUELO | unverifiable | `UNKNOWN` | check port/server |

- **`cross status [--msg|--run-id|--agent]`:** status summary: outbox by
  state and by agent (with session status), `expired_unmanaged` (EN_VUELO with
  expired lease), idempotency by status, `claimed_orphaned` (CLAIMED_BY from
  idle session), `escalated_pending` (URGENTE without RECIBIDO), `aviso_spof`,
  `dlq_unread`/`by_flag`. With `--msg`, adds `lifecycle` (outbox + idempotency
  + audit_log for that msg_id).
- **`cross reconcile --msg msg_X --check-file PATH [--expected-token T]`:**
  verifies whether a deliverable reached its destination by searching for its token in the
  output file. Verdicts: `CONFIRMED` (token in check-file -> `mark_confirmed`),
  `AMBIGUOUS` (check exists but without token -> `investigate`), `NOT_FOUND`
  (check does not exist -> `retry`). Implements the RECONCILE step from 12.10.
- **`cross aviso-spof [--apply] [--for ses_X]`:** implements the
  SPOF mitigation from 12.13. Scans expired `EN_VUELO` entries: if `dest` is my session and it is
  idle, appends `AVISO-SPOF` to `escalated.md` (only with `--apply`); if it belongs to
  another session, notifies the leader (without `--apply` it is a dry run, does not write or send).
   The leader notice goes to `leader_session_id` from `cross.config.json` (fallback to
   my own session if not defined).

### 12.15 Operational actions (`cross ack/nack/resume/restart-task/nudge/escalate/dlq/quarantine/diagnose`, Phase 4b)
> **NOTE:** Canonical CLI reference: `cross.ps1 --help` (this section summarizes; the help is authoritative).

Implemented in `cross/modules/cross-action.psm1` (2026-08-13). They complement the
READ layer of 12.14 with the actions the leader executes per 7.5 and
12.10/12.11: they DO mutate outbox, escalated, DLQ and audit. Commands:

- **`cross ack --token T --for-msg-id X [--to ses_Y] [--model M]`:** emits
  `ACK:<token>:<SENDER_ID>[:<MODEL>]` (3-4 segments, 7.1) to the destination and
  logs `ACK|ENVIADO` in `audit_log.md`. `--to` defaults to my session.
- **`cross nack --token T --for-msg-id X --reason R [--note] [--for-run-id R]
  [--to] [--model]`:** emits `NACK:<token>:<id>[:model]:<reason>` (4-5 segments,
  7.5) with closed reasons. The enriched format
  (`NACK:...:<msg_id>:<run_id>`, 7 segments) ONLY travels on the wire when
  `--for-run-id` is passed: `msg_id` and `run_id` go together, and the parser distinguishes
  the enriched (6 fields after `NACK:`) from the generic. The audit stores the reason.
- **`cross resume --to ses_X --task-id TX [--from] [--text]`:** implements the
  RESUME from 12.10 (sec 6.1c). Sends `prompt_async` to the same session with
  continuation instruction; does NOT create new `msg_id`, does NOT touch the outbox, does NOT
  increment `attempt` (sec 12.1).
- **`cross restart-task --msg-id X [--to] [--text]`:** implements the RETRY from
  12.10 with the SAME `msg_id` (idempotent): attempt+1 persisted in the outbox,
  status reset to `EN_VUELO`. Errors: `OUTBOX_MSG_NOT_FOUND` /
  `MAX_RETRIES_EXCEEDED` (max `max_retries` from `cross.config.json`).
- **`cross nudge --to ses_X --task "..." [--token]`:** firm prompt that ignores
  `Continue`/prior guidance (antidote to derailment by
  auto-continuation, 6.1c).
- **`cross escalate --msg-id X --to ses_Y --reason "..." [--run-id] [--apply]`:**
  appends the canonical `URGENTE` line to `escalated.md` (12.6). Without `--apply` does NOT
  notify (dry run); with `--apply` sends wake-on-write to the destination.
- **`cross dlq --msg-id X [--to] [--retries] [--flag F] [--summary]`:**
  appends the DLQ line to `dlq-messages.md` (12.7) with closed flags
  `HUMAN_REVIEW|NACK_ORIGINATED|QUARANTINE|PROVIDER_DOWN` and marks the outbox
  `ESTADO=DLQ`.
- **`cross quarantine --msg-id X --reason "..." [--check-log] [--minutes N]`:**
  DLQ with `flag=HUMAN_REVIEW` + outbox `ESTADO=QUARANTINE`. With `--check-log`
  diagnoses via `opencode.log` (see `diagnose`) and appends `log=<classification>`
  to the DLQ summary.
- **`cross diagnose --msg X [--outbox-file] [--minutes N]`:** classifies the
  message destination by reading `opencode.log` (config `log_path`) in a window of N
  minutes (10 by default), filtering by the outbox `dest`. Classifications:
  `PROVIDER_DOWN` (`[504]`/`[524]`/`stream error 504|524`/`connect timeout`/
  `ENOTFOUND`/`Rate limit exceeded`), `AGENT_SLEEPING` (`exiting loop`),
  `CONFIG_ERROR` (other `stream error`), `NO_ERROR`, `NO_DATA`. The window and
  timestamps are compared in UTC (the `Z` in the log is mandatory).

Write rules: all these subcommands are **append-only** on their
files (audit, escalated, DLQ, outbox); they do not rewrite previous lines.

## Appendix A: Future improvements

> **Consensus (Improvement Rounds 2026-08-10):** documented as future work; do NOT
> promise functionality the server does not support yet.
>
> **Prioritized backlog v1.7 (advisor consensus 2026-08-11):**
> | Priority | Risk | Proposal | Note |
> |--|--|--|--|
> | HIGH | LOW | **SQLite (`cross.db`)** | Resolves the `Add-Content` race condition (CROSS_WINDOWS.md #6). External review note: it is an architectural improvement, not an urgent fix (the single-writer rule already eliminates T10 from the protocol). Decide based on actual growth. |
> | HIGH | LOW | **`session.status`/idle/error** | `GET /session/:id` already exists; use it as the primary presence signal and keep growth heuristics as fallback (external review). |
> | MEDIUM | MEDIUM-HIGH | **SSE / long-polling** | Only if the backend supports it; if not, do NOT implement. Test experimentally first: `GET /event`, create activity, observe `session.status`/`message.updated`/`session.idle`/`session.error` (external review). |
> | LOW | LOW | **`@opencode-ai/sdk` SDK** | DX improvement; `curl`+ASCII works now. Verify semantics first. |
> | LOW/MEDIUM | HIGH | **`session.abort`** | Opt-in / soft-abort only first. Blind aborting may leave inconsistent states. |
> | LOW/MEDIUM | MEDIUM-HIGH | **Envelope v2 exclusive (Fase 3, v2.0)** | COMPLETED (v1.17): v1 parser removed, `Parse-CrossEnvelope` is the only parser. v2 (`ENVELOPE-V2: {json}` / pure JSON) is the only accepted format. |

- **Envelope JSON v2 exclusive (Fase 3, v2.0): COMPLETED.** Endgame of improvement #1
  (GLM-5.3 design, "Sobre estructurado JSON"). Since v2.0 the engine accepts
  **only** `ENVELOPE-V2: {json}` / pure JSON — v1 legacy ACK:/NACK: free-text formats are
  **rejected** (see sec 12.1 ENVELOPE-V2 note, v1.9.0). Fase 3
  made v2 the ONLY format: `Parse-CrossEnvelope` (v2-only, legacy
  v1 regexes removed in v1.17) is the sole parser, and the contract becomes
  fully validated (`v=2`, `type` --- {message,ack,nack}, mandatory non-empty
  `msg_id`/`timestamp`, `requires_ack` bool -- invariants already enforced by
  the T-fuzz fuzzer). **Shipped in v2.0.0 as a BREAKING change** (no v1 fallback).
  Dependencies (Fase 2 deprecation v1.10, advisor migration) are satisfied.

- **Long-polling / SSE:** if the OpenCode Desktop API ever supports them,
  replace active polling (section 6) with these mechanisms to reduce
  load and latency. Out of scope for v1.1 (requires backend support).
- **Batch operations:** send/read multiple sessions in a single call.
- **Centralized heartbeat:** revisit `heartbeat.json` only if `GET /session/:id`
  does not cover presence, with a write mechanism using locking.
- **Wrapper with `--aviso-atasco` mode (proposed by model-d, v1.3):** have
  `send_message.ps1` count failed retries and, after 3 failures, automatically
  send `ESTANCADO-Rx:<ID>:<MODEL>` to the leader's session and abort,
  instead of leaving the agent trying commands blindly (see 11.6).
- **Leader election / eliminate SPOF (recommended by external review,
  2026-08-11):** mechanism for another session to assume coordination if the
  leader does not scan the outbox (12.10) or does not respond, e.g. detection of
  outbox with expired `EN_VUELO` and absence of recent leader management.
  Accepted as a trade-off in v1.6 (12.13).