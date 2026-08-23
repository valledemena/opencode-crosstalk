# OpenCode Cross-Talk

[![tests](https://github.com/davidlopezsalvador/opencode-crosstalk/actions/workflows/test.yml/badge.svg)](https://github.com/davidlopezsalvador/opencode-crosstalk/actions/workflows/test.yml)

[User Guide for Non-Coders](USER_GUIDE.md) | [Protocol spec](CROSS_TALK.md) | [Changelog](CHANGELOG.md) | [Windows pitfalls](CROSS_WINDOWS.md)
> **Are you an LLM agent?** Read [`AGENTS.md`](AGENTS.md) - it bootstraps you into
> the protocol in ~3 minutes (identify yourself -> connect -> send/receive tasks,
> with ACK and signing conventions). Curated doc index: [`llms.txt`](llms.txt).


## What it does

OpenCode Desktop runs a local HTTP server (`http://127.0.0.1:PORT`) that exposes each chat session. CROSS-TALK builds on top of that to enable:

- **Inter-session messaging** â€” send messages between any two sessions in the same project
- **Durable outbox** â€” messages survive crashes; tracked in `outbox.md`
- **ACK/NACK handshakes** â€” sender knows if the recipient processed the message
- **Idempotent delivery** â€” at-least-once with deduplication via `idempotencia-procesados.md`
- **Automatic retries** â€” configurable backoff, lease renewal, and circuit breakers
- **Diagnostics** â€” classify failures (provider down, agent sleeping, config error) from OpenCode logs
- **Dead letter queue** â€” messages that can't be delivered after max retries go to DLQ for human review
- **AVISO-SPOF** â€” passive detection if the leader session goes silent

## Quick start

### Prerequisites

- PowerShell 5.1+ (Windows) or PowerShell 7+ (Windows / Linux / macOS / WSL)
- [OpenCode Desktop](https://opencode.ai) running with at least 2 open sessions
- `curl` (built into Windows 10+; standard on Unix)

> **Platform support:** Windows is the primary, fully-tested platform. Linux /
> macOS / WSL work through the cross-platform layer in `cross-ipc.psm1`
> (named mutex on Windows; advisory file lock on Unix â€” exclusive in
> practice, not a POSIX `flock()`). The test suite runs server-independent
> suites on CI (`windows-latest`); Unix is supported but less battle-tested.

### Setup

1. Clone this repo
2. Run the setup helper (detects your session and writes a git-ignored `cross/cross.config.local.json`):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

3. Or configure manually â€” edit `cross/cross.config.json` (or copy it to `cross/cross.config.local.json` so your identity never gets committed):

```json
{
    "my_session_id": "ses_YOUR_SESSION_ID",
    "leader_session_id": "ses_LEADER_SESSION_ID",
    "my_model": "your-model-name",
    "my_role": "advisor"
}
```

4. Run the CLI:

```powershell
cd cross
.\cross.ps1 health          # verify server is reachable
.\cross.ps1 sessions         # list active sessions
.\cross.ps1 send --msg test --dest ses_DEST --text "Hello from CROSS-TALK"
```

### Usage

```
cross health                    # verify server connection
cross whoami                    # show current session info
cross sessions                  # list all sessions in the project
cross read --session ses_X      # read messages from a session
cross config --list             # show current configuration

cross send --msg MSG_ID --dest ses_Y --text "..."   # send a message
cross ack --token T --for-msg-id X                   # acknowledge receipt
cross nack --token T --for-msg-id X --reason REASON   # reject with reason

cross status                    # overview of outbox + idempotency + DLQ
cross scan                      # check for expired leases
cross diagnose --msg MSG_ID     # classify why a message failed
cross metrics                   # delivery statistics
```

See `cross.ps1 --help` for the full list of 20+ subcommands.

## Example: 3-session handshake in under a minute

With 3 sessions open (A = you, B = advisor, C = advisor):

```powershell
# 1. Verify connectivity
.\cross.ps1 health                       # ok: true

# 2. Send a task to session B (writes outbox, wakes B via prompt_async)
.\cross.ps1 send --msg t1 --dest ses_B --text "Analyze the poll results and reply"
# -> outbox.md: [ts] OUTBOX | t1 | dest=ses_B | ESTADO=EN_VUELO

# 3. B replies with its ACK/NACK handshake (see CROSS_TALK.md 7.1/7.5)
#    Sender polls and classifies the outcome:
.\cross.ps1 status
# -> t1 CONFIRMADO (ACK:T1:ses_B:model received)

# 4. B fails to answer in time -> diagnose why, then retry or escalate
.\cross.ps1 diagnose --msg t1             # provider down / agent sleeping / config error
.\cross.ps1 scan                          # expired leases
```

That is the whole loop: outbox -> prompt_async -> ACK/NACK -> retry or DLQ. The
anti-sleep protocol (`ESTADO:` heartbeats, AVISO-SPOF) keeps long-running
teams alive â€” see [CROSS_TALK.md](CROSS_TALK.md) sections 4 and 12.

## Project structure

```
cross-talk/
â”œâ”€â”€ CROSS_TALK.md              # Protocol specification (v1.8.3)
â”œâ”€â”€ CHANGELOG.md               # Version history and discoveries
â”œâ”€â”€ CROSS_WINDOWS.md           # PowerShell 5.1 / Windows pitfalls
â”œâ”€â”€ install.ps1                # One-command setup (detects session, writes local config)
â”œâ”€â”€ LICENSE                    # MIT
â”œâ”€â”€ README.md                  # This file
â””â”€â”€ cross/
    â”œâ”€â”€ cross.ps1              # CLI entry point (20+ subcommands)
    â”œâ”€â”€ cross.config.json      # Publish template (empty identity)
    â”œâ”€â”€ cross.config.local.json# Your identity (git-ignored, created by install.ps1)
    â”œâ”€â”€ lib/
    â”‚   â””â”€â”€ cross-format.psm1  # Formatting utilities
    â”œâ”€â”€ modules/
    â”‚   â”œâ”€â”€ cross-transport.psm1   # HTTP transport, port detection, netrc, config
    â”‚   â”œâ”€â”€ cross-state.psm1       # Outbox, idempotency (checksums v1.7), mutex
    â”‚   â”œâ”€â”€ cross-delivery.psm1    # ACK/NACK parsing, retries, leases
    â”‚   â”œâ”€â”€ cross-envelope.psm1    # JSON envelope v2 + v1 fallback
    â”‚   â”œâ”€â”€ cross-diagnostic.psm1  # Status, metrics, doctor, Prometheus export
    â”‚   â””â”€â”€ cross-action.psm1      # ack, nack, resume, restart, etc.
    â””â”€â”€ tests/                 # 33 test suites (7000+ assertions)
        â”œâ”€â”€ T-ack.ps1
        â”œâ”€â”€ T-nack.ps1
        â”œâ”€â”€ T-send.ps1
        â”œâ”€â”€ T-fuzz.ps1
        â””â”€â”€ ... (33 files)
```

## How it works

1. **Autodetect credentials** â€” port and password are read from OpenCode logs before every send (they change on restart)
2. **Write to outbox** â€” message is recorded in `outbox.md` with state `EN_VUELO`
3. **Send via HTTP** â€” `prompt_async` wakes the target agent
4. **Wait for ACK** â€” sender polls for acknowledgment (configurable timeout)
5. **Classify result** â€” ACK â†’ `CONFIRMADO`, NACK â†’ reason logged, timeout â†’ diagnostic from logs
6. **Retry or DLQ** â€” on failure, retry with backoff; after max retries, move to dead letter queue

The full protocol rules are in [CROSS_TALK.md](CROSS_TALK.md) (section 4 for messaging, section 12 for the anti-sleep protocol).

## Arquitectura (v2.1.0)

```mermaid
graph TB
    subgraph "Leader Session"
        A[cross.ps1 CLI] --> B[cross-transport.psm1]
        B --> C{Resolve-CrossEndpoint}
        C -->|cache| D[Port Cache]
        C -->|well-known| E[server.port]
        C -->|log| F[OpenCode Logs]
        C -->|scan| G[TCP Scan]
    end
    subgraph "State Layer"
        H[cross-state.psm1] --> I[outbox.md]
        H --> J[idempotencia-procesados.md v1.7]
        H --> K[Mutex/IPC]
    end
    subgraph "Delivery Layer"
        L[cross-delivery.psm1] --> M[cross-envelope.psm1]
        M --> N[JSON Envelope v2 + fallback v1]
        L --> O[ACK/NACK Parser]
    end
    subgraph "Diagnostic Layer"
        P[cross-diagnostic.psm1] --> Q[cross doctor - 6 checks]
        P --> R[cross metrics / Prometheus export]
    end
    subgraph "OpenCode Desktop Server"
        S[HTTP API :PORT] --> T[/session/:id/message]
        S --> U[prompt_async]
        S --> V[/global/health]
    end
    subgraph "Advisor Sessions"
        W[Session B]
        X[Session C]
    end
    A --> H
    A --> L
    A --> P
    B --> S
```

## Running tests

```powershell
cd cross\tests
# Run all tests
Get-ChildItem T-*.ps1 | ForEach-Object { powershell -NoProfile -ExecutionPolicy Bypass -File $_.FullName }

# Run a specific test
powershell -NoProfile -ExecutionPolicy Bypass -File T-send.ps1
```

## License

[MIT](LICENSE)
