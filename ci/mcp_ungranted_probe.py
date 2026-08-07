#!/usr/bin/env python3
"""VAL-MCP-010 — per-tool permission on an ungranted host.

Starts `mtouch mcp`, and over one stdio JSON-RPC session confirms that
initialize / tools/list / the doctor tool all succeed while an AX-dependent
tool (snapshot) returns an isError result naming Accessibility. Meaningful only
on a host WITHOUT the Accessibility grant (e.g. a fresh CI runner).

Exit 0 iff every check passes.
"""
import json
import os
import subprocess
import sys
import time

BIN = os.environ.get("MTOUCH_BIN", ".build/debug/mtouch")


def main() -> int:
    proc = subprocess.Popen(
        [BIN, "mcp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    ok = True

    def send(obj):
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    def read_resp(want_id, timeout=15):
        end = time.time() + timeout
        while time.time() < end:
            line = proc.stdout.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                return "NON_JSON_ON_STDOUT"  # stdout purity violation
            if msg.get("id") == want_id:
                return msg
        return None

    def check(cond, desc):
        nonlocal ok
        print(f"  {'PASS' if cond else 'FAIL'}  {desc}")
        if not cond:
            ok = False

    send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": {"protocolVersion": "2025-11-25", "capabilities": {},
                     "clientInfo": {"name": "ci-ungranted", "version": "0"}}})
    init = read_resp(1)
    check(isinstance(init, dict)
          and init.get("result", {}).get("serverInfo", {}).get("name") == "mtouch",
          "initialize -> serverInfo.name = mtouch")

    send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    tl = read_resp(2)
    tools = [t.get("name") for t in (tl or {}).get("result", {}).get("tools", [])] if isinstance(tl, dict) else []
    check("doctor" in tools and "snapshot" in tools, f"tools/list includes doctor+snapshot ({len(tools)} tools)")

    # doctor tool: a report — succeeds even ungranted (isError falsey)
    send({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
          "params": {"name": "doctor", "arguments": {}}})
    dr = read_resp(3)
    check(isinstance(dr, dict) and not dr.get("result", {}).get("isError", False),
          "doctor tool succeeds (ungranted report, not isError)")

    # snapshot tool: AX-dependent -> isError naming Accessibility
    send({"jsonrpc": "2.0", "id": 4, "method": "tools/call",
          "params": {"name": "snapshot", "arguments": {"app": "com.apple.TextEdit"}}})
    sr = read_resp(4)
    res = sr.get("result", {}) if isinstance(sr, dict) else {}
    text = " ".join(c.get("text", "") for c in res.get("content", []) if isinstance(c, dict))
    check(res.get("isError") is True and "ccessibilit" in text,
          "snapshot tool -> isError naming Accessibility")

    try:
        proc.stdin.close()
        proc.wait(timeout=3)
    except Exception:
        proc.kill()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
