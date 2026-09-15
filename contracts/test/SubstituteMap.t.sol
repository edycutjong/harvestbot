// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {SubstituteMap} from "../src/SubstituteMap.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev INV-4 support — the curated map the mandate and guard both read.
contract SubstituteMapTest is BaseTest {
    function test_seed_pair_is_symmetric() public view {
        assertTrue(subMap.isSubstitute(address(AMZN), address(NFLX)));
        assertTrue(subMap.isSubstitute(address(NFLX), address(AMZN)));
    }

    function test_offmap_asset_is_not_a_substitute() public view {
        assertFalse(subMap.isSubstitute(address(AMZN), address(PLTR)));
        assertFalse(subMap.isSubstitute(address(PLTR), address(AMZN)));
    }

    function test_reenabling_a_disabled_pair_does_not_duplicate_it_in_substitutesOf() public {
        address[] memory s = subMap.substitutesOf(address(AMZN));
        assertEq(s.length, 1);
        assertEq(s[0], address(NFLX));

        vm.prank(owner);
        subMap.setPair(address(AMZN), address(NFLX), false);
        assertEq(subMap.substitutesOf(address(AMZN)).length, 0);

        vm.prank(owner);
        subMap.setPair(address(AMZN), address(NFLX), true); // re-enable does not duplicate
        assertEq(subMap.substitutesOf(address(AMZN)).length, 1);
    }

    function test_identicalCluster_always_includes_self_first() public view {
        address[] memory c = subMap.identicalCluster(address(AMZN));
        assertEq(c.length, 1);
        assertEq(c[0], address(AMZN));
    }

    function test_setPair_and_setIdentical_are_owner_only() public {
        vm.startPrank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        subMap.setPair(address(AMZN), address(PLTR), true);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        subMap.setIdentical(address(AMZN), address(PLTR), true);
        vm.stopPrank();
    }

    function test_self_pair_is_rejected() public {
        vm.prank(owner);
        vm.expectRevert(SubstituteMap.SelfPair.selector);
        subMap.setPair(address(AMZN), address(AMZN), true);
    }
}
