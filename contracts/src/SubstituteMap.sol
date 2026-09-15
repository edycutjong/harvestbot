// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISubstituteMap} from "./interfaces/ISubstituteMap.sol";

/// @title SubstituteMap — curated rotations and "substantially identical" clusters
/// @notice Two relations, both symmetric and owner-curated:
///         - `pair`: sanctioned harvest rotations (sell A → buy B keeps market exposure).
///         - `identical`: assets the wash-sale rule treats as the same security (blocked together).
///         The curation is a disclosed owner risk — this is not an oracle judgment.
contract SubstituteMap is ISubstituteMap, Ownable {
    mapping(address => mapping(address => bool)) internal _pair;
    mapping(address => address[]) internal _subs;
    mapping(address => mapping(address => bool)) internal _subListed; // membership in _subs, independent of the flag
    mapping(address => mapping(address => bool)) internal _identical;
    mapping(address => address[]) internal _cluster;
    mapping(address => mapping(address => bool)) internal _clusterListed;

    error SelfPair();

    constructor(address initialOwner) Ownable(initialOwner) {}

    function isSubstitute(address sell, address buy) external view returns (bool) {
        return _pair[sell][buy];
    }

    function substitutesOf(address asset) external view returns (address[] memory out) {
        address[] storage all = _subs[asset];
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            if (_pair[asset][all[i]]) n++;
        }
        out = new address[](n);
        uint256 j;
        for (uint256 i = 0; i < all.length; i++) {
            if (_pair[asset][all[i]]) out[j++] = all[i];
        }
    }

    function setPair(address a, address b, bool allowed) external onlyOwner {
        if (a == b) revert SelfPair();
        if (!_subListed[a][b]) {
            // list once; the flag toggles freely afterwards (regression: re-enable used to duplicate)
            _subListed[a][b] = true;
            _subListed[b][a] = true;
            _subs[a].push(b);
            _subs[b].push(a);
        }
        _pair[a][b] = allowed;
        _pair[b][a] = allowed;
        emit PairSet(a, b, allowed);
    }

    function setIdentical(address a, address b, bool identical) external onlyOwner {
        if (a == b) revert SelfPair();
        if (!_clusterListed[a][b]) {
            _clusterListed[a][b] = true;
            _clusterListed[b][a] = true;
            _cluster[a].push(b);
            _cluster[b].push(a);
        }
        _identical[a][b] = identical;
        _identical[b][a] = identical;
        emit IdenticalSet(a, b, identical);
    }

    /// @notice `asset` itself plus every asset currently marked substantially identical to it.
    function identicalCluster(address asset) external view returns (address[] memory out) {
        address[] storage all = _cluster[asset];
        uint256 n = 1;
        for (uint256 i = 0; i < all.length; i++) {
            if (_identical[asset][all[i]]) n++;
        }
        out = new address[](n);
        out[0] = asset;
        uint256 j = 1;
        for (uint256 i = 0; i < all.length; i++) {
            if (_identical[asset][all[i]]) out[j++] = all[i];
        }
    }
}
