# A strict allowlist: never print the input line, request, URL, headers or reason text.
{
    reason = "unclassified"; direction = "unknown"; stage = "other"; severity = "unknown"; connection = ""; code = ""
    if (match($0, /\[(debug|info|notice|warn|error|crit|alert|emerg)\]/)) severity = substr($0, RSTART + 1, RLENGTH - 2)
    if (match($0, /\*[0-9]+ /) && RLENGTH <= 22) connection = substr($0, RSTART + 1, RLENGTH - 2)
    if (match($0, /\([0-9]+:/) && RLENGTH <= 12) code = substr($0, RSTART + 1, RLENGTH - 2)
    if ($0 ~ /upstream timed out/) { reason = "timeout"; direction = "upstream" }
    else if ($0 ~ /client timed out/) { reason = "timeout"; direction = "downstream" }
    else if ($0 ~ /upstream prematurely closed/) { reason = "peer_closed"; direction = "upstream" }
    else if ($0 ~ /client prematurely closed|client closed connection/) { reason = "peer_closed"; direction = "downstream" }
    else if ($0 ~ /\(104:|\(54:/) reason = "connection_reset"
    else if ($0 ~ /\(32:/) reason = "broken_pipe"
    else if ($0 ~ /connect\(\) failed/) { reason = "connect_failed"; direction = "upstream" }
    else if ($0 ~ /invalid|too large|too long/) reason = "invalid_request_or_configuration"
    if ($0 ~ /while proxying upgraded connection/) stage = "upgraded_tunnel"
    else if ($0 ~ /while reading.*upstream/) { stage = "upstream_read"; direction = "upstream" }
    else if ($0 ~ /while sending.*upstream/) { stage = "upstream_write"; direction = "upstream" }
    else if ($0 ~ /while connecting to upstream/) { stage = "upstream_connect"; direction = "upstream" }
    printf "{\"event\":\"codex_gateway_close\",\"severity\":\"%s\",\"connection\":\"%s\",\"reason\":\"%s\",\"direction\":\"%s\",\"stage\":\"%s\",\"system_errno\":\"%s\"}\n", severity, connection, reason, direction, stage, code
    fflush()
}
