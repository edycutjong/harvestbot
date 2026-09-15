// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IWashSaleGuard {
    event WindowOpened(
        address indexed owner, address indexed asset, uint256 harvestedAt, uint256 windowEnd
    );

    error NotMandate();
    error WashSaleViolation(address owner, address asset, address blockedBy, uint256 windowEnd);

    function openWindow(address owner, address asset, uint256 harvestedAt) external;
    function assertBuyAllowed(address owner, address asset) external view;
    function windowEndsAt(address owner, address asset) external view returns (uint256);
    function WASH_SALE_WINDOW() external pure returns (uint256);
}
