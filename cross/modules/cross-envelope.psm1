# cross-envelope.psm1 - Structured envelope format (v2 JSON) with v1 fallback.
# Phase 1 (v1.9): constructores y parser del sobre estructurado JSON v2.
# El sobre v1 ([msg_id=... | ...]) NO se modifica; el v2 viaja como linea
# adicional "ENVELOPE-V2: {json}" en el cuerpo del mensaje y el parser
# acepta ambos (v2 primero, v1 fallback). payload.text es SIEMPRE string;
# si el emisor quiere estructuras complejas, las serializa a JSON string.
Set-StrictMode -Version 2.0

if (-not (Get-Command ConvertTo-AsciiSafe -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\lib\cross-format.psm1') -Force -DisableNameChecking
}

# Phase 2 (2026-10-28): HMAC-SHA256 signature over the canonical envelope text.
# Canonical form: "v2\n{type}\n{msg_id}\n{token}\n{timestamp}\n{payloadText}".
# Secret precedence: param -Secret > env CROSS_HMAC_SECRET > file cross/cross.hmac.secret.
function Get-CrossHmacSecret {
    param([string]$Secret = '', [string]$RepoRoot = '')
    if ($Secret) { return $Secret }
    $envSec = [System.Environment]::GetEnvironmentVariable('CROSS_HMAC_SECRET', 'Process')
    if ($envSec) { return $envSec }
    if (-not $RepoRoot) { $RepoRoot = (Resolve-Path '..' | Split-Path -Parent) }
    $filePath = Join-Path $RepoRoot 'cross/cross.hmac.secret'
    if (Test-Path -LiteralPath $filePath) {
        $txt = [System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8).Trim()
        if ($txt) { return $txt }
    }
    return ''
}
function Get-CrossHmacSignature {
    param(
        [string]$Type,
        [string]$MsgId,
        [string]$Token,
        [string]$Timestamp,
        [string]$PayloadText,
        [string]$Secret = ''
    )
    $sec = Get-CrossHmacSecret -Secret $Secret
    if (-not $sec) { return '' }
    $canonical = "v2`n$Type`n$MsgId`n$Token`n$Timestamp`n$PayloadText"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($sec)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList @(,$keyBytes)
    $hash = $hmac.ComputeHash($bytes)
    $sig = [BitConverter]::ToString($hash) -replace '-', ''
    $sig = $sig.ToLower()
    $hmac.Dispose()
    return $sig
}
function Test-CrossEnvelopeSignature {
    param(
        [Parameter(Mandatory=$true)][object]$Envelope,
        [string]$Secret = ''
    )
    $sigProp = $Envelope.PSObject.Properties['sig']
    if (-not $sigProp -or [string]::IsNullOrEmpty([string]$sigProp.Value)) { return @{ valid = $false; reason = 'missing_sig' } }
    $expected = Get-CrossHmacSignature -Type ([string]$Envelope.PSObject.Properties['type'].Value) -MsgId ([string]$Envelope.PSObject.Properties['msg_id'].Value) -Token ([string]$Envelope.PSObject.Properties['token'].Value) -Timestamp ([string]$Envelope.PSObject.Properties['timestamp'].Value) -PayloadText $(if ($Envelope.PSObject.Properties['payload'] -and $Envelope.PSObject.Properties['payload'].Value) { [string]$Envelope.PSObject.Properties['payload'].Value.PSObject.Properties['text'].Value } else { '' }) -Secret $Secret
    $actual = [string]$sigProp.Value
    $match = ($expected -and ($expected -eq $actual))
    return @{ valid = $match; expected = $expected; actual = $actual; has_sig = $true }
}

function New-CrossEnvelope {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [string]$RunId = '',
        [string]$Token = '',
        [bool]$RequiresAck = $true,
        [string]$Lease = '',
        [string]$Successor = '',
        [string]$SenderSessionId = '',
        [string]$SenderModel = '',
        [string]$Text = '',
        [string]$Timestamp = '',
        [string]$Secret = ''
    )
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $env = [ordered]@{
        v = 2
        type = 'message'
        msg_id = $MsgId
        requires_ack = $RequiresAck
        timestamp = $Timestamp
    }
    if ($RunId) { $env['run_id'] = $RunId }
    if ($Token) { $env['token'] = $Token }
    if ($Lease) { $env['lease'] = $Lease }
    if ($Successor) { $env['successor'] = $Successor }
    if ($SenderSessionId -or $SenderModel) {
        $sender = [ordered]@{}
        if ($SenderSessionId) { $sender['session_id'] = $SenderSessionId }
        if ($SenderModel) { $sender['model'] = $SenderModel }
        $env['sender'] = $sender
    }
    $env['payload'] = [ordered]@{ text = $Text }
    $sig = Get-CrossHmacSignature -Type 'message' -MsgId $MsgId -Token $Token -Timestamp $Timestamp -PayloadText $Text -Secret $Secret
    if ($sig) { $env['sig'] = $sig }
    return ($env | ConvertTo-Json -Depth 5 -Compress)
}

