// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISwap {
    function swapExactIn(address sellAsset, address buyAsset, uint256 sellQty, address to)
        external
        returns (uint256 boughtQty);
}
