// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {IWashSaleGuard} from "../src/interfaces/IWashSaleGuard.sol";

/// @dev INV-3 — wash-sale monotonicity. After a harvest the way back is walled for 30 days.
contract WashSaleTest is BaseTest {
    uint256 internal constant WINDOW = 2_592_000;

    function test_window_is_thirty_days() public view {
        assertEq(guard.WASH_SALE_WINDOW(), WINDOW);
        assertEq(WINDOW, 30 days);
    }

    function test_openWindow_is_mandate_only() public {
        vm.prank(stranger);
        vm.expectRevert(IWashSaleGuard.NotMandate.selector);
        guard.openWindow(owner, address(AMZN), block.timestamp);
    }

    function test_rebuy_inside_window_reverts_WashSaleViolation() public {
        uint256 t = block.timestamp;
        vm.prank(address(mandate));
        guard.openWindow(owner, address(AMZN), t);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWashSaleGuard.WashSaleViolation.selector,
                owner,
                address(AMZN),
                address(AMZN),
                t + WINDOW
            )
        );
        guard.assertBuyAllowed(owner, address(AMZN));
    }

    function test_rebuy_one_second_before_window_end_still_reverts() public {
        uint256 t = block.timestamp;
        vm.prank(address(mandate));
        guard.openWindow(owner, address(AMZN), t);
        vm.warp(t + WINDOW - 1);
        vm.expectRevert();
        guard.assertBuyAllowed(owner, address(AMZN));
    }

    function test_rebuy_at_window_end_is_allowed() public {
        uint256 t = block.timestamp;
        vm.prank(address(mandate));
        guard.openWindow(owner, address(AMZN), t);
        vm.warp(t + WINDOW);
        guard.assertBuyAllowed(owner, address(AMZN)); // no revert
        assertEq(guard.windowEndsAt(owner, address(AMZN)), t + WINDOW);
    }

    function test_substitute_is_NOT_blocked_by_the_sold_assets_window() public {
        // AMZN ↔ NFLX are substitutes (different issuer/company), not substantially identical
        vm.prank(address(mandate));
        guard.openWindow(owner, address(AMZN), block.timestamp);
        guard.assertBuyAllowed(owner, address(NFLX)); // no revert
        assertEq(guard.windowEndsAt(owner, address(NFLX)), 0);
    }

    function test_substantially_identical_asset_is_blocked_with_the_original() public {
        // a second wrapper of the same underlying — e.g. another issuer's AMZN token
        address amznWrapper2 = address(PLTR); // reuse a token address as the stand-in
        vm.prank(owner);
        subMap.setIdentical(address(AMZN), amznWrapper2, true);

        uint256 t = block.timestamp;
        vm.prank(address(mandate));
        guard.openWindow(owner, address(AMZN), t);

        vm.expectRevert(
            abi.encodeWithSelector(
                IWashSaleGuard.WashSaleViolation.selector,
                owner,
                amznWrapper2,
                address(AMZN),
                t + WINDOW
            )
        );
        guard.assertBuyAllowed(owner, amznWrapper2);
        assertEq(guard.windowEndsAt(owner, amznWrapper2), t + WINDOW);
    }

    function test_windows_are_per_owner() public {
        vm.prank(address(mandate));
        guard.openWindow(owner, address(AMZN), block.timestamp);
        guard.assertBuyAllowed(stranger, address(AMZN)); // someone else's account is unaffected
    }

    /// @dev Property: for any harvest time and any offset < 30 days, the rebuy is blocked; ≥ 30 days it is not.
    function testFuzz_window_is_exactly_thirty_days(uint64 harvestedAt, uint64 offset) public {
        harvestedAt = uint64(bound(harvestedAt, 1, type(uint64).max / 4));
        offset = uint64(bound(offset, 0, 2 * WINDOW));
        vm.prank(address(mandate));
        guard.openWindow(owner, address(AMZN), harvestedAt);
        vm.warp(uint256(harvestedAt) + offset);
        if (offset < WINDOW) {
            vm.expectRevert();
            guard.assertBuyAllowed(owner, address(AMZN));
        } else {
            guard.assertBuyAllowed(owner, address(AMZN));
        }
    }
}
