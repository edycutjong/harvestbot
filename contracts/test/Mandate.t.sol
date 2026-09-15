// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {HarvestMandate} from "../src/HarvestMandate.sol";
import {IWashSaleGuard} from "../src/interfaces/IWashSaleGuard.sol";
import {IExecutionRouter} from "../src/interfaces/IExecutionRouter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev The three beats + every revert path of `proposeHarvest`. INV-1 … INV-5.
contract MandateTest is BaseTest {
    uint256 internal constant SELL_QTY = 81_728_148_108_628_507_367;

    function setUp() public override {
        super.setUp();
        seedPortfolio();
        stakeBond();
    }

    // ── Beat 1 — HARVEST ─────────────────────────────────────────────────────

    function test_beat1_harvest_realizes_minus_3140_rotates_into_NFLX_and_opens_the_window()
        public
    {
        (bytes memory env, uint64[] memory ids, int256 expectedLoss) = harvestEnvelope(SELL_QTY, 1);
        assertEq(expectedLoss, -3_140_000_000);

        uint256 amznBefore = mandate.holdings(address(AMZN));
        uint256 t = block.timestamp;

        vm.expectEmit(true, true, true, false);
        emit HarvestMandate.HarvestReport(
            owner, address(AMZN), address(NFLX), ids, expectedLoss, bytes32(0), 1, 0, 0
        );
        vm.prank(agent);
        bytes memory ret = router.execute(env);
        assertEq(abi.decode(ret, (int256)), expectedLoss);

        // rotated, not withdrawn (INV-1): AMZN down by sellQty, NFLX up by the swap proceeds
        assertEq(mandate.holdings(address(AMZN)), amznBefore - SELL_QTY);
        uint256 expectedNflx = SELL_QTY * MARK / (900 * USD);
        assertEq(mandate.holdings(address(NFLX)), expectedNflx);
        assertEq(NFLX.balanceOf(address(mandate)), expectedNflx);

        // ledger: 8 AMZN lots closed, one prorated, one new NFLX lot with basis = proceeds
        assertEq(ledger.openLotCount(owner, address(AMZN)), 56);
        assertEq(ledger.openLotCount(owner, address(NFLX)), 1);
        (, uint256[] memory q, uint256[] memory b,) = ledger.getOpenLots(owner, address(NFLX));
        assertEq(q[0], expectedNflx);
        assertEq(b[0], SELL_QTY * MARK / SHARE);

        // wash-sale clock started on AMZN
        assertEq(guard.windowEndsAt(owner, address(AMZN)), t + 30 days);
        assertTrue(mandate.usedNonce(1));
    }

    // ── Beat 2 — BLOCKED REBUY ───────────────────────────────────────────────

    function test_beat2_rotating_back_into_AMZN_inside_the_window_reverts_WashSaleViolation()
        public
    {
        (bytes memory env,,) = harvestEnvelope(SELL_QTY, 1);
        vm.prank(agent);
        router.execute(env);
        uint256 windowEnd = guard.windowEndsAt(owner, address(AMZN));

        // agent now tries NFLX → AMZN (on-map, but AMZN is walled)
        (uint64[] memory ids,) = ledger.computeHarvest(owner, address(NFLX), SHARE, 900 * USD);
        HarvestMandate.HarvestDecision memory d =
            decision(address(NFLX), address(AMZN), SHARE, ids, 2);
        bytes memory rebuy = envelope(d, ids, agentPk);

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWashSaleGuard.WashSaleViolation.selector,
                owner,
                address(AMZN),
                address(AMZN),
                windowEnd
            )
        );
        router.execute(rebuy);
    }

    function test_beat2_after_thirty_days_the_rebuy_path_is_open_again() public {
        (bytes memory env,,) = harvestEnvelope(SELL_QTY, 1);
        vm.prank(agent);
        router.execute(env);
        vm.warp(block.timestamp + 30 days);
        guard.assertBuyAllowed(owner, address(AMZN)); // no revert
    }

    // ── Beat 3 — OFF-MAP (the mandate side; the slash lives in Bond.t.sol) ──

    function test_beat3_offmap_rotation_into_PLTR_reverts_OffMapSubstitute() public {
        (uint64[] memory ids,) = ledger.computeHarvest(owner, address(AMZN), SELL_QTY, MARK);
        HarvestMandate.HarvestDecision memory d =
            decision(address(AMZN), address(PLTR), SELL_QTY, ids, 7);
        bytes memory rogue = envelope(d, ids, agentPk);

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                HarvestMandate.OffMapSubstitute.selector, address(AMZN), address(PLTR)
            )
        );
        router.execute(rogue);
        // nothing moved
        assertEq(mandate.holdings(address(AMZN)), 640 * SHARE);
        assertEq(mandate.holdings(address(PLTR)), 0);
    }

    // ── INV-5 authenticity / replay / freshness ──────────────────────────────

    function test_envelope_signed_by_a_stranger_is_rejected() public {
        (uint64[] memory ids,) = ledger.computeHarvest(owner, address(AMZN), SELL_QTY, MARK);
        HarvestMandate.HarvestDecision memory d =
            decision(address(AMZN), address(NFLX), SELL_QTY, ids, 1);
        uint256 strangerPk = 0xBAD;
        bytes memory env = envelope(d, ids, strangerPk);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(HarvestMandate.BadSignature.selector, vm.addr(strangerPk))
        );
        router.execute(env);
    }

    function test_replaying_a_used_nonce_is_rejected() public {
        (bytes memory env,,) = harvestEnvelope(SELL_QTY, 1);
        vm.prank(agent);
        router.execute(env);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(HarvestMandate.NonceUsed.selector, 1));
        router.execute(env);
    }

    function test_expired_envelope_is_rejected() public {
        (bytes memory env,,) = harvestEnvelope(SELL_QTY, 1);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(agent);
        vm.expectRevert();
        router.execute(env);
    }

    function test_envelope_for_a_different_owner_is_rejected() public {
        (uint64[] memory ids,) = ledger.computeHarvest(owner, address(AMZN), SELL_QTY, MARK);
        HarvestMandate.HarvestDecision memory d =
            decision(address(AMZN), address(NFLX), SELL_QTY, ids, 1);
        d.owner = stranger;
        bytes memory env = envelope(d, ids, agentPk);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(HarvestMandate.WrongOwner.selector, stranger));
        router.execute(env);
    }

    // ── INV-2 loss integrity ─────────────────────────────────────────────────

    function test_envelope_with_a_non_hifo_lot_selection_is_rejected() public {
        uint64[] memory ids = new uint64[](9);
        for (uint64 i = 0; i < 9; i++) {
            ids[i] = i; // lowest-basis lots — a gain, and not what HIFO picks
        }
        HarvestMandate.HarvestDecision memory d =
            decision(address(AMZN), address(NFLX), SELL_QTY, ids, 1);
        bytes memory env = envelope(d, ids, agentPk);
        vm.prank(agent);
        vm.expectRevert(); // SelectionMismatch(expected, got)
        router.execute(env);
    }

    function test_harvest_that_would_realize_a_gain_is_rejected() public {
        // mark above every basis → HIFO still picks the top lots but the result is a gain
        vm.prank(owner);
        oracle.setPrice(address(AMZN), 500 * USD);
        (uint64[] memory ids, int256 gain) =
            ledger.computeHarvest(owner, address(AMZN), SELL_QTY, 500 * USD);
        assertGt(gain, 0);
        HarvestMandate.HarvestDecision memory d =
            decision(address(AMZN), address(NFLX), SELL_QTY, ids, 1);
        bytes memory env = envelope(d, ids, agentPk);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(HarvestMandate.NoLossToHarvest.selector, gain));
        router.execute(env);
    }

    function test_mark_price_comes_from_the_oracle_not_the_envelope() public {
        // agent computed its selection at a stale mark; the mandate recomputes at the oracle's and rejects
        (uint64[] memory ids,) = ledger.computeHarvest(owner, address(AMZN), 200 * SHARE, 300 * USD);
        HarvestMandate.HarvestDecision memory d =
            decision(address(AMZN), address(NFLX), 200 * SHARE, ids, 1);
        bytes memory env = envelope(d, ids, agentPk);
        // at the real mark ($412.30) selling 200 shares picks the same top-20 lots but the loss differs; selection
        // hash is identical here, so we make the oracle move so that the picked set changes:
        vm.prank(owner);
        oracle.setPrice(address(AMZN), MARK);
        // Selection at $300 for 200 shares = top 20 lots; at $412.30 the same 20 → same hash; loss recomputed by
        // the contract regardless. Assert the realized loss reported equals the ORACLE-mark loss.
        (, int256 lossAtOracle) = ledger.computeHarvest(owner, address(AMZN), 200 * SHARE, MARK);
        vm.prank(agent);
        bytes memory ret = router.execute(env);
        assertEq(abi.decode(ret, (int256)), lossAtOracle);
    }

    // ── INV-1 custody ────────────────────────────────────────────────────────

    function test_INV1_no_agent_path_can_withdraw_assets() public {
        vm.startPrank(agent);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        mandate.withdraw(address(AMZN), SHARE, agent);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        mandate.setAgentKey(agent);
        vm.stopPrank();
    }

    function test_INV1_proposeHarvest_is_router_only_even_for_the_agent() public {
        (bytes memory env,,) = harvestEnvelope(SELL_QTY, 1);
        vm.prank(agent);
        vm.expectRevert(HarvestMandate.NotRouter.selector);
        mandate.proposeHarvest(env);
    }

    function test_INV1_vault_total_value_is_preserved_across_a_rotation() public {
        (bytes memory env,,) = harvestEnvelope(SELL_QTY, 1);
        uint256 aumBefore = mandate.aumUsd();
        vm.prank(agent);
        router.execute(env);
        // MockSwap trades at the oracle marks with no fee → AUM unchanged up to integer rounding
        assertApproxEqAbs(mandate.aumUsd(), aumBefore, 1_000); // ≤ $0.001 of rounding across the division chain
    }

    function test_owner_can_withdraw_and_the_agent_cannot_stop_it() public {
        vm.prank(owner);
        mandate.withdraw(address(AMZN), 5 * SHARE, owner);
        assertEq(AMZN.balanceOf(owner), 5 * SHARE);
        assertEq(mandate.holdings(address(AMZN)), 635 * SHARE);
    }

    function test_deposit_records_a_lot_and_tracks_the_asset() public view {
        address[] memory a = mandate.assets();
        assertEq(a.length, 1);
        assertEq(a[0], address(AMZN));
        assertEq(mandate.aumUsd(), 640 * MARK); // 640 shares × $412.30
    }

    // ── EIP-712 wiring ───────────────────────────────────────────────────────

    function test_recoverEnvelope_returns_the_agent_for_a_signed_envelope() public view {
        (bytes memory env,,) = harvestEnvelope(SELL_QTY, 1);
        (HarvestMandate.HarvestDecision memory d, address signer) = mandate.recoverEnvelope(env);
        assertEq(signer, agent);
        assertEq(d.sellAsset, address(AMZN));
        assertEq(d.nonce, 1);
    }
}
