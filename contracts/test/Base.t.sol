// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TaxLotLedger} from "../src/TaxLotLedger.sol";
import {SubstituteMap} from "../src/SubstituteMap.sol";
import {WashSaleGuard} from "../src/WashSaleGuard.sol";
import {ExecutionRouter} from "../src/ExecutionRouter.sol";
import {HarvestMandate} from "../src/HarvestMandate.sol";
import {AgentBond} from "../src/AgentBond.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {MockSwap} from "../src/mocks/MockSwap.sol";
import {ITaxLotLedger} from "../src/interfaces/ITaxLotLedger.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {ISwap} from "../src/interfaces/ISwap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Deploys the whole system with the seed shape from specs/seed-data.md §2.1b:
///      64 lots × 10 shares, basis ramp $380.00 → $455.00, mark $412.30, AMZN ↔ NFLX substitutes,
///      PLTR off-map. Money in USDC 6dp, quantities in 18dp.
abstract contract BaseTest is Test {
    uint256 internal constant USD = 1e6;
    uint256 internal constant SHARE = 1e18;
    uint256 internal constant LOTS = 64;
    uint256 internal constant LOT_QTY = 10 * SHARE;
    uint256 internal constant BASIS_LO = 380 * USD; // per share
    uint256 internal constant BASIS_HI = 455 * USD; // per share
    uint256 internal constant MARK = 412_300_000; // $412.30 per share
    uint256 internal constant BOND = 13_200 * USD; // $13,200.00

    address internal owner = makeAddr("maya");
    uint256 internal agentPk = 0xA6E47;
    address internal agent = vm.addr(agentPk);
    address internal challenger = makeAddr("challenger");
    address internal stranger = makeAddr("stranger");

    MockStockToken internal AMZN;
    MockStockToken internal NFLX;
    MockStockToken internal PLTR;
    MockUSDC internal USDC;
    MockOracle internal oracle;
    MockSwap internal swap;
    TaxLotLedger internal ledger;
    SubstituteMap internal subMap;
    WashSaleGuard internal guard;
    ExecutionRouter internal router;
    HarvestMandate internal mandate;
    AgentBond internal bond;

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        AMZN = new MockStockToken("MOCK Amazon", "mAMZN");
        NFLX = new MockStockToken("MOCK Netflix", "mNFLX");
        PLTR = new MockStockToken("MOCK Palantir", "mPLTR");
        USDC = new MockUSDC();
        oracle = new MockOracle(owner);
        swap = new MockSwap(IPriceOracle(address(oracle)));
        ledger = new TaxLotLedger(owner);
        subMap = new SubstituteMap(owner);
        guard = new WashSaleGuard(owner, subMap);
        router = new ExecutionRouter(owner);
        mandate = new HarvestMandate(
            owner,
            ITaxLotLedger(address(ledger)),
            guard,
            subMap,
            IPriceOracle(address(oracle)),
            ISwap(address(swap)),
            address(router)
        );
        bond = new AgentBond(IERC20(address(USDC)));

        vm.startPrank(owner);
        ledger.setMandate(address(mandate));
        guard.setMandate(address(mandate));
        subMap.setPair(address(AMZN), address(NFLX), true);
        oracle.setPrice(address(AMZN), MARK);
        oracle.setPrice(address(NFLX), 900 * USD);
        oracle.setPrice(address(PLTR), 150 * USD);
        mandate.setAgentKey(agent);
        router.setPolicy(
            agent,
            address(mandate),
            HarvestMandate.proposeHarvest.selector,
            uint64(block.timestamp + 365 days),
            10
        );
        vm.stopPrank();

        // swap liquidity (MOCK venue): plenty of NFLX and PLTR
        NFLX.mint(address(swap), 100_000 * SHARE);
        PLTR.mint(address(swap), 100_000 * SHARE);

        // agent bond
        USDC.mint(agent, BOND);
    }

    // ── seed helpers ─────────────────────────────────────────────────────────

    /// @dev per-share basis for lot i on the deterministic ramp, then × 10 shares
    function basisFor(uint256 i) internal pure returns (uint256) {
        uint256 perShare = BASIS_LO + (BASIS_HI - BASIS_LO) * i / (LOTS - 1);
        return perShare * LOT_QTY / SHARE;
    }

    function seedPortfolio() internal {
        AMZN.mint(owner, LOTS * LOT_QTY);
        vm.startPrank(owner);
        AMZN.approve(address(mandate), type(uint256).max);
        for (uint256 i = 0; i < LOTS; i++) {
            mandate.deposit(address(AMZN), LOT_QTY, basisFor(i));
            vm.warp(block.timestamp + 1 hours); // distinct acquisition times (64 h total)
        }
        vm.stopPrank();
    }

    function stakeBond() internal {
        vm.startPrank(agent);
        USDC.approve(address(bond), BOND);
        bond.stake(address(mandate), BOND);
        vm.stopPrank();
    }

    // ── envelope helpers ─────────────────────────────────────────────────────

    function decision(
        address sell,
        address buy,
        uint256 sellQty,
        uint64[] memory ids,
        uint256 nonce
    ) internal view returns (HarvestMandate.HarvestDecision memory d) {
        d = HarvestMandate.HarvestDecision({
            owner: owner,
            sellAsset: sell,
            buyAsset: buy,
            maxSellQty: sellQty,
            lotSelection: keccak256(abi.encodePacked(ids)),
            rationaleHash: keccak256("rule-v1:hifo"),
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    function sign(HarvestMandate.HarvestDecision memory d, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, mandate.hashDecision(d));
        return abi.encodePacked(r, s, v);
    }

    function envelope(HarvestMandate.HarvestDecision memory d, uint64[] memory ids, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(d, ids, sign(d, pk));
    }

    /// @dev Builds the canonical Beat-1 envelope: HIFO picks for `sellQty` at the oracle mark.
    function harvestEnvelope(uint256 sellQty, uint256 nonce)
        internal
        view
        returns (bytes memory env, uint64[] memory ids, int256 loss)
    {
        (ids, loss) = ledger.computeHarvest(owner, address(AMZN), sellQty, MARK);
        HarvestMandate.HarvestDecision memory d =
            decision(address(AMZN), address(NFLX), sellQty, ids, nonce);
        env = envelope(d, ids, agentPk);
    }
}
