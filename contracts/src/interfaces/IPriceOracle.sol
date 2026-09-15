// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice USDC (6dp) per 1e18 base units of `asset`.
interface IPriceOracle {
    function price(address asset) external view returns (uint256);
}
