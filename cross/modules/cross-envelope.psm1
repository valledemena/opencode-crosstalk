# cross-envelope.psm1 - Structured envelope format (v2 JSON) with v1 fallback.
# Fase 1 (v1.9): constructores y parser del sobre estructurado JSON v2.
# El sobre v1 ([msg_id=... | ...]) NO se modifica; el v2 viaja como linea
# adicional "ENVELOPE-V2: {json}" en el cuerpo del mensaje y el parser
# acepta ambos (v2 primero, v1 fallback). payload.text es SIEMPRE string;
# si el emisor quiere estructuras complejas, las serializa a JSON string.
Set-StrictMode -Version 2.0

if (-not (Get-Command ConvertTo-AsciiSafe -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\lib\cross-format.psm1') -Force -DisableNameChecking
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
        [string]$Timestamp = ''
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
    return ($env | ConvertTo-Json -Depth 5 -Compress)
}

function New-CrossAckJson {
    param(
        [Parameter(Mandatory=$true)][string]$Token,
        [string]$MsgId = '',
        [string]$Emitter = '',
        [string]$Model = '',
        [string]$Timestamp = ''
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
        [string]$RunId = ''
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
        [string]$Timestamp = ''
    )
    $json = New-CrossEnvelope -MsgId $MsgId -RunId $RunId -Token $Token -RequiresAck $RequiresAck -Lease $Lease -Successor $Successor -SenderSessionId $SenderSessionId -SenderModel $SenderModel -Text $Text -Timestamp $Timestamp
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
    }
}

Export-ModuleMember -Function New-CrossEnvelope, New-CrossAckJson, New-CrossNackJson, Format-CrossEnvelopeV2, Parse-CrossEnvelope