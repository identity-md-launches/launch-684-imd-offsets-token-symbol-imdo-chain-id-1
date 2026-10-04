# IMD Offsets (IMDO)

IMDO funds regenerative contributions through a public treasury that buys and retires ecological credits on Regen Network. These contracts send fees to that treasury; they do not execute or attest to credit purchases or retirements. Holding IMDO confers no payouts, rewards, yield, staking, or treasury entitlement.

**Delivery status.** The delivery is `src/IMDOFeeHook.sol` (token and hook, no library imports), `script/Deploy.s.sol`, this README and the root `foundry.toml`. The supplied repository had no launch factory implementation or deployment manifest. Revision 2 (2026-10-04) made sells split across several swaps in one transaction be billed on their cumulative size and added the root `foundry.toml` with `bytecode_hash = "none"`. Revision 3 (2026-10-04) answers an independent review with four changes: (1) no single swap is ever charged more than 2% of its own basis, whatever was sold earlier under the same `tx.origin`; (2) the IMDO fee of an exact-output sell is always booked as an ERC-6909 claim and burned by `harvest()`, never taken out of the PoolManager in the middle of the swap; (3) sells are sized against the lower of the one-block-lagged snapshot and the booked reserve just before the swap; (4) the deploy script requires the hook to be bound to exactly the configured pool.

No live deployment or external audit was performed. Factory integration is checked with a model position owner against a real Uniswap v4 PoolManager, not an unspecified production factory.

**Token.** `src/IMDOFeeHook.sol:IMDOToken` has no constructor arguments. It mints exactly **1,000,000 IMDO**, or **1,000,000 × 10^18** base units, once to its deployer. This supply is an implementation choice because the assignment did not specify a quantity. The launch factory must be the deployer. The name is `IMD Offsets`, symbol `IMDO`, and decimals **18**. Transfers and approved `transferFrom` calls move exactly their stated amount. Maximum uint256 allowance is treated as unlimited. Holders can call `burn(uint256)` to destroy only their own balance and reduce total supply. Transfers to the zero address revert; use `burn` deliberately. There is no mint entry point, owner, administrator, tax, blacklist, pause, trading gate, or upgrade mechanism.

**Pool and fee policy.** `IMDOFeeHook(IPoolManager manager, address token)` fixes its manager and token at construction. Treasury **0xb1eC9d1C36974d05eb9889eBf8A150b05791E559**, thresholds, rates, **20,000 ppm** cap, and burning behavior are compile-time constants. The target is **Sepolia, chain ID 11155111**. The pool pairs native ETH, currency0 **address(0)**, with IMDO, currency1. WETH is not the quote asset. Initialization accepts static LP fees **500**, **3,000**, or **10,000 ppm** (**0.05%**, **0.3%**, or **1%**); it rejects zero and dynamic LP fees. The launch configuration selects the tier and tick spacing; the integration model uses **3,000 ppm**, spacing **60**.

Let `C` be the sum of actual IMDO inputs sold by the same `tx.origin` in this transaction, including this swap, and `R` be the sizing reserve: the previous block's token reserve snapshot, or the pool's booked token reserve immediately before this swap when that is lower (see *block snapshot* below). Values are base units, not token display amounts.

| C / R | Sell size in basis points | Hook rate | Fee ppm |
| --- | --- | --- | --- |
| Below 1% | Below 100 | 0% | 0 |
| At least 1%, below 3% | 100–299 | 0.5% | 5,000 |
| At least 3%, below 5% | 300–499 | 1% | 10,000 |
| At least 5% | 500 or more | 2% | 20,000 |

Threshold comparisons preserve fractional basis points: a sell is "at least 1%" when `C >= ceil(R / 100)`, so when `R` is not a multiple of 100 a sell of exactly `floor(R / 100)` base units is still below 1% and free. Zero sold gives zero fee. With positive sales and no previous-block reserve (`R == 0`), the rate is **20,000 ppm**. This covers the initialization block, in which the factory initializes and seeds the pool and trading may already open: there is no previous-block snapshot yet, and the only alternatives, billing at 0% or against the live reserve, would let the launch block be dumped free or let a same-block liquidity addition lower the bracket. The cap is the conservative bound for that one block; from the next block the schedule applies. There is no launch-block trading lock.

