// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITaxLotLedger} from "./interfaces/ITaxLotLedger.sol";
import {IWashSaleGuard} from "./interfaces/IWashSaleGuard.sol";
import {ISubstituteMap} from "./interfaces/ISubstituteMap.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ISwap} from "./interfaces/ISwap.sol";

/// @title HarvestMandate — owner-custody vault that lets a bounded agent harvest tax losses
/// @notice The owner deposits Stock Tokens (each deposit is a tax lot). The agent — reachable ONLY
///         through the ExecutionRouter — can propose a harvest. The mandate re-validates everything
///         from scratch (signature, nonce, deadline, substitute map, wash-sale window, HIFO selection,
///         realized loss at the oracle mark) and either executes the rotation or reverts.
///         There is no agent-reachable path that moves assets out of the vault (INV-1).
contract HarvestMandate is Ownable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    // keccak256("HarvestDecision(address owner,address sellAsset,address buyAsset,uint256 maxSellQty,bytes32 lotSelection,bytes32 rationaleHash,uint256 nonce,uint256 deadline)")
    bytes32 public constant DECISION_TYPEHASH = keccak256(
        "HarvestDecision(address owner,address sellAsset,address buyAsset,uint256 maxSellQty,bytes32 lotSelection,bytes32 rationaleHash,uint256 nonce,uint256 deadline)"
    );
    uint256 internal constant QTY_UNIT = 1e18;

    struct HarvestDecision {
        address owner;
        address sellAsset;
        address buyAsset;
        uint256 maxSellQty;
        bytes32 lotSelection; // keccak256(abi.encodePacked(uint64[] lotIds))
        bytes32 rationaleHash; // keccak256 of the canonical rationale JSON (committed in-repo)
        uint256 nonce;
        uint256 deadline;
    }

    ITaxLotLedger public immutable ledger;
    IWashSaleGuard public immutable guard;
    ISubstituteMap public immutable subMap;
    IPriceOracle public immutable oracle;
    ISwap public immutable swap;
    address public immutable router;

    address public agentKey;
    mapping(uint256 => bool) public usedNonce;
    mapping(address => uint256) public holdings;
    address[] internal _assets;
    mapping(address => bool) internal _isAsset;

    event Deposited(address indexed asset, uint256 qty, uint256 costBasis, uint64 lotId);
    event Withdrawn(address indexed asset, uint256 qty, address to);
    event AgentKeySet(address indexed agentKey);
    event HarvestReport(
        address indexed owner,
        address indexed sellAsset,
        address indexed buyAsset,
        uint64[] lotIds,
        int256 realizedLoss,
        bytes32 rationaleHash,
        uint256 nonce,
        uint64 newLotId,
        uint256 boughtQty
    );

    error NotRouter();
    error ZeroAddress();
    error BadSignature(address recovered);
    error NonceUsed(uint256 nonce);
    error Expired(uint256 deadline);
    error WrongOwner(address owner);
    error OffMapSubstitute(address sellAsset, address buyAsset);
    error SelectionMismatch(bytes32 expected, bytes32 got);
    error NoLossToHarvest(int256 realized);
    error LossMismatch(int256 computed, int256 realized);
    error InsufficientHoldings(address asset, uint256 have, uint256 want);

    constructor(
        address initialOwner,
        ITaxLotLedger ledger_,
        IWashSaleGuard guard_,
        ISubstituteMap subMap_,
        IPriceOracle oracle_,
        ISwap swap_,
        address router_
    ) Ownable(initialOwner) EIP712("HarvestBot", "1") {
        ledger = ledger_;
        guard = guard_;
        subMap = subMap_;
        oracle = oracle_;
        swap = swap_;
        if (router_ == address(0)) revert ZeroAddress();
        router = router_;
    }

    // ── owner custody (never reachable by the agent) ─────────────────────────

    /// @notice Deposit `qty` of `asset` bought for `costBasis` USDC (6dp). Records one tax lot.
    function deposit(address asset, uint256 qty, uint256 costBasis)
        external
        onlyOwner
        nonReentrant
        returns (uint64 lotId)
    {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), qty);
        holdings[asset] += qty;
        _track(asset);
        lotId = ledger.recordLot(owner(), asset, qty, costBasis);
        emit Deposited(asset, qty, costBasis, lotId);
    }

    function withdraw(address asset, uint256 qty, address to) external onlyOwner nonReentrant {
        uint256 have = holdings[asset];
        if (qty > have) revert InsufficientHoldings(asset, have, qty);
        holdings[asset] = have - qty;
        IERC20(asset).safeTransfer(to, qty);
        emit Withdrawn(asset, qty, to);
    }

    function setAgentKey(address agentKey_) external onlyOwner {
        if (agentKey_ == address(0)) revert ZeroAddress();
        agentKey = agentKey_;
        emit AgentKeySet(agentKey_);
    }

    // ── agent entrypoint (router only) ───────────────────────────────────────

    /// @notice Execute a signed HarvestDecision. Every claim in the envelope is recomputed here.
    /// @param signedEnvelope abi.encode(HarvestDecision, uint64[] lotIds, bytes signature)
    function proposeHarvest(bytes calldata signedEnvelope)
        external
        nonReentrant
        returns (int256 realizedLoss)
    {
        if (msg.sender != router) revert NotRouter();

        (HarvestDecision memory d, uint64[] memory lotIds, bytes memory sig) =
            abi.decode(signedEnvelope, (HarvestDecision, uint64[], bytes));

        _authenticate(d, sig);

        // INV-4 — on-map only
        if (!subMap.isSubstitute(d.sellAsset, d.buyAsset)) {
            revert OffMapSubstitute(d.sellAsset, d.buyAsset);
        }
        // INV-3 — the asset we rotate INTO must not be inside a wash-sale window
        guard.assertBuyAllowed(d.owner, d.buyAsset);

        uint256 mark = oracle.price(d.sellAsset);
        uint64[] memory ids;
        (ids, realizedLoss) = _realizeChecked(d, lotIds, mark);
        (uint64 newLotId, uint256 bought) = _rotate(d, mark);

        // INV-3 — start the 30-day clock on what we sold
        guard.openWindow(d.owner, d.sellAsset, block.timestamp);

        emit HarvestReport(
            d.owner,
            d.sellAsset,
            d.buyAsset,
            ids,
            realizedLoss,
            d.rationaleHash,
            d.nonce,
            newLotId,
            bought
        );
    }

    /// @dev INV-5 — authenticity, replay, freshness, ownership.
    function _authenticate(HarvestDecision memory d, bytes memory sig) internal {
        address signer = ECDSA.recover(hashDecision(d), sig);
        if (signer != agentKey) revert BadSignature(signer);
        if (usedNonce[d.nonce]) revert NonceUsed(d.nonce);
        if (block.timestamp > d.deadline) revert Expired(d.deadline);
        if (d.owner != owner()) revert WrongOwner(d.owner);
        usedNonce[d.nonce] = true;
    }

    /// @dev INV-2 — the contract's own HIFO at the oracle mark must equal the agent's selection,
    ///      the result must be a loss, and `realize` must reproduce `computeHarvest` exactly.
    function _realizeChecked(HarvestDecision memory d, uint64[] memory lotIds, uint256 mark)
        internal
        returns (uint64[] memory ids, int256 realizedLoss)
    {
        int256 loss;
        (ids, loss) = ledger.computeHarvest(d.owner, d.sellAsset, d.maxSellQty, mark);
        bytes32 sel = keccak256(abi.encodePacked(ids));
        if (sel != d.lotSelection) revert SelectionMismatch(sel, d.lotSelection);
        if (loss >= 0) revert NoLossToHarvest(loss);
        realizedLoss = ledger.realize(d.owner, d.sellAsset, d.maxSellQty, lotIds, mark);
        if (realizedLoss != loss) revert LossMismatch(loss, realizedLoss);
    }

    /// @dev Rotation — assets never leave the vault, they change ticker. The new lot's basis is the
    ///      proceeds of the sale at the mark.
    function _rotate(HarvestDecision memory d, uint256 mark)
        internal
        returns (uint64 newLotId, uint256 bought)
    {
        uint256 have = holdings[d.sellAsset];
        if (d.maxSellQty > have) revert InsufficientHoldings(d.sellAsset, have, d.maxSellQty);
        holdings[d.sellAsset] = have - d.maxSellQty;
        IERC20(d.sellAsset).forceApprove(address(swap), d.maxSellQty);
        bought = swap.swapExactIn(d.sellAsset, d.buyAsset, d.maxSellQty, address(this));
        holdings[d.buyAsset] += bought;
        _track(d.buyAsset);
        newLotId = ledger.recordLot(d.owner, d.buyAsset, bought, d.maxSellQty * mark / QTY_UNIT);
    }

    // ── views ────────────────────────────────────────────────────────────────

    function hashDecision(HarvestDecision memory d) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    DECISION_TYPEHASH,
                    d.owner,
                    d.sellAsset,
                    d.buyAsset,
                    d.maxSellQty,
                    d.lotSelection,
                    d.rationaleHash,
                    d.nonce,
                    d.deadline
                )
            )
        );
    }

    /// @notice Decode + recover the signer of an envelope without executing it (used by AgentBond.challenge).
    function recoverEnvelope(bytes calldata signedEnvelope)
        external
        view
        returns (HarvestDecision memory d, address signer)
    {
        bytes memory sig;
        (d,, sig) = abi.decode(signedEnvelope, (HarvestDecision, uint64[], bytes));
        signer = ECDSA.recover(hashDecision(d), sig);
    }

    /// @notice Assets under management in USDC (6dp) at the oracle marks.
    function aumUsd() external view returns (uint256 total) {
        for (uint256 i = 0; i < _assets.length; i++) {
            uint256 h = holdings[_assets[i]];
            if (h == 0) continue;
            total += h * oracle.price(_assets[i]) / QTY_UNIT;
        }
    }

    function assets() external view returns (address[] memory) {
        return _assets;
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _track(address asset) internal {
        if (!_isAsset[asset]) {
            _isAsset[asset] = true;
            _assets.push(asset);
        }
    }
}
