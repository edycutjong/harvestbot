// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentBond {
    event Staked(address indexed agent, address indexed mandate, uint256 amount, uint256 total);
    event Slashed(
        address indexed agent,
        address indexed mandate,
        uint256 S,
        uint256 bounty,
        uint256 restitution,
        bytes32 proofHash
    );
    event BondWithdrawn(address indexed agent, uint256 amount);

    error NotAgentOfMandate();
    error BelowRequiredBond(uint256 required, uint256 staked);
    error NoViolation();
    error AlreadyChallenged(bytes32 proofHash);
    error CooldownActive(uint256 until);
    error NothingToWithdraw();
    error EnvelopeNotLive();
    error AgentStillActive();
    error BoundToOtherMandate(address mandate);

    function stake(address mandate, uint256 amount) external;
    function requiredBond(address mandate) external view returns (uint256);
    function challenge(address mandate, bytes calldata signedEnvelope) external;
    function bondOf(address agent) external view returns (uint256);
    function withdrawBond() external;
}
