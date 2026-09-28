// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ITaxLotLedger} from "../interfaces/ITaxLotLedger.sol";

/// @title TaxLotLedgerMemCopy — BENCHMARK ONLY: the fair Solidity baseline for the Stylus ledger
/// @notice Same ABI, storage layout, `recordLot` semantics and integer maths as `TaxLotLedger`, but
///         `computeHarvest` copies the open lots from storage into memory ONCE and runs every HIFO
///         selection pass over memory — the structure of the Rust `compute` in stylus/ledger. The
///         shipped Solidity twin re-reads `lots[i]` from storage on every pass, which inflated the
///         first Stylus-vs-Solidity ratio we published. Nothing in the product (mandate, router,
///         bond) uses this contract; it exists so the engine comparison is apples to apples.
contract TaxLotLedgerMemCopy is ITaxLotLedger, Ownable {
    uint256 internal constant QTY_UNIT = 1e18;

    struct Lot {
        uint256 qty;
        uint256 costBasis;
        uint256 acquiredAt;
        bool open;
    }

    /// @dev The memory image of a lot — the same three fields the Rust `MemLot` carries.
    struct MemLot {
        uint256 qty;
        uint256 basis;
        bool open;
    }

    // slither-disable-next-line uninitialized-state -- mapping of dynamic arrays; populated by push() in recordLot
    mapping(address owner => mapping(address asset => Lot[])) internal _lots;
    mapping(address owner => mapping(address asset => uint256)) internal _openCount;
    mapping(address owner => mapping(address asset => uint256)) internal _openQty;

    address public mandate;

    event MandateSet(address indexed mandate);

    error MandateAlreadySet();
    error ZeroAddress();

    constructor(address initialOwner) Ownable(initialOwner) {}

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

    // ── writes (mandate only) — identical to TaxLotLedger ─────────────────────

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
        uint256 j = 0;
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

    // ── HIFO core, memory-copy structure ─────────────────────────────────────

    /// @dev Same selection rule and integer semantics as TaxLotLedger._computeHarvest (cross-multiplied
    ///      comparison, first-seen wins ties, floor-division proration). Only the data path differs:
    ///      one storage pass → memory, then every selection pass reads memory.
    function _computeHarvest(address owner, address asset, uint256 sellQty, uint256 markPrice)
        internal
        view
        returns (uint64[] memory lotIds, int256 realizedLoss)
    {
        if (sellQty == 0) revert ZeroQty();
        uint256 available = _openQty[owner][asset];
        if (sellQty > available) revert InsufficientOpenQty(sellQty, available);

        MemLot[] memory mem = _load(_lots[owner][asset]);
        bool[] memory taken = new bool[](mem.length);
        uint64[] memory picks = new uint64[](_openCount[owner][asset]);
        uint256 k = 0;
        uint256 remaining = sellQty;

        while (remaining > 0) {
            uint256 best = _best(mem, taken);
            taken[best] = true;
            picks[k++] = uint64(best);

            MemLot memory lot = mem[best];
            uint256 q = lot.qty <= remaining ? lot.qty : remaining;
            uint256 basisOut = q == lot.qty ? lot.basis : lot.basis * q / lot.qty;
            realizedLoss += int256(q * markPrice / QTY_UNIT) - int256(basisOut);
            remaining -= q;
        }

        lotIds = new uint64[](k);
        for (uint256 i = 0; i < k; i++) {
            lotIds[i] = picks[i];
        }
    }

    /// @dev One pass over storage → memory (the Rust `mem: Vec<MemLot>`).
    function _load(Lot[] storage lots) internal view returns (MemLot[] memory mem) {
        uint256 n = lots.length;
        mem = new MemLot[](n);
        for (uint256 i = 0; i < n; i++) {
            Lot storage s = lots[i];
            mem[i] = MemLot({qty: s.qty, basis: s.costBasis, open: s.open});
        }
    }

    /// @dev The open, untaken lot with the highest basis/qty; first seen wins ties. Memory only.
    function _best(MemLot[] memory mem, bool[] memory taken) internal pure returns (uint256 best) {
        best = type(uint256).max;
        for (uint256 i = 0; i < mem.length; i++) {
            if (!mem[i].open || taken[i]) continue;
            if (best == type(uint256).max) {
                best = i;
                continue;
            }
            // basis_i/qty_i > basis_b/qty_b  ⇔  basis_i·qty_b > basis_b·qty_i
            if (mem[i].basis * mem[best].qty > mem[best].basis * mem[i].qty) {
                best = i;
            }
        }
    }
}
