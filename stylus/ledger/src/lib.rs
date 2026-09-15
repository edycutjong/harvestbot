//! HarvestBot `TaxLotLedger` — the Stylus (Rust → WASM) HIFO tax-lot engine.
//!
//! ABI-identical to `contracts/src/TaxLotLedger.sol` so the two can be benchmarked on the same
//! inputs. Units: `qty` in token base units (18dp), `cost_basis` in USDC 6dp (total for the lot),
//! `mark_price` in USDC 6dp per 1e18 base units. `realized_loss` is signed; negative = loss.
//!
//! The HIFO scan reads every open lot into memory once and does the selection there — the
//! part of the algorithm where WASM beats EVM opcodes and where the gas number comes from.

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloc::vec::Vec;
use alloy_primitives::{Address, I256, U256};
use alloy_sol_types::sol;
use stylus_sdk::prelude::*;

const QTY_UNIT: u128 = 1_000_000_000_000_000_000; // 1e18

sol! {
    event LotRecorded(address indexed owner, address indexed asset, uint64 indexed lotId, uint256 qty, uint256 costBasis);
    event LotsRealized(address indexed owner, address indexed asset, uint64[] lotIds, uint256 sellQty, int256 realizedLoss);
    event MandateSet(address indexed mandate);

    error NotMandate();
    error ZeroQty();
    error InsufficientOpenQty(uint256 requested, uint256 available);
    error SelectionMismatch();
    error MandateAlreadySet();
    error ZeroAddress();
    error Unauthorized();
}

#[derive(SolidityError)]
pub enum LedgerError {
    NotMandate(NotMandate),
    ZeroQty(ZeroQty),
    InsufficientOpenQty(InsufficientOpenQty),
    SelectionMismatch(SelectionMismatch),
    MandateAlreadySet(MandateAlreadySet),
    ZeroAddress(ZeroAddress),
    Unauthorized(Unauthorized),
}

impl core::fmt::Debug for LedgerError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        let name = match self {
            LedgerError::NotMandate(_) => "NotMandate",
            LedgerError::ZeroQty(_) => "ZeroQty",
            LedgerError::InsufficientOpenQty(_) => "InsufficientOpenQty",
            LedgerError::SelectionMismatch(_) => "SelectionMismatch",
            LedgerError::MandateAlreadySet(_) => "MandateAlreadySet",
            LedgerError::ZeroAddress(_) => "ZeroAddress",
            LedgerError::Unauthorized(_) => "Unauthorized",
        };
        f.write_str(name)
    }
}

sol_storage! {
    #[entrypoint]
    pub struct TaxLotLedger {
        address owner;
        address mandate;
        mapping(address => mapping(address => Lot[])) lots;
        mapping(address => mapping(address => uint256)) open_count;
        mapping(address => mapping(address => uint256)) open_qty;
    }

    pub struct Lot {
        uint256 qty;
        uint256 cost_basis;
        uint256 acquired_at;
        bool open;
    }
}

/// In-memory copy of a lot for the HIFO scan.
#[derive(Clone, Copy)]
struct MemLot {
    qty: U256,
    basis: U256,
    open: bool,
}

#[public]
impl TaxLotLedger {
    #[constructor]
    pub fn constructor(&mut self, initial_owner: Address) {
        self.owner.set(initial_owner);
    }

    // ── wiring ───────────────────────────────────────────────────────────────

    pub fn owner(&self) -> Address {
        self.owner.get()
    }

    pub fn mandate(&self) -> Address {
        self.mandate.get()
    }

    /// One-shot: bind the mandate that may write to the ledger.
    pub fn set_mandate(&mut self, mandate: Address) -> Result<(), LedgerError> {
        if self.vm().msg_sender() != self.owner.get() {
            return Err(LedgerError::Unauthorized(Unauthorized {}));
        }
        if !self.mandate.get().is_zero() {
            return Err(LedgerError::MandateAlreadySet(MandateAlreadySet {}));
        }
        if mandate.is_zero() {
            return Err(LedgerError::ZeroAddress(ZeroAddress {}));
        }
        self.mandate.set(mandate);
        self.vm().log(MandateSet { mandate });
        Ok(())
    }

    // ── writes (mandate only) ────────────────────────────────────────────────