function New-CrossAckJson {
    param(
        [Parameter(Mandatory=$true)][string]$Token,
        [string]$MsgId = '',
        [string]$Emitter = '',
        [string]$Model = '',
        [string]$Timestamp = '',
        [string]$Secret = ''
    )
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $env = [ordered]@{
        v = 2
        type = 'ack'
        token = $Token
        timestamp = $Timestamp
    }
    if ($MsgId) { $env['msg_id'] = $MsgId }
    if ($Emitter) { $env['emitter'] = $Emitter }
    if ($Model) { $env['model'] = $Model }
    $sig = Get-CrossHmacSignature -Type 'ack' -MsgId $MsgId -Token $Token -Timestamp $Timestamp -PayloadText '' -Secret $Secret
    if ($sig) { $env['sig'] = $sig }
    return ($env | ConvertTo-Json -Depth 4 -Compress)
}

function New-CrossNackJson {
    param(
        [Parameter(Mandatory=$true)][string]$Token,
        [string]$MsgId = '',
        [string]$Emitter = '',
        [string]$Model = '',
        [string]$Reason = '',
        [string]$Detail = '',
        [string]$Timestamp = '',
        [string]$RunId = '',
        [string]$Secret = ''
    )
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $env = [ordered]@{
        v = 2
        type = 'nack'
        token = $Token
        timestamp = $Timestamp
    }
    if ($MsgId) { $env['msg_id'] = $MsgId }
    if ($Emitter) { $env['emitter'] = $Emitter }
    if ($Model) { $env['model'] = $Model }
    if ($Reason) { $env['reason'] = $Reason }
    if ($Detail) { $env['detail'] = $Detail }
    if ($RunId) { $env['run_id'] = $RunId }
    $sig = Get-CrossHmacSignature -Type 'nack' -MsgId $MsgId -Token $Token -Timestamp $Timestamp -PayloadText '' -Secret $Secret
    if ($sig) { $env['sig'] = $sig }
    return ($env | ConvertTo-Json -Depth 4 -Compress)
}

function Format-CrossEnvelopeV2 {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [string]$RunId = '',
        [string]$Token = '',
        [bool]$RequiresAck = $true,
        [string]$Lease = '',
        [string]$Successor = '',
        [string]$SenderSessionId = '',
        [string]$SenderModel = '',
        [string]$Text = '',
        [string]$Timestamp = '',
        [string]$Secret = ''
    )
    $json = New-CrossEnvelope -MsgId $MsgId -RunId $RunId -Token $Token -RequiresAck $RequiresAck -Lease $Lease -Successor $Successor -SenderSessionId $SenderSessionId -SenderModel $SenderModel -Text $Text -Timestamp $Timestamp -Secret $Secret
    return ('ENVELOPE-V2: ' + (ConvertTo-AsciiSafe $json))
}

