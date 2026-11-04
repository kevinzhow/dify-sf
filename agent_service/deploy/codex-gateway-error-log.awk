# A strict allowlist: never print the input line, request, URL, headers or reason text.
{
    reason = "unclassified"; direction = "unknown"; stage = "other"; severity = "unknown"; connection = ""; code = ""
    if (match($0, /\[(debug|info|notice|warn|error|crit|alert|emerg)\]/)) severity = substr($0, RSTART + 1, RLENGTH - 2)
    if (match($0, /\*[0-9]+ /) && RLENGTH <= 22) connection = substr($0, RSTART + 1, RLENGTH - 2)
    message = $0
    if (match(message, /: \*[0-9]+ /)) message = substr(message, RSTART + RLENGTH)
    # Match nginx's own message prefix, never client-supplied request/header context.
    if (match(message, /, client:|, server:|, request:/)) message = substr(message, 1, RSTART - 1)
    if (message ~ /^upstream timed out/) { reason = "timeout"; direction = "upstream" }
    else if (message ~ /^client timed out/) { reason = "timeout"; direction = "downstream" }
    else if (message ~ /^upstream prematurely closed/) { reason = "peer_closed"; direction = "upstream" }
    else if (message ~ /^(client prematurely closed|client closed connection)/) { reason = "peer_closed"; direction = "downstream" }
    else if (message ~ /^(recv|send|readv|writev)\(\) failed \((104|54):/) reason = "connection_reset"
    else if (message ~ /^(recv|send|readv|writev)\(\) failed \(32:/) reason = "broken_pipe"
    else if (message ~ /^connect\(\) failed/) { reason = "connect_failed"; direction = "upstream" }
    else if (message ~ /^(client sent|invalid|too large|too long)/) reason = "invalid_request_or_configuration"
    if (reason != "unclassified" && reason != "invalid_request_or_configuration") {
    if (match(message, /\([0-9]+:/) && RLENGTH <= 12) code = substr(message, RSTART + 1, RLENGTH - 2)
    if (message ~ /while proxying upgraded connection/) stage = "upgraded_tunnel"
    else if (message ~ /while reading.*upstream/) { stage = "upstream_read"; direction = "upstream" }
    else if (message ~ /while sending.*upstream/) { stage = "upstream_write"; direction = "upstream" }
    else if (message ~ /while connecting to upstream/) { stage = "upstream_connect"; direction = "upstream" }
    }
    printf "{\"event\":\"codex_gateway_close\",\"severity\":\"%s\",\"connection\":\"%s\",\"reason\":\"%s\",\"direction\":\"%s\",\"stage\":\"%s\",\"system_errno\":\"%s\"}\n", severity, connection, reason, direction, stage, code
    fflush()
}