Buy/sell classification and sell sizing use the token side of the actual `afterSwap` `BalanceDelta`, including partial fills. A negative IMDO delta is a sell. Buys pay **zero hook fee**, in both exact-input and exact-output modes; the pool's ordinary LP/protocol fees still apply.

For an exact-input sell, the fee is `ceil(gross ETH output × rate / 1,000,000)` wei. It reduces ETH output and goes **directly from PoolManager to the fixed treasury**. For an exact-output sell, v4 permits an after-swap return delta only on the unspecified asset, which is IMDO input: `ceil(actual IMDO input × rate / 1,000,000)` base units are added to input, booked as an ERC-6909 claim held by the hook (`pendingToken`), and **burned** when anyone calls `harvest()`. Until then the IMDO sits in the PoolManager and can go nowhere but the burn. Specified ETH output stays unchanged; this case sends no hook ETH to the treasury. A ceiling rounds up by less than one base unit; the rate itself never exceeds 20,000 ppm.

This follows [OpenZeppelin BaseHookFee's unspecified-currency, positive-return-delta, rounded-up fee and ERC-6909 claim pattern](https://github.com/OpenZeppelin/uniswap-hooks/blob/master/src/fee/BaseHookFee.sol). Because library paths cannot be delivered under this assignment, the source contains minimal ABI-compatible v4 declarations and implements that pattern directly; it does not claim to inherit a vendored OpenZeppelin contract.

**Transaction accumulation and block snapshot.** EIP-1153 transient storage keeps one ledger per `tx.origin` for the current transaction, across routers, recipients, and exact-input/output modes: `sold` (IMDO paid into the pool), `ethBasis` (gross ETH output of exact-input legs), `tokenBasis` (IMDO input of exact-output legs), `ethPaid` and `tokenPaid` (hook fees collected so far on each side). Buys do not reset it. It disappears at transaction end; `cumulativeSold(origin)` and `originLedger(origin)` expose the running values. `tx.origin` groups volume only and never authorizes an action. Different origins and different transactions have separate totals. Bundled smart-account users sharing an origin also share the bracket: `afterSwap` sees the router, not the end user, so a small sell settled after someone else's large sell under the same origin (ERC-4337 bundle, relayer, batch settlement) is billed at the cumulative bracket, up to 2% of its own output instead of 0%. It can never be charged more than that (per-swap cap below).

The fee owed by an origin is the schedule applied to the cumulative size: after every leg the origin owes `ceil(ethBasis × rate(sold) / 1,000,000)` wei and `ceil(tokenBasis × rate(sold) / 1,000,000)` IMDO base units. Each leg collects the current **shortfall** (owed minus already paid), so legs that were free or cheaper when the running total was lower are repriced when a later leg lifts the bracket, **subject to the per-swap cap**.

**Per-swap cap.** No leg is ever charged more than `ceil(its own basis × 20,000 / 1,000,000)`: 2% of its own gross ETH output for an exact-input leg, 2% of its own IMDO input for an exact-output leg. This holds for every swap regardless of what the same origin sold before, so one user's sell can never be consumed, or pushed below its minimum output by more than 2%, to pay for another user's earlier volume. Any shortfall above the cap stays in the transient ledger, is collected by the origin's later sells in the same transaction (each again bounded by its own cap), and is dropped when the transaction ends.

Consequences, for a snapshot reserve `R` and 1,000 IMDO per ETH. One 5% sell with 50 ETH gross output pays 1.0 ETH. 0.99% then 4.01% in one transaction pays 0, then 0.802 ETH (the second leg's cap, 2% of 40.1 ETH); the remaining 0.198 ETH is not collected unless the origin sells again. 0.99% + 1.99% + 2.02% pays 0, then 0.149 ETH (0.5% of 29.8 ETH), then 0.404 ETH (2% of 20.2 ETH). In general the total collected is at least `rate(cumulative at that leg) × that leg's basis` summed over legs (every leg pays at least its own basis at the bracket its cumulative size reached) and at most the schedule on the total. A split therefore can pay less than one sell of the same total, by at most the fee the legs sold *before* the bracket rose would have owed at the higher rate; the hook deliberately does not collect that part from a later swap beyond 2% of that swap, because the later swap may belong to a different user.

A leg can only charge its unspecified currency: ETH on exact-input legs, IMDO on exact-output legs. When the shortfall is on the other side it is converted at the current leg's own realized price (`legEth / legSold` of the settled delta) and collected in the currency the leg can charge, within the same per-swap cap. The conversion uses the price the pool actually gave for that leg; it is not an oracle.

Note for test authors: Foundry clears transient storage between top-level calls made by a test, so multi-leg scenarios must be driven from inside one call (a helper contract that performs all swaps), as on chain within one transaction. `vm.prank(sender, origin)` sets the `tx.origin` the hook sees for that call.

`tokenReserve` is this pool's booked IMDO inventory, including uncollected LP fees. It increases/decreases with actual swap deltas and full liquidity callback deltas, includes donations, and excludes protocol fees measured immediately before and after each swap. Pool-wide manager balances are never used as a reserve oracle. Fee collection removes collected IMDO from the ledger even when the liquidity change is zero. Hook fees and claims are separate from that inventory.

Before the first ledger mutation in a new block, the old ledger becomes `laggedTokenReserve`; it stays fixed for the rest of that block. Idle blocks preserve the same inventory. A sell is sized against `min(laggedTokenReserve, tokenReserve immediately before the swap)`. Liquidity additions, donations, buys, or sells in the current block therefore cannot increase that block's denominator, and tokens parked as liquidity across a block boundary stop counting the moment they are withdrawn, so a seller cannot park IMDO, withdraw it and sell the same IMDO against the inflated snapshot. The lower bound also means liquidity removed, or IMDO bought out of the pool, earlier in the same block makes later sells in that block size against the smaller reserve (never a lower bracket, possibly a higher one). A donation to the manager outside this pool's `donate` operation does not affect it. Inflation that is kept in the pool through a block boundary and through the sell does count: this is a one-block lag, not a time-weighted oracle, and a seller who holds additional IMDO and leaves it deposited (including out of range) for at least a block while selling other IMDO still enlarges the denominator.

**Fee delivery and custody.** A failed ETH transfer, including insufficient manager cash or a treasury that rejects ETH, rolls back that transfer and mints an ERC-6909 fee claim to the hook. The IMDO fee of an exact-output sell is never transferred during the swap: it is always minted as a claim and burned later by `harvest()`. v4 credits an ERC-20 settlement by the manager's balance difference since `sync`, so removing IMDO from the manager mid-swap would under-credit a swapper that pays before swapping (sync, transfer, swap, settle); a claim leaves the manager's balance untouched and every settlement order pays exactly sold + fee. The native ETH fee is unaffected because native settlement is by `msg.value`. These paths preserve normal swap settlement and do not redirect fees to LPs or the caller. Standard pool liquidity, balance, allowance, slippage and gas requirements still apply.

Anyone can call `harvest()` with no reward. It unlocks the manager, redeems at most `pendingETH` to the same treasury, and redeems at most `pendingToken` for burning. Each redemption is atomic. Rejected transfers leave their claims available for a later call; calling while the manager is already unlocked also leaves claims untouched. Harvest does not swap, collect factory fees, change brackets, forward money to its caller, or redeem unsolicited claim transfers. A transient guard protects payment paths. Every hook callback and `unlockCallback` accepts only the immutable manager; `unlockCallback` additionally requires an active harvest. `redeemETH` and `takeAndBurn` accept only self-calls.

The hook has no ETH receive function. Fee handling leaves no fee tokens or ETH in the hook: its only fee holdings are the tracked manager claims (`pendingETH`, `pendingToken`), and the harvest take-and-burn is atomic. As with any address, forced ETH or unsolicited ERC-20/claim transfers cannot be prohibited; those are outside this custody invariant and have no rescue function.

**Factory, LP fees, and swarm.** The factory creates the token, deploys the correctly mined hook, and initializes the attached pool **in one transaction**. `beforeInitialize` binds exactly one ETH/IMDO pool and prevents successful initialization at a mined hook address that has no implementation. Deploying and initializing separately is not supported: an intervening caller could bind the hook first.

The pool's own LP fee is credited by PoolManager to liquidity positions under its existing rules. For the factory-owned position, **the factory receives its accrued LP fees and retains its existing distribution logic and recipients**. Other LP positions retain their own proportional entitlements. Any manager protocol fee continues to the manager's existing protocol-fee accounting. The hook returns zero liquidity adjustment, never overrides the pool fee, and neither claims nor redirects the factory position's fees. The hook's separate **ETH fee goes only to 0xb1eC9d1C36974d05eb9889eBf8A150b05791E559; its IMDO fee is burned**. It creates no holder rewards.

No production factory address, current factory payout addresses, source, or swarm Merkle root was supplied. Consequently their exact deployed recipients cannot be identified or attested here. The existing factory and distributor must be supplied by the launch environment. The local comparison uses identical hooked and hookless pool positions, collects both fee currencies to the model factory's fixed recipient, checks equal payouts, and exercises a separately funded one-leaf Merkle claim. Ordinary untaxed ERC-20 transfers preserve the distributor's token accounting.

**Permissions and callers.** The hook address must satisfy `uint160(address) & 0x3fff == 0x25d4` (**9684**). Its constructor enforces that mask. Enabled callbacks are `beforeInitialize`, `afterAddLiquidity`, `afterRemoveLiquidity`, `beforeSwap`, `afterSwap`, and `afterDonate`; `afterSwapReturnDelta` is enabled. Every other permission is false, including `beforeSwapReturnDelta` and both liquidity return-delta permissions. `beforeSwap` observes protocol fees and returns zero delta and zero fee override. There is no share token or access-control role. Public token methods are `transfer`, `approve`, `transferFrom`, and self-`burn`. Public hook actions consist of `harvest` and read-only getters/quotes. Callbacks and self-call helpers have the restrictions described above. No function can change treasury, cap, brackets, token, manager, or the bound pool.

**Deployment script.** `script/Deploy.s.sol:Deploy` has no package imports beyond the delivered source. It deliberately delegates launch behavior to the actual configured factory instead of inventing a replacement ABI. Configure:

| Environment value | Meaning |
| --- | --- |
| `POOL_MANAGER` | Verified target chain manager address; constructor argument, not hardcoded |
| `LAUNCH_FACTORY` | Existing factory to call atomically |
| `TOKEN` | Factory's predicted, not yet deployed token address |
| `HOOK_SALT` | Mined CREATE2 salt for these exact constructor arguments and creation code |
| `LAUNCH_CALLDATA` | ABI-encoded call for that factory, containing its normal launch, token/hook creation and initialization inputs |
| `HOOK_DEPLOYER` | Optional actual CREATE2 creator; defaults to `LAUNCH_FACTORY` |
| `LAUNCH_VALUE` | Optional ETH value in wei; default **0** |
| `POOL_FEE` | Optional LP fee of the one pool the hook may be bound to; **500**, **3000** or **10000**; default **3000** |
| `TICK_SPACING` | Optional tick spacing of that pool; default **60** |
| `SQRT_PRICE_X96` | Optional expected initial sqrt price; default **0** = not checked |
| `RPC_URL` | Sepolia RPC supplied to Foundry |

`tokenCreationCode()` and `hookCreationCode(manager, token)` produce the payloads. `mine(deployer, manager, token, start, attempts)` searches a bounded salt range for an unused address; resume with a new range if needed. `predict` implements the standard CREATE2 address formula. Salt mining must use the exact final build, constructor arguments, and CREATE2 creator. The local deployment test searches up to **200,000** salts.

After filling the factory-specific configuration, simulate with:

```sh
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL"
```

The script checks chain **11155111**, manager/factory code, fresh targets, mined permissions, token runtime identity and fixed supply, immutable hook policy, and attached-pool initialization. Because the hook binds one pool irreversibly, the script also requires `hook.poolId()` to equal the id of `PoolKey(ETH, TOKEN, POOL_FEE, TICK_SPACING, hook)` and, when `SQRT_PRICE_X96` is set, the pool's current `slot0` price (read through the manager's `extsload`) to equal it; a launch that initialized any other key or price fails the script instead of being reported as verified. It calls the factory once. `LaunchPrepared` records initcode and calldata hashes; `LaunchVerified` records the pool ID and deployed runtime hashes. Simulation performs no live deployment; signing and broadcast are launch-operator actions. Runtime checks after the factory call are script postconditions, not logic installed into the factory.

**Launch attestation — candidate, not a deployment receipt.** This worker's delivery paths are the four files named above, so the attestation is recorded here. Where the repository also carries a root `launch.json` manifest, that file is maintained outside this delivery and is the machine-read record; the block below is the descriptive record of what these contracts fix, not a claim to conform to a factory manifest schema:

```json
{
  "status": "candidate-awaiting-factory-rehearsal",
  "chainId": 11155111,
  "token": {
    "artifact": "src/IMDOFeeHook.sol:IMDOToken",
    "constructorArgs": [],
    "name": "IMD Offsets",
    "symbol": "IMDO",
    "decimals": 18,
    "initialSupply": "1000000000000000000000000",
    "recipient": "deploying launch factory",
    "postDeploymentMint": false
  },
  "hook": {
    "artifact": "src/IMDOFeeHook.sol:IMDOFeeHook",
    "constructorArgs": ["$poolManager", "$token"],
    "flags": 9684,
    "quoteAsset": "0x0000000000000000000000000000000000000000",
    "treasury": "0xb1eC9d1C36974d05eb9889eBf8A150b05791E559",
    "sellThresholdBps": [100, 300, 500],
    "feePpm": [0, 5000, 10000, 20000],
    "maxFeePpm": 20000,
    "reserveLagBlocks": 1,
    "accumulator": "tx.origin transient ledger, cumulative billing with shortfall carry, each swap capped at 2% of its own basis",
    "sizingReserve": "min(previous-block snapshot, booked reserve before the swap)",
    "exactOutputTokenFee": "ERC-6909 claim, burned by harvest()",
    "owner": null,
    "upgradeable": false,
    "holderRewards": false
  },
  "pool": {"fee": 3000, "tickSpacing": 60, "initializer": "launch factory"},
  "deploymentTransaction": null,
  "factoryPayoutRecipientsVerified": false,
  "rootBuildReproducibilityVerified": true,
  "auditPerformed": false
}
```

The pool values in this candidate record are the tested selection, not a deployed pool. Final deployed addresses, CREATE2 salt, creation/runtime hashes, factory recipients and transaction hash must come from the configured factory rehearsal and launch receipt.

**Build reproducibility.** The root `foundry.toml` is, verbatim:

```toml
[profile.default]
src = "src"
script = "script"
test = "test"
out = "out"
libs = ["lib"]
solc_version = "0.8.26"
optimizer = true
optimizer_runs = 200
evm_version = "cancun"
via_ir = false
bytecode_hash = "none"
```

A plain `forge build` with this file is the reproducible build; no build flag replaces it. The Solidity files pin compiler **0.8.26** and use Cancun transient storage. With this profile the artifact metadata for IMDOToken, IMDOFeeHook and Deploy records `"bytecodeHash": "none"` and the runtime bytecode ends in the CBOR tail `a164736f6c634300081a000a`, which encodes only `{"solc": 0.8.26}` and no `ipfs` key. This was checked directly on the built artifacts, not inferred from a successful compilation. The delivered source has no external imports, so `libs = ["lib"]` resolves nothing and no dependency needs to exist for the build.

**Local verification.** `forge build` at the repository root succeeds for the delivered source and script. Root runtime sizes are **1,586 bytes** for the token and **9,050 bytes** for the hook, both below the **24,576-byte** EIP-170 limit. For revision 3 this worker ran, in the assignment's disposable `test/scratch/`, the reviewer's proof `Proof_d76a25dd4a0f.t.sol` (1 test) and 13 own checks against a real Uniswap v4 `PoolManager` with a hooked pool beside an identical hookless twin; all 14 pass on this revision, and the proof and the checks for each reported defect fail on the previous revision. Covered: buys identical to the hookless pool; exact ETH fee to the treasury at each bracket for exact-input sells; two users under one `tx.origin` (the second pays at most 2% of its own output); a three-leg split paying 0, then each later leg's cap; exact-output sells through a settle-after router and through a pay-first router (prepaying more than, and exactly, sold + fee) all paying sold + fee once, with `harvest()` burning exactly the fee; an exact-output leg under a shared origin capped at 2% of its own input; park-withdraw-sell and same-block liquidity inflation both billed at the uninflated bracket; a treasury that rejects ETH leaving a claim that `harvest()` later pays; and the deploy script accepting the configured pool and rejecting a wrong key or price.

Those scratch checks are removed by the task runner and are not delivered. The repository's regression suite under `test/` is written and maintained by a different contributor and was not available to this worker during the revision; assertions there that encode the previous behaviour (a later leg collecting the whole repricing of earlier legs, an exact-output fee burned during the swap rather than by `harvest()`, sizing against the lagged snapshot only) need updating to the behaviour stated above. No fork rehearsal, live factory/distributor verification, Slither, Mythril, or external audit is claimed.
