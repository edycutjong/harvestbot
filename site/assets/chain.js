/* HarvestBot — read the three demo beats straight from Robinhood Chain testnet (46630).
   Plain fetch JSON-RPC, no wallet, no library. Every address and hash below is from
   deployments/46630.json and receipts/46630.json in this repo. If the RPC is unreachable
   the page falls back to those committed receipts and SAYS so. */
(function () {
  "use strict";
  var RPC = "https://rpc.testnet.chain.robinhood.com";
  var EXPLORER = "https://explorer.testnet.chain.robinhood.com";
  var A = {
    owner:  "0x72cd3cB98A5d9B830b386EeBA7B2340132Ba557b",
    agent:  "0xF783e954a1827bD33d210Ed2d21120aC1511457E",
    ledger: "0xEff7B46049fC677F58264e0ebb19dF1a39195a21",
    mandate:"0x15FDF1F8A537ea7e660C9867b3e5e66B0996a6E2",
    router: "0x2a121714bEA2B69154521aEba9C5039C500c19aE",
    guard:  "0x1A98594aA8dC627b34b586756833bbe508B0A29C",
    subMap: "0x1e8Df64A7B17490dcDd4E03E695Cb1E766A37CfE",
    bond:   "0x822fAC45a881801955b3130076A58790bBb40736",
    oracle: "0xBaDD49e6f6665Bdc90AE21EC2AAA22fD8cf52598",
    swap:   "0xFd7f7A2beE5F1DC47A59691bF023948567969E6a",
    usdc:   "0x0E8A996DBD141352fA10940ae8045C323dC03f89",
    AMZN:   "0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02",
    NFLX:   "0x3b8262A63d25f0477c4DDE23F83cfe22Cb768C93",
    PLTR:   "0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0"
  };
  var TX = {
    beat1:  "0x689c4d345c492c08ef06aed9341de941cb131835cce52886d700207925f26123",
    beat2:  "0xd486468ea84c6d419b28401386ce832483f809f96a35ea94e9c4a92037fecf10",
    beat3a: "0x7dca068071e91ca95b992d62eb3096ec465b8bae8fd939f1baf426902d990bf6",
    beat3s: "0xcceb12a766ef6c8f4e861f9c7ac6f30cb495044f5032cec3fec4127c87066493"
  };
  var TOPIC = {
    LotsRealized: "0xc0c2a4f66f0394cd998efa4ab6c34fca5259e4e5fb6e824abd6b1a269f848ed4",
    Slashed:      "0xe455707f854823f99133287adb9a386697b6d32b7a612fb6bb5894acf54bebda"
  };
  var SEL = {
    bondOf: "0x72d2b6c0", windowEndsAt: "0x9675a141", assertBuyAllowed: "0xf05e3f9e",
    isSubstitute: "0x287759d2", computeHarvest: "0x25d8385a", openLotCount: "0xf2e78fe3",
    WashSaleViolation: "0x581b60e1"
  };
  /* receipts/46630.json, committed 2026-09-15 — the fallback, labeled as such wherever it is shown */
  var COMMITTED = {
    beat1:  { status: 1, block: 119852570, gas: 1096548, lotIds: [63,62,61,60,59,58,57,56,55], sellQty: "638501157098660213", realizedLoss: "-24531251" },
    beat2:  { status: 0, block: 119852786, gas: 133328, windowEnd: 1792060681 },
    beat3a: { status: 0, block: 119852971 },
    beat3s: { status: 1, block: 119853005, gas: 170719, S: "200000000", bounty: "20000000", restitution: "180000000", bondBefore: "1000000000", bondAfter: "800000000" }
  };

  function pad(x) { return String(x).replace(/^0x/, "").toLowerCase().padStart(64, "0"); }
  function word(hex, i) { return hex.slice(2 + i * 64, 2 + (i + 1) * 64); }
  function big(h) { return BigInt("0x" + (h || "0")); }
  function signed(h) { var v = big(h); return v >= (1n << 255n) ? v - (1n << 256n) : v; }
  function units(v, dec, places) {
    v = BigInt(v); var neg = v < 0n; if (neg) v = -v;
    var base = 10n ** BigInt(dec), whole = v / base, frac = (v % base).toString().padStart(dec, "0").slice(0, places);
    var w = whole.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    return (neg ? "-" : "") + w + (places ? "." + frac : "");
  }
  function short(h, a, b) { return h.slice(0, a || 10) + "…" + h.slice(-(b || 4)); }
  function txUrl(h) { return EXPLORER + "/tx/" + h; }
  function addrUrl(h) { return EXPLORER + "/address/" + h; }

  function rpc(batch, ms) {
    var ctl = typeof AbortController !== "undefined" ? new AbortController() : null;
    var t = setTimeout(function () { if (ctl) ctl.abort(); }, ms || 9000);
    return fetch(RPC, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify(batch.map(function (c, i) { return { jsonrpc: "2.0", id: i + 1, method: c[0], params: c[1] }; })),
      signal: ctl ? ctl.signal : undefined
    }).then(function (r) {
      clearTimeout(t); if (!r.ok) throw new Error("RPC HTTP " + r.status); return r.json();
    }).then(function (arr) {
      var out = []; (Array.isArray(arr) ? arr : [arr]).forEach(function (x) { out[x.id - 1] = x; }); return out;
    });
  }
  function call(to, data) { return ["eth_call", [{ to: to, data: data }, "latest"]]; }

  function decodeLots(data) {
    var off = Number(big(word(data, 0))) / 32, n = Number(big(word(data, off)));
    var ids = []; for (var i = 0; i < n; i++) ids.push(Number(big(word(data, off + 1 + i))));
    return { lotIds: ids, sellQty: big(word(data, 1)).toString(), realizedLoss: signed(word(data, 2)).toString() };
  }

  /* One batched round trip: head block, 4 receipts, and 7 live view calls. */
  function readAll() {
    var sellQty = 638501157098660213n, mark = 412300000n;
    var batch = [
      ["eth_blockNumber", []],
      ["eth_getTransactionReceipt", [TX.beat1]],
      ["eth_getTransactionReceipt", [TX.beat2]],
      ["eth_getTransactionReceipt", [TX.beat3a]],
      ["eth_getTransactionReceipt", [TX.beat3s]],
      call(A.bond, SEL.bondOf + pad(A.agent)),
      call(A.guard, SEL.windowEndsAt + pad(A.owner) + pad(A.AMZN)),
      call(A.guard, SEL.assertBuyAllowed + pad(A.owner) + pad(A.AMZN)),
      call(A.subMap, SEL.isSubstitute + pad(A.AMZN) + pad(A.PLTR)),
      call(A.subMap, SEL.isSubstitute + pad(A.AMZN) + pad(A.NFLX)),
      ["eth_getCode", [A.ledger, "latest"]],
      call(A.ledger, SEL.computeHarvest + pad(A.owner) + pad(A.AMZN) + pad(sellQty.toString(16)) + pad(mark.toString(16))),
      call(A.ledger, SEL.openLotCount + pad(A.owner) + pad(A.AMZN)),
      ["eth_chainId", []]
    ];
    return rpc(batch).then(function (r) {
      var ok = function (i) { return r[i] && !r[i].error && r[i].result != null; };
      if (!ok(0) || !ok(1)) throw new Error("RPC returned no head/receipt");
      var rec = function (i) {
        var x = r[i].result; if (!x) return null;
        return { status: Number(big(x.status.slice(2))), block: Number(big(x.blockNumber.slice(2))), gas: Number(big(x.gasUsed.slice(2))), from: x.from, to: x.to, logs: x.logs || [] };
      };
      var out = { live: true, head: Number(big(r[0].result.slice(2))), chainId: ok(13) ? Number(big(r[13].result.slice(2))) : null, at: new Date() };
      out.beat1 = rec(1); out.beat2 = rec(2); out.beat3a = rec(3); out.beat3s = rec(4);
      if (out.beat1) {
        var l = out.beat1.logs.filter(function (g) { return g.topics[0] === TOPIC.LotsRealized; })[0];
        if (l) { var d = decodeLots(l.data); out.beat1.lotIds = d.lotIds; out.beat1.sellQty = d.sellQty; out.beat1.realizedLoss = d.realizedLoss; out.beat1.logAddress = l.address; }
      }
      if (out.beat3s) {
        var s = out.beat3s.logs.filter(function (g) { return g.topics[0] === TOPIC.Slashed; })[0];
        if (s) { out.beat3s.S = big(word(s.data, 0)).toString(); out.beat3s.bounty = big(word(s.data, 1)).toString(); out.beat3s.restitution = big(word(s.data, 2)).toString(); }
      }
      out.bondNow = ok(5) ? big(r[5].result.slice(2)).toString() : null;
      out.windowEnd = ok(6) ? Number(big(r[6].result.slice(2))) : null;
      var ab = r[7];
      if (ab && ab.error && ab.error.data && String(ab.error.data).indexOf(SEL.WashSaleViolation) === 0) {
        out.rebuyNow = { reverts: true, error: "WashSaleViolation", windowEnd: Number(big(word("0x" + String(ab.error.data).slice(10), 3))) };
      } else if (ab && !ab.error) { out.rebuyNow = { reverts: false }; }
      out.pltrOnMap = ok(8) ? big(r[8].result.slice(2)) === 1n : null;
      out.nflxOnMap = ok(9) ? big(r[9].result.slice(2)) === 1n : null;
      out.ledgerCodePrefix = ok(10) ? r[10].result.slice(0, 10) : null;
      out.ledgerCodeBytes = ok(10) ? (r[10].result.length - 2) / 2 : null;
      if (ok(11)) { var nx = decodeLotsRet(r[11].result); out.nextHarvest = nx; }
      out.openLots = ok(12) ? Number(big(r[12].result.slice(2))) : null;
      return out;
    });
  }
  /* computeHarvest returns (uint64[] lotIds, int256 realizedLoss) */
  function decodeLotsRet(hex) {
    var off = Number(big(word(hex, 0))) / 32, n = Number(big(word(hex, off)));
    var ids = []; for (var i = 0; i < n; i++) ids.push(Number(big(word(hex, off + 1 + i))));
    return { lotIds: ids, realizedLoss: signed(word(hex, 1)).toString() };
  }
  function fallback(err) {
    return { live: false, error: String(err && err.message || err), head: null, at: new Date(),
      beat1: COMMITTED.beat1, beat2: COMMITTED.beat2, beat3a: COMMITTED.beat3a, beat3s: COMMITTED.beat3s,
      bondNow: COMMITTED.beat3s.bondAfter, windowEnd: COMMITTED.beat2.windowEnd };
  }
  function read() { return readAll().catch(fallback); }

  window.HB = { RPC: RPC, EXPLORER: EXPLORER, A: A, TX: TX, COMMITTED: COMMITTED, read: read,
    units: units, short: short, txUrl: txUrl, addrUrl: addrUrl };
})();
