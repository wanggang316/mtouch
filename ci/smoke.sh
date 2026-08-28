#!/usr/bin/env bash
# End-to-end smoke of the shipped CLI surface, using only behaviour that needs NO
# TCC grant and no display — so it runs on a bare CI runner and still exercises
# real end-to-end paths (argument parsing, exit-code taxonomy, the MCP stdio
# handshake, and the offline report renderer) rather than re-running unit tests.
#
# Exit codes are measured DIRECTLY. Never through a pipe: a pipeline reports the
# LAST command's status, which silently turns a failure into a pass.
set -uo pipefail

MTOUCH="${MTOUCH_BIN:-.build/debug/mtouch}"
PASS=0
FAIL=0

check() {
  local desc="$1" expected="$2"
  shift 2
  "$@" >/tmp/smoke.out 2>/tmp/smoke.err
  local got=$?
  if [ "$got" = "$expected" ]; then
    printf 'ok    %-52s exit %s\n' "$desc" "$got"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %-52s expected %s, got %s\n' "$desc" "$expected" "$got"
    sed 's/^/        /' /tmp/smoke.err | head -3
    FAIL=$((FAIL + 1))
  fi
}

contains() {
  local desc="$1" needle="$2" file="$3"
  if grep -qF -- "$needle" "$file"; then
    printf 'ok    %-52s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %-52s (missing: %s)\n' "$desc" "$needle"
    FAIL=$((FAIL + 1))
  fi
}

echo "== CLI surface =="
check "--help succeeds" 0 "$MTOUCH" --help
"$MTOUCH" --help >/tmp/help.txt 2>&1
for sub in init doctor apps app windows snapshot read act wait clipboard screenshot record report mcp batch; do
  contains "--help lists '$sub'" "  $sub" /tmp/help.txt
done

echo
echo "== exit-code taxonomy (usage errors precede every permission check) =="
check "unknown subcommand"                64 "$MTOUCH" definitely-not-a-subcommand
check "missing required --app"            64 "$MTOUCH" windows
check "empty --app value"                 64 "$MTOUCH" windows --app ""
check "unknown act verb"                  64 "$MTOUCH" act definitely-not-a-verb
check "--no-verify on a ref verb"         64 "$MTOUCH" act press e1 --app com.apple.finder --no-verify
check "--pid without --app"               64 "$MTOUCH" act click --at 1,1 --pid 1
check "quiet window longer than timeout"  64 "$MTOUCH" wait --app com.apple.finder --stable --stable-for 5s --timeout 1s
check "app that is not installed"          1 "$MTOUCH" app launch --app com.example.definitely.absent

echo
echo "== doctor reports status without failing the run =="
"$MTOUCH" doctor >/tmp/doctor.txt 2>&1; echo "      doctor exit=$?"
contains "doctor names Accessibility" "Accessibility" /tmp/doctor.txt

echo
echo "== MCP stdio handshake (no AX needed to enumerate tools) =="
python3 - "$MTOUCH" <<'PY' >/tmp/mcp.txt 2>&1
import json, subprocess, sys
p = subprocess.Popen([sys.argv[1], "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def send(o): p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush()
send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}})
p.stdout.readline()
send({"jsonrpc":"2.0","method":"notifications/initialized"})
send({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}})
tools = json.loads(p.stdout.readline())["result"]["tools"]
print("TOOLS " + " ".join(sorted(t["name"] for t in tools)))
p.terminate()
PY
cat /tmp/mcp.txt
contains "MCP exposes the pinned tool set" "TOOLS act app apps clipboard doctor read screenshot snapshot wait windows" /tmp/mcp.txt

echo
echo "== report renders a synthetic bundle offline =="
RUN="$(mktemp -d)/run"
mkdir -p "$RUN"
printf '{"schemaVersion":1,"stepCount":1,"mtouchVersion":"smoke","macOSVersion":"smoke","createdAt":{"wallClock":1,"monotonic":1}}\n' > "$RUN/run.json"
printf '{"command":"apps","timestamp":1,"wallClock":1,"args":{},"outcome":{"ok":true,"exit":0,"errorClass":null}}\n' > "$RUN/trajectory.jsonl"
check "report renders" 0 "$MTOUCH" report "$RUN"
if [ -f "$RUN/report.html" ]; then
  contains "report is a document" "<html" "$RUN/report.html"
  if grep -qE 'https?://|<link |@import|srcset=' "$RUN/report.html"; then
    printf 'FAIL  %-52s (report references an external resource)\n' "report is fully offline"; FAIL=$((FAIL + 1))
  else
    printf 'ok    %-52s\n' "report is fully offline"; PASS=$((PASS + 1))
  fi
  A=$(shasum -a 256 "$RUN/report.html" | cut -d' ' -f1)
  "$MTOUCH" report "$RUN" >/dev/null 2>&1
  B=$(shasum -a 256 "$RUN/report.html" | cut -d' ' -f1)
  if [ "$A" = "$B" ]; then
    printf 'ok    %-52s\n' "report re-renders byte-identically"; PASS=$((PASS + 1))
  else
    printf 'FAIL  %-52s\n' "report re-renders byte-identically"; FAIL=$((FAIL + 1))
  fi
fi

echo
echo "──────── smoke: $PASS passed, $FAIL failed ────────"
[ "$FAIL" -eq 0 ]
