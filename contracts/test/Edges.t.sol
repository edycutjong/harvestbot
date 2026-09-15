// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {TaxLotLedger} from "../src/TaxLotLedger.sol";
import {WashSaleGuard} from "../src/WashSaleGuard.sol";
import {HarvestMandate} from "../src/HarvestMandate.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {MockSwap} from "../src/mocks/MockSwap.sol";
import {ITaxLotLedger} from "../src/interfaces/ITaxLotLedger.sol";
import {IAgentBond} from "../src/interfaces/IAgentBond.sol";

/// @dev Wiring, units and revert edges that the beat tests never reach.
contract EdgesTest is BaseTest {
    function test_ledger_and_guard_mandate_can_only_be_bound_once() public {
        vm.startPrank(owner);
        vm.expectRevert(TaxLotLedger.MandateAlreadySet.selector);
        ledger.setMandate(stranger);
        vm.expectRevert(WashSaleGuard.MandateAlreadySet.selector);
        guard.setMandate(stranger);
        vm.stopPrank();
        assertEq(ledger.mandate(), address(mandate));
        assertEq(guard.mandate(), address(mandate));
    }

    function test_empty_ledger_reports_zero_and_rejects_a_zero_quantity_harvest() public {
        assertEq(ledger.lotCount(owner, address(AMZN)), 0);
        assertEq(ledger.openLotCount(owner, address(AMZN)), 0);
        assertEq(ledger.unrealizedLoss(owner, address(AMZN), MARK), 0);
        vm.expectRevert(ITaxLotLedger.ZeroQty.selector);
        ledger.computeHarvest(owner, address(AMZN), 0, MARK);
        vm.prank(address(mandate));
        vm.expectRevert(ITaxLotLedger.ZeroQty.selector);
        ledger.recordLot(owner, address(AMZN), 0, USD);
    }

    function test_lotCount_includes_closed_lots_openLotCount_does_not() public {
        seedPortfolio();
        (uint64[] memory ids,) = ledger.computeHarvest(owner, address(AMZN), LOT_QTY, MARK);
        vm.prank(address(mandate));
        ledger.realize(owner, address(AMZN), LOT_QTY, ids, MARK);
        assertEq(ledger.lotCount(owner, address(AMZN)), 64);
        assertEq(ledger.openLotCount(owner, address(AMZN)), 63);
    }

    function test_eip712_domain_is_HarvestBot_v1_bound_to_the_mandate_and_chain() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("HarvestBot"),
                keccak256("1"),
                block.chainid,
                address(mandate)
            )
        );
        assertEq(mandate.domainSeparator(), expected);
    }

    function test_mock_usdc_has_six_decimals_and_stock_tokens_eighteen() public view {
        assertEq(USDC.decimals(), 6);
        assertEq(AMZN.decimals(), 18);
    }

    function test_oracle_reverts_for_an_unpriced_asset() public {
        address unknown = makeAddr("unknown-token");
        vm.expectRevert(abi.encodeWithSelector(MockOracle.NoPrice.selector, unknown));
        oracle.price(unknown);
    }

    function test_swap_quotes_at_oracle_marks_and_reverts_without_liquidity() public {
        // 1 AMZN at $412.30 → NFLX at $900 = 0.4581… NFLX
        assertEq(swap.quote(address(AMZN), address(NFLX), SHARE), SHARE * MARK / (900 * USD));
        // drain NFLX liquidity, then try to buy it
        uint256 liq = NFLX.balanceOf(address(swap));
        vm.prank(address(swap));
        NFLX.transfer(stranger, liq);
        AMZN.mint(owner, SHARE);
        vm.startPrank(owner);
        AMZN.approve(address(swap), SHARE);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockSwap.InsufficientLiquidity.selector,
                address(NFLX),
                SHARE * MARK / (900 * USD),
                0
            )
        );
        swap.swapExactIn(address(AMZN), address(NFLX), SHARE, owner);
        vm.stopPrank();
    }

    function test_harvest_after_an_owner_withdrawal_that_outran_the_ledger_reverts_InsufficientHoldings()
        public
    {
        // regression: withdraw() moves tokens but leaves lots open; a later harvest must fail on
        // holdings, not silently under-deliver to the swap
        seedPortfolio();
        stakeBond();
        vm.prank(owner);
        mandate.withdraw(address(AMZN), 600 * SHARE, owner);
        uint256 q = 81_728_148_108_628_507_367; // > 40 shares left
        (bytes memory env,,) = harvestEnvelope(q, 1);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                HarvestMandate.InsufficientHoldings.selector, address(AMZN), 40 * SHARE, q
            )
        );
        router.execute(env);
    }

    function test_withdrawBond_with_nothing_staked_reverts() public {
        vm.prank(agent);
        vm.expectRevert(IAgentBond.NothingToWithdraw.selector);
        bond.withdrawBond();
    }

    function test_withdraw_more_than_held_reverts() public {
        seedPortfolio();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                HarvestMandate.InsufficientHoldings.selector,
                address(AMZN),
                640 * SHARE,
                641 * SHARE
            )
        );
        mandate.withdraw(address(AMZN), 641 * SHARE, owner);
    }

    function test_rotation_into_an_existing_asset_does_not_duplicate_the_asset_list() public {
        seedPortfolio();
        stakeBond();
        (bytes memory env1,,) = harvestEnvelope(SHARE, 1);
        vm.prank(agent);
        router.execute(env1);
        // second harvest, same destination NFLX → assets() stays [AMZN, NFLX]
        vm.warp(block.timestamp + 1);
        (bytes memory env2,,) = harvestEnvelope(SHARE, 2);
        vm.prank(agent);
        router.execute(env2);
        assertEq(mandate.assets().length, 2);
    }
}

contract ZeroAddressTest is BaseTest {
    function test_wiring_rejects_the_zero_address() public {
        TaxLotLedger l = new TaxLotLedger(owner);
        WashSaleGuard g = new WashSaleGuard(owner, subMap);
        vm.startPrank(owner);
        vm.expectRevert(TaxLotLedger.ZeroAddress.selector);
        l.setMandate(address(0));
        vm.expectRevert(WashSaleGuard.ZeroAddress.selector);
        g.setMandate(address(0));
        vm.expectRevert(HarvestMandate.ZeroAddress.selector);
        mandate.setAgentKey(address(0));
        vm.stopPrank();
    }
}
