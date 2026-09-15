// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {IAgentBond} from "../src/interfaces/IAgentBond.sol";
import {HarvestMandate} from "../src/HarvestMandate.sol";

/// @dev INV-6 — bond dominance. Beat 3 lives here: the signed off-map envelope IS the proof.
contract BondTest is BaseTest {
    uint256 internal constant SELL_QTY = 81_728_148_108_628_507_367;

    function setUp() public override {
        super.setUp();
        seedPortfolio();
    }

    function rogueEnvelope(uint256 nonce) internal view returns (bytes memory) {
        (uint64[] memory ids,) = ledger.computeHarvest(owner, address(AMZN), SELL_QTY, MARK);
        HarvestMandate.HarvestDecision memory d =
            decision(address(AMZN), address(PLTR), SELL_QTY, ids, nonce);
        return envelope(d, ids, agentPk);
    }

    function test_requiredBond_is_five_percent_of_aum_above_the_floor() public view {
        // AUM = 640 × $412.30 = $263,872.00 → 5% = $13,193.60
        assertEq(mandate.aumUsd(), 263_872 * USD);
        assertEq(bond.requiredBond(address(mandate)), 13_193_600_000);
    }

    function test_requiredBond_floor_is_1000_usdc_for_a_small_vault() public {
        vm.prank(owner);
        oracle.setPrice(address(AMZN), 1 * USD); // AUM = $640
        assertEq(bond.requiredBond(address(mandate)), 1_000 * USD);
    }

    function test_stake_below_required_reverts() public {
        vm.startPrank(agent);
        USDC.approve(address(bond), BOND);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentBond.BelowRequiredBond.selector, 13_193_600_000, 1_000 * USD
            )
        );
        bond.stake(address(mandate), 1_000 * USD);
        vm.stopPrank();
    }

    function test_only_the_mandates_agent_key_can_stake_for_it() public {
        USDC.mint(stranger, BOND);
        vm.startPrank(stranger);
        USDC.approve(address(bond), BOND);
        vm.expectRevert(IAgentBond.NotAgentOfMandate.selector);
        bond.stake(address(mandate), BOND);
        vm.stopPrank();
    }

    function test_beat3_offmap_envelope_slashes_2640_pays_264_bounty_restitutes_2376() public {
        stakeBond();
        bytes memory rogue = rogueEnvelope(7);

        (HarvestMandate.HarvestDecision memory d,) = mandate.recoverEnvelope(rogue);
        bytes32 proofHash = mandate.hashDecision(d);

        uint256 ownerBefore = USDC.balanceOf(owner);
        vm.prank(challenger);
        vm.expectEmit(true, true, false, true);
        emit IAgentBond.Slashed(
            agent, address(mandate), 2_640 * USD, 264 * USD, 2_376 * USD, proofHash
        );
        bond.challenge(address(mandate), rogue);
        assertTrue(bond.challenged(proofHash));

        assertEq(bond.bondOf(agent), BOND - 2_640 * USD);
        assertEq(USDC.balanceOf(challenger), 264 * USD);
        assertEq(USDC.balanceOf(owner) - ownerBefore, 2_376 * USD);
    }

    function test_the_same_proof_cannot_be_used_twice() public {
        stakeBond();
        bytes memory rogue = rogueEnvelope(7);
        vm.prank(challenger);
        bond.challenge(address(mandate), rogue);
        vm.prank(challenger);
        vm.expectRevert();
        bond.challenge(address(mandate), rogue);
    }

    function test_a_valid_onmap_envelope_is_not_a_violation() public {
        stakeBond();
        (bytes memory env,,) = harvestEnvelope(SELL_QTY, 1);
        vm.prank(challenger);
        vm.expectRevert(IAgentBond.NoViolation.selector);
        bond.challenge(address(mandate), env);
    }

    function test_an_envelope_signed_by_someone_else_cannot_slash_the_agent() public {
        stakeBond();
        (uint64[] memory ids,) = ledger.computeHarvest(owner, address(AMZN), SELL_QTY, MARK);
        HarvestMandate.HarvestDecision memory d =
            decision(address(AMZN), address(PLTR), SELL_QTY, ids, 7);
        bytes memory forged = envelope(d, ids, 0xBAD);
        vm.prank(challenger);
        vm.expectRevert(IAgentBond.NotAgentOfMandate.selector);
        bond.challenge(address(mandate), forged);
    }

    function test_rebuy_inside_the_window_is_the_second_slashable_offence() public {
        stakeBond();
        (bytes memory env,,) = harvestEnvelope(SELL_QTY, 1);
        vm.prank(agent);
        router.execute(env); // AMZN now walled
        (uint64[] memory ids,) = ledger.computeHarvest(owner, address(NFLX), SHARE, 900 * USD);
        HarvestMandate.HarvestDecision memory d =
            decision(address(NFLX), address(AMZN), SHARE, ids, 2);
        bytes memory rebuy = envelope(d, ids, agentPk);
        vm.prank(challenger);
        bond.challenge(address(mandate), rebuy);
        assertEq(USDC.balanceOf(challenger), 264 * USD);
    }

    function test_slash_is_capped_at_the_bond() public {
        // S = min(B, 0 + 0.20·B) is always ≤ B; after four slashes the bond is still ≥ 0
        stakeBond();
        for (uint256 n = 1; n <= 4; n++) {
            vm.prank(challenger);
            bond.challenge(address(mandate), rogueEnvelope(100 + n));
        }
        assertLt(bond.bondOf(agent), BOND);
        assertGt(bond.bondOf(agent), 0);
    }

    function test_withdrawBond_blocked_during_cooldown_and_reset_by_a_slash() public {
        stakeBond();
        vm.prank(agent);
        vm.expectRevert();
        bond.withdrawBond();

        vm.warp(block.timestamp + 6 days);
        vm.prank(challenger);
        bond.challenge(address(mandate), rogueEnvelope(7)); // resets the cooldown
        vm.warp(block.timestamp + 2 days); // 8 days after stake, but only 2 after the slash
        vm.prank(agent);
        vm.expectRevert();
        bond.withdrawBond();

        vm.warp(block.timestamp + 6 days);
        vm.prank(agent);
        bond.withdrawBond();
        assertEq(bond.bondOf(agent), 0);
        assertEq(USDC.balanceOf(agent), BOND - 2_640 * USD);
    }

    /// @dev Property (INV-6): for any bond ≥ floor, a proven breach costs the agent strictly more than the bounty
    ///      it could collect by challenging itself: S − bounty = 0.9·S > 0 and S = 0.2·B > 0.
    function testFuzz_breach_is_strictly_negative_EV_for_the_agent(uint256 b) public {
        b = bound(b, 13_193_600_000, 1_000_000 * USD);
        USDC.mint(agent, b);
        vm.startPrank(agent);
        USDC.approve(address(bond), b);
        bond.stake(address(mandate), b);
        vm.stopPrank();
        uint256 staked = bond.bondOf(agent);

        vm.prank(agent); // the agent challenges itself to try to recoup
        bond.challenge(address(mandate), rogueEnvelope(55));
        uint256 S = staked - bond.bondOf(agent);
        uint256 bounty = S / 10;
        assertGt(S, bounty);
        assertEq(S, staked * 2_000 / 10_000);
    }
}
