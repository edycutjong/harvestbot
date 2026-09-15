// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HarvestMandate} from "../src/HarvestMandate.sol";

/// @notice Builds and signs a HarvestDecision envelope with the agent key — no chain writes.
///         The lot selection is passed in (from `computeHarvest` on the live ledger); the mandate
///         will recompute it anyway (INV-2). Output: hex envelope on stdout + `ENVELOPE_OUT` file.
///
/// env: AGENT_PK, SELL, BUY, SELL_QTY, LOT_IDS (comma list), NONCE, DEADLINE, RATIONALE (string), ENVELOPE_OUT
contract EnvelopeScript is Script {
    function run() external {
        string memory d =
            vm.readFile(string.concat("../deployments/", vm.toString(block.chainid), ".json"));
        HarvestMandate mandate = HarvestMandate(vm.parseJsonAddress(d, ".mandate"));
        address owner = vm.parseJsonAddress(d, ".owner");

        uint256[] memory raw = vm.envUint("LOT_IDS", ",");
        uint64[] memory ids = new uint64[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) {
            ids[i] = uint64(raw[i]);
        }

        HarvestMandate.HarvestDecision memory dec = HarvestMandate.HarvestDecision({
            owner: owner,
            sellAsset: vm.envAddress("SELL"),
            buyAsset: vm.envAddress("BUY"),
            maxSellQty: vm.envUint("SELL_QTY"),
            lotSelection: keccak256(abi.encodePacked(ids)),
            rationaleHash: keccak256(bytes(vm.envString("RATIONALE"))),
            nonce: vm.envUint("NONCE"),
            deadline: vm.envUint("DEADLINE")
        });

        bytes32 digest = mandate.hashDecision(dec);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(vm.envUint("AGENT_PK"), digest);
        bytes memory env = abi.encode(dec, ids, abi.encodePacked(r, s, v));

        vm.writeFile(vm.envString("ENVELOPE_OUT"), vm.toString(env));
        console.log("digest    ", vm.toString(digest));
        console.log("envelope ->", vm.envString("ENVELOPE_OUT"));
    }
}
