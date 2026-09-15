// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Hello — the first real transaction HarvestBot sends on Robinhood Chain.
/// @notice Exists only to prove the deploy path (RPC, chain id, gas, explorer) end-to-end
///         before any ledger logic is written. Removed once the real contracts land.
contract Hello {
    event Greeted(address indexed from, string message, uint256 chainId);

    string public message;

    constructor(string memory initial) {
        message = initial;
        emit Greeted(msg.sender, initial, block.chainid);
    }

    function greet(string calldata m) external {
        message = m;
        emit Greeted(msg.sender, m, block.chainid);
    }
}
