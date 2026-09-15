// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @title MockOracle — MOCK mark prices (USDC 6dp per 1e18 units), owner-set.
/// @dev Labeled MOCK everywhere it appears. A Chainlink feed can replace it behind the same interface.
contract MockOracle is IPriceOracle, Ownable {
    mapping(address => uint256) internal _price;

    event PriceSet(address indexed asset, uint256 price);

    error NoPrice(address asset);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setPrice(address asset, uint256 p) external onlyOwner {
        _price[asset] = p;
        emit PriceSet(asset, p);
    }

    function price(address asset) external view returns (uint256 p) {
        p = _price[asset];
        if (p == 0) revert NoPrice(asset);
    }
}
