#!/usr/bin/env python3
"""HarvestBot benchmark — Stylus vs two Solidity TaxLotLedgers on the SAME chain, SAME inputs.

Engines (deployments/46630-bench.json):
  solidity         — the shipped Solidity twin (re-reads lots[i] from storage on every HIFO pass)
  solidity_memcopy — contracts/src/bench/TaxLotLedgerMemCopy.sol: one storage→memory pass, then
                     every pass over memory — the structure of the Rust ledger. The FAIR baseline.
  stylus           — the production Stylus (Rust → WASM) ledger

For each lot count N in SIZES: seed N lots (qty 10 shares, basis ramp $380→$455) on every ledger
under a distinct (owner, asset) key, then measure `computeHarvest` for the 9-lot HIFO harvest:
  gas      — NodeInterface.gasEstimateComponents (Arbitrum's own total / L1-calldata split)
  latency  — wall-clock of eth_call, N_RUNS samples → p50 / p95
Writes bench/results.json + bench/RESULTS.md. Nothing is simulated: every number is an RPC answer.

env: RPC, PRIVATE_KEY (writer), DEPLOYMENTS (default deployments/46630-bench.json), SIZES, N_RUNS
"""

import json
import os
import subprocess
import sys
import time
import statistics

RPC = os.environ["RPC"]
PK = os.environ["PRIVATE_KEY"]
D = json.load(open(os.environ.get("DEPLOYMENTS", "deployments/46630-bench.json")))
SIZES = [int(x) for x in os.environ.get("SIZES", "8,16,32,64,128").split(",")]
N_RUNS = int(os.environ.get("N_RUNS", "50"))
USD, SHARE, MARK, LOT_QTY = 10**6, 10**18, 412_300_000, 10 * 10**18
WRITER = D["writer"]
LEDGERS = {"solidity": D["solidity"]}
if "solidityMemCopy" in D:
    LEDGERS["solidity_memcopy"] = D["solidityMemCopy"]
LEDGERS["stylus"] = D["stylus"]


def ratios(r):
    """Solidity ÷ Stylus: `ratio*` vs the shipped twin, `ratio*Fair` vs the memory-copy ledger."""
    s, y = r["solidity"], r["stylus"]
    r["ratio"] = round(s["gas"] / y["gas"], 2)
    r["ratioL2"] = round(s["gasL2"] / y["gasL2"], 2)
    if "solidity_memcopy" in r:
        m = r["solidity_memcopy"]
        r["ratioFair"] = round(m["gas"] / y["gas"], 2)
        r["ratioL2Fair"] = round(m["gasL2"] / y["gasL2"], 2)


