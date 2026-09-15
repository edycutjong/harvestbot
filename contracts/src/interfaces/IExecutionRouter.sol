// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IExecutionRouter {
    struct Policy {
        address target;
        bytes4 selector;
        uint256 valueLimit; // always 0 — the agent can never move ETH
        uint64 expiry;
        uint32 maxCallsPerDay;
        uint32 callsToday;
        uint64 dayStart;
    }

    event PolicySet(
        address indexed signer,
        address indexed target,
        bytes4 selector,
        uint64 expiry,
        uint32 maxCallsPerDay
    );
    event Executed(
        address indexed signer, address indexed target, bytes4 selector, bytes32 envelopeHash
    );

    error NoPolicy(address signer);
    error PolicyExpired(uint64 expiry);
    error RateLimited(uint32 maxCallsPerDay);

    function setPolicy(
        address signer,
        address target,
        bytes4 selector,
        uint64 expiry,
        uint32 maxCallsPerDay
    ) external;
    function execute(bytes calldata signedEnvelope) external returns (bytes memory);
    function policyOf(address signer) external view returns (Policy memory);
}
