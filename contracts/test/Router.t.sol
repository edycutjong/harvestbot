// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {IExecutionRouter} from "../src/interfaces/IExecutionRouter.sol";
import {HarvestMandate} from "../src/HarvestMandate.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev The session-key bound: one target, one selector, value 0, expiry, rate limit.
contract RouterTest is BaseTest {
    uint256 internal constant SELL_QTY = 81_728_148_108_628_507_367;

    function setUp() public override {
        super.setUp();
        seedPortfolio();
        stakeBond();
    }

    function test_policy_pins_target_selector_and_zero_value() public view {
        IExecutionRouter.Policy memory p = router.policyOf(agent);
        assertEq(p.target, address(mandate));
        assertEq(p.selector, HarvestMandate.proposeHarvest.selector);
        assertEq(p.valueLimit, 0);
        assertEq(p.maxCallsPerDay, 10);
    }

    function test_a_key_without_a_policy_cannot_execute() public {
        (bytes memory env,,) = harvestEnvelope(SELL_QTY, 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IExecutionRouter.NoPolicy.selector, stranger));
        router.execute(env);
    }

    function test_expired_policy_is_rejected_before_the_mandate_is_reached() public {
        (bytes memory env,,) = harvestEnvelope(SELL_QTY, 1);
        uint64 expiry = router.policyOf(agent).expiry;
        vm.warp(uint256(expiry) + 1);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IExecutionRouter.PolicyExpired.selector, expiry));
        router.execute(env);
    }

    function test_rate_limit_resets_after_a_day() public {
        vm.prank(owner);
        router.setPolicy(
            agent,
            address(mandate),
            HarvestMandate.proposeHarvest.selector,
            uint64(block.timestamp + 365 days),
            1
        );

        (bytes memory env1,,) = harvestEnvelope(SHARE, 1);
        vm.prank(agent);
        router.execute(env1);

        (bytes memory env2,,) = harvestEnvelope(SHARE, 2);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IExecutionRouter.RateLimited.selector, 1));
        router.execute(env2);

        vm.warp(block.timestamp + 1 days);
        (bytes memory env3,,) = harvestEnvelope(SHARE, 3); // fresh deadline after the warp
        vm.prank(agent);
        router.execute(env3); // new day, allowed
    }

    function test_setPolicy_is_owner_only() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        router.setPolicy(agent, address(mandate), bytes4(0), 0, 0);
    }

    function test_mandate_reverts_bubble_up_through_the_router() public {
        (uint64[] memory ids,) = ledger.computeHarvest(owner, address(AMZN), SELL_QTY, MARK);
        HarvestMandate.HarvestDecision memory d =
            decision(address(AMZN), address(PLTR), SELL_QTY, ids, 9);
        bytes memory rogue = envelope(d, ids, agentPk);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                HarvestMandate.OffMapSubstitute.selector, address(AMZN), address(PLTR)
            )
        );
        router.execute(rogue);
    }
}