    pub fn record_lot(
        &mut self,
        owner: Address,
        asset: Address,
        qty: U256,
        cost_basis: U256,
    ) -> Result<u64, LedgerError> {
        self.only_mandate()?;
        if qty.is_zero() {
            return Err(LedgerError::ZeroQty(ZeroQty {}));
        }
        let now = U256::from(self.vm().block_timestamp());
        let mut lots = self.lots.setter(owner);
        let mut lots = lots.setter(asset);
        let lot_id = lots.len() as u64;
        let mut lot = lots.grow();
        lot.qty.set(qty);
        lot.cost_basis.set(cost_basis);
        lot.acquired_at.set(now);
        lot.open.set(true);

        let mut oc = self.open_count.setter(owner);
        let mut oc = oc.setter(asset);
        let v = oc.get() + U256::from(1);
        oc.set(v);
        let mut oq = self.open_qty.setter(owner);
        let mut oq = oq.setter(asset);
        let v = oq.get() + qty;
        oq.set(v);

        self.vm().log(LotRecorded {
            owner,
            asset,
            lotId: lot_id,
            qty,
            costBasis: cost_basis,
        });
        Ok(lot_id)
    }

    /// INV-2: recomputes the HIFO selection and reverts if `lot_ids` differs.
    pub fn realize(
        &mut self,
        owner: Address,
        asset: Address,
        sell_qty: U256,
        lot_ids: Vec<u64>,
        mark_price: U256,
    ) -> Result<I256, LedgerError> {
        self.only_mandate()?;
        let (expected, loss) = self.compute(owner, asset, sell_qty, mark_price)?;
        if expected.len() != lot_ids.len()
            || expected.iter().zip(lot_ids.iter()).any(|(a, b)| a != b)
        {
            return Err(LedgerError::SelectionMismatch(SelectionMismatch {}));
        }

        let mut closed: u64 = 0;
        {
            let mut lots = self.lots.setter(owner);
            let mut lots = lots.setter(asset);
            let mut remaining = sell_qty;
            for id in expected.iter() {
                let mut lot = lots.setter(*id).expect("lot id from compute");
                let q = lot.qty.get();
                if q <= remaining {
                    remaining -= q;
                    lot.qty.set(U256::ZERO);
                    lot.cost_basis.set(U256::ZERO);
                    lot.open.set(false);
                    closed += 1;
                } else {
                    let basis = lot.cost_basis.get();
                    let basis_out = basis * remaining / q;
                    lot.cost_basis.set(basis - basis_out);
                    lot.qty.set(q - remaining);
                    remaining = U256::ZERO;
                }
            }
        }
        let mut oc = self.open_count.setter(owner);
        let mut oc = oc.setter(asset);
        let v = oc.get() - U256::from(closed);
        oc.set(v);
        let mut oq = self.open_qty.setter(owner);
        let mut oq = oq.setter(asset);
        let v = oq.get() - sell_qty;
        oq.set(v);

        self.vm().log(LotsRealized {
            owner,
            asset,
            lotIds: expected,
            sellQty: sell_qty,
            realizedLoss: loss,
        });
        Ok(loss)
    }

    // ── views ────────────────────────────────────────────────────────────────

    pub fn compute_harvest(
        &self,
        owner: Address,
        asset: Address,
        sell_qty: U256,
        mark_price: U256,
    ) -> Result<(Vec<u64>, I256), LedgerError> {
        self.compute(owner, asset, sell_qty, mark_price)
    }

    pub fn unrealized_loss(&self, owner: Address, asset: Address, mark_price: U256) -> I256 {
        let lots = self.lots.get(owner);
        let lots = lots.get(asset);
        let mut total = I256::ZERO;
        for i in 0..lots.len() {
            let lot = lots.get(i).expect("index < len");
            if !lot.open.get() {
                continue;
            }
            total += value_of(lot.qty.get(), mark_price) - to_i(lot.cost_basis.get());
        }
        total
    }

    pub fn get_open_lots(
        &self,
        owner: Address,
        asset: Address,
    ) -> (Vec<u64>, Vec<U256>, Vec<U256>, Vec<U256>) {
        let lots = self.lots.get(owner);
        let lots = lots.get(asset);
        let mut ids = Vec::new();
        let mut qty = Vec::new();
        let mut basis = Vec::new();
        let mut acquired = Vec::new();
        for i in 0..lots.len() {
            let lot = lots.get(i).expect("index < len");
            if !lot.open.get() {
                continue;
            }
            ids.push(i as u64);
            qty.push(lot.qty.get());
            basis.push(lot.cost_basis.get());
            acquired.push(lot.acquired_at.get());
        }
        (ids, qty, basis, acquired)
    }

