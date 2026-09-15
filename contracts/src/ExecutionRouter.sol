// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IExecutionRouter} from "./interfaces/IExecutionRouter.sol";

/// @title ExecutionRouter — the session-key bound
/// @notice The agent's key never holds owner powers. It may call exactly ONE (target, selector) with
///         value 0, before `expiry`, at most `maxCallsPerDay` times. Everything else reverts here,
///         before the mandate is ever reached.
contract ExecutionRouter is IExecutionRouter, Ownable {
    using Address for address;

    mapping(address => Policy) internal _policy;

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setPolicy(
        address signer,
        address target,
        bytes4 selector,
        uint64 expiry,
        uint32 maxCallsPerDay
    ) external onlyOwner {
        _policy[signer] = Policy({
            target: target,
            selector: selector,
            valueLimit: 0,
            expiry: expiry,
            maxCallsPerDay: maxCallsPerDay,
            callsToday: 0,
            dayStart: uint64(block.timestamp)
        });
        emit PolicySet(signer, target, selector, expiry, maxCallsPerDay);
    }

    /// @notice msg.sender must be the policy signer. Forwards `signedEnvelope` to the single allowed selector.
    function execute(bytes calldata signedEnvelope) external returns (bytes memory ret) {
        Policy storage p = _policy[msg.sender];
        if (p.target == address(0)) revert NoPolicy(msg.sender);
        if (block.timestamp > p.expiry) revert PolicyExpired(p.expiry);

        if (block.timestamp >= p.dayStart + 1 days) {
            p.dayStart = uint64(block.timestamp);
            p.callsToday = 0;
        }
        if (p.callsToday >= p.maxCallsPerDay) revert RateLimited(p.maxCallsPerDay);
        p.callsToday += 1;

        ret = p.target.functionCall(abi.encodeWithSelector(p.selector, signedEnvelope));
        emit Executed(msg.sender, p.target, p.selector, keccak256(signedEnvelope));
    }

    function policyOf(address signer) external view returns (Policy memory) {
        return _policy[signer];
    }
}
