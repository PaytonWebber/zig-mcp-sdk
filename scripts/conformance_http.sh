#!/usr/bin/env bash
# MCP Streamable HTTP conformance check.
#
# Starts the greeter_http example and drives it with curl: session lifecycle,
# concurrent sessions with independent version negotiation, tool calls, the
# SSE GET stream (server-initiated notifications), security rejections, and
# DELETE termination.
#
# Usage: scripts/conformance_http.sh [path-to-greeter_http]
# Requires: zig build examples (or pass a binary path), curl.
set -euo pipefail

BIN="${1:-./zig-out/bin/greeter_http}"
PORT=8080
BASE="http://127.0.0.1:$PORT"
JSON=(-H "Content-Type: application/json" -H "Accept: application/json")

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN not found or not executable (run 'zig build examples' first)" >&2
    exit 1
fi

tmpdir="$(mktemp -d)"
"$BIN" &>"$tmpdir/server.log" &
SERVER_PID=$!
cleanup() {
    kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$tmpdir"
}
trap cleanup EXIT

for _ in $(seq 50); do
    curl -s -o /dev/null "$BASE" && break
    sleep 0.1
done

failures=0
expect_eq() {
    local desc="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        echo "ok: $desc"
    else
        echo "FAIL: $desc (want $want, got $got)" >&2
        failures=$((failures + 1))
    fi
}
expect_contains() {
    local desc="$1" pattern="$2" haystack="$3"
    if grep -qF -- "$pattern" <<<"$haystack"; then
        echo "ok: $desc"
    else
        echo "FAIL: $desc (missing: $pattern)" >&2
        failures=$((failures + 1))
    fi
}

init_session() {
    local version="$1" headers_file="$2"
    curl -s -D "$headers_file" "${JSON[@]}" -d \
        '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"'"$version"'","capabilities":{},"clientInfo":{"name":"conformance","version":"1.0"}},"id":1}' \
        "$BASE"
}
session_id() {
    grep -i '^mcp-session-id:' "$1" | tr -d '\r' | awk '{print $2}'
}

# --- Two concurrent sessions, independent version negotiation
RESP_A="$(init_session 2025-06-18 "$tmpdir/h_a.txt")"
SID_A="$(session_id "$tmpdir/h_a.txt")"
RESP_B="$(init_session 2025-03-26 "$tmpdir/h_b.txt")"
SID_B="$(session_id "$tmpdir/h_b.txt")"

expect_contains "session A negotiates its requested version" '"protocolVersion":"2025-06-18"' "$RESP_A"
expect_contains "session B negotiates its requested version" '"protocolVersion":"2025-03-26"' "$RESP_B"
[[ -n "$SID_A" && -n "$SID_B" && "$SID_A" != "$SID_B" ]] \
    && echo "ok: sessions get distinct ids" \
    || { echo "FAIL: sessions get distinct ids" >&2; failures=$((failures + 1)); }

# --- SSE stream opened before initialized; onReady notification arrives on it
timeout 6 curl -s -N -H "Accept: text/event-stream" -H "Mcp-Session-Id: $SID_A" "$BASE" >"$tmpdir/sse.txt" &
SSE_PID=$!
sleep 1

code="$(curl -s -o /dev/null -w '%{http_code}' "${JSON[@]}" -H "Mcp-Session-Id: $SID_A" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$BASE")"
expect_eq "initialized notification gets 202" 202 "$code"

# Second GET while the stream is open conflicts
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Accept: text/event-stream" -H "Mcp-Session-Id: $SID_A" "$BASE")"
expect_eq "second SSE stream gets 409" 409 "$code"

# --- Tool call on the ready session
CALL="$(curl -s "${JSON[@]}" -H "Mcp-Session-Id: $SID_A" \
    -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"greet","arguments":{"name":"HTTP"}},"id":2}' "$BASE")"
expect_contains "tools/call returns the greeting" 'Hello, HTTP! Welcome to the Zig MCP SDK.' "$CALL"

# --- Security rejections
code="$(curl -s -o /dev/null -w '%{http_code}' "${JSON[@]}" -H "Origin: http://evil.example" -H "Mcp-Session-Id: $SID_A" \
    -d '{"jsonrpc":"2.0","method":"ping","id":9}' "$BASE")"
expect_eq "cross-site Origin gets 403" 403 "$code"

code="$(curl -s -o /dev/null -w '%{http_code}' -H "Content-Type: text/plain" -H "Accept: application/json" -H "Mcp-Session-Id: $SID_A" \
    -d '{}' "$BASE")"
expect_eq "wrong Content-Type gets 415" 415 "$code"

code="$(curl -s -o /dev/null -w '%{http_code}' "${JSON[@]}" -H "Mcp-Session-Id: 00000000000000000000000000000000" \
    -d '{"jsonrpc":"2.0","method":"ping","id":9}' "$BASE")"
expect_eq "unknown session gets 404" 404 "$code"

code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$BASE")"
expect_eq "unsupported method gets 405" 405 "$code"

wait "$SSE_PID" 2>/dev/null || true
expect_contains "onReady log message arrives as an SSE event" \
    'data: {"jsonrpc":"2.0","method":"notifications/message"' "$(cat "$tmpdir/sse.txt")"

# --- DELETE terminates the session
code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Mcp-Session-Id: $SID_A" "$BASE")"
expect_eq "DELETE terminates the session" 200 "$code"

code="$(curl -s -o /dev/null -w '%{http_code}' "${JSON[@]}" -H "Mcp-Session-Id: $SID_A" \
    -d '{"jsonrpc":"2.0","method":"ping","id":3}' "$BASE")"
expect_eq "request after DELETE gets 404" 404 "$code"

if [[ "$failures" -gt 0 ]]; then
    echo "$failures HTTP conformance check(s) failed" >&2
    exit 1
fi
echo "all HTTP conformance checks passed"