    pub fn open_lot_count(&self, owner: Address, asset: Address) -> U256 {
        self.open_count.get(owner).get(asset)
    }

    pub fn open_qty(&self, owner: Address, asset: Address) -> U256 {
        self.open_qty.get(owner).get(asset)
    }

    pub fn lot_count(&self, owner: Address, asset: Address) -> U256 {
        U256::from(self.lots.get(owner).get(asset).len())
    }

    /// `(qty, costBasis, acquiredAt, open)` for one lot.
    pub fn lot_at(&self, owner: Address, asset: Address, lot_id: u64) -> (U256, U256, U256, bool) {
        let lots = self.lots.get(owner);
        let lots = lots.get(asset);
        match lots.get(lot_id) {
            Some(lot) => (
                lot.qty.get(),
                lot.cost_basis.get(),
                lot.acquired_at.get(),
                lot.open.get(),
            ),
            None => (U256::ZERO, U256::ZERO, U256::ZERO, false),
        }
    }
}

impl TaxLotLedger {
    fn only_mandate(&self) -> Result<(), LedgerError> {
        if self.vm().msg_sender() != self.mandate.get() {
            return Err(LedgerError::NotMandate(NotMandate {}));
        }
        Ok(())
    }

    /// HIFO specific-lot identification, highest basis-per-unit first; last lot prorated.
    /// Same integer semantics as the Solidity twin (cross-multiplied comparison, floor division).
    fn compute(
        &self,
        owner: Address,
        asset: Address,
        sell_qty: U256,
        mark_price: U256,
    ) -> Result<(Vec<u64>, I256), LedgerError> {
        if sell_qty.is_zero() {
            return Err(LedgerError::ZeroQty(ZeroQty {}));
        }
        let available = self.open_qty.get(owner).get(asset);
        if sell_qty > available {
            return Err(LedgerError::InsufficientOpenQty(InsufficientOpenQty {
                requested: sell_qty,
                available,
            }));
        }

        // one pass over storage → memory
        let lots_s = self.lots.get(owner);
        let lots_s = lots_s.get(asset);
        let n = lots_s.len();
        let mut mem: Vec<MemLot> = Vec::with_capacity(n);
        for i in 0..n {
            let lot = lots_s.get(i).expect("index < len");
            mem.push(MemLot {
                qty: lot.qty.get(),
                basis: lot.cost_basis.get(),
                open: lot.open.get(),
            });
        }

        let mut taken = alloc::vec![false; n];
        let mut picks: Vec<u64> = Vec::new();
        let mut remaining = sell_qty;
        let mut realized = I256::ZERO;

        while !remaining.is_zero() {
            let mut best: Option<usize> = None;
            for (i, l) in mem.iter().enumerate() {
                if !l.open || taken[i] {
                    continue;
                }
                match best {
                    None => best = Some(i),
                    Some(b) => {
                        // basis_i/qty_i > basis_b/qty_b  ⇔  basis_i·qty_b > basis_b·qty_i
                        if l.basis * mem[b].qty > mem[b].basis * l.qty {
                            best = Some(i);
                        }
                    }
                }
            }
            let b = best.expect("open qty covers sell_qty");
            taken[b] = true;
            picks.push(b as u64);
            let lot = mem[b];
            let q = if lot.qty <= remaining {
                lot.qty
            } else {
                remaining
            };
            let basis_out = if q == lot.qty {
                lot.basis
            } else {
                lot.basis * q / lot.qty
            };
            realized += value_of(q, mark_price) - to_i(basis_out);
            remaining -= q;
        }
        Ok((picks, realized))
    }
}

#[inline]
fn value_of(qty: U256, mark_price: U256) -> I256 {
    to_i(qty * mark_price / U256::from(QTY_UNIT))
}

