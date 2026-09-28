// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ITaxLotLedger} from "../src/interfaces/ITaxLotLedger.sol";
import {TaxLotLedger} from "../src/TaxLotLedger.sol";
import {TaxLotLedgerMemCopy} from "../src/bench/TaxLotLedgerMemCopy.sol";

/// @dev Differential: the benchmark-only memory-copy ledger must return exactly what the shipped
///      Solidity twin returns — same lot ids, same order, same realized loss — or the fair baseline
///      in bench/RESULTS.md would be comparing different work.
contract MemCopyTest is Test {
    uint256 internal constant USD = 1e6;
    uint256 internal constant SHARE = 1e18;
    uint256 internal constant LOT_QTY = 10 * SHARE;
    uint256 internal constant MARK = 412_300_000;
    uint256 internal constant BENCH_SELL = 81_728_148_108_628_507_367; // scripts/bench.py sell_qty(n>=9)

    address internal who = makeAddr("maya");
    address internal asset = address(0xA55E7);

    TaxLotLedger internal ref;
    TaxLotLedgerMemCopy internal mem;

    function setUp() public {
        ref = new TaxLotLedger(address(this));
        mem = new TaxLotLedgerMemCopy(address(this));
        ref.setMandate(address(this));
        mem.setMandate(address(this));
    }

    function _record(uint256 qty, uint256 basis) internal {
        uint64 a = ref.recordLot(who, asset, qty, basis);
        uint64 b = mem.recordLot(who, asset, qty, basis);
        assertEq(a, b);
    }

    /// bench.py ramp: 10 shares, basis $380 → $455 per share across n lots
    function _seedRamp(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            _record(LOT_QTY, (380 * USD + (455 * USD - 380 * USD) * i / (n - 1)) * 10);
        }
    }

    function _assertSame(uint256 sellQty, uint256 mark) internal view {
        (uint64[] memory a, int256 la) = ref.computeHarvest(who, asset, sellQty, mark);
        (uint64[] memory b, int256 lb) = mem.computeHarvest(who, asset, sellQty, mark);
        assertEq(a.length, b.length, "pick count");
        for (uint256 i = 0; i < a.length; i++) {
            assertEq(a[i], b[i], "lot id");
        }
        assertEq(la, lb, "realized loss");
    }

    function _benchCase(uint256 n) internal {
        _seedRamp(n);
        _assertSame(n >= 9 ? BENCH_SELL : LOT_QTY * n / 2, MARK);
    }

    function test_bench_seed_8_lots_identical_output() public {
        _benchCase(8);
    }

    function test_bench_seed_16_lots_identical_output() public {
        _benchCase(16);
    }

    function test_bench_seed_32_lots_identical_output() public {
        _benchCase(32);
    }

    function test_bench_seed_64_lots_identical_output_minus_3140_dollars() public {
        _benchCase(64);
        (, int256 loss) = mem.computeHarvest(who, asset, BENCH_SELL, MARK);
        assertEq(loss, -3_140_000_000);
    }

    function test_bench_seed_128_lots_identical_output() public {
        _benchCase(128);
    }

    function test_memcopy_reads_storage_once_so_it_is_cheaper_cold_at_64_lots() public {
        _seedRamp(64);
        vm.cool(address(ref));
        uint256 g0 = gasleft();
        ref.computeHarvest(who, asset, BENCH_SELL, MARK);
        uint256 gRef = g0 - gasleft();
        vm.cool(address(mem));
        g0 = gasleft();
        mem.computeHarvest(who, asset, BENCH_SELL, MARK);
        uint256 gMem = g0 - gasleft();
        assertLt(gMem, gRef);
    }

    /// Arbitrary lots (ties included: basis/qty drawn from small ranges), arbitrary sell size.
    function testFuzz_identical_selection_on_random_lots(uint8 nRaw, uint256 seed, uint256 sellRaw)
        public
    {
        uint256 n = bound(nRaw, 1, 40);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            uint256 qty = (uint256(keccak256(abi.encode(seed, i, 1))) % 20 + 1) * SHARE / 2;
            uint256 basis = (uint256(keccak256(abi.encode(seed, i, 2))) % 16 + 1) * 250 * USD;
            _record(qty, basis);
            total += qty;
        }
        _assertSame(bound(sellRaw, 1, total), MARK);
    }

    /// realize() on both, then a second harvest on the partially-drained books must still agree.
    function testFuzz_realize_leaves_identical_books(uint256 seed, uint256 sell1, uint256 sell2)
        public
    {
        uint256 total;
        for (uint256 i = 0; i < 24; i++) {
            uint256 qty = (uint256(keccak256(abi.encode(seed, i, 1))) % 9 + 1) * SHARE;
            _record(qty, (uint256(keccak256(abi.encode(seed, i, 2))) % 90 + 300) * qty / 1e12);
            total += qty;
        }
        sell1 = bound(sell1, 1, total - 1);
        (uint64[] memory ids,) = ref.computeHarvest(who, asset, sell1, MARK);
        assertEq(
            ref.realize(who, asset, sell1, ids, MARK), mem.realize(who, asset, sell1, ids, MARK)
        );

        assertEq(ref.openQty(who, asset), mem.openQty(who, asset));
        assertEq(ref.openLotCount(who, asset), mem.openLotCount(who, asset));
        assertEq(ref.unrealizedLoss(who, asset, MARK), mem.unrealizedLoss(who, asset, MARK));
        _assertSame(bound(sell2, 1, total - sell1), MARK);
    }

    function test_views_match_after_a_partial_realize() public {
        _seedRamp(16);
        uint256 q = LOT_QTY * 3 + LOT_QTY / 3;
        (uint64[] memory ids,) = mem.computeHarvest(who, asset, q, MARK);
        ref.realize(who, asset, q, ids, MARK);
        mem.realize(who, asset, q, ids, MARK);

        (uint64[] memory i1, uint256[] memory q1, uint256[] memory b1, uint256[] memory t1) =
            ref.getOpenLots(who, asset);
        (uint64[] memory i2, uint256[] memory q2, uint256[] memory b2, uint256[] memory t2) =
            mem.getOpenLots(who, asset);
        assertEq(i1.length, 13);
        assertEq(i1.length, i2.length);
        for (uint256 i = 0; i < i1.length; i++) {
            assertEq(i1[i], i2[i]);
            assertEq(q1[i], q2[i]);
            assertEq(b1[i], b2[i]);
            assertEq(t1[i], t2[i]);
        }
        assertEq(ref.lotCount(who, asset), mem.lotCount(who, asset));
        TaxLotLedger.Lot memory a = ref.lotAt(who, asset, ids[3]);
        TaxLotLedgerMemCopy.Lot memory b = mem.lotAt(who, asset, ids[3]);
        assertEq(a.qty, b.qty);
        assertEq(a.costBasis, b.costBasis);
        assertTrue(b.open);
        assertFalse(mem.lotAt(who, asset, ids[0]).open);
    }

    function test_reverts_match_the_shipped_twin() public {
        _seedRamp(8);
        vm.expectRevert(ITaxLotLedger.ZeroQty.selector);
        mem.computeHarvest(who, asset, 0, MARK);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaxLotLedger.InsufficientOpenQty.selector, 81 * SHARE, 80 * SHARE
            )
        );
        mem.computeHarvest(who, asset, 81 * SHARE, MARK);

        uint64[] memory wrong = new uint64[](1);
        vm.expectRevert(ITaxLotLedger.SelectionMismatch.selector);
        mem.realize(who, asset, LOT_QTY, wrong, MARK); // HIFO picks lot 7, not 0
        uint64[] memory two = new uint64[](2);
        vm.expectRevert(ITaxLotLedger.SelectionMismatch.selector);
        mem.realize(who, asset, LOT_QTY, two, MARK);

        vm.expectRevert(ITaxLotLedger.ZeroQty.selector);
        mem.recordLot(who, asset, 0, 1);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ITaxLotLedger.NotMandate.selector);
        mem.recordLot(who, asset, 1, 1);

        vm.expectRevert(TaxLotLedgerMemCopy.MandateAlreadySet.selector);
        mem.setMandate(address(1));
        TaxLotLedgerMemCopy fresh = new TaxLotLedgerMemCopy(address(this));
        vm.expectRevert(TaxLotLedgerMemCopy.ZeroAddress.selector);
        fresh.setMandate(address(0));
    }
}
