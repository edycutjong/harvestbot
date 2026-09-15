// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ITaxLotLedger} from "./interfaces/ITaxLotLedger.sol";

/// @title TaxLotLedger — Solidity twin of the Stylus HIFO tax-lot engine
/// @notice Append-only lot ledger with specific-lot (HIFO) identification, partial-lot proration and
///         deterministic realized-loss computation. Field-identical to the Stylus contract so the two
///         can be gas-benchmarked against each other on the same inputs.
/// @dev HIFO ranks open lots by basis-per-unit descending (cross-multiplied, no division). The scan is
///      O(n·k) for n open lots and k picks; the demo bounds n at 64.
contract TaxLotLedger is ITaxLotLedger, Ownable {
    uint256 internal constant QTY_UNIT = 1e18;

    struct Lot {
        uint256 qty; // remaining base units
        uint256 costBasis; // remaining USDC (6dp) basis for `qty`
        uint256 acquiredAt; // block.timestamp of acquisition
        bool open;
    }

    mapping(address owner => mapping(address asset => Lot[])) internal _lots;
    mapping(address owner => mapping(address asset => uint256)) internal _openCount;
    mapping(address owner => mapping(address asset => uint256)) internal _openQty;

    address public mandate;

    event MandateSet(address indexed mandate);

    error MandateAlreadySet();
    error ZeroAddress();

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice One-shot wiring: the mandate is deployed after the ledger and bound once.
    function setMandate(address mandate_) external onlyOwner {
        if (mandate != address(0)) revert MandateAlreadySet();
        if (mandate_ == address(0)) revert ZeroAddress();
        mandate = mandate_;
        emit MandateSet(mandate_);
    }

    modifier onlyMandate() {
        if (msg.sender != mandate) revert NotMandate();
        _;
    }

    // ── writes (mandate only) ────────────────────────────────────────────────

    function recordLot(address owner, address asset, uint256 qty, uint256 costBasis)
        external
        onlyMandate
        returns (uint64 lotId)
    {
        if (qty == 0) revert ZeroQty();
        Lot[] storage lots = _lots[owner][asset];
        lotId = uint64(lots.length);
        lots.push(Lot({qty: qty, costBasis: costBasis, acquiredAt: block.timestamp, open: true}));
        _openCount[owner][asset] += 1;
        _openQty[owner][asset] += qty;
        emit LotRecorded(owner, asset, lotId, qty, costBasis);
    }

    /// @inheritdoc ITaxLotLedger
    /// @dev INV-2: recomputes the HIFO selection from scratch and reverts if `lotIds` differs.
    function realize(
        address owner,
        address asset,
        uint256 sellQty,
        uint64[] calldata lotIds,
        uint256 markPrice
    ) external onlyMandate returns (int256 realizedLoss) {
        (uint64[] memory expected, int256 loss) = _computeHarvest(owner, asset, sellQty, markPrice);
        if (expected.length != lotIds.length) revert SelectionMismatch();
        for (uint256 i = 0; i < expected.length; i++) {
            if (expected[i] != lotIds[i]) revert SelectionMismatch();
        }

        Lot[] storage lots = _lots[owner][asset];
        uint256 remaining = sellQty;
        for (uint256 i = 0; i < expected.length; i++) {
            Lot storage lot = lots[expected[i]];
            if (lot.qty <= remaining) {
                remaining -= lot.qty;
                lot.qty = 0;
                lot.costBasis = 0;
                lot.open = false;
                _openCount[owner][asset] -= 1;
            } else {
                // partial: prorate the basis, keep the lot open
                uint256 basisOut = lot.costBasis * remaining / lot.qty;
                lot.costBasis -= basisOut;
                lot.qty -= remaining;
                remaining = 0;
            }
        }
        _openQty[owner][asset] -= sellQty;
        emit LotsRealized(owner, asset, expected, sellQty, loss);
        return loss;
    }

    // ── views ────────────────────────────────────────────────────────────────

    function computeHarvest(address owner, address asset, uint256 sellQty, uint256 markPrice)
        external
        view
        returns (uint64[] memory lotIds, int256 realizedLoss)
    {
        return _computeHarvest(owner, asset, sellQty, markPrice);
    }

    function unrealizedLoss(address owner, address asset, uint256 markPrice)
        external
        view
        returns (int256 total)
    {
        Lot[] storage lots = _lots[owner][asset];
        for (uint256 i = 0; i < lots.length; i++) {
            if (!lots[i].open) continue;
            total += int256(lots[i].qty * markPrice / QTY_UNIT) - int256(lots[i].costBasis);
        }
    }

    function getOpenLots(address owner, address asset)
        external
        view
        returns (
            uint64[] memory ids,
            uint256[] memory qty,
            uint256[] memory basis,
            uint256[] memory acquiredAt
        )
    {
        Lot[] storage lots = _lots[owner][asset];
        uint256 n = _openCount[owner][asset];
        ids = new uint64[](n);
        qty = new uint256[](n);
        basis = new uint256[](n);
        acquiredAt = new uint256[](n);
        uint256 j;
        for (uint256 i = 0; i < lots.length; i++) {
            if (!lots[i].open) continue;
            ids[j] = uint64(i);
            qty[j] = lots[i].qty;
            basis[j] = lots[i].costBasis;
            acquiredAt[j] = lots[i].acquiredAt;
            j++;
        }
    }

    function openLotCount(address owner, address asset) external view returns (uint256) {
        return _openCount[owner][asset];
    }

    function openQty(address owner, address asset) external view returns (uint256) {
        return _openQty[owner][asset];
    }

    function lotCount(address owner, address asset) external view returns (uint256) {
        return _lots[owner][asset].length;
    }

    function lotAt(address owner, address asset, uint64 lotId) external view returns (Lot memory) {
        return _lots[owner][asset][lotId];
    }

    // ── HIFO core ────────────────────────────────────────────────────────────

    /// @dev Specific-lot identification, highest basis-per-unit first. The final lot is prorated.
    ///      realizedLoss = Σ (markPrice·q_i/1e18 − basis_i) over the taken quantity; negative = loss.
    function _computeHarvest(address owner, address asset, uint256 sellQty, uint256 markPrice)
        internal
        view
        returns (uint64[] memory lotIds, int256 realizedLoss)
    {
        if (sellQty == 0) revert ZeroQty();
        uint256 available = _openQty[owner][asset];
        if (sellQty > available) revert InsufficientOpenQty(sellQty, available);

        Lot[] storage lots = _lots[owner][asset];
        uint256 n = lots.length;
        bool[] memory taken = new bool[](n);
        uint64[] memory picks = new uint64[](_openCount[owner][asset]);
        uint256 k;
        uint256 remaining = sellQty;

        while (remaining > 0) {
            // select the open, untaken lot with the highest basis/qty
            uint256 best = type(uint256).max;
            for (uint256 i = 0; i < n; i++) {
                if (!lots[i].open || taken[i]) continue;
                if (best == type(uint256).max) {
                    best = i;
                    continue;
                }
                // lots[i].basis/qty > lots[best].basis/qty  ⇔  basis_i·qty_best > basis_best·qty_i
                if (lots[i].costBasis * lots[best].qty > lots[best].costBasis * lots[i].qty) {
                    best = i;
                }
            }
            taken[best] = true;
            picks[k++] = uint64(best);

            Lot storage lot = lots[best];
            uint256 q = lot.qty <= remaining ? lot.qty : remaining;
            uint256 basisOut = q == lot.qty ? lot.costBasis : lot.costBasis * q / lot.qty;
            realizedLoss += int256(q * markPrice / QTY_UNIT) - int256(basisOut);
            remaining -= q;
        }

        lotIds = new uint64[](k);
        for (uint256 i = 0; i < k; i++) {
            lotIds[i] = picks[i];
        }
    }
}
