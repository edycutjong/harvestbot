// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {ITaxLotLedger} from "../src/interfaces/ITaxLotLedger.sol";
import {TaxLotLedger} from "../src/TaxLotLedger.sol";

/// @dev HIFO specific-lot identification — the engine the whole product rests on.
contract HifoTest is BaseTest {
    uint256 internal constant SELL_QTY = 81_728_148_108_628_507_367; // 81.728148… shares → −$3,140.00 exactly

    function setUp() public override {
        super.setUp();
        seedPortfolio();
    }

    function test_seed_records_64_open_lots_of_10_shares() public view {
        assertEq(ledger.openLotCount(owner, address(AMZN)), 64);
        assertEq(ledger.openQty(owner, address(AMZN)), 640 * SHARE);
        (uint64[] memory ids,,,) = ledger.getOpenLots(owner, address(AMZN));
        assertEq(ids.length, 64);
    }

    function test_hifo_selects_the_nine_highest_basis_lots_in_descending_order() public view {
        (uint64[] memory ids,) = ledger.computeHarvest(owner, address(AMZN), SELL_QTY, MARK);
        assertEq(ids.length, 9);
        for (uint256 i = 0; i < 9; i++) {
            assertEq(ids[i], uint64(63 - i));
        }
    }

    function test_seed_scenario_realizes_exactly_minus_3140_dollars() public view {
        (, int256 loss) = ledger.computeHarvest(owner, address(AMZN), SELL_QTY, MARK);
        assertEq(loss, -3_140_000_000);
    }

    function test_hifo_beats_fifo_on_the_same_quantity() public view {
        // FIFO would sell lots 0..8 (lowest basis, all IN the money at $412.30) — a GAIN, not a loss.
        int256 fifo;
        for (uint256 i = 0; i < 8; i++) {
            fifo += int256(LOT_QTY * MARK / SHARE) - int256(basisFor(i));
        }
        (, int256 hifo) = ledger.computeHarvest(owner, address(AMZN), SELL_QTY, MARK);
        assertGt(fifo, 0);
        assertLt(hifo, fifo);
    }

    function test_partial_lot_is_prorated_not_rounded_to_whole_lots() public {
        // sell 1.5 lots: lot 63 in full + half of lot 62
        uint256 q = LOT_QTY + LOT_QTY / 2;
        (uint64[] memory ids, int256 loss) = ledger.computeHarvest(owner, address(AMZN), q, MARK);
        assertEq(ids.length, 2);
        int256 expected = int256(LOT_QTY * MARK / SHARE) - int256(basisFor(63))
            + int256((LOT_QTY / 2) * MARK / SHARE) - int256(basisFor(62) / 2);
        assertEq(loss, expected);

        vm.prank(address(mandate));
        ledger.realize(owner, address(AMZN), q, ids, MARK);
        TaxLotLedger.Lot memory l62 = ledger.lotAt(owner, address(AMZN), 62);
        assertTrue(l62.open);
        assertEq(l62.qty, LOT_QTY / 2);
        assertEq(l62.costBasis, basisFor(62) - basisFor(62) / 2);
        assertFalse(ledger.lotAt(owner, address(AMZN), 63).open);
        assertEq(ledger.openLotCount(owner, address(AMZN)), 63);
    }

    function test_realize_matches_computeHarvest_and_closes_full_lots() public {
        (uint64[] memory ids, int256 loss) =
            ledger.computeHarvest(owner, address(AMZN), SELL_QTY, MARK);
        vm.prank(address(mandate));
        int256 realized = ledger.realize(owner, address(AMZN), SELL_QTY, ids, MARK);
        assertEq(realized, loss);
        assertEq(ledger.openLotCount(owner, address(AMZN)), 56); // 8 closed, lot 55 still open (prorated)
        assertEq(ledger.openQty(owner, address(AMZN)), 640 * SHARE - SELL_QTY);
    }

    function test_realize_reverts_on_tampered_lot_selection() public {
        (uint64[] memory ids,) = ledger.computeHarvest(owner, address(AMZN), SELL_QTY, MARK);
        ids[0] = 0; // swap the top pick for the lowest-basis lot
        vm.prank(address(mandate));
        vm.expectRevert(ITaxLotLedger.SelectionMismatch.selector);
        ledger.realize(owner, address(AMZN), SELL_QTY, ids, MARK);
    }

    function test_computeHarvest_reverts_when_sellQty_exceeds_open_quantity() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaxLotLedger.InsufficientOpenQty.selector, 641 * SHARE, 640 * SHARE
            )
        );
        ledger.computeHarvest(owner, address(AMZN), 641 * SHARE, MARK);
    }

    function test_recordLot_is_mandate_only() public {
        vm.prank(stranger);
        vm.expectRevert(ITaxLotLedger.NotMandate.selector);
        ledger.recordLot(owner, address(AMZN), SHARE, USD);
    }

    function test_unrealizedLoss_sums_only_open_lots() public {
        int256 before = ledger.unrealizedLoss(owner, address(AMZN), MARK);
        (uint64[] memory ids, int256 loss) =
            ledger.computeHarvest(owner, address(AMZN), SELL_QTY, MARK);
        vm.prank(address(mandate));
        ledger.realize(owner, address(AMZN), SELL_QTY, ids, MARK);
        int256 after_ = ledger.unrealizedLoss(owner, address(AMZN), MARK);
        // the realized part left the unrealized total; ±1 (=$0.000001) is integer proration rounding
        assertApproxEqAbs(after_, before - loss, 1);
    }

    /// @dev Property: for any sellQty ≤ open, HIFO loss ≤ FIFO-style loss (HIFO is loss-maximal per unit sold).
    function testFuzz_hifo_is_never_worse_than_selling_lowest_basis_first(uint256 q) public view {
        q = bound(q, 1, 640 * SHARE);
        (, int256 hifo) = ledger.computeHarvest(owner, address(AMZN), q, MARK);
        // naive lowest-basis-first over the same quantity
        int256 lifoLike;
        uint256 rem = q;
        for (uint256 i = 0; i < LOTS && rem > 0; i++) {
            uint256 take = rem < LOT_QTY ? rem : LOT_QTY;
            lifoLike += int256(take * MARK / SHARE) - int256(basisFor(i) * take / LOT_QTY);
            rem -= take;
        }
        assertLe(hifo, lifoLike);
    }
}
