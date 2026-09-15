// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITaxLotLedger — onchain HIFO tax-lot accounting (Stylus engine; Solidity twin is ABI-identical)
/// @dev Units: `qty` in token base units (18dp for Robinhood Stock Tokens); `costBasis` = total USDC (6dp)
///      paid for the lot; `markPrice` = USDC (6dp) per 1e18 base units. value = qty * markPrice / 1e18.
interface ITaxLotLedger {
    event LotRecorded(
        address indexed owner,
        address indexed asset,
        uint64 indexed lotId,
        uint256 qty,
        uint256 costBasis
    );
    event LotsRealized(
        address indexed owner,
        address indexed asset,
        uint64[] lotIds,
        uint256 sellQty,
        int256 realizedLoss
    );

    error NotMandate();
    error ZeroQty();
    error InsufficientOpenQty(uint256 requested, uint256 available);
    error SelectionMismatch();

    function recordLot(address owner, address asset, uint256 qty, uint256 costBasis)
        external
        returns (uint64 lotId);
    function computeHarvest(address owner, address asset, uint256 sellQty, uint256 markPrice)
        external
        view
        returns (uint64[] memory lotIds, int256 realizedLoss);
    function realize(
        address owner,
        address asset,
        uint256 sellQty,
        uint64[] calldata lotIds,
        uint256 markPrice
    ) external returns (int256 realizedLoss);
    function unrealizedLoss(address owner, address asset, uint256 markPrice)
        external
        view
        returns (int256);
    function getOpenLots(address owner, address asset)
        external
        view
        returns (
            uint64[] memory ids,
            uint256[] memory qty,
            uint256[] memory basis,
            uint256[] memory acquiredAt
        );
    function openLotCount(address owner, address asset) external view returns (uint256);
    function openQty(address owner, address asset) external view returns (uint256);
}
