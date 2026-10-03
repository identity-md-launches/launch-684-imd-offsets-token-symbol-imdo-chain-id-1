# IMD Offsets (IMDO)

IMDO funds regenerative contributions through a public treasury that buys and retires ecological credits on Regen Network. These contracts send fees to that treasury; they do not execute or attest to credit purchases or retirements. Holding IMDO confers no payouts, rewards, yield, staking, or treasury entitlement.

**Delivery status.** The source and deployment script are self-contained. The supplied repository had no source, dependencies, root `foundry.toml`, launch factory implementation, or deployment manifest. Two limitations prevent claiming that this delivery satisfies every admission criterion:

1. The assignment prohibits creating or modifying configuration files but also requires a root `foundry.toml`. That file is absent and has not been created. Default compilation contains an IPFS metadata hash, so root build reproducibility admission is **not satisfied**.
2. Cumulative sell volume selects each current leg's bracket. Previous legs are not retroactively repriced. This prevents repeatedly resetting the free bracket in one transaction, but does **not** make the total fee independent of splitting. Full retrospective billing is not implemented; its conflict with bounded, nonnegative exact-input output is explained below.

No live deployment or external audit was performed. Factory integration is checked with a model position owner and distributor against a real Uniswap v4 PoolManager, not an unspecified production factory.

**Token.** `src/IMDOFeeHook.sol:IMDOToken` has no constructor arguments. It mints exactly **1,000,000 IMDO**, or **1,000,000 × 10^18** base units, once to its deployer. This supply is an implementation choice because the assignment did not specify a quantity. The launch factory must be the deployer. The name is `IMD Offsets`, symbol `IMDO`, and decimals **18**. Transfers and approved `transferFrom` calls move exactly their stated amount. Maximum uint256 allowance is treated as unlimited. Holders can call `burn(uint256)` to destroy only their own balance and reduce total supply. Transfers to the zero address revert; use `burn` deliberately. There is no mint entry point, owner, administrator, tax, blacklist, pause, trading gate, or upgrade mechanism.

**Pool and fee policy.** `IMDOFeeHook(IPoolManager manager, address token)` fixes its manager and token at construction. Treasury **0xb1eC9d1C36974d05eb9889eBf8A150b05791E559**, thresholds, rates, **20,000 ppm** cap, and burning behavior are compile-time constants. The target is **Sepolia, chain ID 11155111**. The pool pairs native ETH, currency0 **address(0)**, with IMDO, currency1. WETH is not the quote asset. Initialization accepts static LP fees **500**, **3,000**, or **10,000 ppm** (**0.05%**, **0.3%**, or **1%**); it rejects zero and dynamic LP fees. The launch configuration selects the tier and tick spacing; the integration model uses **3,000 ppm**, spacing **60**.

Let `C` be the sum of actual IMDO inputs sold by the same `tx.origin` in this transaction, including this swap, and `R` be the previous block's token reserve. Values are base units, not token display amounts.

| C / R | Sell size in basis points | Hook rate | Fee ppm |
| --- | --- | --- | --- |
| Below 1% | Below 100 | 0% | 0 |
| At least 1%, below 3% | 100–299 | 0.5% | 5,000 |
| At least 3%, below 5% | 300–499 | 1% | 10,000 |
| At least 5% | 500 or more | 2% | 20,000 |

Threshold comparisons preserve fractional basis points. Zero sold gives zero fee. With positive sales and no previous-block reserve, the rate is **20,000 ppm**, including the initialization block. There is no launch-block trading lock.

Buy/sell classification and sell sizing use the token side of the actual `afterSwap` `BalanceDelta`, including partial fills. A negative IMDO delta is a sell. Buys pay **zero hook fee**, in both exact-input and exact-output modes; the pool's ordinary LP/protocol fees still apply.

