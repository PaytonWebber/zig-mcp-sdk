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

# --- initialized with no stream open: the onReady notification is buffered
code="$(curl -s -o /dev/null -w '%{http_code}' "${JSON[@]}" -H "Mcp-Session-Id: $SID_A" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$BASE")"
expect_eq "initialized notification gets 202" 202 "$code"

# --- Opening the stream replays the buffered event with an id
timeout 4 curl -s -N -H "Accept: text/event-stream" -H "Mcp-Session-Id: $SID_A" "$BASE" >"$tmpdir/sse.txt" &
SSE_PID=$!
sleep 1

# --- Plain JSON tool call (no Accept: text/event-stream)
CALL="$(curl -s "${JSON[@]}" -H "Mcp-Session-Id: $SID_A" \
    -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"greet","arguments":{"name":"HTTP"}},"id":2}' "$BASE")"
expect_contains "tools/call returns the greeting" 'Hello, HTTP! Welcome to the Zig MCP SDK.' "$CALL"

# --- Streamed tool call: progress events then the result on the POST stream
STREAMED="$(curl -s -N -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -H "Mcp-Session-Id: $SID_A" \
    -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"multi_greet","arguments":{"name":"Zig","count":3},"_meta":{"progressToken":"pt-1"}},"id":3}' "$BASE")"
progress_count="$(grep -c '"method":"notifications/progress"' <<<"$STREAMED" || true)"
expect_eq "streamed tools/call carries 3 progress events" 3 "$progress_count"
expect_contains "streamed tools/call ends with the result" 'Greeting 3: Hello, Zig!' "$STREAMED"
expect_contains "progress events echo the progress token" '"progressToken":"pt-1"' "$STREAMED"

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
expect_contains "buffered onReady log message is replayed when the stream opens" \
    'data: {"jsonrpc":"2.0","method":"notifications/message"' "$(cat "$tmpdir/sse.txt")"
expect_contains "replayed events carry SSE ids" 'id: 1' "$(cat "$tmpdir/sse.txt")"

# --- Reconnect with Last-Event-ID: takes over the slot (last connection
# wins) and resumes from the given id
RESUMED="$(timeout 3 curl -s -N -H "Accept: text/event-stream" -H "Mcp-Session-Id: $SID_A" -H "Last-Event-ID: 0" "$BASE" || true)"
expect_contains "reconnect with Last-Event-ID replays earlier events" '"method":"notifications/message"' "$RESUMED"
expect_contains "replayed events keep their original ids" 'id: 1' "$RESUMED"

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
