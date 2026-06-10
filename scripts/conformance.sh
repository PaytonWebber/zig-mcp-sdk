#!/usr/bin/env bash
# MCP stdio conformance check.
#
# Drives the greeter example through a full JSON-RPC session over stdio and
# asserts on the wire responses: lifecycle handshake, ping, tools, resources,
# prompts, JSON-RPC error codes, and parse-error recovery.
#
# Usage: scripts/conformance.sh [path-to-greeter]
# Requires: zig build examples (or pass a binary path).
set -euo pipefail

BIN="${1:-./zig-out/bin/greeter}"

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN not found or not executable (run 'zig build examples' first)" >&2
    exit 1
fi

input=$(cat <<'EOF'
{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"conformance","version":"1.0"}},"id":1}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","method":"ping","id":2}
{"jsonrpc":"2.0","method":"tools/list","id":3}
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"greet","arguments":{"name":"Conformance"}},"id":4}
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"multi_greet","arguments":{"name":"Zig","count":2}},"id":5}
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"multi_greet","arguments":{"name":"Zig","count":0}},"id":6}
{"jsonrpc":"2.0","method":"resources/list","id":7}
{"jsonrpc":"2.0","method":"resources/read","params":{"uri":"greeting://instructions"},"id":8}
{"jsonrpc":"2.0","method":"prompts/list","id":9}
{"jsonrpc":"2.0","method":"prompts/get","params":{"name":"greeting_template","arguments":{"name":"Ada"}},"id":10}
{"jsonrpc":"2.0","method":"no/such/method","id":11}
not even json
{"jsonrpc":"2.0","method":"ping","id":12}
EOF
)

output="$(printf '%s\n' "$input" | "$BIN")"

failures=0

# Assert some response line matches an extended regex.
expect() {
    local desc="$1" pattern="$2"
    if grep -qE -- "$pattern" <<<"$output"; then
        echo "ok: $desc"
    else
        echo "FAIL: $desc" >&2
        echo "      missing pattern: $pattern" >&2
        failures=$((failures + 1))
    fi
}

expect "initialize echoes requested protocol version" '"protocolVersion":"2025-03-26"'
expect "initialize returns serverInfo" '"serverInfo".*"name":"greeter"'
expect "ping returns an empty result" '"id":2.*"result":\{\}|"result":\{\}.*"id":2'
expect "tools/list includes the greet tool" '"name":"greet"'
expect "tools/list carries a comptime-generated schema" '"inputSchema":\{"type":"object"'
expect "tools/call greet returns the greeting" 'Hello, Conformance! Welcome to the Zig MCP SDK\.'
expect "tools/call multi_greet honors typed count arg" 'Greeting 2: Hello, Zig!'
expect "tool-level failure is an isError result, not a protocol error" '"id":6.*"isError":true|"isError":true.*"id":6'
expect "resources/list includes the instructions resource" '"uri":"greeting://instructions"'
expect "resources/read returns the resource text" 'Welcome to the Greeter MCP Server!'
expect "prompts/list includes the template prompt" '"name":"greeting_template"'
expect "prompts/get returns messages" '"id":10.*"messages"|"messages".*"id":10'
expect "unknown method gets method_not_found" '"id":11.*-32601|-32601.*"id":11'
expect "invalid JSON gets parse_error with null id" '"id":null.*-32700|-32700.*"id":null'
expect "server recovers after a parse error" '"id":12.*"result"|"result".*"id":12'

# 12 requests carry ids, plus one parse-error response with a null id.
line_count="$(grep -c . <<<"$output")"
if [[ "$line_count" -eq 13 ]]; then
    echo "ok: response count is 13"
else
    echo "FAIL: expected 13 response lines, got $line_count" >&2
    failures=$((failures + 1))
fi

if [[ "$failures" -gt 0 ]]; then
    echo "$failures conformance check(s) failed" >&2
    exit 1
fi
echo "all conformance checks passed"
