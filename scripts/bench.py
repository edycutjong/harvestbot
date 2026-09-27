#!/usr/bin/env python3
"""HarvestBot benchmark — Stylus vs Solidity TaxLotLedger on the SAME chain, SAME inputs.

For each lot count N in SIZES: seed N lots (qty 10 shares, basis ramp $380→$455) on both ledgers
under a distinct (owner, asset) key, then measure `computeHarvest` for the 9-lot HIFO harvest:
  gas      — eth_estimateGas (deterministic; what a tx would consume for this view's compute)
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
LEDGERS = {"solidity": D["solidity"], "stylus": D["stylus"]}


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
    return uint(cast("nonce", WRITER))


def seed(kind, addr, n):
    a = asset_for(n)
    have = uint(cast("call", addr, "lotCount(address,address)(uint256)", WRITER, a))
    if have >= n:
        return
    nn = nonce()
    for i in range(have, n):
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
            "--async",
        )
        if r.returncode != 0:
            print(kind, n, "recordLot failed:", r.stderr[:200])
            sys.exit(1)
        nn += 1
    # wait for the last one
    for _ in range(120):
        if (
            uint(cast("call", addr, "lotCount(address,address)(uint256)", WRITER, a))
            >= n
        ):
            return
        time.sleep(1)
    print("seed timeout")
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
            r[kind].update({"gas": g, "gasL1": l1, "gasL2": l2})
        r["ratio"] = round(r["solidity"]["gas"] / r["stylus"]["gas"], 2)
        r["ratioL2"] = round(r["solidity"]["gasL2"] / r["stylus"]["gasL2"], 2)
    SIZES = [int(k) for k in results["results"]]
else:
    results = {
        "chainId": D["chainId"],
        "ledgers": LEDGERS,
        "writer": WRITER,
        "sizes": SIZES,
        "runs": N_RUNS,
        "markPrice": MARK,
        "note": "gas = eth_estimateGas of computeHarvest (HIFO over all open lots, 9 picks); latency = eth_call wall-clock incl. network",
        "results": {},
    }
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
        s, y = (
            results["results"][str(n)]["solidity"],
            results["results"][str(n)]["stylus"],
        )
        assert s["lotIds"] == y["lotIds"] and s["realizedLoss"] == y["realizedLoss"], (
            "engines disagree!"
        )
        results["results"][str(n)]["ratio"] = round(s["gas"] / y["gas"], 2)
        results["results"][str(n)]["ratioL2"] = round(s["gasL2"] / y["gasL2"], 2)
        os.makedirs("bench", exist_ok=True)
        json.dump(results, open("bench/results.json", "w"), indent=2)  # partial save

os.makedirs("bench", exist_ok=True)
json.dump(results, open("bench/results.json", "w"), indent=2)
lines = [
    "# Benchmark — Stylus vs Solidity `computeHarvest` (HIFO, up to 9 picks — 4 at 8 lots)",
    "",
    f"Chain {D['chainId']} (Robinhood Chain testnet) · Solidity `{LEDGERS['solidity']}` · Stylus `{LEDGERS['stylus']}` · mark $412.30 · {N_RUNS} eth_call samples per cell",
    "",
    "| Open lots | Solidity gas (L2 compute) | Stylus gas (L2 compute) | **Solidity ÷ Stylus (L2)** | total incl. L1 calldata | Sol p50 / p95 (ms) | Stylus p50 / p95 (ms) | Identical output |",
    "|---|---|---|---|---|---|---|---|",
]
for n in SIZES:
    r = results["results"][str(n)]
    s, y = r["solidity"], r["stylus"]
    lines.append(
        f"| {n} | {s['gasL2']:,} | {y['gasL2']:,} | **{r['ratioL2']}×** | {s['gas']:,} / {y['gas']:,} ({r['ratio']}×) | {s['p50_ms']} / {s['p95_ms']} | {y['p50_ms']} / {y['p95_ms']} | ✅ lots {s['lotIds']} loss {s['realizedLoss']} |"
    )
lines += [
    "",
    "Reproduce: `RPC=... PRIVATE_KEY=... python3 scripts/bench.py` (seeds are idempotent; ~500 recordLot txs on first run; `--components-only` refreshes the gas split without re-seeding).",
    "Gas is Arbitrum's own `NodeInterface.gasEstimateComponents` for the view call: **L2 compute** is what the two engines actually differ on; the L1 calldata share (identical calldata, ~14k) is shown in the total. Latency is `eth_call` wall-clock through the public RPC and is network-bound, not engine-bound.",
    "",
    "**Reading the numbers honestly.** The Stylus program is *uncached* on this testnet, so every call pays a WASM initialisation floor (visible at 8 lots, where the two are near parity). Both engines pay the same cold `SLOAD` per lot; Stylus wins only on the comparison loop, so the ratio grows with portfolio size — the shape a tax-lot ledger actually has (Maya's 64 lots become hundreds over years of purchases). Caching the program (`cargo stylus cache bid`) would remove the init floor, but this testnet has no ArbOS cache manager (`ArbWasmCache.allCacheManagers()` returns `[]` on chain 46630), so these are worst-case Stylus numbers.",
]
open("bench/RESULTS.md", "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