For an exact-input sell, the fee is `ceil(gross ETH output × rate / 1,000,000)` wei. It reduces ETH output and goes **directly from PoolManager to the fixed treasury**. For an exact-output sell, v4 permits an after-swap return delta only on the unspecified asset, which is IMDO input: `ceil(actual IMDO input × rate / 1,000,000)` base units are added to input and **burned**. Specified ETH output stays unchanged; this case sends no hook ETH to the treasury. A ceiling rounds up by less than one base unit; the rate itself never exceeds 20,000 ppm.

This follows [OpenZeppelin BaseHookFee's unspecified-currency, positive-return-delta, rounded-up fee and ERC-6909 claim pattern](https://github.com/OpenZeppelin/uniswap-hooks/blob/master/src/fee/BaseHookFee.sol). Because library paths cannot be delivered under this assignment, the source contains minimal ABI-compatible v4 declarations and implements that pattern directly; it does not claim to inherit a vendored OpenZeppelin contract.

**Transaction accumulation and block snapshot.** EIP-1153 transient storage aggregates all sell inputs for `tx.origin`, across routers, recipients, and exact-input/output modes. Buys do not reset it. It disappears at transaction end; `cumulativeSold(origin)` exposes the current transaction's running amount. `tx.origin` groups volume only and never authorizes an action. Different origins and different transactions have separate totals. Bundled smart-account users sharing an origin also share the bracket.

The current leg pays its full fee basis at the running total's bracket. For a reserve of 10,000 IMDO, two 60-IMDO sells in one transaction charge zero on the first and 0.5% of the second leg's gross ETH output. A single 120-IMDO sell charges 0.5% of its entire gross output. This distinction is intentional and is a limitation against a requirement for retrospective cumulative billing. For example, repricing a previously free 99.999-IMDO sell when a final 0.001-IMDO sell crosses 1% would demand a fee much larger than the last leg's ETH proceeds. A fee returned solely on that last exact-input leg would turn its ETH credit into debt and break ordinary output-only settlement. This implementation preserves bounded per-leg fees and nonnegative ETH output.

`tokenReserve` is this pool's booked IMDO inventory, including uncollected LP fees. It increases/decreases with actual swap deltas and full liquidity callback deltas, includes donations, and excludes protocol fees measured immediately before and after each swap. Pool-wide manager balances are never used as a reserve oracle. Fee collection removes collected IMDO from the ledger even when the liquidity change is zero. Hook fees and claims are separate from that inventory.

Before the first ledger mutation in a new block, the old ledger becomes `laggedTokenReserve`; it stays fixed for the rest of that block. Idle blocks preserve the same inventory. Liquidity additions, donations, buys, or sells in the current block cannot increase that block's denominator. A donation to the manager outside this pool's `donate` operation does not affect it. Inflation maintained through a block boundary can affect a later snapshot: this is a one-block lag, not a time-weighted price oracle.

**Fee delivery and custody.** A failed ETH transfer, including insufficient manager cash or a treasury that rejects ETH, rolls back that transfer and mints an ERC-6909 fee claim to the hook. Similarly, token take-and-burn is atomic; if unavailable before the router settles input, the token fee becomes a claim pending burn. These paths preserve normal swap settlement and do not redirect fees to LPs or the caller. Standard pool liquidity, balance, allowance, slippage and gas requirements still apply.

Anyone can call `harvest()` with no reward. It unlocks the manager, redeems at most `pendingETH` to the same treasury, and redeems at most `pendingToken` for burning. Each redemption is atomic. Rejected transfers leave their claims available for a later call; calling while the manager is already unlocked also leaves claims untouched. Harvest does not swap, collect factory fees, change brackets, forward money to its caller, or redeem unsolicited claim transfers. A transient guard protects payment paths. Every hook callback and `unlockCallback` accepts only the immutable manager; `unlockCallback` additionally requires an active harvest. `redeemETH` and `takeAndBurn` accept only self-calls.

The hook has no ETH receive function. Successful fee handling leaves no fee tokens or ETH in the hook: its only outstanding fee holdings are the tracked manager claims. As with any address, forced ETH or unsolicited ERC-20/claim transfers cannot be prohibited; those are outside this custody invariant and have no rescue function.

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
| `RPC_URL` | Sepolia RPC supplied to Foundry |

`tokenCreationCode()` and `hookCreationCode(manager, token)` produce the payloads. `mine(deployer, manager, token, start, attempts)` searches a bounded salt range for an unused address; resume with a new range if needed. `predict` implements the standard CREATE2 address formula. Salt mining must use the exact final build, constructor arguments, and CREATE2 creator. The local deployment test searches up to **200,000** salts.

After filling the factory-specific configuration, simulate with:

```sh
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL"
```

The script checks chain **11155111**, manager/factory code, fresh targets, mined permissions, token runtime identity and fixed supply, immutable hook policy, and attached-pool initialization. It calls the factory once. `LaunchPrepared` records initcode and calldata hashes; `LaunchVerified` records the pool ID and deployed runtime hashes. Simulation performs no live deployment; signing and broadcast are launch-operator actions. Runtime checks after the factory call are script postconditions, not logic installed into the factory.

**Launch attestation — candidate, not a deployment receipt.** Kept here because a separate `launch.json` is outside the permitted delivery paths. This is a descriptive record, not a claim to conform to an unspecified factory manifest schema:

```json
{
  "status": "candidate-blocked-on-root-build-configuration-and-policy-clarification",
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
    "accumulator": "tx.origin transient current-leg brackets",
    "exactOutputTokenFee": "burn",
    "owner": null,
    "upgradeable": false,
    "holderRewards": false
  },
  "pool": {"fee": 3000, "tickSpacing": 60, "initializer": "launch factory"},
  "deploymentTransaction": null,
  "factoryPayoutRecipientsVerified": false,
  "rootBuildReproducibilityVerified": false,
  "auditPerformed": false
}
```

The pool values in this candidate record are the tested selection, not a deployed pool. Final deployed addresses, CREATE2 salt, creation/runtime hashes, factory recipients and transaction hash must come from the configured factory rehearsal and launch receipt.

**Build reproducibility blocker.** There is no root `foundry.toml`, so there are no contents to quote verbatim. Creating it would violate the explicit configuration-file prohibition. The required configuration remains the following **undelivered proposal**, not a quotation of an existing file:

```toml
[profile.default]
solc_version = "0.8.26"
optimizer = true
optimizer_runs = 200
evm_version = "cancun"
via_ir = true
bytecode_hash = "none"
```

The Solidity files pin compiler **0.8.26** and use Cancun transient storage. A default source build succeeds, but artifact CBOR metadata contains the `ipfs` key for both IMDOToken and IMDOFeeHook. This was checked directly, not inferred from a successful compilation. No build flag is proposed as a replacement for the missing root configuration. The scratch test project uses the settings above and its artifacts omit IPFS; that does not satisfy the requirement for a committed root profile.

**Local verification.** `forge build` succeeds for the delivered source and script when disposable tests are excluded. The scratch build and aggregate `forge test` run passed **35 tests, zero failures, zero skips**: **24** real-manager integration tests, **9** pinned baseline checks, and **2** deployment-script checks. The integration suite includes **256 runs each** for rate-cap fuzzing and differential exact-input/output sell accounting. It also checks a fresh token-only pool buying with no preexisting manager ETH, an ETH-only pool deferring token-fee burning until settlement, and protocol-fee collection. Scratch artifact CBOR is `a164736f6c634300081a` for both delivered contracts: it contains the compiler version and no IPFS key. Optimized scratch runtime sizes are **1,344 bytes** for the token and **6,742 bytes** for the hook, both below the **24,576-byte** EIP-170 limit.

Tests and their downloaded dependencies live only under the assignment's disposable `test/scratch/`. Production code does not import them and has no network dependency. Scratch checks use `forge build --root test/scratch` and `forge test --root test/scratch`; the protected suite additionally receives the compiled token/hook initcode and declared permissions through its prescribed environment variables. Pinned inputs are untouched; scratch copies only adapt imports to the harness. Scratch tests are removed by the task runner and are not a delivered regression suite. No fork rehearsal, live factory/distributor verification, Slither, Mythril, or external audit is claimed.