#[inline]
fn to_i(u: U256) -> I256 {
    I256::try_from(u).unwrap_or(I256::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use stylus_sdk::testing::*;

    const USD: u128 = 1_000_000;
    const SHARE: u128 = QTY_UNIT;
    const MARK: u128 = 412_300_000;

    fn basis_for(i: u128) -> U256 {
        let per_share = 380 * USD + (455 * USD - 380 * USD) * i / 63;
        U256::from(per_share * 10)
    }

    fn seeded() -> (TestVM, TaxLotLedger, Address, Address, Address) {
        let vm = TestVM::default();
        let owner = Address::from([0x11; 20]);
        let mandate = Address::from([0x22; 20]);
        let asset = Address::from([0x33; 20]);
        let mut c = TaxLotLedger::from(&vm);
        c.constructor(owner);
        vm.set_sender(owner);
        c.set_mandate(mandate).unwrap();
        vm.set_sender(mandate);
        for i in 0..64u128 {
            c.record_lot(owner, asset, U256::from(10 * SHARE), basis_for(i))
                .unwrap();
        }
        (vm, c, owner, mandate, asset)
    }

    #[test]
    fn seed_scenario_realizes_exactly_minus_3140_dollars() {
        let (_vm, c, owner, _m, asset) = seeded();
        let sell = U256::from(81_728_148_108_628_507_367u128);
        let (ids, loss) = c
            .compute_harvest(owner, asset, sell, U256::from(MARK))
            .unwrap();
        assert_eq!(ids, alloc::vec![63, 62, 61, 60, 59, 58, 57, 56, 55]);
        assert_eq!(loss, I256::try_from(-3_140_000_000i64).unwrap());
    }

    #[test]
    fn realize_closes_eight_lots_and_prorates_the_ninth() {
        let (_vm, mut c, owner, _m, asset) = seeded();
        let sell = U256::from(81_728_148_108_628_507_367u128);
        let (ids, loss) = c
            .compute_harvest(owner, asset, sell, U256::from(MARK))
            .unwrap();
        let realized = c
            .realize(owner, asset, sell, ids, U256::from(MARK))
            .unwrap();
        assert_eq!(realized, loss);
        assert_eq!(c.open_lot_count(owner, asset), U256::from(56));
        assert_eq!(c.open_qty(owner, asset), U256::from(640 * SHARE) - sell);
        let (q, _b, _t, open) = c.lot_at(owner, asset, 55);
        assert!(open);
        assert!(q < U256::from(10 * SHARE));
        let (_q, _b, _t, open63) = c.lot_at(owner, asset, 63);
        assert!(!open63);
    }

    #[test]
    fn tampered_selection_is_rejected() {
        let (_vm, mut c, owner, _m, asset) = seeded();
        let sell = U256::from(10 * SHARE);
        let err = c
            .realize(owner, asset, sell, alloc::vec![0], U256::from(MARK))
            .unwrap_err();
        assert!(matches!(err, LedgerError::SelectionMismatch(_)));
    }

    #[test]
    fn non_mandate_cannot_write() {
        let (vm, mut c, owner, _m, asset) = seeded();
        vm.set_sender(Address::from([0x99; 20]));
        let err = c
            .record_lot(owner, asset, U256::from(SHARE), U256::from(USD))
            .unwrap_err();
        assert!(matches!(err, LedgerError::NotMandate(_)));
    }

    #[test]
    fn over_selling_is_rejected() {
        let (_vm, c, owner, _m, asset) = seeded();
        let err = c
            .compute_harvest(owner, asset, U256::from(641 * SHARE), U256::from(MARK))
            .unwrap_err();
        assert!(matches!(err, LedgerError::InsufficientOpenQty(_)));
    }

    #[test]
    fn mandate_binds_once_and_only_by_owner() {
        let vm = TestVM::default();
        let owner = Address::from([0x11; 20]);
        let mut c = TaxLotLedger::from(&vm);
        c.constructor(owner);
        vm.set_sender(Address::from([0x99; 20]));
        assert!(matches!(
            c.set_mandate(owner).unwrap_err(),
            LedgerError::Unauthorized(_)
        ));
        vm.set_sender(owner);
        assert!(matches!(
            c.set_mandate(Address::ZERO).unwrap_err(),
            LedgerError::ZeroAddress(_)
        ));
        c.set_mandate(Address::from([0x22; 20])).unwrap();
        assert!(matches!(
            c.set_mandate(owner).unwrap_err(),
            LedgerError::MandateAlreadySet(_)
        ));
    }
}
