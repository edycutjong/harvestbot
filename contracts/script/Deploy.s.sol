// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TaxLotLedger} from "../src/TaxLotLedger.sol";
import {SubstituteMap} from "../src/SubstituteMap.sol";
import {WashSaleGuard} from "../src/WashSaleGuard.sol";
import {ExecutionRouter} from "../src/ExecutionRouter.sol";
import {HarvestMandate} from "../src/HarvestMandate.sol";
import {AgentBond} from "../src/AgentBond.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {MockSwap} from "../src/mocks/MockSwap.sol";
import {ITaxLotLedger} from "../src/interfaces/ITaxLotLedger.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {ISwap} from "../src/interfaces/ISwap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploys the HarvestBot shell around a ledger and writes `deployments/<chainid>.json`.
///
/// env:
///   LEDGER          — existing ledger address (the Stylus one on Robinhood Chain). If unset, the
///                     Solidity twin is deployed (used on Arbitrum Sepolia for the benchmark).
///   AGENT_ADDRESS   — the agent's session key (separate from the deployer/owner)
///   ASSET_SELL / ASSET_BUY / ASSET_OFFMAP — Stock Token addresses (real faucet tokens on 46630)
///   MARK_SELL / MARK_BUY / MARK_OFFMAP    — MOCK oracle marks, USDC 6dp per share
contract DeployScript is Script {
    struct Out {
        address owner;
        address agent;
        address ledger;
        bool stylus;
        address subMap;
        address guard;
        address router;
        address mandate;
        address bond;
        address usdc;
        address oracle;
        address swap;
    }

    function run() external {
        Out memory o = _deploy();
        _write(o);
        console.log("mandate", o.mandate);
        console.log("bond   ", o.bond);
        console.log("router ", o.router);
    }

    function _deploy() internal returns (Out memory o) {
        // Every handle is written straight into `o` (memory) rather than held as a local: the legacy
        // (non-IR) pipeline used by `forge build` / `forge coverage` otherwise runs out of stack.
        o.owner = msg.sender;
        o.agent = vm.envAddress("AGENT_ADDRESS");
        o.ledger = vm.envOr("LEDGER", address(0));
        o.stylus = o.ledger != address(0);

        vm.startBroadcast();

        o.usdc = address(new MockUSDC());
        o.oracle = address(new MockOracle(o.owner));
        o.swap = address(new MockSwap(IPriceOracle(o.oracle)));
        o.subMap = address(new SubstituteMap(o.owner));
        o.guard = address(new WashSaleGuard(o.owner, SubstituteMap(o.subMap)));
        o.router = address(new ExecutionRouter(o.owner));
        if (!o.stylus) o.ledger = address(new TaxLotLedger(o.owner));

        o.mandate = address(
            new HarvestMandate(
                o.owner,
                ITaxLotLedger(o.ledger),
                WashSaleGuard(o.guard),
                SubstituteMap(o.subMap),
                IPriceOracle(o.oracle),
                ISwap(o.swap),
                o.router
            )
        );
        o.bond = address(new AgentBond(IERC20(o.usdc)));

        _wire(o);

        vm.stopBroadcast();
    }

    /// @dev Wiring — identical ABI whether the ledger is Stylus or Solidity. Forge's local EVM cannot
    ///      simulate a Stylus (WASM) call, so for the Stylus ledger `setMandate` is sent with `cast`
    ///      right after this script.
    function _wire(Out memory o) internal {
        address sell = vm.envAddress("ASSET_SELL");
        address buy = vm.envAddress("ASSET_BUY");
        if (!o.stylus) ITaxLotLedgerAdmin(o.ledger).setMandate(o.mandate);
        WashSaleGuard(o.guard).setMandate(o.mandate);
        SubstituteMap(o.subMap).setPair(sell, buy, true);
        MockOracle(o.oracle).setPrice(sell, vm.envUint("MARK_SELL"));
        MockOracle(o.oracle).setPrice(buy, vm.envUint("MARK_BUY"));
        MockOracle(o.oracle).setPrice(vm.envAddress("ASSET_OFFMAP"), vm.envUint("MARK_OFFMAP"));
        HarvestMandate(o.mandate).setAgentKey(o.agent);
        ExecutionRouter(o.router)
            .setPolicy(
                o.agent,
                o.mandate,
                HarvestMandate.proposeHarvest.selector,
                uint64(block.timestamp + 90 days),
                20
            );
    }

    function _write(Out memory o) internal {
        string memory j = "d";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeAddress(j, "owner", o.owner);
        vm.serializeAddress(j, "agent", o.agent);
        vm.serializeAddress(j, "ledger", o.ledger);
        vm.serializeString(j, "ledgerKind", o.stylus ? "stylus" : "solidity");
        vm.serializeAddress(j, "subMap", o.subMap);
        vm.serializeAddress(j, "guard", o.guard);
        vm.serializeAddress(j, "router", o.router);
        vm.serializeAddress(j, "mandate", o.mandate);
        vm.serializeAddress(j, "bond", o.bond);
        vm.serializeAddress(j, "usdc", o.usdc);
        vm.serializeAddress(j, "oracle", o.oracle);
        vm.serializeAddress(j, "swap", o.swap);
        vm.serializeAddress(j, "assetSell", vm.envAddress("ASSET_SELL"));
        vm.serializeAddress(j, "assetBuy", vm.envAddress("ASSET_BUY"));
        string memory out = vm.serializeAddress(j, "assetOffmap", vm.envAddress("ASSET_OFFMAP"));
        vm.writeJson(out, string.concat("../deployments/", vm.toString(block.chainid), ".json"));
    }
}

interface ITaxLotLedgerAdmin {
    function setMandate(address) external;
}