function Parse-CrossEnvelope {
    param([AllowEmptyString()][string]$Text = '')
    $invalid = @{ valid = $false; format = '' }
    if (-not $Text) { return $invalid }
    $candidate = ''
    $idx = $Text.IndexOf('ENVELOPE-V2:')
    if ($idx -ge 0) {
        $rest = $Text.Substring($idx + 12)
        $nl = $rest.IndexOfAny([char[]]"`r`n")
        if ($nl -ge 0) { $rest = $rest.Substring(0, $nl) }
        $open = $rest.IndexOf('{')
        if ($open -ge 0) {
            $candidate = $rest.Substring($open).Trim()
            if (-not $candidate.EndsWith('}')) {
                $lastClose = $candidate.LastIndexOf('}')
                if ($lastClose -gt 0) { $candidate = $candidate.Substring(0, $lastClose + 1) }
            }
        }
    } else {
        $trimmed = $Text.Trim()
        if ($trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) { $candidate = $trimmed }
    }
    if (-not $candidate) { return $invalid }
    $obj = $null
    try {
        $obj = $candidate | ConvertFrom-Json
    } catch {
        $obj = $null
    }
    if ($null -eq $obj) {
        # Varios JSON en la misma linea (p.ej. dos ENVELOPE-V2): gana la
        # primera ocurrencia parseable; se prueban los recortes en cada '}'
        # (un '}' dentro de un string de payload falla y se sigue probando).
        $closeIdx = $candidate.IndexOf('}')
        while ($closeIdx -ge 0) {
            try { $obj = $candidate.Substring(0, $closeIdx + 1) | ConvertFrom-Json } catch { $obj = $null }
            if ($null -ne $obj) { $candidate = $candidate.Substring(0, $closeIdx + 1); break }
            $closeIdx = $candidate.IndexOf('}', $closeIdx + 1)
        }
    }
    if ($null -eq $obj) { return $invalid }
    $vProp = $obj.PSObject.Properties['v']
    $typeProp = $obj.PSObject.Properties['type']
    if (-not $vProp -or -not $typeProp) { return $invalid }
    try { if ([int]$obj.v -ne 2) { return $invalid } } catch { return $invalid }
    $type = [string]$obj.type
    if ($type -notin @('message', 'ack', 'nack')) { return $invalid }
    $midProp = $obj.PSObject.Properties['msg_id']
    if (-not $midProp -or $null -eq $midProp.Value -or [string]$midProp.Value -eq '') { return $invalid }
    $reqAckProp = $obj.PSObject.Properties['requires_ack']
    if ($reqAckProp -and $obj.requires_ack -isnot [bool]) { return $invalid }
    $tsProp = $obj.PSObject.Properties['timestamp']
    if (-not $tsProp -or [string]$obj.timestamp -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}') { return $invalid }
    function Get-Str([object]$o, [string]$k) {
        $p = $o.PSObject.Properties[$k]
        if ($null -ne $p -and $null -ne $p.Value) { return [string]$p.Value }
        return ''
    }
    $payloadText = ''
    $payloadProp = $obj.PSObject.Properties['payload']
    if ($payloadProp -and $null -ne $obj.payload) {
        $pt = $obj.payload.PSObject.Properties['text']
        if ($null -ne $pt -and $null -ne $pt.Value) { $payloadText = [string]$pt.Value }
    }
    return @{
        valid = $true
        format = 'v2-json'
        type = $type
        msg_id = Get-Str $obj 'msg_id'
        run_id = Get-Str $obj 'run_id'
        token = Get-Str $obj 'token'
        requires_ack = $(if ($reqAckProp) { [bool]$obj.requires_ack } else { $true })
        lease = Get-Str $obj 'lease'
        successor = Get-Str $obj 'successor'
        emitter = Get-Str $obj 'emitter'
        model = Get-Str $obj 'model'
        reason = Get-Str $obj 'reason'
        detail = Get-Str $obj 'detail'
        timestamp = Get-Str $obj 'timestamp'
        payload_text = $payloadText
        sig = Get-Str $obj 'sig'
    }
}

Export-ModuleMember -Function New-CrossEnvelope, New-CrossAckJson, New-CrossNackJson, Format-CrossEnvelopeV2, Parse-CrossEnvelope, Get-CrossHmacSecret, Get-CrossHmacSignature, Test-CrossEnvelopeSignature