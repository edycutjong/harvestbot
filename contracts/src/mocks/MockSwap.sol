// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwap} from "../interfaces/ISwap.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @title MockSwap — MOCK fixed-rate venue. Swaps at the oracle mark, no slippage, no fee.
/// @dev There is no AMM for Stock Tokens on the testnet; this stands in for one and is labeled MOCK.
///      Liquidity is whatever tokens are transferred to it.
contract MockSwap is ISwap {
    using SafeERC20 for IERC20;

    IPriceOracle public immutable oracle;

    event Swapped(
        address indexed sellAsset,
        address indexed buyAsset,
        uint256 sellQty,
        uint256 boughtQty,
        address to
    );

    error InsufficientLiquidity(address buyAsset, uint256 needed, uint256 available);

    constructor(IPriceOracle oracle_) {
        oracle = oracle_;
    }

    function quote(address sellAsset, address buyAsset, uint256 sellQty)
        public
        view
        returns (uint256)
    {
        return sellQty * oracle.price(sellAsset) / oracle.price(buyAsset);
    }

    function swapExactIn(address sellAsset, address buyAsset, uint256 sellQty, address to)
        external
        returns (uint256 boughtQty)
    {
        boughtQty = quote(sellAsset, buyAsset, sellQty);
        uint256 avail = IERC20(buyAsset).balanceOf(address(this));
        if (boughtQty > avail) revert InsufficientLiquidity(buyAsset, boughtQty, avail);
        IERC20(sellAsset).safeTransferFrom(msg.sender, address(this), sellQty);
        IERC20(buyAsset).safeTransfer(to, boughtQty);
        emit Swapped(sellAsset, buyAsset, sellQty, boughtQty, to);
    }
}
