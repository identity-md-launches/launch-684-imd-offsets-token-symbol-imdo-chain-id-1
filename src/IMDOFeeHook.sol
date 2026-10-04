// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A fixed supply, ordinary ERC-20. The launch factory receives the entire supply.
contract IMDOToken {
    string public constant name = "IMD Offsets";
    string public constant symbol = "IMDO";
    uint8 public constant decimals = 18;
    uint256 public constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 public totalSupply = INITIAL_SUPPLY;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    error InvalidAddress();
    error InsufficientBalance();
    error InsufficientAllowance();

    constructor() {
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert InvalidAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function burn(uint256 amount) external {
        uint256 balance = balanceOf[msg.sender];
        if (balance < amount) revert InsufficientBalance();
        balanceOf[msg.sender] = balance - amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert InvalidAddress();
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance();
        balanceOf[from] = balance - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

// Minimal v4 ABI declarations are kept here so the delivered contracts have no
// uncommitted library dependencies. Their wire layout matches Uniswap v4-core.
type Currency is address;
type BalanceDelta is int256;
type BeforeSwapDelta is int256;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

library Hooks {
    struct Permissions {
        bool beforeInitialize;
        bool afterInitialize;
        bool beforeAddLiquidity;
        bool afterAddLiquidity;
        bool beforeRemoveLiquidity;
        bool afterRemoveLiquidity;
        bool beforeSwap;
        bool afterSwap;
        bool beforeDonate;
        bool afterDonate;
        bool beforeSwapReturnDelta;
        bool afterSwapReturnDelta;
        bool afterAddLiquidityReturnDelta;
        bool afterRemoveLiquidityReturnDelta;
    }
}

interface IPoolManager {
    function take(Currency currency, address to, uint256 amount) external;
    function mint(address to, uint256 id, uint256 amount) external;
    function burn(address from, uint256 id, uint256 amount) external;
    function unlock(bytes calldata data) external returns (bytes memory);
    function protocolFeesAccrued(Currency currency) external view returns (uint256);
}

/// @notice Immutable IMDO/native ETH launch-pool fee hook.
/// @dev Uses OpenZeppelin BaseHookFee's afterSwap unspecified-currency fee pattern:
///      positive returned delta, rounded-up ppm fee, ERC-6909 claims if not paid now.
///      No LP fee override, liquidity return delta, router gate or privileged role.
contract IMDOFeeHook {
    IPoolManager public immutable poolManager;
    address public immutable token;
    address public constant TREASURY = 0xb1eC9d1C36974d05eb9889eBf8A150b05791E559;
    uint24 public constant MAX_FEE_PPM = 20_000;
    uint256 public constant PPM = 1_000_000;
    uint160 public constant FLAGS = 0x25d4;
    uint160 private constant ALL_FLAGS = (1 << 14) - 1;

    bool public initialized;
    bytes32 public poolId;
    uint256 public tokenReserve;
    uint256 public laggedTokenReserve;
    uint256 public reserveBlock;
    uint256 public pendingETH;
    uint256 public pendingToken;

    /// @notice One tx.origin's sells in the current transaction (transient; gone at tx end).
    /// @dev Invariant after every leg: ethPaid <= ceil(ethBasis * rate / PPM) and
    ///      tokenPaid <= ceil(tokenBasis * rate / PPM), where rate is the bracket of `sold`.
    ///      The difference is the shortfall still owed; later legs collect it, each one
    ///      bounded by MAX_FEE_PPM of its own basis.
    struct Ledger {
        uint256 sold; // IMDO actually paid into the pool, all legs
        uint256 ethBasis; // gross ETH output of exact-input legs (fee basis in ETH)
        uint256 tokenBasis; // IMDO input of exact-output legs (fee basis in IMDO)
        uint256 ethPaid; // ETH fee collected so far (sent to TREASURY or claimed)
        uint256 tokenPaid; // IMDO fee collected so far (burned or claimed)
    }

    bytes32 private constant SOLD_NAMESPACE = keccak256("IMDO.sold.by.origin");
    bytes32 private constant PROTOCOL_SLOT = keccak256("IMDO.protocol.before.swap");
    bytes32 private constant ENTERED_SLOT = keccak256("IMDO.external.payment.guard");
    bytes32 private constant HARVEST_SLOT = keccak256("IMDO.harvest.callback");

    error OnlyPoolManager();
    error OnlySelf();
    error InvalidConfiguration();
    error InvalidPool();
    error ReentrantPayment();
    error UnexpectedUnlock();

    event PoolBound(bytes32 indexed id);
    event SellFee(
        address indexed origin, uint256 cumulativeSold, uint24 feePpm, address currency, uint256 amount, bool claimed
    );
    event Harvested(uint256 ethAmount, uint256 tokenAmount);

    constructor(IPoolManager manager_, address token_) {
        if (address(manager_) == address(0) || token_ == address(0)) revert InvalidConfiguration();
        if (uint160(address(this)) & ALL_FLAGS != FLAGS) revert InvalidConfiguration();
        poolManager = manager_;
        token = token_;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier paymentGuard() {
        if (_load(ENTERED_SLOT) != 0) revert ReentrantPayment();
        _store(ENTERED_SLOT, 1);
        _;
        _store(ENTERED_SLOT, 0);
    }

    function getHookPermissions() external pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterAddLiquidity = true;
        p.afterRemoveLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.afterDonate = true;
        p.afterSwapReturnDelta = true;
    }

    /// @dev Launch factory must deploy AND initialize atomically. Binding is one-time.
    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (
            initialized || Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != token
                || key.hooks != address(this) || (key.fee != 500 && key.fee != 3_000 && key.fee != 10_000)
        ) revert InvalidPool();
        initialized = true;
        poolId = keccak256(abi.encode(key));
        reserveBlock = block.number;
        emit PoolBound(poolId);
        return this.beforeInitialize.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        _checkPool(key);
        _updateReserve(_amount1(delta));
        // The manager's delta ALREADY includes feesAccrued. Never subtract, divert,
        // burn, or replace the factory's LP fee entitlement. Zero hook delta.
        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        _checkPool(key);
        _updateReserve(_amount1(delta));
        return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        _store(PROTOCOL_SLOT, poolManager.protocolFeesAccrued(Currency.wrap(token)));
        // Observation only: no swap interception and no LP fee override.
        return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        paymentGuard
        returns (bytes4, int128)
    {
        _checkPool(key);
        uint256 protocolFee = poolManager.protocolFeesAccrued(Currency.wrap(token)) - _load(PROTOCOL_SLOT);
        _store(PROTOCOL_SLOT, 0);
        int128 tokenDelta = _amount1(delta);
        // Sizing reserve: the one-block-lagged snapshot, or this pool's booked reserve
        // just before this swap when that is LOWER. Liquidity parked across a block
        // boundary and withdrawn before selling therefore no longer counts.
        _rollReserve();
        uint256 sizingReserve = tokenReserve < laggedTokenReserve ? tokenReserve : laggedTokenReserve;
        _updateReserve(tokenDelta);
        tokenReserve -= protocolFee;

        // Classification and sizing use the actual settled pool delta, never the
        // requested amountSpecified (which denotes ETH for an exact-output sell).
        if (tokenDelta >= 0) return (this.afterSwap.selector, 0);
        uint256 sold = uint256(-int256(tokenDelta));
        int128 ethDelta = _amount0(delta);
        uint256 legEth = ethDelta > 0 ? uint256(uint128(ethDelta)) : 0;
        bool exactInput = params.amountSpecified < 0;
        // tx.origin groups volume for cumulative billing; it grants NO authority.
        (uint24 rate, uint256 fee, uint256 cumulative) = _bill(tx.origin, exactInput, sold, legEth, sizingReserve);
        if (fee == 0) return (this.afterSwap.selector, 0);

        bool claimed;
        if (exactInput) {
            // An unfunded manager or rejecting recipient must not veto a sell.
            try poolManager.take(Currency.wrap(address(0)), TREASURY, fee) {}
            catch {
                poolManager.mint(address(this), 0, fee);
                pendingETH += fee;
                claimed = true;
            }
        } else {
            // The v4 return delta can charge only the unspecified side. For exact
            // output sells this is IMDO input; it is destroyed, never distributed.
            // It is ALWAYS booked as an ERC-6909 claim (BaseHookFee pattern) and burned
            // by harvest(): taking real IMDO out of the manager mid-swap would lower the
            // balance a pay-first (sync, transfer, swap, settle) swapper is credited from.
            poolManager.mint(address(this), uint160(token), fee);
            pendingToken += fee;
            claimed = true;
        }
        emit SellFee(tx.origin, cumulative, rate, exactInput ? address(0) : token, fee, claimed);
        return (this.afterSwap.selector, int128(int256(fee)));
    }

    function afterDonate(address, PoolKey calldata key, uint256, uint256 amount1, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        _checkPool(key);
        _rollReserve();
        tokenReserve += amount1;
        return this.afterDonate.selector;
    }

    /// @dev Cumulative billing. The fee owed by an origin is always the schedule applied
    ///      to EVERYTHING it sold this transaction: ceil(basis * rate(sold) / PPM) per side.
    ///      Each leg collects the current shortfall (owed minus already paid), so earlier
    ///      legs are repriced when a later leg lifts the bracket. A leg can only charge
    ///      its unspecified currency: ETH on exact-input legs, IMDO on exact-output legs.
    ///      The other side's shortfall is converted at this leg's own realized price.
    ///      PER-SWAP CAP: no leg is ever charged more than ceil(its own basis *
    ///      MAX_FEE_PPM / PPM): its gross ETH output for exact-input legs, its IMDO input
    ///      for exact-output legs. afterSwap cannot see the end user, and several users'
    ///      sells can share one tx.origin (bundlers, relayers, batch settlement), so a
    ///      leg must never pay more than the hard cap on itself for volume that came
    ///      before it. Any shortfall above that bound carries to the origin's next sell
    ///      in the same transaction and is dropped when the transaction ends.
    function _bill(address origin, bool exactInput, uint256 legSold, uint256 legEth, uint256 reserve)
        private
        returns (uint24 rate, uint256 fee, uint256 cumulative)
    {
        bytes32 base = keccak256(abi.encode(SOLD_NAMESPACE, origin));
        Ledger memory l = _loadLedger(base);
        l.sold += legSold;
        if (exactInput) l.ethBasis += legEth;
        else l.tokenBasis += legSold;

        rate = feePpm(l.sold, reserve);
        // Rate cap is unconditional; ceil is the BaseHookFee rounding convention.
        assert(rate <= MAX_FEE_PPM);
        fee = _collect(l, exactInput, legSold, legEth, rate);
        _storeLedger(base, l);
        cumulative = l.sold;
    }

    /// @dev Shortfall collection for one leg; updates `l` in memory. See _bill.
    function _collect(Ledger memory l, bool exactInput, uint256 legSold, uint256 legEth, uint24 rate)
        private
        pure
        returns (uint256 fee)
    {
        uint256 ethDue = _ceilPpm(l.ethBasis, rate);
        uint256 tokenDue = _ceilPpm(l.tokenBasis, rate);
        uint256 ethShort = ethDue > l.ethPaid ? ethDue - l.ethPaid : 0;
        uint256 tokenShort = tokenDue > l.tokenPaid ? tokenDue - l.tokenPaid : 0;

        if (exactInput) {
            // IMDO shortfall priced in ETH at this leg's rate (legEth per legSold).
            uint256 converted = (tokenShort != 0 && legEth != 0) ? _ceilDiv(tokenShort * legEth, legSold) : 0;
            uint256 want = ethShort + converted;
            uint256 cap = _ceilPpm(legEth, MAX_FEE_PPM); // <= legEth: ETH credit stays nonnegative
            if (want <= cap) {
                fee = want;
                l.ethPaid = ethDue;
                if (converted != 0) l.tokenPaid = tokenDue;
            } else {
                fee = cap; // bounded by the cap on this leg's own output; the rest carries forward
                uint256 ethPart = fee < ethShort ? fee : ethShort;
                l.ethPaid += ethPart;
                uint256 rest = fee - ethPart;
                if (rest != 0) l.tokenPaid += rest * legSold / legEth;
            }
        } else {
            // ETH shortfall priced in IMDO at this leg's rate (legSold per legEth).
            uint256 converted = (ethShort != 0 && legEth != 0) ? _ceilDiv(ethShort * legSold, legEth) : 0;
            uint256 want = tokenShort + converted;
            uint256 cap = _ceilPpm(legSold, MAX_FEE_PPM);
            if (want <= cap) {
                fee = want;
                l.tokenPaid = tokenDue;
                if (converted != 0) l.ethPaid = ethDue;
            } else {
                fee = cap; // bounded by the cap on this leg's own input; the rest carries forward
                uint256 tokenPart = fee < tokenShort ? fee : tokenShort;
                l.tokenPaid += tokenPart;
                uint256 rest = fee - tokenPart;
                if (rest != 0) l.ethPaid += rest * legEth / legSold;
            }
        }
    }

    function _ceilPpm(uint256 basis, uint24 rate) private pure returns (uint256) {
        return (basis * rate + PPM - 1) / PPM;
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @notice Bracket for `sold` IMDO against `reserve` (see afterSwap for the sizing reserve).
    /// @dev Exact boundaries are compared by cross multiplication, without a truncated
    ///      bps intermediate. No snapshot (reserve == 0) bills at the cap.
    function feePpm(uint256 sold, uint256 reserve) public pure returns (uint24) {
        if (sold == 0) return 0;
        if (reserve == 0) return MAX_FEE_PPM;
        // Divide reserve into exact ceil thresholds without multiplying user input.
        if (sold < _ceilPercent(reserve, 1)) return 0;
        if (sold < _ceilPercent(reserve, 3)) return 5_000;
        if (sold < _ceilPercent(reserve, 5)) return 10_000;
        return MAX_FEE_PPM;
    }

    function _ceilPercent(uint256 reserve, uint256 percent) private pure returns (uint256) {
        return (reserve / 100) * percent + ((reserve % 100) * percent + 99) / 100;
    }

    /// @notice IMDO sold by `origin` so far in the current transaction.
    function cumulativeSold(address origin) external view returns (uint256) {
        return _load(keccak256(abi.encode(SOLD_NAMESPACE, origin)));
    }

    /// @notice Full per-origin billing ledger for the current transaction.
    function originLedger(address origin) external view returns (Ledger memory) {
        return _loadLedger(keccak256(abi.encode(SOLD_NAMESPACE, origin)));
    }

    /// @notice Permissionless redemption of this hook's already accrued fee claims.
    /// @dev If manager is currently unlocked or treasury refuses ETH, claims remain.
    function harvest() external paymentGuard {
        if (pendingETH == 0 && pendingToken == 0) return;
        _store(HARVEST_SLOT, 1);
        try poolManager.unlock("") returns (bytes memory) {} catch {}
        _store(HARVEST_SLOT, 0);
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        if (_load(HARVEST_SLOT) != 1) revert UnexpectedUnlock();
        _store(HARVEST_SLOT, 2);
        uint256 ethAmount = pendingETH;
        uint256 tokenAmount = pendingToken;
        if (ethAmount != 0) {
            try this.redeemETH(ethAmount) {
                pendingETH = 0;
            } catch {
                ethAmount = 0;
            }
        }
        if (tokenAmount != 0) {
            try this.takeAndBurn(tokenAmount, true) {
                pendingToken = 0;
            } catch {
                tokenAmount = 0;
            }
        }
        emit Harvested(ethAmount, tokenAmount);
        return "";
    }

    /// @dev Self-call makes claim burn + transfer atomic even on recipient failure.
    function redeemETH(uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), TREASURY, amount);
    }

    function takeAndBurn(uint256 amount, bool claims) external {
        if (msg.sender != address(this)) revert OnlySelf();
        if (claims) poolManager.burn(address(this), uint160(token), amount);
        poolManager.take(Currency.wrap(token), address(this), amount);
        IMDOToken(token).burn(amount);
    }

    function _checkPool(PoolKey calldata key) private view {
        if (!initialized || keccak256(abi.encode(key)) != poolId) revert InvalidPool();
    }

    function _rollReserve() private {
        if (reserveBlock < block.number) {
            laggedTokenReserve = tokenReserve;
            reserveBlock = block.number;
        }
    }

    function _updateReserve(int128 callerTokenDelta) private {
        _rollReserve();
        if (callerTokenDelta < 0) tokenReserve += uint256(-int256(callerTokenDelta));
        else tokenReserve -= uint128(callerTokenDelta);
    }

    function _amount0(BalanceDelta delta) private pure returns (int128) {
        return int128(BalanceDelta.unwrap(delta) >> 128);
    }

    function _amount1(BalanceDelta delta) private pure returns (int128) {
        return int128(BalanceDelta.unwrap(delta));
    }

    function _loadLedger(bytes32 base) private view returns (Ledger memory l) {
        l.sold = _load(base);
        l.ethBasis = _load(bytes32(uint256(base) + 1));
        l.tokenBasis = _load(bytes32(uint256(base) + 2));
        l.ethPaid = _load(bytes32(uint256(base) + 3));
        l.tokenPaid = _load(bytes32(uint256(base) + 4));
    }

    function _storeLedger(bytes32 base, Ledger memory l) private {
        _store(base, l.sold);
        _store(bytes32(uint256(base) + 1), l.ethBasis);
        _store(bytes32(uint256(base) + 2), l.tokenBasis);
        _store(bytes32(uint256(base) + 3), l.ethPaid);
        _store(bytes32(uint256(base) + 4), l.tokenPaid);
    }

    function _load(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") { value := tload(slot) }
    }

    function _store(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") { tstore(slot, value) }
    }
}
