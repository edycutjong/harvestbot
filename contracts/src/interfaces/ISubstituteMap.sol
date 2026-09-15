// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISubstituteMap {
    event PairSet(address indexed a, address indexed b, bool allowed);
    event IdenticalSet(address indexed a, address indexed b, bool identical);

    function isSubstitute(address sell, address buy) external view returns (bool);
    function substitutesOf(address asset) external view returns (address[] memory);
    function setPair(address a, address b, bool allowed) external;
    function setIdentical(address a, address b, bool identical) external;
    function identicalCluster(address asset) external view returns (address[] memory);
}
