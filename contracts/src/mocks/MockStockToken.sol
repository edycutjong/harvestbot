// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockStockToken — MOCK. Test-only stand-in for a Robinhood Stock Token (18dp ERC-20).
/// @dev Used in Foundry tests and on the Arbitrum Sepolia benchmark mirror only. On Robinhood Chain
///      testnet the mandate holds the REAL faucet Stock Tokens (TSLA/AMZN/PLTR/NFLX/AMD).
contract MockStockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
