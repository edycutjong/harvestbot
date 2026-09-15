// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IWashSaleGuard} from "./interfaces/IWashSaleGuard.sol";
import {ISubstituteMap} from "./interfaces/ISubstituteMap.sol";

/// @title WashSaleGuard — the IRS 30-day wash-sale rule, compiled into a contract
/// @notice After a harvest of `asset`, any rebuy of `asset` or of anything in its
///         substantially-identical cluster reverts until `harvestedAt + 30 days`.
///         The agent cannot bypass this: the mandate calls `assertBuyAllowed` before every rotation.
contract WashSaleGuard is IWashSaleGuard, Ownable {
    uint256 internal constant _WINDOW = 2_592_000; // 30 days

    ISubstituteMap public immutable subMap;
    address public mandate;
    mapping(address owner => mapping(address asset => uint256)) public windowEnd;

    event MandateSet(address indexed mandate);

    error MandateAlreadySet();
    error ZeroAddress();

    constructor(address initialOwner, ISubstituteMap subMap_) Ownable(initialOwner) {
        subMap = subMap_;
    }

    function setMandate(address mandate_) external onlyOwner {
        if (mandate != address(0)) revert MandateAlreadySet();
        if (mandate_ == address(0)) revert ZeroAddress();
        mandate = mandate_;
        emit MandateSet(mandate_);
    }

    function WASH_SALE_WINDOW() external pure returns (uint256) {
        return _WINDOW;
    }

    function openWindow(address owner, address asset, uint256 harvestedAt) external {
        if (msg.sender != mandate) revert NotMandate();
        uint256 end = harvestedAt + _WINDOW;
        windowEnd[owner][asset] = end;
        emit WindowOpened(owner, asset, harvestedAt, end);
    }

    /// @notice Reverts `WashSaleViolation` if `asset` or any member of its identical cluster is inside a window.
    function assertBuyAllowed(address owner, address asset) external view {
        address[] memory cluster = subMap.identicalCluster(asset);
        for (uint256 i = 0; i < cluster.length; i++) {
            uint256 end = windowEnd[owner][cluster[i]];
            if (block.timestamp < end) revert WashSaleViolation(owner, asset, cluster[i], end);
        }
    }

    /// @notice Latest window end across `asset` and its identical cluster (0 if none open).
    function windowEndsAt(address owner, address asset) external view returns (uint256 latest) {
        address[] memory cluster = subMap.identicalCluster(asset);
        for (uint256 i = 0; i < cluster.length; i++) {
            uint256 end = windowEnd[owner][cluster[i]];
            if (end > latest) latest = end;
        }
    }
}
