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
        address owner = msg.sender;
        address agent = vm.envAddress("AGENT_ADDRESS");
        address sell = vm.envAddress("ASSET_SELL");
        address buy = vm.envAddress("ASSET_BUY");
        address offmap = vm.envAddress("ASSET_OFFMAP");
        address ledgerAddr = vm.envOr("LEDGER", address(0));

        vm.startBroadcast();

        MockUSDC usdc = new MockUSDC();
        MockOracle oracle = new MockOracle(owner);
        MockSwap swap = new MockSwap(IPriceOracle(address(oracle)));
        SubstituteMap subMap = new SubstituteMap(owner);
        WashSaleGuard guard = new WashSaleGuard(owner, subMap);
        ExecutionRouter router = new ExecutionRouter(owner);

        bool stylus = ledgerAddr != address(0);
        if (!stylus) {
            ledgerAddr = address(new TaxLotLedger(owner));
        }

        HarvestMandate mandate = new HarvestMandate(
            owner,
            ITaxLotLedger(ledgerAddr),
            guard,
            subMap,
            IPriceOracle(address(oracle)),
            ISwap(address(swap)),
            address(router)
        );
        AgentBond bond = new AgentBond(IERC20(address(usdc)));

        // wiring — identical ABI whether the ledger is Stylus or Solidity. Forge's local EVM cannot
        // simulate a Stylus (WASM) call, so for the Stylus ledger `setMandate` is sent with `cast`
        // right after this script (see Makefile `deploy-robinhood`).
        if (!stylus) ITaxLotLedgerAdmin(ledgerAddr).setMandate(address(mandate));
        guard.setMandate(address(mandate));
        subMap.setPair(sell, buy, true);
        oracle.setPrice(sell, vm.envUint("MARK_SELL"));
        oracle.setPrice(buy, vm.envUint("MARK_BUY"));
        oracle.setPrice(offmap, vm.envUint("MARK_OFFMAP"));
        mandate.setAgentKey(agent);
        router.setPolicy(
            agent, address(mandate), HarvestMandate.proposeHarvest.selector, uint64(block.timestamp + 90 days), 20
        );

        vm.stopBroadcast();

        o = Out({
            owner: owner,
            agent: agent,
            ledger: ledgerAddr,
            stylus: stylus,
            subMap: address(subMap),
            guard: address(guard),
            router: address(router),
            mandate: address(mandate),
            bond: address(bond),
            usdc: address(usdc),
            oracle: address(oracle),
            swap: address(swap)
        });
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