def cast(*args, timeout=120, retries=5):
    """Public RPCs hiccup; retry empty/failed reads (never retries sends — they carry a nonce)."""
    for attempt in range(retries):
        r = subprocess.run(
            ["cast", *args, "--rpc-url", RPC],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if r.returncode == 0 and r.stdout.strip():
            return r
        # a send with an explicit --nonce is safe to retry on a TRANSPORT error (the node never saw it)
        if (
            args[0] == "send"
            and "error sending request" not in r.stderr
            and "connection" not in r.stderr
        ):
            return r
        time.sleep(1 + attempt)
    return r


def uint(r):
    return int(r.stdout.split()[0])


def basis(i, n):  # total basis for lot i of n on the ramp, 10 shares
    per = 380 * USD + (455 * USD - 380 * USD) * i // (n - 1)
    return per * 10


def asset_for(n):  # synthetic asset key per size — the ledger never touches the token
    return "0x" + f"{0xA55E7 * 10**6 + n:040x}"


def nonce():
    return max(
        uint(cast("nonce", WRITER)), uint(cast("nonce", WRITER, "--block", "pending"))
    )


def book_ok(addr, n):
    """The seeded book must be exactly the ramp, in order — a dropped tx mid-seed shifts every later lot."""
    r = cast(
        "call",
        addr,
        "getOpenLots(address,address)(uint64[],uint256[],uint256[],uint256[])",
        WRITER,
        asset_for(n),
        "--json",
    )
    ids, qty, bas, _ = json.loads(r.stdout)
    return len(ids) == n and all(
        int(qty[i]) == LOT_QTY and int(bas[i]) == basis(i, n) for i in range(n)
    )


def lot_count(addr, a):
    return uint(cast("call", addr, "lotCount(address,address)(uint256)", WRITER, a))


def seed(kind, addr, n):
    """Idempotent and sequential: lot i is sent only once the ledger holds exactly i lots, and each
    recordLot waits for its receipt. The public RPC is load-balanced and its nodes lag or drop
    responses, so a failed send is re-checked against lotCount and retried with the SAME nonce — a
    stale nonce or count must never append a lot twice or out of order."""
    a = asset_for(n)
    i, nn, tries = lot_count(addr, a), None, 0
    while i < n:
        for _ in range(60):  # wait out a lagging node
            if lot_count(addr, a) >= i:
                break
            time.sleep(1)
        have = lot_count(addr, a)
        if have > i:
            i, nn = have, None
            continue
        nn = nonce() if nn is None else nn
        r = cast(
            "send",
            addr,
            "recordLot(address,address,uint256,uint256)",
            WRITER,
            a,
            str(LOT_QTY),
            str(basis(i, n)),
            "--private-key",
            PK,
            "--nonce",
            str(nn),
            timeout=180,
        )
        if r.returncode == 0 and "status               1" in r.stdout:
            i, nn, tries = i + 1, None, 0
            continue
        for _ in range(60):  # the tx may have landed even though the response was lost
            if lot_count(addr, a) > i:
                break
            time.sleep(1)
        if lot_count(addr, a) > i:
            i, nn, tries = i + 1, None, 0
            continue
        if "nonce too low" in r.stderr:
            nn = None  # stale nonce from a lagging node: nothing of ours is pending at it
        tries += 1
        if tries > 10:
            print(kind, n, i, "recordLot failed:", r.stderr[:200])
            sys.exit(1)
    if not book_ok(addr, n):
        print(kind, n, "seeded book is not the ramp in order — use a fresh ledger")
        sys.exit(1)


def sell_qty(
    n,
):  # 9 lots' worth scaled to the spec's 81.728148108628507367 shares at n=64 → keep 8 full + 1 partial
    return 81_728_148_108_628_507_367 if n >= 9 else LOT_QTY * n // 2


NODE_INTERFACE = "0x00000000000000000000000000000000000000C8"  # Arbitrum NodeInterface (virtual precompile)


def components(addr, n):
    """(total, l1, l2) gas for the call — Arbitrum's own split, so the compute ratio excludes the shared calldata cost."""
    a, q = asset_for(n), sell_qty(n)
    data = subprocess.run(
        [
            "cast",
            "calldata",
            "computeHarvest(address,address,uint256,uint256)",
            WRITER,
            a,
            str(q),
            str(MARK),
        ],
        capture_output=True,
        text=True,
    ).stdout.strip()
    r = cast(
        "call",
        NODE_INTERFACE,
        "gasEstimateComponents(address,bool,bytes)(uint64,uint64,uint256,uint256)",
        addr,
        "false",
        data,
        "--from",
        WRITER,
    )
    total, l1 = [int(x.split()[0]) for x in r.stdout.strip().splitlines()[:2]]
    return total, l1, total - l1


def measure(kind, addr, n):
    a, q = asset_for(n), sell_qty(n)
    sig = "computeHarvest(address,address,uint256,uint256)(uint64[],int256)"
    gas, gas_l1, gas_l2 = components(addr, n)
    out = (
        cast("call", addr, sig, WRITER, a, str(q), str(MARK))
        .stdout.strip()
        .splitlines()
    )
    ids, loss = out[0], out[1].split()[0]
    lat = []
    for _ in range(N_RUNS):
        t0 = time.perf_counter()
        cast("call", addr, sig, WRITER, a, str(q), str(MARK))
        lat.append((time.perf_counter() - t0) * 1000)
    lat.sort()
    p50 = statistics.median(lat)
    p95 = lat[int(0.95 * (len(lat) - 1))]
    return {
        "lots": n,
        "gas": gas,
        "gasL1": gas_l1,
        "gasL2": gas_l2,
        "lotIds": ids,
        "realizedLoss": loss,
        "p50_ms": round(p50, 1),
        "p95_ms": round(p95, 1),
        "runs": N_RUNS,
    }


if "--components-only" in sys.argv:
    # refresh the gas split on an existing results.json without re-seeding or re-sampling latency
    results = json.load(open("bench/results.json"))
    for n, r in results["results"].items():
        for kind, addr in LEDGERS.items():
            g, l1, l2 = components(addr, int(n))
            if kind in r:
                r[kind].update({"gas": g, "gasL1": l1, "gasL2": l2})
        ratios(r)
    SIZES = [int(k) for k in results["results"]]
else:
    results = {
        "chainId": D["chainId"],
        "ledgers": LEDGERS,
        "writer": WRITER,
        "sizes": SIZES,
        "runs": N_RUNS,
        "markPrice": MARK,
        "note": "gas = NodeInterface.gasEstimateComponents of computeHarvest (HIFO over all open lots, up to 9 picks); gasL2 = total - L1 calldata; latency = eth_call wall-clock incl. network; ratio* = shipped Solidity / Stylus, ratio*Fair = memory-copy Solidity / Stylus",
        "results": {},
    }
    if os.path.exists("bench/results.json"):
        # keep the provenance of the numbers already published on the video / OG images / X thread
        prev = json.load(open("bench/results.json"))
        if "firstPublished" in prev:
            results["firstPublished"] = prev["firstPublished"]
    for n in SIZES:
        for kind, addr in LEDGERS.items():
            print(f"seed {kind:8s} n={n:3d} ...", end=" ", flush=True)
            seed(kind, addr, n)
            print("ok", end=" | ", flush=True)
            m = measure(kind, addr, n)
            results["results"].setdefault(str(n), {})[kind] = m
            print(
                f"gas={m['gas']:>8,} (L2 {m['gasL2']:,})  p50={m['p50_ms']}ms  p95={m['p95_ms']}ms  loss={m['realizedLoss']}"
            )
        r = results["results"][str(n)]
        outs = {(r[k]["lotIds"], r[k]["realizedLoss"]) for k in LEDGERS}
        assert len(outs) == 1, f"engines disagree at n={n}: {outs}"
        ratios(r)
        os.makedirs("bench", exist_ok=True)
        json.dump(results, open("bench/results.json", "w"), indent=2)  # partial save

os.makedirs("bench", exist_ok=True)
json.dump(results, open("bench/results.json", "w"), indent=2)
FAIR = "solidity_memcopy" in LEDGERS
lines = [
    "# Benchmark — Stylus vs Solidity `computeHarvest` (HIFO, up to 9 picks — 4 at 8 lots)",
    "",
    f"Chain {D['chainId']} (Robinhood Chain testnet) · Solidity (shipped twin) `{LEDGERS['solidity']}`"
    + (f" · Solidity (memory-copy) `{LEDGERS['solidity_memcopy']}`" if FAIR else "")
    + f" · Stylus `{LEDGERS['stylus']}` · mark $412.30 · {N_RUNS} eth_call samples per cell",
    "",
]
if FAIR:
    lines += [
        "**Two baselines, two ratios.** The *shipped twin* (`contracts/src/TaxLotLedger.sol`) re-reads `lots[i]` from storage on every HIFO selection pass; the Rust ledger copies the lots to memory once. The *memory-copy* ledger (`contracts/src/bench/TaxLotLedgerMemCopy.sol`, benchmark only, differential-tested to return identical output) gives Solidity the same structure — so **Solidity (memory-copy) ÷ Stylus is the fair engine-to-engine figure**. Solidity (shipped) ÷ Stylus is what we first published (2.87× at 64 lots); about 41% of that ratio (2.87× → 1.69×) was our Solidity baseline re-reading storage, not the engine.",
        "",
        "| Open lots | Solidity shipped (L2) | Solidity memory-copy (L2) | Stylus (L2) | **Fair: memory-copy ÷ Stylus** | As first published: shipped ÷ Stylus | total incl. L1 (shipped / memcopy / Stylus) | p50 / p95 ms (shipped · memcopy · Stylus) | Identical output (all three) |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for n in SIZES:
        r = results["results"][str(n)]
        s, m, y = r["solidity"], r["solidity_memcopy"], r["stylus"]
        lines.append(
            f"| {n} | {s['gasL2']:,} | {m['gasL2']:,} | {y['gasL2']:,} | **{r['ratioL2Fair']}×** | {r['ratioL2']}× | {s['gas']:,} / {m['gas']:,} / {y['gas']:,} | {s['p50_ms']}/{s['p95_ms']} · {m['p50_ms']}/{m['p95_ms']} · {y['p50_ms']}/{y['p95_ms']} | ✅ lots {s['lotIds']} loss {s['realizedLoss']} |"
        )
else:
    lines += [
        "| Open lots | Solidity gas (L2 compute) | Stylus gas (L2 compute) | **Solidity ÷ Stylus (L2)** | total incl. L1 calldata | Sol p50 / p95 (ms) | Stylus p50 / p95 (ms) | Identical output |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for n in SIZES:
        r = results["results"][str(n)]
        s, y = r["solidity"], r["stylus"]
        lines.append(
            f"| {n} | {s['gasL2']:,} | {y['gasL2']:,} | **{r['ratioL2']}×** | {s['gas']:,} / {y['gas']:,} ({r['ratio']}×) | {s['p50_ms']} / {s['p95_ms']} | {y['p50_ms']} / {y['p95_ms']} | ✅ lots {s['lotIds']} loss {s['realizedLoss']} |"
        )
FP = results.get("firstPublished")
if FP:
    fp64 = FP["results"]["64"]
    lines += [
        "",
        f"**Provenance.** The first published run ({FP['date']}) measured the shipped twin vs Stylus at 64 lots as {fp64['solidity']:,} vs {fp64['stylus']:,} L2 gas ({fp64['ratioL2']}×) — the numbers on the demo video, OG images and X thread. The table above is the re-run in which all three engines were measured together; L2 gas estimates drift by a few dozen gas between runs, the ratios do not.",
    ]
lines += [
    "",
    "Reproduce: `RPC=... PRIVATE_KEY=... python3 scripts/bench.py` (seeds are idempotent — a ledger that already holds N lots under the size key is not re-seeded; ~750 recordLot txs on a fresh set of ledgers; `--components-only` refreshes the gas split without re-seeding).",
    "Gas is Arbitrum's own `NodeInterface.gasEstimateComponents` for the view call: **L2 compute** is what the engines actually differ on; the L1 calldata share (identical calldata, ~14k) is shown in the total. Latency is `eth_call` wall-clock through the public RPC and is network-bound, not engine-bound.",
    "",
    "**Reading the numbers honestly.** The Stylus program is *uncached* on this testnet, so every call pays a WASM initialisation floor — at 8 lots the memory-copy Solidity ledger is cheaper than Stylus. All engines pay the same cold `SLOAD` per lot; Stylus wins only on the comparison loop, so the ratio grows with portfolio size — the shape a tax-lot ledger actually has (Maya's 64 lots become hundreds over years of purchases). Caching the program (`cargo stylus cache bid`) would remove the init floor, but this testnet has no ArbOS cache manager (`ArbWasmCache.allCacheManagers()` returns `[]` on chain 46630), so these are worst-case Stylus numbers.",
]
open("bench/RESULTS.md", "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
