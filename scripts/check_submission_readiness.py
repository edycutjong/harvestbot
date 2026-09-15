#!/usr/bin/env python3
"""Fails (exit 1) if any judged surface still carries a placeholder, a broken cross-reference, or a
claim the receipts do not back. Run before every publish."""
import json, os, re, subprocess, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); os.chdir(root)
fails = []
def fail(m): fails.append(m); print("FAIL", m)
def ok(m): print("ok  ", m)

surfaces = ["README.md", "DEMO.md", "JUDGE.md", "docs/ARCHITECTURE.md", "docs/DX-REPORT.md", "docs/SLITHER.md"]
for f in surfaces:
    if not os.path.exists(f): fail(f"missing {f}"); continue
    t = open(f).read()
    for pat in [r"0x\.\.\.", r"youtu\.be/xxx", r"\bTODO\b", r"\bTBD\b", r"\[insert", r"lorem ipsum", r"OWNER/REPO"]:
        if re.search(pat, t): fail(f"{f}: placeholder /{pat}/")
    for pat in [r"OFFLINE=1", r"MOCK_MODE", r"USE_MOCK", r"--dry-run", r"DEMO_MODE=1"]:
        if re.search(pat, t): fail(f"{f}: kill-switch flag {pat} in a judged surface (R10)")
ok("placeholders / kill-switch flags")

dep = json.load(open("deployments/46630.json")); rec = json.load(open("receipts/46630.json"))
for k in ["beat1", "beat2", "beat3_attempt", "beat3_slash"]:
    if k not in rec or not rec[k].get("tx", "").startswith("0x"): fail(f"receipts: missing {k}")
if rec["beat1"]["status"] != "0x1": fail("beat1 not successful")
if rec["beat2"]["status"] != "0x0": fail("beat2 should be an on-chain revert")
if rec["beat3_attempt"]["status"] != "0x0": fail("beat3 attempt should be an on-chain revert")
if rec["beat3_slash"]["status"] != "0x1" or int(rec["beat3_slash"]["slashed"]) <= 0: fail("beat3 slash not successful")
ok("receipts: three beats present with the right statuses")

readme = open("README.md").read()
for k in ["beat1", "beat2", "beat3_slash"]:
    if rec[k]["tx"] not in readme and rec[k]["tx"][:10] not in readme: fail(f"README does not link {k} tx")
if dep["ledger"].lower() not in readme.lower(): fail("README does not list the Stylus ledger address")
ok("README references the live txs + ledger")

if os.path.exists("bench/results.json"):
    b = json.load(open("bench/results.json"))
    for n, r in b["results"].items():
        if r["solidity"]["lotIds"] != r["stylus"]["lotIds"]: fail(f"bench n={n}: engines disagree")
    if "64" in b["results"]:
        r64 = b["results"]["64"]; ratio = r64.get("ratioL2", r64["ratio"]); ok(f"bench 64 lots: Solidity/Stylus L2 = {ratio}x")
        if str(ratio) not in readme: fail("README killer number does not match bench/results.json (ratioL2)")
        if f"{r64['solidity'].get('gasL2', r64['solidity']['gas']):,}" not in readme: fail("README 64-lot Solidity gas does not match the bench")
else:
    fail("bench/results.json missing")

n_tests = subprocess.run(["grep", "-rhoE", r"function test[A-Za-z0-9_]*\(", "contracts/test"], capture_output=True, text=True).stdout.count("function")
m = re.search(r"(\d+)\s+(Foundry|tests)", readme)
if not m or int(m.group(1)) != n_tests: fail(f"README test count != {n_tests} functions in contracts/test")
else: ok(f"README test count matches: {n_tests}")

for f in [".claude", "CLAUDE.md", "AGENTS.md"]:
    if os.path.exists(f): fail(f"kitchen file in repo: {f}")
if subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout.lower().find("claude") >= 0: fail("tracked file mentions claude")
ok("no kitchen files tracked")

print("\n" + ("READY" if not fails else f"{len(fails)} problem(s)"))
sys.exit(1 if fails else 0)
