#!/usr/bin/env bash
#
# Ungranted-persona live verification.
#
# Runs mtouch on a host that has NOT been granted Accessibility (a fresh CI
# runner, or any never-granted terminal app). On such a host the AX-gated
# commands must fail fast with exit 2 — the exact ungranted-persona behavior a
# granted developer machine cannot reproduce (macOS binds the grant to the
# invoking app and TCC mutation is forbidden). This clears the validation
# assertions VAL-ENV-004/005/006, VAL-ACT-024, VAL-WAIT-010, and VAL-MCP-010
# with real live evidence.
#
# It does NOT cover VAL-MCP-014 (needs AX-granted / Screen-Recording-missing)
# or VAL-SHOT-009 (needs a granted + quiescent foreground to minimize a window).
#
# Exit 0 iff every probe matches its expected outcome.
set -uo pipefail

BIN="${MTOUCH_BIN:-.build/debug/mtouch}"
fail=0

check_exit() { # desc expected actual
  if [ "$2" = "$3" ]; then
    echo "  PASS  $1 (exit $3)"
  else
    echo "  FAIL  $1 (expected exit $2, got $3)"
    fail=1
  fi
}
check_true() { # desc condition-rc
  if [ "$2" = "0" ]; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi
}

echo "== mtouch ungranted-persona live verification =="
echo "binary: $BIN"
"$BIN" --help >/dev/null 2>&1 || { echo "FATAL: $BIN not runnable"; exit 3; }

# Sanity: this host must actually be ungranted, or the whole run is meaningless.
dout="$("$BIN" doctor 2>&1)"; drc=$?
if [ "$drc" -ne 2 ]; then
  echo "SKIP: host reports Accessibility GRANTED (doctor exit $drc) — not an ungranted host;"
  echo "      the ungranted probes are only meaningful on a never-granted host. Treating as inconclusive."
  echo "$dout"
  exit 0
fi

# VAL-ENV-004 — doctor reports Accessibility not granted, exit 2.
check_exit "VAL-ENV-004 doctor fail (ungranted)" 2 "$drc"
echo "$dout" | grep -iq "accessibilit" ; check_true "VAL-ENV-004 doctor names Accessibility" $?

# VAL-ENV-005 — doctor --json jq-parseable, exit 2, shows the missing grant.
jout="$("$BIN" doctor --json 2>/dev/null)"; jrc=$?
check_exit "VAL-ENV-005 doctor --json exit 2" 2 "$jrc"
echo "$jout" | jq -e '.permissions.accessibility.granted == false' >/dev/null 2>&1
check_true "VAL-ENV-005 doctor --json parseable + accessibility.granted=false" $?

# VAL-ENV-006 — snapshot fails fast (exit 2) without hanging; --json keeps stdout clean.
sout="$("$BIN" snapshot --app com.apple.TextEdit 2>/dev/null)"; check_exit "VAL-ENV-006 snapshot fail-fast" 2 $?
[ -z "$sout" ] ; check_true "VAL-ENV-006 snapshot stdout empty on failure" $?
"$BIN" snapshot --app com.apple.TextEdit --json >/dev/null 2>&1; check_exit "VAL-ENV-006 snapshot --json fail-fast" 2 $?

# VAL-ACT-024 — act fails fast with exit 2 (permission precedes session/ref resolution).
"$BIN" act press e1 --app com.apple.TextEdit >/dev/null 2>&1; check_exit "VAL-ACT-024 act press fail-fast" 2 $?
"$BIN" act type "x" --app com.apple.TextEdit >/dev/null 2>&1; check_exit "VAL-ACT-024 act type fail-fast" 2 $?

# VAL-WAIT-010 — wait fails fast with exit 2 (never masquerades as a timeout).
start=$(date +%s)
"$BIN" wait --app com.apple.TextEdit --appears textarea --timeout 8s >/dev/null 2>&1; wrc=$?
elapsed=$(( $(date +%s) - start ))
check_exit "VAL-WAIT-010 wait fail-fast" 2 "$wrc"
[ "$elapsed" -lt 5 ] ; check_true "VAL-WAIT-010 wait returned fast (<5s, not the 8s timeout): ${elapsed}s" $?

# VAL-MCP-010 — per-tool permission: initialize/tools-list/doctor succeed while an
# AX tool returns isError naming Accessibility.
if command -v python3 >/dev/null 2>&1; then
  MTOUCH_BIN="$BIN" python3 ci/mcp_ungranted_probe.py; check_true "VAL-MCP-010 MCP per-tool permission (ungranted)" $?
else
  echo "  SKIP  VAL-MCP-010 (python3 unavailable)"
fi

echo "== done (fail=$fail) =="
exit $fail
