// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HarvestMandate} from "../src/HarvestMandate.sol";
import {AgentBond} from "../src/AgentBond.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Seeds the deployed mandate with the demo portfolio shape (specs/seed-data.md §2.1b) at
///         whatever scale the wallet actually holds: 64 lots, basis ramp $380 → $455 per share.
///         Then funds the MOCK swap with the buy-side token and stakes the agent's bond.
///
/// env: SEED_TOTAL_QTY (base units of ASSET_SELL to deposit across 64 lots),
///      SWAP_LIQ_QTY (base units of ASSET_BUY to transfer to the swap), AGENT_PK, BOND_AMOUNT (6dp)
contract SeedScript is Script {
    uint256 constant LOTS = 64;
    uint256 constant USD = 1e6;
    uint256 constant SHARE = 1e18;

    function run() external {
        string memory d = vm.readFile(string.concat("../deployments/", vm.toString(block.chainid), ".json"));
        address mandateAddr = vm.parseJsonAddress(d, ".mandate");
        address bondAddr = vm.parseJsonAddress(d, ".bond");
        address usdcAddr = vm.parseJsonAddress(d, ".usdc");
        address swapAddr = vm.parseJsonAddress(d, ".swap");
        address sell = vm.parseJsonAddress(d, ".assetSell");
        address buy = vm.parseJsonAddress(d, ".assetBuy");

        uint256 total = vm.envUint("SEED_TOTAL_QTY");
        uint256 lotQty = total / LOTS;
        uint256 agentPk = vm.envUint("AGENT_PK");
        uint256 bondAmt = vm.envUint("BOND_AMOUNT");

        HarvestMandate mandate = HarvestMandate(mandateAddr);

        // ── owner: deposit 64 lots + fund the swap + mint the agent's bond token ──
        vm.startBroadcast();
        IERC20(sell).approve(mandateAddr, total);
        for (uint256 i = 0; i < LOTS; i++) {
            uint256 perShare = 380 * USD + (455 * USD - 380 * USD) * i / (LOTS - 1);
            uint256 basis = perShare * lotQty / SHARE;
            mandate.deposit(sell, lotQty, basis);
        }
        IERC20(buy).transfer(swapAddr, vm.envUint("SWAP_LIQ_QTY"));
        MockUSDC(usdcAddr).mint(vm.addr(agentPk), bondAmt);
        vm.stopBroadcast();

        // ── agent: stake the bond ──
        vm.startBroadcast(agentPk);
        MockUSDC(usdcAddr).approve(bondAddr, bondAmt);
        AgentBond(bondAddr).stake(mandateAddr, bondAmt);
        vm.stopBroadcast();

        console.log("lots deposited", LOTS, "lotQty", lotQty);
    }
}
