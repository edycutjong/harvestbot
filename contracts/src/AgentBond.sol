// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAgentBond} from "./interfaces/IAgentBond.sol";
import {ISubstituteMap} from "./interfaces/ISubstituteMap.sol";
import {IWashSaleGuard} from "./interfaces/IWashSaleGuard.sol";
import {HarvestMandate} from "./HarvestMandate.sol";

/// @title AgentBond — a slashable bond that makes every provable breach negative-EV for the agent
/// @notice The agent stakes at least `max(1000 USDC, 5% of AUM)`. Anyone holding an envelope the
///         agent SIGNED that violates the mandate (off-map rotation, or a rebuy inside a wash-sale
///         window) can call `challenge()`. The mandate would have reverted such an envelope — the
///         signature alone is the offence. Slash S = min(B, L_owner + 0.20·B); 10% bounty to the
///         challenger, the rest to the mandate owner (INV-6).
contract AgentBond is IAgentBond, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BOND_FLOOR = 1_000e6; // 1,000 USDC
    uint256 public constant AUM_BPS = 500; // 5 %
    uint256 public constant SLASH_BPS = 2_000; // 20 % of B on top of owner loss
    uint256 public constant BOUNTY_BPS = 1_000; // 10 % of S
    uint256 public constant COOLDOWN = 7 days;
    /// @dev How long after its deadline an unexecuted envelope still counts as proof. Without it an agent
    ///      could sign violations with a same-block deadline and never be challengeable.
    uint256 public constant CHALLENGE_GRACE = 1 days;

    IERC20 public immutable bondToken; // MOCK USDC on testnet, 6dp

    mapping(address agent => uint256) internal _bond;
    mapping(address mandate => address agent) public agentOf;
    mapping(address agent => address mandate) public mandateOf;
    mapping(address agent => uint256) public cooldownEnd;
    mapping(bytes32 proofHash => bool) public challenged;

    constructor(IERC20 bondToken_) {
        bondToken = bondToken_;
    }

    // ── staking ──────────────────────────────────────────────────────────────

    /// @notice Stake `amount` toward `mandate`. Caller must be the mandate's current agent key.
    ///         An agent's bond backs ONE mandate at a time: while any bond is staked it cannot be
    ///         re-pointed at another mandate (which would let it exit through a mandate it controls).
    function stake(address mandate, uint256 amount) external nonReentrant {
        if (HarvestMandate(mandate).agentKey() != msg.sender) revert NotAgentOfMandate();
        address bound = mandateOf[msg.sender];
        if (bound != address(0) && bound != mandate && _bond[msg.sender] != 0) {
            revert BoundToOtherMandate(bound);
        }
        bondToken.safeTransferFrom(msg.sender, address(this), amount);
        _bond[msg.sender] += amount;
        agentOf[mandate] = msg.sender;
        mandateOf[msg.sender] = mandate;
        cooldownEnd[msg.sender] = block.timestamp + COOLDOWN;
        uint256 required = requiredBond(mandate);
        if (_bond[msg.sender] < required) revert BelowRequiredBond(required, _bond[msg.sender]);
        emit Staked(msg.sender, mandate, amount, _bond[msg.sender]);
    }

    function requiredBond(address mandate) public view returns (uint256) {
        uint256 pct = HarvestMandate(mandate).aumUsd() * AUM_BPS / 10_000;
        return pct > BOND_FLOOR ? pct : BOND_FLOOR;
    }

    function bondOf(address agent) external view returns (uint256) {
        return _bond[agent];
    }

    /// @notice Agent exits after the cooldown, and only once the owner has rotated its key out of the
    ///         mandate — an agent that can still sign harvests cannot pull the bond that backs them.
    ///         A successful challenge resets the cooldown.
    function withdrawBond() external nonReentrant {
        uint256 b = _bond[msg.sender];
        if (b == 0) revert NothingToWithdraw();
        address m = mandateOf[msg.sender];
        if (HarvestMandate(m).agentKey() == msg.sender) revert AgentStillActive();
        if (block.timestamp < cooldownEnd[msg.sender]) {
            revert CooldownActive(cooldownEnd[msg.sender]);
        }
        _bond[msg.sender] = 0;
        bondToken.safeTransfer(msg.sender, b);
        emit BondWithdrawn(msg.sender, b);
    }

    // ── slashing ─────────────────────────────────────────────────────────────

    /// @notice Permissionless. Proof = a LIVE envelope the agent signed that the mandate must reject.
    ///         Violations recognised: (a) off-map substitute; (b) rotating INTO an asset inside a
    ///         wash-sale window. L_owner is 0 for both — the mandate reverts before any funds move.
    /// @dev    "Live" = addressed to this mandate's owner, nonce unused, and no more than
    ///         `CHALLENGE_GRACE` past its deadline. An executed envelope (nonce used) was fully validated
    ///         when it ran; judging it — or a long-dead one — against TODAY's map and windows would let
    ///         anyone slash an honest agent for state that changed after it signed (e.g. replaying last
    ///         month's AMZN→NFLX harvest once NFLX is itself harvested). The grace period stops the
    ///         opposite abuse: a same-block deadline that expires before any challenger can act.
    function challenge(address mandate, bytes calldata signedEnvelope) external nonReentrant {
        HarvestMandate m = HarvestMandate(mandate);
        (HarvestMandate.HarvestDecision memory d, address signer) =
            m.recoverEnvelope(signedEnvelope);
        address agent = agentOf[mandate];
        if (signer != agent || agent == address(0)) revert NotAgentOfMandate();
        if (
            d.owner != m.owner() || m.usedNonce(d.nonce)
                || block.timestamp > d.deadline + CHALLENGE_GRACE
        ) {
            revert EnvelopeNotLive();
        }

        bytes32 proofHash = m.hashDecision(d);
        if (challenged[proofHash]) revert AlreadyChallenged(proofHash);

        bool violation = !m.subMap().isSubstitute(d.sellAsset, d.buyAsset);
        if (!violation) {
            // a rebuy of something still inside its window is the second recognised offence —
            // only the guard's own WashSaleViolation counts, never an arbitrary revert
            try m.guard().assertBuyAllowed(d.owner, d.buyAsset) {}
            catch (bytes memory reason) {
                violation = reason.length >= 4
                    && bytes4(reason) == IWashSaleGuard.WashSaleViolation.selector;
            }
        }
        if (!violation) revert NoViolation();
        challenged[proofHash] = true;

        uint256 B = _bond[agent];
        uint256 lOwner = 0; // reverted attempt: no owner loss
        uint256 S = lOwner + B * SLASH_BPS / 10_000;
        if (S > B) S = B;
        uint256 bounty = S * BOUNTY_BPS / 10_000;
        uint256 restitution = S - bounty;

        _bond[agent] = B - S;
        cooldownEnd[agent] = block.timestamp + COOLDOWN;
        if (bounty > 0) bondToken.safeTransfer(msg.sender, bounty);
        if (restitution > 0) bondToken.safeTransfer(m.owner(), restitution);
        emit Slashed(agent, mandate, S, bounty, restitution, proofHash);
    }
}
