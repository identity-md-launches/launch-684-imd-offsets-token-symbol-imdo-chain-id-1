// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMDOToken, IMDOFeeHook} from "../src/IMDOFeeHook.sol";
import {Deploy} from "../script/Deploy.s.sol";

/*
 * IMDO launch test suite.
 *
 * This file is deliberately self-contained. The delivered repository has no `lib/`, no `foundry.toml` and no
 * forge-std, and this task may only write this one path, so everything the suite needs is in here:
 *
 *   - a minimal cheatcode interface and assertion helpers (no forge-std);
 *   - a model launch factory (`ModelFactory`) that creates the token, CREATE2-deploys the hook at its mined
 *     address, initializes the pool and owns a liquidity position in one transaction, and distributes the
 *     position's pool fees to a fixed recipient, the way the real factory does for whoever it pays today;
 *   - a model swarm Merkle distributor funded with IMDO;
 *   - at the bottom of the file, Uniswap v4-core (commit 46c6834698c48bc4a463a86d8420f4eb1d7f3b75, April 2026)
 *     flattened verbatim with `forge flatten`: the real `PoolManager`, its libraries, `StateLibrary`, and the
 *     `PoolSwapTest` / `PoolModifyLiquidityTest` / `PoolDonateTest` routers. The hook is exercised against the
 *     real manager, not a mock, so the delta accounting, ERC-6909 claims and hook-call wrapping are the ones
 *     the launch will meet. Licenses of the vendored sources are retained in their headers (BUSL-1.1 for
 *     PoolManager, MIT for the libraries, UNLICENSED for the test routers); nothing from them is deployed.
 *
 * Two "universes" are built for most tests: U (the launch pool with the hook attached) and T (an identical pool
 * on a fresh manager with no hook). Every trade is replayed on both. T supplies the gross quotes, so the hook's
 * fee can be asserted to the wei without re-deriving the AMM math, and T is the control that shows the
 * factory's own fee accounting is unchanged by the hook.
 */

// ───────────────────────────────── vendored Uniswap v4-core (forge flatten) ─────────────────────────────────

// lib/v4-core/src/types/BeforeSwapDelta.sol

// Return type of the beforeSwap hook.
// Upper 128 bits is the delta in specified tokens. Lower 128 bits is delta in unspecified tokens (to match the afterSwap hook)
type BeforeSwapDelta is int256;

// Creates a BeforeSwapDelta from specified and unspecified
function toBeforeSwapDelta(int128 deltaSpecified, int128 deltaUnspecified)
    pure
    returns (BeforeSwapDelta beforeSwapDelta)
{
    assembly ("memory-safe") {
        beforeSwapDelta := or(shl(128, deltaSpecified), and(sub(shl(128, 1), 1), deltaUnspecified))
    }
}

/// @notice Library for getting the specified and unspecified deltas from the BeforeSwapDelta type
library BeforeSwapDeltaLibrary {
    /// @notice A BeforeSwapDelta of 0
    BeforeSwapDelta public constant ZERO_DELTA = BeforeSwapDelta.wrap(0);

    /// extracts int128 from the upper 128 bits of the BeforeSwapDelta
    /// returned by beforeSwap
    function getSpecifiedDelta(BeforeSwapDelta delta) internal pure returns (int128 deltaSpecified) {
        assembly ("memory-safe") {
            deltaSpecified := sar(128, delta)
        }
    }

    /// extracts int128 from the lower 128 bits of the BeforeSwapDelta
    /// returned by beforeSwap and afterSwap
    function getUnspecifiedDelta(BeforeSwapDelta delta) internal pure returns (int128 deltaUnspecified) {
        assembly ("memory-safe") {
            deltaUnspecified := signextend(15, delta)
        }
    }
}

// lib/v4-core/src/libraries/BitMath.sol

/// @title BitMath
/// @dev This library provides functionality for computing bit properties of an unsigned integer
/// @author Solady (https://github.com/Vectorized/solady/blob/8200a70e8dc2a77ecb074fc2e99a2a0d36547522/src/utils/LibBit.sol)
library BitMath {
    /// @notice Returns the index of the most significant bit of the number,
    ///     where the least significant bit is at index 0 and the most significant bit is at index 255
    /// @param x the value for which to compute the most significant bit, must be greater than 0
    /// @return r the index of the most significant bit
    function mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0);

        assembly ("memory-safe") {
            r := shl(7, lt(0xffffffffffffffffffffffffffffffff, x))
            r := or(r, shl(6, lt(0xffffffffffffffff, shr(r, x))))
            r := or(r, shl(5, lt(0xffffffff, shr(r, x))))
            r := or(r, shl(4, lt(0xffff, shr(r, x))))
            r := or(r, shl(3, lt(0xff, shr(r, x))))
            // forgefmt: disable-next-item
            r := or(r, byte(and(0x1f, shr(shr(r, x), 0x8421084210842108cc6318c6db6d54be)),
                0x0706060506020500060203020504000106050205030304010505030400000000))
        }
    }

    /// @notice Returns the index of the least significant bit of the number,
    ///     where the least significant bit is at index 0 and the most significant bit is at index 255
    /// @param x the value for which to compute the least significant bit, must be greater than 0
    /// @return r the index of the least significant bit
    function leastSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0);

        assembly ("memory-safe") {
            // Isolate the least significant bit.
            x := and(x, sub(0, x))
            // For the upper 3 bits of the result, use a De Bruijn-like lookup.
            // Credit to adhusson: https://blog.adhusson.com/cheap-find-first-set-evm/
            // forgefmt: disable-next-item
            r := shl(5, shr(252, shl(shl(2, shr(250, mul(x,
                0xb6db6db6ddddddddd34d34d349249249210842108c6318c639ce739cffffffff))),
                0x8040405543005266443200005020610674053026020000107506200176117077)))
            // For the lower 5 bits of the result, use a De Bruijn lookup.
            // forgefmt: disable-next-item
            r := or(r, byte(and(div(0xd76453e0, shr(r, x)), 0x1f),
                0x001f0d1e100c1d070f090b19131c1706010e11080a1a141802121b1503160405))
        }
    }
}

// lib/v4-core/src/libraries/CustomRevert.sol

/// @title Library for reverting with custom errors efficiently
/// @notice Contains functions for reverting with custom errors with different argument types efficiently
/// @dev To use this library, declare `using CustomRevert for bytes4;` and replace `revert CustomError()` with
/// `CustomError.selector.revertWith()`
/// @dev The functions may tamper with the free memory pointer but it is fine since the call context is exited immediately
library CustomRevert {
    /// @dev ERC-7751 error for wrapping bubbled up reverts
    error WrappedError(address target, bytes4 selector, bytes reason, bytes details);

    /// @dev Reverts with the selector of a custom error in the scratch space
    function revertWith(bytes4 selector) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            revert(0, 0x04)
        }
    }

    /// @dev Reverts with a custom error with an address argument in the scratch space
    function revertWith(bytes4 selector, address addr) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            mstore(0x04, and(addr, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(0, 0x24)
        }
    }

    /// @dev Reverts with a custom error with an int24 argument in the scratch space
    function revertWith(bytes4 selector, int24 value) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            mstore(0x04, signextend(2, value))
            revert(0, 0x24)
        }
    }

    /// @dev Reverts with a custom error with a uint160 argument in the scratch space
    function revertWith(bytes4 selector, uint160 value) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            mstore(0x04, and(value, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(0, 0x24)
        }
    }

    /// @dev Reverts with a custom error with two int24 arguments
    function revertWith(bytes4 selector, int24 value1, int24 value2) internal pure {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, selector)
            mstore(add(fmp, 0x04), signextend(2, value1))
            mstore(add(fmp, 0x24), signextend(2, value2))
            revert(fmp, 0x44)
        }
    }

    /// @dev Reverts with a custom error with two uint160 arguments
    function revertWith(bytes4 selector, uint160 value1, uint160 value2) internal pure {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, selector)
            mstore(add(fmp, 0x04), and(value1, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(fmp, 0x24), and(value2, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(fmp, 0x44)
        }
    }

    /// @dev Reverts with a custom error with two address arguments
    function revertWith(bytes4 selector, address value1, address value2) internal pure {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, selector)
            mstore(add(fmp, 0x04), and(value1, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(fmp, 0x24), and(value2, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(fmp, 0x44)
        }
    }

    /// @notice bubble up the revert message returned by a call and revert with a wrapped ERC-7751 error
    /// @dev this method can be vulnerable to revert data bombs
    function bubbleUpAndRevertWith(
        address revertingContract,
        bytes4 revertingFunctionSelector,
        bytes4 additionalContext
    ) internal pure {
        bytes4 wrappedErrorSelector = WrappedError.selector;
        assembly ("memory-safe") {
            // Ensure the size of the revert data is a multiple of 32 bytes
            let encodedDataSize := mul(div(add(returndatasize(), 31), 32), 32)

            let fmp := mload(0x40)

            // Encode wrapped error selector, address, function selector, offset, additional context, size, revert reason
            mstore(fmp, wrappedErrorSelector)
            mstore(add(fmp, 0x04), and(revertingContract, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(
                add(fmp, 0x24),
                and(revertingFunctionSelector, 0xffffffff00000000000000000000000000000000000000000000000000000000)
            )
            // offset revert reason
            mstore(add(fmp, 0x44), 0x80)
            // offset additional context
            mstore(add(fmp, 0x64), add(0xa0, encodedDataSize))
            // size revert reason
            mstore(add(fmp, 0x84), returndatasize())
            // revert reason
            returndatacopy(add(fmp, 0xa4), 0, returndatasize())
            // size additional context
            mstore(add(fmp, add(0xa4, encodedDataSize)), 0x04)
            // additional context
            mstore(
                add(fmp, add(0xc4, encodedDataSize)),
                and(additionalContext, 0xffffffff00000000000000000000000000000000000000000000000000000000)
            )
            revert(fmp, add(0xe4, encodedDataSize))
        }
    }
}

// lib/v4-core/src/libraries/FixedPoint128.sol

/// @title FixedPoint128
/// @notice A library for handling binary fixed point numbers, see https://en.wikipedia.org/wiki/Q_(number_format)
library FixedPoint128 {
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
}

// lib/v4-core/src/libraries/FixedPoint96.sol

/// @title FixedPoint96
/// @notice A library for handling binary fixed point numbers, see https://en.wikipedia.org/wiki/Q_(number_format)
/// @dev Used in SqrtPriceMath.sol
library FixedPoint96 {
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
}

// lib/v4-core/src/libraries/FullMath.sol

/// @title Contains 512-bit math functions
/// @notice Facilitates multiplication and division that can have overflow of an intermediate value without any loss of precision
/// @dev Handles "phantom overflow" i.e., allows multiplication and division where an intermediate value overflows 256 bits
library FullMath {
    /// @notice Calculates floor(a×b÷denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result
    /// @dev Credit to Remco Bloemen under MIT license https://xn--2-umb.com/21/muldiv
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            // Compute the product mod 2**256 and mod 2**256 - 1
            // then use the Chinese Remainder Theorem to reconstruct
            // the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2**256 + prod0
            uint256 prod0 = a * b; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Make sure the result is less than 2**256.
            // Also prevents denominator == 0
            require(denominator > prod1);

            // Handle non-overflow cases, 256 by 256 division
            if (prod1 == 0) {
                assembly ("memory-safe") {
                    result := div(prod0, denominator)
                }
                return result;
            }

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0]
            // Compute remainder using mulmod
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, denominator)
            }
            // Subtract 256 bit number from 512 bit number
            assembly ("memory-safe") {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator
            // Compute largest power of two divisor of denominator.
            // Always >= 1.
            uint256 twos = (0 - denominator) & denominator;
            // Divide denominator by power of two
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
            }

            // Divide [prod1 prod0] by the factors of two
            assembly ("memory-safe") {
                prod0 := div(prod0, twos)
            }
            // Shift in bits from prod1 into prod0. For this we need
            // to flip `twos` such that it is 2**256 / twos.
            // If twos is zero, then it becomes one
            assembly ("memory-safe") {
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert denominator mod 2**256
            // Now that denominator is an odd number, it has an inverse
            // modulo 2**256 such that denominator * inv = 1 mod 2**256.
            // Compute the inverse by starting with a seed that is correct
            // correct for four bits. That is, denominator * inv = 1 mod 2**4
            uint256 inv = (3 * denominator) ^ 2;
            // Now use Newton-Raphson iteration to improve the precision.
            // Thanks to Hensel's lifting lemma, this also works in modular
            // arithmetic, doubling the correct bits in each step.
            inv *= 2 - denominator * inv; // inverse mod 2**8
            inv *= 2 - denominator * inv; // inverse mod 2**16
            inv *= 2 - denominator * inv; // inverse mod 2**32
            inv *= 2 - denominator * inv; // inverse mod 2**64
            inv *= 2 - denominator * inv; // inverse mod 2**128
            inv *= 2 - denominator * inv; // inverse mod 2**256

            // Because the division is now exact we can divide by multiplying
            // with the modular inverse of denominator. This will give us the
            // correct result modulo 2**256. Since the preconditions guarantee
            // that the outcome is less than 2**256, this is the final result.
            // We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inv;
            return result;
        }
    }

    /// @notice Calculates ceil(a×b÷denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result
    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            result = mulDiv(a, b, denominator);
            if (mulmod(a, b, denominator) != 0) {
                require(++result > 0);
            }
        }
    }
}

// lib/v4-core/src/interfaces/external/IERC20Minimal.sol

/// @title Minimal ERC20 interface for Uniswap
/// @notice Contains a subset of the full ERC20 interface that is used in Uniswap V3
interface IERC20Minimal {
    /// @notice Returns an account's balance in the token
    /// @param account The account for which to look up the number of tokens it has, i.e. its balance
    /// @return The number of tokens held by the account
    function balanceOf(address account) external view returns (uint256);

    /// @notice Transfers the amount of token from the `msg.sender` to the recipient
    /// @param recipient The account that will receive the amount transferred
    /// @param amount The number of tokens to send from the sender to the recipient
    /// @return Returns true for a successful transfer, false for an unsuccessful transfer
    function transfer(address recipient, uint256 amount) external returns (bool);

    /// @notice Returns the current allowance given to a spender by an owner
    /// @param owner The account of the token owner
    /// @param spender The account of the token spender
    /// @return The current allowance granted by `owner` to `spender`
    function allowance(address owner, address spender) external view returns (uint256);

    /// @notice Sets the allowance of a spender from the `msg.sender` to the value `amount`
    /// @param spender The account which will be allowed to spend a given amount of the owners tokens
    /// @param amount The amount of tokens allowed to be used by `spender`
    /// @return Returns true for a successful approval, false for unsuccessful
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Transfers `amount` tokens from `sender` to `recipient` up to the allowance given to the `msg.sender`
    /// @param sender The account from which the transfer will be initiated
    /// @param recipient The recipient of the transfer
    /// @param amount The amount of the transfer
    /// @return Returns true for a successful transfer, false for unsuccessful
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    /// @notice Event emitted when tokens are transferred from one address to another, either via `#transfer` or `#transferFrom`.
    /// @param from The account from which the tokens were sent, i.e. the balance decreased
    /// @param to The account to which the tokens were sent, i.e. the balance increased
    /// @param value The amount of tokens that were transferred
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Event emitted when the approval amount for the spender of a given owner's tokens changes.
    /// @param owner The account that approved spending of its tokens
    /// @param spender The account for which the spending allowance was modified
    /// @param value The new allowance from the owner to the spender
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

// lib/v4-core/src/interfaces/external/IERC6909Claims.sol

/// @notice Interface for claims over a contract balance, wrapped as a ERC6909
interface IERC6909Claims {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event OperatorSet(address indexed owner, address indexed operator, bool approved);

    event Approval(address indexed owner, address indexed spender, uint256 indexed id, uint256 amount);

    event Transfer(address caller, address indexed from, address indexed to, uint256 indexed id, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner balance of an id.
    /// @param owner The address of the owner.
    /// @param id The id of the token.
    /// @return amount The balance of the token.
    function balanceOf(address owner, uint256 id) external view returns (uint256 amount);

    /// @notice Spender allowance of an id.
    /// @param owner The address of the owner.
    /// @param spender The address of the spender.
    /// @param id The id of the token.
    /// @return amount The allowance of the token.
    function allowance(address owner, address spender, uint256 id) external view returns (uint256 amount);

    /// @notice Checks if a spender is approved by an owner as an operator
    /// @param owner The address of the owner.
    /// @param spender The address of the spender.
    /// @return approved The approval status.
    function isOperator(address owner, address spender) external view returns (bool approved);

    /// @notice Transfers an amount of an id from the caller to a receiver.
    /// @param receiver The address of the receiver.
    /// @param id The id of the token.
    /// @param amount The amount of the token.
    /// @return bool True, always, unless the function reverts
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);

    /// @notice Transfers an amount of an id from a sender to a receiver.
    /// @param sender The address of the sender.
    /// @param receiver The address of the receiver.
    /// @param id The id of the token.
    /// @param amount The amount of the token.
    /// @return bool True, always, unless the function reverts
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external returns (bool);

    /// @notice Approves an amount of an id to a spender.
    /// @param spender The address of the spender.
    /// @param id The id of the token.
    /// @param amount The amount of the token.
    /// @return bool True, always
    function approve(address spender, uint256 id, uint256 amount) external returns (bool);

    /// @notice Sets or removes an operator for the caller.
    /// @param operator The address of the operator.
    /// @param approved The approval status.
    /// @return bool True, always
    function setOperator(address operator, bool approved) external returns (bool);
}

// lib/v4-core/src/interfaces/IExtsload.sol

/// @notice Interface for functions to access any storage slot in a contract
interface IExtsload {
    /// @notice Called by external contracts to access granular pool state
    /// @param slot Key of slot to sload
    /// @return value The value of the slot as bytes32
    function extsload(bytes32 slot) external view returns (bytes32 value);

    /// @notice Called by external contracts to access granular pool state
    /// @param startSlot Key of slot to start sloading from
    /// @param nSlots Number of slots to load into return value
    /// @return values List of loaded values.
    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory values);

    /// @notice Called by external contracts to access sparse pool state
    /// @param slots List of slots to SLOAD from.
    /// @return values List of loaded values.
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory values);
}

// lib/v4-core/src/interfaces/IExttload.sol

/// @notice Interface for functions to access any transient storage slot in a contract
interface IExttload {
    /// @notice Called by external contracts to access transient storage of the contract
    /// @param slot Key of slot to tload
    /// @return value The value of the slot as bytes32
    function exttload(bytes32 slot) external view returns (bytes32 value);

    /// @notice Called by external contracts to access sparse transient pool state
    /// @param slots List of slots to tload
    /// @return values List of loaded values
    function exttload(bytes32[] calldata slots) external view returns (bytes32[] memory values);
}

// lib/v4-core/src/interfaces/callback/IUnlockCallback.sol

/// @notice Interface for the callback executed when an address unlocks the pool manager
interface IUnlockCallback {
    /// @notice Called by the pool manager on `msg.sender` when the manager is unlocked
    /// @param data The data that was passed to the call to unlock
    /// @return Any data that you want to be returned from the unlock call
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

// lib/v4-core/src/libraries/LiquidityMath.sol

/// @title Math library for liquidity
library LiquidityMath {
    /// @notice Add a signed liquidity delta to liquidity and revert if it overflows or underflows
    /// @param x The liquidity before change
    /// @param y The delta by which liquidity should be changed
    /// @return z The liquidity delta
    function addDelta(uint128 x, int128 y) internal pure returns (uint128 z) {
        assembly ("memory-safe") {
            z := add(and(x, 0xffffffffffffffffffffffffffffffff), signextend(15, y))
            if shr(128, z) {
                // revert SafeCastOverflow()
                mstore(0, 0x93dafdf1)
                revert(0x1c, 0x04)
            }
        }
    }
}

// lib/v4-core/src/libraries/Lock.sol

/// @notice This is a temporary library that allows us to use transient storage (tstore/tload)
/// TODO: This library can be deleted when we have the transient keyword support in solidity.
library Lock {
    // The slot holding the unlocked state, transiently. bytes32(uint256(keccak256("Unlocked")) - 1)
    bytes32 internal constant IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    function unlock() internal {
        assembly ("memory-safe") {
            // unlock
            tstore(IS_UNLOCKED_SLOT, true)
        }
    }

    function lock() internal {
        assembly ("memory-safe") {
            tstore(IS_UNLOCKED_SLOT, false)
        }
    }

    function isUnlocked() internal view returns (bool unlocked) {
        assembly ("memory-safe") {
            unlocked := tload(IS_UNLOCKED_SLOT)
        }
    }
}

// lib/v4-core/src/libraries/NonzeroDeltaCount.sol

/// @notice This is a temporary library that allows us to use transient storage (tstore/tload)
/// for the nonzero delta count.
/// TODO: This library can be deleted when we have the transient keyword support in solidity.
library NonzeroDeltaCount {
    // The slot holding the number of nonzero deltas. bytes32(uint256(keccak256("NonzeroDeltaCount")) - 1)
    bytes32 internal constant NONZERO_DELTA_COUNT_SLOT =
        0x7d4b3164c6e45b97e7d87b7125a44c5828d005af88f9d751cfd78729c5d99a0b;

    function read() internal view returns (uint256 count) {
        assembly ("memory-safe") {
            count := tload(NONZERO_DELTA_COUNT_SLOT)
        }
    }

    function increment() internal {
        assembly ("memory-safe") {
            let count := tload(NONZERO_DELTA_COUNT_SLOT)
            count := add(count, 1)
            tstore(NONZERO_DELTA_COUNT_SLOT, count)
        }
    }

    /// @notice Potential to underflow. Ensure checks are performed by integrating contracts to ensure this does not happen.
    /// Current usage ensures this will not happen because we call decrement with known boundaries (only up to the number of times we call increment).
    function decrement() internal {
        assembly ("memory-safe") {
            let count := tload(NONZERO_DELTA_COUNT_SLOT)
            count := sub(count, 1)
            tstore(NONZERO_DELTA_COUNT_SLOT, count)
        }
    }
}

// lib/solmate/src/auth/Owned.sol

/// @notice Simple single owner authorization mixin.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/auth/Owned.sol)
abstract contract Owned {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed user, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////
                            OWNERSHIP STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;

    modifier onlyOwner() virtual {
        require(msg.sender == owner, "UNAUTHORIZED");

        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner) {
        owner = _owner;

        emit OwnershipTransferred(address(0), _owner);
    }

    /*//////////////////////////////////////////////////////////////
                             OWNERSHIP LOGIC
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) public virtual onlyOwner {
        owner = newOwner;

        emit OwnershipTransferred(msg.sender, newOwner);
    }
}

// lib/v4-core/src/libraries/ParseBytes.sol

/// @notice Parses bytes returned from hooks and the byte selector used to check return selectors from hooks.
/// @dev parseSelector also is used to parse the expected selector
/// For parsing hook returns, note that all hooks return either bytes4 or (bytes4, 32-byte-delta) or (bytes4, 32-byte-delta, uint24).
library ParseBytes {
    function parseSelector(bytes memory result) internal pure returns (bytes4 selector) {
        // equivalent: (selector,) = abi.decode(result, (bytes4, int256));
        assembly ("memory-safe") {
            selector := mload(add(result, 0x20))
        }
    }

    function parseFee(bytes memory result) internal pure returns (uint24 lpFee) {
        // equivalent: (,, lpFee) = abi.decode(result, (bytes4, int256, uint24));
        assembly ("memory-safe") {
            lpFee := mload(add(result, 0x60))
        }
    }

    function parseReturnDelta(bytes memory result) internal pure returns (int256 hookReturn) {
        // equivalent: (, hookReturnDelta) = abi.decode(result, (bytes4, int256));
        assembly ("memory-safe") {
            hookReturn := mload(add(result, 0x40))
        }
    }
}

// lib/v4-core/src/libraries/ProtocolFeeLibrary.sol

/// @notice library of functions related to protocol fees
library ProtocolFeeLibrary {
    /// @notice Max protocol fee is 0.1% (1000 pips)
    /// @dev Increasing these values could lead to overflow in Pool.swap
    uint16 public constant MAX_PROTOCOL_FEE = 1000;

    /// @notice Thresholds used for optimized bounds checks on protocol fees
    uint24 internal constant FEE_0_THRESHOLD = 1001;
    uint24 internal constant FEE_1_THRESHOLD = 1001 << 12;

    /// @notice the protocol fee is represented in hundredths of a bip
    uint256 internal constant PIPS_DENOMINATOR = 1_000_000;

    function getZeroForOneFee(uint24 self) internal pure returns (uint16) {
        return uint16(self & 0xfff);
    }

    function getOneForZeroFee(uint24 self) internal pure returns (uint16) {
        return uint16(self >> 12);
    }

    function isValidProtocolFee(uint24 self) internal pure returns (bool valid) {
        // Equivalent to: getZeroForOneFee(self) <= MAX_PROTOCOL_FEE && getOneForZeroFee(self) <= MAX_PROTOCOL_FEE
        assembly ("memory-safe") {
            let isZeroForOneFeeOk := lt(and(self, 0xfff), FEE_0_THRESHOLD)
            let isOneForZeroFeeOk := lt(and(self, 0xfff000), FEE_1_THRESHOLD)
            valid := and(isZeroForOneFeeOk, isOneForZeroFeeOk)
        }
    }

    // The protocol fee is taken from the input amount first and then the LP fee is taken from the remaining
    // The swap fee is capped at 100%
    // Equivalent to protocolFee + lpFee(1_000_000 - protocolFee) / 1_000_000 (rounded up)
    /// @dev here `self` is just a single direction's protocol fee, not a packed type of 2 protocol fees
    function calculateSwapFee(uint16 self, uint24 lpFee) internal pure returns (uint24 swapFee) {
        // protocolFee + lpFee - (protocolFee * lpFee / 1_000_000)
        assembly ("memory-safe") {
            self := and(self, 0xfff)
            lpFee := and(lpFee, 0xffffff)
            let numerator := mul(self, lpFee)
            swapFee := sub(add(self, lpFee), div(numerator, PIPS_DENOMINATOR))
        }
    }
}

// lib/v4-core/src/types/Slot0.sol

/**
 * @dev Slot0 is a packed version of solidity structure.
 * Using the packaged version saves gas by not storing the structure fields in memory slots.
 *
 * Layout:
 * 24 bits empty | 24 bits lpFee | 12 bits protocolFee 1->0 | 12 bits protocolFee 0->1 | 24 bits tick | 160 bits sqrtPriceX96
 *
 * Fields in the direction from the least significant bit:
 *
 * The current price
 * uint160 sqrtPriceX96;
 *
 * The current tick
 * int24 tick;
 *
 * Protocol fee, expressed in hundredths of a bip, upper 12 bits are for 1->0, and the lower 12 are for 0->1
 * the maximum is 1000 - meaning the maximum protocol fee is 0.1%
 * the protocolFee is taken from the input first, then the lpFee is taken from the remaining input
 * uint24 protocolFee;
 *
 * The current LP fee of the pool. If the pool is dynamic, this does not include the dynamic fee flag.
 * uint24 lpFee;
 */
type Slot0 is bytes32;

using Slot0Library for Slot0 global;

/// @notice Library for getting and setting values in the Slot0 type
library Slot0Library {
    uint160 internal constant MASK_160_BITS = 0x00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    uint24 internal constant MASK_24_BITS = 0xFFFFFF;

    uint8 internal constant TICK_OFFSET = 160;
    uint8 internal constant PROTOCOL_FEE_OFFSET = 184;
    uint8 internal constant LP_FEE_OFFSET = 208;

    // #### GETTERS ####
    function sqrtPriceX96(Slot0 _packed) internal pure returns (uint160 _sqrtPriceX96) {
        assembly ("memory-safe") {
            _sqrtPriceX96 := and(MASK_160_BITS, _packed)
        }
    }

    function tick(Slot0 _packed) internal pure returns (int24 _tick) {
        assembly ("memory-safe") {
            _tick := signextend(2, shr(TICK_OFFSET, _packed))
        }
    }

    function protocolFee(Slot0 _packed) internal pure returns (uint24 _protocolFee) {
        assembly ("memory-safe") {
            _protocolFee := and(MASK_24_BITS, shr(PROTOCOL_FEE_OFFSET, _packed))
        }
    }

    function lpFee(Slot0 _packed) internal pure returns (uint24 _lpFee) {
        assembly ("memory-safe") {
            _lpFee := and(MASK_24_BITS, shr(LP_FEE_OFFSET, _packed))
        }
    }

    // #### SETTERS ####
    function setSqrtPriceX96(Slot0 _packed, uint160 _sqrtPriceX96) internal pure returns (Slot0 _result) {
        assembly ("memory-safe") {
            _result := or(and(not(MASK_160_BITS), _packed), and(MASK_160_BITS, _sqrtPriceX96))
        }
    }

    function setTick(Slot0 _packed, int24 _tick) internal pure returns (Slot0 _result) {
        assembly ("memory-safe") {
            _result := or(and(not(shl(TICK_OFFSET, MASK_24_BITS)), _packed), shl(TICK_OFFSET, and(MASK_24_BITS, _tick)))
        }
    }

    function setProtocolFee(Slot0 _packed, uint24 _protocolFee) internal pure returns (Slot0 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(PROTOCOL_FEE_OFFSET, MASK_24_BITS)), _packed),
                shl(PROTOCOL_FEE_OFFSET, and(MASK_24_BITS, _protocolFee))
            )
        }
    }

    function setLpFee(Slot0 _packed, uint24 _lpFee) internal pure returns (Slot0 _result) {
        assembly ("memory-safe") {
            _result := or(
                and(not(shl(LP_FEE_OFFSET, MASK_24_BITS)), _packed),
                shl(LP_FEE_OFFSET, and(MASK_24_BITS, _lpFee))
            )
        }
    }
}

// lib/v4-core/src/libraries/UnsafeMath.sol

/// @title Math functions that do not check inputs or outputs
/// @notice Contains methods that perform common math functions but do not do any overflow or underflow checks
library UnsafeMath {
    /// @notice Returns ceil(x / y)
    /// @dev division by 0 will return 0, and should be checked externally
    /// @param x The dividend
    /// @param y The divisor
    /// @return z The quotient, ceil(x / y)
    function divRoundingUp(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly ("memory-safe") {
            z := add(div(x, y), gt(mod(x, y), 0))
        }
    }

    /// @notice Calculates floor(a×b÷denominator)
    /// @dev division by 0 will return 0, and should be checked externally
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result, floor(a×b÷denominator)
    function simpleMulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        assembly ("memory-safe") {
            result := div(mul(a, b), denominator)
        }
    }
}

// lib/v4-core/src/ERC6909.sol

/// @notice Minimalist and gas efficient standard ERC6909 implementation.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC6909.sol)
/// @dev Copied from the commit at 4b47a19038b798b4a33d9749d25e570443520647
/// @dev This contract has been modified from the implementation at the above link.
abstract contract ERC6909 is IERC6909Claims {
    /*//////////////////////////////////////////////////////////////
                             ERC6909 STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(address owner => mapping(address operator => bool isOperator)) public isOperator;

    mapping(address owner => mapping(uint256 id => uint256 balance)) public balanceOf;

    mapping(address owner => mapping(address spender => mapping(uint256 id => uint256 amount))) public allowance;

    /*//////////////////////////////////////////////////////////////
                              ERC6909 LOGIC
    //////////////////////////////////////////////////////////////*/

    function transfer(address receiver, uint256 id, uint256 amount) public virtual returns (bool) {
        balanceOf[msg.sender][id] -= amount;

        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender, msg.sender, receiver, id, amount);

        return true;
    }

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) public virtual returns (bool) {
        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            uint256 allowed = allowance[sender][msg.sender][id];
            if (allowed != type(uint256).max) allowance[sender][msg.sender][id] = allowed - amount;
        }

        balanceOf[sender][id] -= amount;

        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender, sender, receiver, id, amount);

        return true;
    }

    function approve(address spender, uint256 id, uint256 amount) public virtual returns (bool) {
        allowance[msg.sender][spender][id] = amount;

        emit Approval(msg.sender, spender, id, amount);

        return true;
    }

    function setOperator(address operator, bool approved) public virtual returns (bool) {
        isOperator[msg.sender][operator] = approved;

        emit OperatorSet(msg.sender, operator, approved);

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                              ERC165 LOGIC
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC165 Interface ID for ERC165
            || interfaceId == 0x0f632fb3; // ERC165 Interface ID for ERC6909
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    function _mint(address receiver, uint256 id, uint256 amount) internal virtual {
        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender, address(0), receiver, id, amount);
    }

    function _burn(address sender, uint256 id, uint256 amount) internal virtual {
        balanceOf[sender][id] -= amount;

        emit Transfer(msg.sender, sender, address(0), id, amount);
    }
}

// lib/v4-core/src/Extsload.sol

/// @notice Enables public storage access for efficient state retrieval by external contracts.
/// https://eips.ethereum.org/EIPS/eip-2330#rationale
abstract contract Extsload is IExtsload {
    /// @inheritdoc IExtsload
    function extsload(bytes32 slot) external view returns (bytes32) {
        assembly ("memory-safe") {
            mstore(0, sload(slot))
            return(0, 0x20)
        }
    }

    /// @inheritdoc IExtsload
    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory) {
        assembly ("memory-safe") {
            let memptr := mload(0x40)
            let start := memptr
            // A left bit-shift of 5 is equivalent to multiplying by 32 but costs less gas.
            let length := shl(5, nSlots)
            // The abi offset of dynamic array in the returndata is 32.
            mstore(memptr, 0x20)
            // Store the length of the array returned
            mstore(add(memptr, 0x20), nSlots)
            // update memptr to the first location to hold a result
            memptr := add(memptr, 0x40)
            let end := add(memptr, length)
            for {} 1 {} {
                mstore(memptr, sload(startSlot))
                memptr := add(memptr, 0x20)
                startSlot := add(startSlot, 1)
                if iszero(lt(memptr, end)) { break }
            }
            return(start, sub(end, start))
        }
    }

    /// @inheritdoc IExtsload
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory) {
        assembly ("memory-safe") {
            let memptr := mload(0x40)
            let start := memptr
            // for abi encoding the response - the array will be found at 0x20
            mstore(memptr, 0x20)
            // next we store the length of the return array
            mstore(add(memptr, 0x20), slots.length)
            // update memptr to the first location to hold an array entry
            memptr := add(memptr, 0x40)
            // A left bit-shift of 5 is equivalent to multiplying by 32 but costs less gas.
            let end := add(memptr, shl(5, slots.length))
            let calldataptr := slots.offset
            for {} 1 {} {
                mstore(memptr, sload(calldataload(calldataptr)))
                memptr := add(memptr, 0x20)
                calldataptr := add(calldataptr, 0x20)
                if iszero(lt(memptr, end)) { break }
            }
            return(start, sub(end, start))
        }
    }
}

// lib/v4-core/src/Exttload.sol

/// @notice Enables public transient storage access for efficient state retrieval by external contracts.
/// https://eips.ethereum.org/EIPS/eip-2330#rationale
abstract contract Exttload is IExttload {
    /// @inheritdoc IExttload
    function exttload(bytes32 slot) external view returns (bytes32) {
        assembly ("memory-safe") {
            mstore(0, tload(slot))
            return(0, 0x20)
        }
    }

    /// @inheritdoc IExttload
    function exttload(bytes32[] calldata slots) external view returns (bytes32[] memory) {
        assembly ("memory-safe") {
            let memptr := mload(0x40)
            let start := memptr
            // for abi encoding the response - the array will be found at 0x20
            mstore(memptr, 0x20)
            // next we store the length of the return array
            mstore(add(memptr, 0x20), slots.length)
            // update memptr to the first location to hold an array entry
            memptr := add(memptr, 0x40)
            // A left bit-shift of 5 is equivalent to multiplying by 32 but costs less gas.
            let end := add(memptr, shl(5, slots.length))
            let calldataptr := slots.offset
            for {} 1 {} {
                mstore(memptr, tload(calldataload(calldataptr)))
                memptr := add(memptr, 0x20)
                calldataptr := add(calldataptr, 0x20)
                if iszero(lt(memptr, end)) { break }
            }
            return(start, sub(end, start))
        }
    }
}

// lib/v4-core/src/libraries/LPFeeLibrary.sol

/// @notice Library of helper functions for a pools LP fee
library LPFeeLibrary {
    using LPFeeLibrary for uint24;
    using CustomRevert for bytes4;

    /// @notice Thrown when the static or dynamic fee on a pool exceeds 100%.
    error LPFeeTooLarge(uint24 fee);

    /// @notice An lp fee of exactly 0b1000000... signals a dynamic fee pool. This isn't a valid static fee as it is > MAX_LP_FEE
    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000;

    /// @notice the second bit of the fee returned by beforeSwap is used to signal if the stored LP fee should be overridden in this swap
    // only dynamic-fee pools can return a fee via the beforeSwap hook
    uint24 public constant OVERRIDE_FEE_FLAG = 0x400000;

    /// @notice mask to remove the override fee flag from a fee returned by the beforeSwaphook
    uint24 public constant REMOVE_OVERRIDE_MASK = 0xBFFFFF;

    /// @notice the lp fee is represented in hundredths of a bip, so the max is 100%
    uint24 public constant MAX_LP_FEE = 1000000;

    /// @notice returns true if a pool's LP fee signals that the pool has a dynamic fee
    /// @param self The fee to check
    /// @return bool True of the fee is dynamic
    function isDynamicFee(uint24 self) internal pure returns (bool) {
        return self == DYNAMIC_FEE_FLAG;
    }

    /// @notice returns true if an LP fee is valid, aka not above the maximum permitted fee
    /// @param self The fee to check
    /// @return bool True of the fee is valid
    function isValid(uint24 self) internal pure returns (bool) {
        return self <= MAX_LP_FEE;
    }

    /// @notice validates whether an LP fee is larger than the maximum, and reverts if invalid
    /// @param self The fee to validate
    function validate(uint24 self) internal pure {
        if (!self.isValid()) LPFeeTooLarge.selector.revertWith(self);
    }

    /// @notice gets and validates the initial LP fee for a pool. Dynamic fee pools have an initial fee of 0.
    /// @dev if a dynamic fee pool wants a non-0 initial fee, it should call `updateDynamicLPFee` in the afterInitialize hook
    /// @param self The fee to get the initial LP from
    /// @return initialFee 0 if the fee is dynamic, otherwise the fee (if valid)
    function getInitialLPFee(uint24 self) internal pure returns (uint24) {
        // the initial fee for a dynamic fee pool is 0
        if (self.isDynamicFee()) return 0;
        self.validate();
        return self;
    }

    /// @notice returns true if the fee has the override flag set (2nd highest bit of the uint24)
    /// @param self The fee to check
    /// @return bool True of the fee has the override flag set
    function isOverride(uint24 self) internal pure returns (bool) {
        return self & OVERRIDE_FEE_FLAG != 0;
    }

    /// @notice returns a fee with the override flag removed
    /// @param self The fee to remove the override flag from
    /// @return fee The fee without the override flag set
    function removeOverrideFlag(uint24 self) internal pure returns (uint24) {
        return self & REMOVE_OVERRIDE_MASK;
    }

    /// @notice Removes the override flag and validates the fee (reverts if the fee is too large)
    /// @param self The fee to remove the override flag from, and then validate
    /// @return fee The fee without the override flag set (if valid)
    function removeOverrideFlagAndValidate(uint24 self) internal pure returns (uint24 fee) {
        fee = self.removeOverrideFlag();
        fee.validate();
    }
}

// lib/v4-core/src/NoDelegateCall.sol

/// @title Prevents delegatecall to a contract
/// @notice Base contract that provides a modifier for preventing delegatecall to methods in a child contract
abstract contract NoDelegateCall {
    using CustomRevert for bytes4;

    error DelegateCallNotAllowed();

    /// @dev The original address of this contract
    address private immutable original;

    constructor() {
        // Immutables are computed in the init code of the contract, and then inlined into the deployed bytecode.
        // In other words, this variable won't change when it's checked at runtime.
        original = address(this);
    }

    /// @dev Private method is used instead of inlining into modifier because modifiers are copied into each method,
    ///     and the use of immutable means the address bytes are copied in every place the modifier is used.
    function checkNotDelegateCall() private view {
        if (address(this) != original) DelegateCallNotAllowed.selector.revertWith();
    }

    /// @notice Prevents delegatecall into the modified method
    modifier noDelegateCall() {
        checkNotDelegateCall();
        _;
    }
}

// lib/v4-core/src/libraries/SafeCast.sol

/// @title Safe casting methods
/// @notice Contains methods for safely casting between types
library SafeCast {
    using CustomRevert for bytes4;

    error SafeCastOverflow();

    /// @notice Cast a uint256 to a uint160, revert on overflow
    /// @param x The uint256 to be downcasted
    /// @return y The downcasted integer, now type uint160
    function toUint160(uint256 x) internal pure returns (uint160 y) {
        y = uint160(x);
        if (y != x) SafeCastOverflow.selector.revertWith();
    }

    /// @notice Cast a uint256 to a uint128, revert on overflow
    /// @param x The uint256 to be downcasted
    /// @return y The downcasted integer, now type uint128
    function toUint128(uint256 x) internal pure returns (uint128 y) {
        y = uint128(x);
        if (x != y) SafeCastOverflow.selector.revertWith();
    }

    /// @notice Cast a int128 to a uint128, revert on overflow or underflow
    /// @param x The int128 to be casted
    /// @return y The casted integer, now type uint128
    function toUint128(int128 x) internal pure returns (uint128 y) {
        if (x < 0) SafeCastOverflow.selector.revertWith();
        y = uint128(x);
    }

    /// @notice Cast a int256 to a int128, revert on overflow or underflow
    /// @param x The int256 to be downcasted
    /// @return y The downcasted integer, now type int128
    function toInt128(int256 x) internal pure returns (int128 y) {
        y = int128(x);
        if (y != x) SafeCastOverflow.selector.revertWith();
    }

    /// @notice Cast a uint256 to a int256, revert on overflow
    /// @param x The uint256 to be casted
    /// @return y The casted integer, now type int256
    function toInt256(uint256 x) internal pure returns (int256 y) {
        y = int256(x);
        if (y < 0) SafeCastOverflow.selector.revertWith();
    }

    /// @notice Cast a uint256 to a int128, revert on overflow
    /// @param x The uint256 to be downcasted
    /// @return The downcasted integer, now type int128
    function toInt128(uint256 x) internal pure returns (int128) {
        if (x >= 1 << 127) SafeCastOverflow.selector.revertWith();
        return int128(int256(x));
    }
}

// lib/v4-core/src/libraries/TickBitmap.sol

/// @title Packed tick initialized state library
/// @notice Stores a packed mapping of tick index to its initialized state
/// @dev The mapping uses int16 for keys since ticks are represented as int24 and there are 256 (2^8) values per word.
library TickBitmap {
    /// @notice Thrown when the tick is not enumerated by the tick spacing
    /// @param tick the invalid tick
    /// @param tickSpacing The tick spacing of the pool
    error TickMisaligned(int24 tick, int24 tickSpacing);

    /// @dev round towards negative infinity
    function compress(int24 tick, int24 tickSpacing) internal pure returns (int24 compressed) {
        // compressed = tick / tickSpacing;
        // if (tick < 0 && tick % tickSpacing != 0) compressed--;
        assembly ("memory-safe") {
            tick := signextend(2, tick)
            tickSpacing := signextend(2, tickSpacing)
            compressed := sub(
                sdiv(tick, tickSpacing),
                // if (tick < 0 && tick % tickSpacing != 0) then tick % tickSpacing < 0, vice versa
                slt(smod(tick, tickSpacing), 0)
            )
        }
    }

    /// @notice Computes the position in the mapping where the initialized bit for a tick lives
    /// @param tick The tick for which to compute the position
    /// @return wordPos The key in the mapping containing the word in which the bit is stored
    /// @return bitPos The bit position in the word where the flag is stored
    function position(int24 tick) internal pure returns (int16 wordPos, uint8 bitPos) {
        assembly ("memory-safe") {
            // signed arithmetic shift right
            wordPos := sar(8, signextend(2, tick))
            bitPos := and(tick, 0xff)
        }
    }

    /// @notice Flips the initialized state for a given tick from false to true, or vice versa
    /// @param self The mapping in which to flip the tick
    /// @param tick The tick to flip
    /// @param tickSpacing The spacing between usable ticks
    function flipTick(mapping(int16 => uint256) storage self, int24 tick, int24 tickSpacing) internal {
        // Equivalent to the following Solidity:
        //     if (tick % tickSpacing != 0) revert TickMisaligned(tick, tickSpacing);
        //     (int16 wordPos, uint8 bitPos) = position(tick / tickSpacing);
        //     uint256 mask = 1 << bitPos;
        //     self[wordPos] ^= mask;
        assembly ("memory-safe") {
            tick := signextend(2, tick)
            tickSpacing := signextend(2, tickSpacing)
            // ensure that the tick is spaced
            if smod(tick, tickSpacing) {
                let fmp := mload(0x40)
                mstore(fmp, 0xd4d8f3e6) // selector for TickMisaligned(int24,int24)
                mstore(add(fmp, 0x20), tick)
                mstore(add(fmp, 0x40), tickSpacing)
                revert(add(fmp, 0x1c), 0x44)
            }
            tick := sdiv(tick, tickSpacing)
            // calculate the storage slot corresponding to the tick
            // wordPos = tick >> 8
            mstore(0, sar(8, tick))
            mstore(0x20, self.slot)
            // the slot of self[wordPos] is keccak256(abi.encode(wordPos, self.slot))
            let slot := keccak256(0, 0x40)
            // mask = 1 << bitPos = 1 << (tick % 256)
            // self[wordPos] ^= mask
            sstore(slot, xor(sload(slot), shl(and(tick, 0xff), 1)))
        }
    }

    /// @notice Returns the next initialized tick contained in the same word (or adjacent word) as the tick that is either
    /// to the left (less than or equal to) or right (greater than) of the given tick
    /// @param self The mapping in which to compute the next initialized tick
    /// @param tick The starting tick
    /// @param tickSpacing The spacing between usable ticks
    /// @param lte Whether to search for the next initialized tick to the left (less than or equal to the starting tick)
    /// @return next The next initialized or uninitialized tick up to 256 ticks away from the current tick
    /// @return initialized Whether the next tick is initialized, as the function only searches within up to 256 ticks
    function nextInitializedTickWithinOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        unchecked {
            int24 compressed = compress(tick, tickSpacing);

            if (lte) {
                (int16 wordPos, uint8 bitPos) = position(compressed);
                // all the 1s at or to the right of the current bitPos
                uint256 mask = type(uint256).max >> (uint256(type(uint8).max) - bitPos);
                uint256 masked = self[wordPos] & mask;

                // if there are no initialized ticks to the right of or at the current tick, return rightmost in the word
                initialized = masked != 0;
                // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                // start from the word of the next tick, since the current tick state doesn't matter
                (int16 wordPos, uint8 bitPos) = position(++compressed);
                // all the 1s at or to the left of the bitPos
                uint256 mask = ~((1 << bitPos) - 1);
                uint256 masked = self[wordPos] & mask;

                // if there are no initialized ticks to the left of the current tick, return leftmost in the word
                initialized = masked != 0;
                // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }
}

// lib/v4-core/src/types/BalanceDelta.sol

/// @dev Two `int128` values packed into a single `int256` where the upper 128 bits represent the amount0
/// and the lower 128 bits represent the amount1.
type BalanceDelta is int256;

using {add as +, sub as -, eq as ==, neq as !=} for BalanceDelta global;
using BalanceDeltaLibrary for BalanceDelta global;
using SafeCast for int256;

function toBalanceDelta(int128 _amount0, int128 _amount1) pure returns (BalanceDelta balanceDelta) {
    assembly ("memory-safe") {
        balanceDelta := or(shl(128, _amount0), and(sub(shl(128, 1), 1), _amount1))
    }
}

function add(BalanceDelta a, BalanceDelta b) pure returns (BalanceDelta) {
    int256 res0;
    int256 res1;
    assembly ("memory-safe") {
        let a0 := sar(128, a)
        let a1 := signextend(15, a)
        let b0 := sar(128, b)
        let b1 := signextend(15, b)
        res0 := add(a0, b0)
        res1 := add(a1, b1)
    }
    return toBalanceDelta(res0.toInt128(), res1.toInt128());
}

function sub(BalanceDelta a, BalanceDelta b) pure returns (BalanceDelta) {
    int256 res0;
    int256 res1;
    assembly ("memory-safe") {
        let a0 := sar(128, a)
        let a1 := signextend(15, a)
        let b0 := sar(128, b)
        let b1 := signextend(15, b)
        res0 := sub(a0, b0)
        res1 := sub(a1, b1)
    }
    return toBalanceDelta(res0.toInt128(), res1.toInt128());
}

function eq(BalanceDelta a, BalanceDelta b) pure returns (bool) {
    return BalanceDelta.unwrap(a) == BalanceDelta.unwrap(b);
}

function neq(BalanceDelta a, BalanceDelta b) pure returns (bool) {
    return BalanceDelta.unwrap(a) != BalanceDelta.unwrap(b);
}

/// @notice Library for getting the amount0 and amount1 deltas from the BalanceDelta type
library BalanceDeltaLibrary {
    /// @notice A BalanceDelta of 0
    BalanceDelta public constant ZERO_DELTA = BalanceDelta.wrap(0);

    function amount0(BalanceDelta balanceDelta) internal pure returns (int128 _amount0) {
        assembly ("memory-safe") {
            _amount0 := sar(128, balanceDelta)
        }
    }

    function amount1(BalanceDelta balanceDelta) internal pure returns (int128 _amount1) {
        assembly ("memory-safe") {
            _amount1 := signextend(15, balanceDelta)
        }
    }
}

// lib/v4-core/src/types/Currency.sol

type Currency is address;

using {greaterThan as >, lessThan as <, greaterThanOrEqualTo as >=, equals as ==} for Currency global;
using CurrencyLibrary for Currency global;

function equals(Currency currency, Currency other) pure returns (bool) {
    return Currency.unwrap(currency) == Currency.unwrap(other);
}

function greaterThan(Currency currency, Currency other) pure returns (bool) {
    return Currency.unwrap(currency) > Currency.unwrap(other);
}

function lessThan(Currency currency, Currency other) pure returns (bool) {
    return Currency.unwrap(currency) < Currency.unwrap(other);
}

function greaterThanOrEqualTo(Currency currency, Currency other) pure returns (bool) {
    return Currency.unwrap(currency) >= Currency.unwrap(other);
}

/// @title CurrencyLibrary
/// @dev This library allows for transferring and holding native tokens and ERC20 tokens
library CurrencyLibrary {
    /// @notice Additional context for ERC-7751 wrapped error when a native transfer fails
    error NativeTransferFailed();

    /// @notice Additional context for ERC-7751 wrapped error when an ERC20 transfer fails
    error ERC20TransferFailed();

    /// @notice A constant to represent the native currency
    Currency public constant ADDRESS_ZERO = Currency.wrap(address(0));

    function transfer(Currency currency, address to, uint256 amount) internal {
        // altered from https://github.com/transmissions11/solmate/blob/44a9963d4c78111f77caa0e65d677b8b46d6f2e6/src/utils/SafeTransferLib.sol
        // modified custom error selectors

        bool success;
        if (currency.isAddressZero()) {
            assembly ("memory-safe") {
                // Transfer the ETH and revert if it fails.
                success := call(gas(), to, amount, 0, 0, 0, 0)
            }
            // revert with NativeTransferFailed, containing the bubbled up error as an argument
            if (!success) {
                CustomRevert.bubbleUpAndRevertWith(to, bytes4(0), NativeTransferFailed.selector);
            }
        } else {
            assembly ("memory-safe") {
                // Get a pointer to some free memory.
                let fmp := mload(0x40)

                // Write the abi-encoded calldata into memory, beginning with the function selector.
                mstore(fmp, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
                mstore(add(fmp, 4), and(to, 0xffffffffffffffffffffffffffffffffffffffff)) // Append and mask the "to" argument.
                mstore(add(fmp, 36), amount) // Append the "amount" argument. Masking not required as it's a full 32 byte type.

                success := and(
                    // Set success to whether the call reverted, if not we check it either
                    // returned exactly 1 (can't just be non-zero data), or had no return data.
                    or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                    // We use 68 because the length of our calldata totals up like so: 4 + 32 * 2.
                    // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
                    // Counterintuitively, this call must be positioned second to the or() call in the
                    // surrounding and() call or else returndatasize() will be zero during the computation.
                    call(gas(), currency, 0, fmp, 68, 0, 32)
                )

                // Now clean the memory we used
                mstore(fmp, 0) // 4 byte `selector` and 28 bytes of `to` were stored here
                mstore(add(fmp, 0x20), 0) // 4 bytes of `to` and 28 bytes of `amount` were stored here
                mstore(add(fmp, 0x40), 0) // 4 bytes of `amount` were stored here
            }
            // revert with ERC20TransferFailed, containing the bubbled up error as an argument
            if (!success) {
                CustomRevert.bubbleUpAndRevertWith(
                    Currency.unwrap(currency), IERC20Minimal.transfer.selector, ERC20TransferFailed.selector
                );
            }
        }
    }

    function balanceOfSelf(Currency currency) internal view returns (uint256) {
        if (currency.isAddressZero()) {
            return address(this).balance;
        } else {
            return IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
        }
    }

    function balanceOf(Currency currency, address owner) internal view returns (uint256) {
        if (currency.isAddressZero()) {
            return owner.balance;
        } else {
            return IERC20Minimal(Currency.unwrap(currency)).balanceOf(owner);
        }
    }

    function isAddressZero(Currency currency) internal pure returns (bool) {
        return Currency.unwrap(currency) == Currency.unwrap(ADDRESS_ZERO);
    }

    function toId(Currency currency) internal pure returns (uint256) {
        return uint160(Currency.unwrap(currency));
    }

    // If the upper 12 bytes are non-zero, they will be zero-ed out
    // Therefore, fromId() and toId() are not inverses of each other
    function fromId(uint256 id) internal pure returns (Currency) {
        return Currency.wrap(address(uint160(id)));
    }
}

// lib/v4-core/src/ERC6909Claims.sol

/// @notice ERC6909Claims inherits ERC6909 and implements an internal burnFrom function
abstract contract ERC6909Claims is ERC6909 {
    /// @notice Burn `amount` tokens of token type `id` from `from`.
    /// @dev if sender is not `from` they must be an operator or have sufficient allowance.
    /// @param from The address to burn tokens from.
    /// @param id The currency to burn.
    /// @param amount The amount to burn.
    function _burnFrom(address from, uint256 id, uint256 amount) internal {
        address sender = msg.sender;
        if (from != sender && !isOperator[from][sender]) {
            uint256 senderAllowance = allowance[from][sender][id];
            if (senderAllowance != type(uint256).max) {
                allowance[from][sender][id] = senderAllowance - amount;
            }
        }
        _burn(from, id, amount);
    }
}

// lib/v4-core/test/utils/LiquidityAmounts.sol

/// @title Liquidity amount functions
/// @notice Provides functions for computing liquidity amounts from token amounts and prices
library LiquidityAmounts {
    /// @notice Downcasts uint256 to uint128
    /// @param x The uint258 to be downcasted
    /// @return y The passed value, downcasted to uint128
    function toUint128(uint256 x) private pure returns (uint128 y) {
        require((y = uint128(x)) == x, "liquidity overflow");
    }

    /// @notice Computes the amount of liquidity received for a given amount of token0 and price range
    /// @dev Calculates amount0 * (sqrt(upper) * sqrt(lower)) / (sqrt(upper) - sqrt(lower))
    /// @param sqrtPriceAX96 A sqrt price representing the first tick boundary
    /// @param sqrtPriceBX96 A sqrt price representing the second tick boundary
    /// @param amount0 The amount0 being sent in
    /// @return liquidity The amount of returned liquidity
    function getLiquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        uint256 intermediate = FullMath.mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96);
        return toUint128(FullMath.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /// @notice Computes the amount of liquidity received for a given amount of token1 and price range
    /// @dev Calculates amount1 / (sqrt(upper) - sqrt(lower)).
    /// @param sqrtPriceAX96 A sqrt price representing the first tick boundary
    /// @param sqrtPriceBX96 A sqrt price representing the second tick boundary
    /// @param amount1 The amount1 being sent in
    /// @return liquidity The amount of returned liquidity
    function getLiquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        return toUint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /// @notice Computes the maximum amount of liquidity received for a given amount of token0, token1, the current
    /// pool prices and the prices at the tick boundaries
    /// @param sqrtPriceX96 A sqrt price representing the current pool prices
    /// @param sqrtPriceAX96 A sqrt price representing the first tick boundary
    /// @param sqrtPriceBX96 A sqrt price representing the second tick boundary
    /// @param amount0 The amount of token0 being sent in
    /// @param amount1 The amount of token1 being sent in
    /// @return liquidity The maximum amount of liquidity received
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1);

            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }

    /// @notice Computes the amount of token0 for a given amount of liquidity and a price range
    /// @param sqrtPriceAX96 A sqrt price representing the first tick boundary
    /// @param sqrtPriceBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount0 The amount of token0
    function getAmount0ForLiquidity(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        return FullMath.mulDiv(
            uint256(liquidity) << FixedPoint96.RESOLUTION, sqrtPriceBX96 - sqrtPriceAX96, sqrtPriceBX96
        ) / sqrtPriceAX96;
    }

    /// @notice Computes the amount of token1 for a given amount of liquidity and a price range
    /// @param sqrtPriceAX96 A sqrt price representing the first tick boundary
    /// @param sqrtPriceBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount1 The amount of token1
    function getAmount1ForLiquidity(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        return FullMath.mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceAX96, FixedPoint96.Q96);
    }

    /// @notice Computes the token0 and token1 value for a given amount of liquidity, the current
    /// pool prices and the prices at the tick boundaries
    /// @param sqrtPriceX96 A sqrt price representing the current pool prices
    /// @param sqrtPriceAX96 A sqrt price representing the first tick boundary
    /// @param sqrtPriceBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount0 The amount of token0
    /// @return amount1 The amount of token1
    function getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = getAmount0ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = getAmount0ForLiquidity(sqrtPriceX96, sqrtPriceBX96, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtPriceAX96, sqrtPriceX96, liquidity);
        } else {
            amount1 = getAmount1ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity);
        }
    }
}

// lib/v4-core/src/libraries/TickMath.sol

/// @title Math library for computing sqrt prices from ticks and vice versa
/// @notice Computes sqrt price for ticks of size 1.0001, i.e. sqrt(1.0001^tick) as fixed point Q64.96 numbers. Supports
/// prices between 2**-128 and 2**128
library TickMath {
    using CustomRevert for bytes4;

    /// @notice Thrown when the tick passed to #getSqrtPriceAtTick is not between MIN_TICK and MAX_TICK
    error InvalidTick(int24 tick);
    /// @notice Thrown when the price passed to #getTickAtSqrtPrice does not correspond to a price between MIN_TICK and MAX_TICK
    error InvalidSqrtPrice(uint160 sqrtPriceX96);

    /// @dev The minimum tick that may be passed to #getSqrtPriceAtTick computed from log base 1.0001 of 2**-128
    /// @dev If ever MIN_TICK and MAX_TICK are not centered around 0, the absTick logic in getSqrtPriceAtTick cannot be used
    int24 internal constant MIN_TICK = -887272;
    /// @dev The maximum tick that may be passed to #getSqrtPriceAtTick computed from log base 1.0001 of 2**128
    /// @dev If ever MIN_TICK and MAX_TICK are not centered around 0, the absTick logic in getSqrtPriceAtTick cannot be used
    int24 internal constant MAX_TICK = 887272;

    /// @dev The minimum tick spacing value drawn from the range of type int16 that is greater than 0, i.e. min from the range [1, 32767]
    int24 internal constant MIN_TICK_SPACING = 1;
    /// @dev The maximum tick spacing value drawn from the range of type int16, i.e. max from the range [1, 32767]
    int24 internal constant MAX_TICK_SPACING = type(int16).max;

    /// @dev The minimum value that can be returned from #getSqrtPriceAtTick. Equivalent to getSqrtPriceAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    /// @dev The maximum value that can be returned from #getSqrtPriceAtTick. Equivalent to getSqrtPriceAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
    /// @dev A threshold used for optimized bounds check, equals `MAX_SQRT_PRICE - MIN_SQRT_PRICE - 1`
    uint160 internal constant MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE =
        1461446703485210103287273052203988822378723970342 - 4295128739 - 1;

    /// @notice Given a tickSpacing, compute the maximum usable tick
    function maxUsableTick(int24 tickSpacing) internal pure returns (int24) {
        unchecked {
            return (MAX_TICK / tickSpacing) * tickSpacing;
        }
    }

    /// @notice Given a tickSpacing, compute the minimum usable tick
    function minUsableTick(int24 tickSpacing) internal pure returns (int24) {
        unchecked {
            return (MIN_TICK / tickSpacing) * tickSpacing;
        }
    }

    /// @notice Calculates sqrt(1.0001^tick) * 2^96
    /// @dev Throws if |tick| > max tick
    /// @param tick The input tick for the above formula
    /// @return sqrtPriceX96 A Fixed point Q64.96 number representing the sqrt of the price of the two assets (currency1/currency0)
    /// at the given tick
    function getSqrtPriceAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick;
            assembly ("memory-safe") {
                tick := signextend(2, tick)
                // mask = 0 if tick >= 0 else -1 (all 1s)
                let mask := sar(255, tick)
                // if tick >= 0, |tick| = tick = 0 ^ tick
                // if tick < 0, |tick| = ~~|tick| = ~(-|tick| - 1) = ~(tick - 1) = (-1) ^ (tick - 1)
                // either way, |tick| = mask ^ (tick + mask)
                absTick := xor(mask, add(mask, tick))
            }

            if (absTick > uint256(int256(MAX_TICK))) InvalidTick.selector.revertWith(tick);

            // The tick is decomposed into bits, and for each bit with index i that is set, the product of 1/sqrt(1.0001^(2^i))
            // is calculated (using Q128.128). The constants used for this calculation are rounded to the nearest integer

            // Equivalent to:
            //     price = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            //     or price = int(2**128 / sqrt(1.0001)) if (absTick & 0x1) else 1 << 128
            uint256 price;
            assembly ("memory-safe") {
                price := xor(shl(128, 1), mul(xor(shl(128, 1), 0xfffcb933bd6fad37aa2d162d1a594001), and(absTick, 0x1)))
            }
            if (absTick & 0x2 != 0) price = (price * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) price = (price * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) price = (price * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) price = (price * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) price = (price * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) price = (price * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) price = (price * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) price = (price * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) price = (price * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) price = (price * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) price = (price * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) price = (price * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) price = (price * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) price = (price * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) price = (price * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) price = (price * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) price = (price * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) price = (price * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) price = (price * 0x48a170391f7dc42444e8fa2) >> 128;

            assembly ("memory-safe") {
                // if (tick > 0) price = type(uint256).max / price;
                if sgt(tick, 0) { price := div(not(0), price) }

                // this divides by 1<<32 rounding up to go from a Q128.128 to a Q128.96.
                // we then downcast because we know the result always fits within 160 bits due to our tick input constraint
                // we round up in the division so getTickAtSqrtPrice of the output price is always consistent
                // `sub(shl(32, 1), 1)` is `type(uint32).max`
                // `price + type(uint32).max` will not overflow because `price` fits in 192 bits
                sqrtPriceX96 := shr(32, add(price, sub(shl(32, 1), 1)))
            }
        }
    }

    /// @notice Calculates the greatest tick value such that getSqrtPriceAtTick(tick) <= sqrtPriceX96
    /// @dev Throws in case sqrtPriceX96 < MIN_SQRT_PRICE, as MIN_SQRT_PRICE is the lowest value getSqrtPriceAtTick may
    /// ever return.
    /// @param sqrtPriceX96 The sqrt price for which to compute the tick as a Q64.96
    /// @return tick The greatest tick for which the getSqrtPriceAtTick(tick) is less than or equal to the input sqrtPriceX96
    function getTickAtSqrtPrice(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        unchecked {
            // Equivalent: if (sqrtPriceX96 < MIN_SQRT_PRICE || sqrtPriceX96 >= MAX_SQRT_PRICE) revert InvalidSqrtPrice();
            // second inequality must be >= because the price can never reach the price at the max tick
            // if sqrtPriceX96 < MIN_SQRT_PRICE, the `sub` underflows and `gt` is true
            // if sqrtPriceX96 >= MAX_SQRT_PRICE, sqrtPriceX96 - MIN_SQRT_PRICE > MAX_SQRT_PRICE - MIN_SQRT_PRICE - 1
            if ((sqrtPriceX96 - MIN_SQRT_PRICE) > MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE) {
                InvalidSqrtPrice.selector.revertWith(sqrtPriceX96);
            }

            uint256 price = uint256(sqrtPriceX96) << 32;

            uint256 r = price;
            uint256 msb = BitMath.mostSignificantBit(r);

            if (msb >= 128) r = price >> (msb - 127);
            else r = price << (127 - msb);

            int256 log_2 = (int256(msb) - 128) << 64;

            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(63, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(62, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(61, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(60, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(59, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(58, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(57, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(56, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(55, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(54, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(53, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(52, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(51, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(50, f))
            }

            int256 log_sqrt10001 = log_2 * 255738958999603826347141; // Q22.128 number

            // Magic number represents the ceiling of the maximum value of the error when approximating log_sqrt10001(x)
            int24 tickLow = int24((log_sqrt10001 - 3402992956809132418596140100660247210) >> 128);

            // Magic number represents the minimum value of the error when approximating log_sqrt10001(x), when
            // sqrtPrice is from the range (2^-64, 2^64). This is safe as MIN_SQRT_PRICE is more than 2^-64. If MIN_SQRT_PRICE
            // is changed, this may need to be changed too
            int24 tickHi = int24((log_sqrt10001 + 291339464771989622907027621153398088495) >> 128);

            tick = tickLow == tickHi ? tickLow : getSqrtPriceAtTick(tickHi) <= sqrtPriceX96 ? tickHi : tickLow;
        }
    }
}

// lib/v4-core/src/libraries/CurrencyDelta.sol

/// @title a library to store callers' currency deltas in transient storage
/// @dev this library implements the equivalent of a mapping, as transient storage can only be accessed in assembly
library CurrencyDelta {
    /// @notice calculates which storage slot a delta should be stored in for a given account and currency
    function _computeSlot(address target, Currency currency) internal pure returns (bytes32 hashSlot) {
        assembly ("memory-safe") {
            mstore(0, and(target, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(32, and(currency, 0xffffffffffffffffffffffffffffffffffffffff))
            hashSlot := keccak256(0, 64)
        }
    }

    function getDelta(Currency currency, address target) internal view returns (int256 delta) {
        bytes32 hashSlot = _computeSlot(target, currency);
        assembly ("memory-safe") {
            delta := tload(hashSlot)
        }
    }

    /// @notice applies a new currency delta for a given account and currency
    /// @return previous The prior value
    /// @return next The modified result
    function applyDelta(Currency currency, address target, int128 delta)
        internal
        returns (int256 previous, int256 next)
    {
        bytes32 hashSlot = _computeSlot(target, currency);

        assembly ("memory-safe") {
            previous := tload(hashSlot)
        }
        next = previous + delta;
        assembly ("memory-safe") {
            tstore(hashSlot, next)
        }
    }
}

// lib/v4-core/src/libraries/CurrencyReserves.sol

library CurrencyReserves {
    using CustomRevert for bytes4;

    /// bytes32(uint256(keccak256("ReservesOf")) - 1)
    bytes32 constant RESERVES_OF_SLOT = 0x1e0745a7db1623981f0b2a5d4232364c00787266eb75ad546f190e6cebe9bd95;
    /// bytes32(uint256(keccak256("Currency")) - 1)
    bytes32 constant CURRENCY_SLOT = 0x27e098c505d44ec3574004bca052aabf76bd35004c182099d8c575fb238593b9;

    function getSyncedCurrency() internal view returns (Currency currency) {
        assembly ("memory-safe") {
            currency := tload(CURRENCY_SLOT)
        }
    }

    function resetCurrency() internal {
        assembly ("memory-safe") {
            tstore(CURRENCY_SLOT, 0)
        }
    }

    function syncCurrencyAndReserves(Currency currency, uint256 value) internal {
        assembly ("memory-safe") {
            tstore(CURRENCY_SLOT, and(currency, 0xffffffffffffffffffffffffffffffffffffffff))
            tstore(RESERVES_OF_SLOT, value)
        }
    }

    function getSyncedReserves() internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(RESERVES_OF_SLOT)
        }
    }
}

// lib/v4-core/src/libraries/Position.sol

/// @title Position
/// @notice Positions represent an owner address' liquidity between a lower and upper tick boundary
/// @dev Positions store additional state for tracking fees owed to the position
library Position {
    using CustomRevert for bytes4;

    /// @notice Cannot update a position with no liquidity
    error CannotUpdateEmptyPosition();

    // info stored for each user's position
    struct State {
        // the amount of liquidity owned by this position
        uint128 liquidity;
        // fee growth per unit of liquidity as of the last update to liquidity or fees owed
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
    }

    /// @notice Returns the State struct of a position, given an owner and position boundaries
    /// @param self The mapping containing all user positions
    /// @param owner The address of the position owner
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @param salt A unique value to differentiate between multiple positions in the same range
    /// @return position The position info struct of the given owners' position
    function get(mapping(bytes32 => State) storage self, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        view
        returns (State storage position)
    {
        bytes32 positionKey = calculatePositionKey(owner, tickLower, tickUpper, salt);
        position = self[positionKey];
    }

    /// @notice A helper function to calculate the position key
    /// @param owner The address of the position owner
    /// @param tickLower the lower tick boundary of the position
    /// @param tickUpper the upper tick boundary of the position
    /// @param salt A unique value to differentiate between multiple positions in the same range, by the same owner. Passed in by the caller.
    function calculatePositionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32 positionKey)
    {
        // positionKey = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt))
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(add(fmp, 0x26), salt) // [0x26, 0x46)
            mstore(add(fmp, 0x06), tickUpper) // [0x23, 0x26)
            mstore(add(fmp, 0x03), tickLower) // [0x20, 0x23)
            mstore(fmp, owner) // [0x0c, 0x20)
            positionKey := keccak256(add(fmp, 0x0c), 0x3a) // len is 58 bytes

            // now clean the memory we used
            mstore(add(fmp, 0x40), 0) // fmp+0x40 held salt
            mstore(add(fmp, 0x20), 0) // fmp+0x20 held tickLower, tickUpper, salt
            mstore(fmp, 0) // fmp held owner
        }
    }

    /// @notice Credits accumulated fees to a user's position
    /// @param self The individual position to update
    /// @param liquidityDelta The change in pool liquidity as a result of the position update
    /// @param feeGrowthInside0X128 The all-time fee growth in currency0, per unit of liquidity, inside the position's tick boundaries
    /// @param feeGrowthInside1X128 The all-time fee growth in currency1, per unit of liquidity, inside the position's tick boundaries
    /// @return feesOwed0 The amount of currency0 owed to the position owner
    /// @return feesOwed1 The amount of currency1 owed to the position owner
    function update(
        State storage self,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal returns (uint256 feesOwed0, uint256 feesOwed1) {
        uint128 liquidity = self.liquidity;

        if (liquidityDelta == 0) {
            // disallow pokes for 0 liquidity positions
            if (liquidity == 0) CannotUpdateEmptyPosition.selector.revertWith();
        } else {
            self.liquidity = LiquidityMath.addDelta(liquidity, liquidityDelta);
        }

        // calculate accumulated fees. overflow in the subtraction of fee growth is expected
        unchecked {
            feesOwed0 =
                FullMath.mulDiv(feeGrowthInside0X128 - self.feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128);
            feesOwed1 =
                FullMath.mulDiv(feeGrowthInside1X128 - self.feeGrowthInside1LastX128, liquidity, FixedPoint128.Q128);
        }

        // update the position
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;
    }
}

// lib/v4-core/src/libraries/SqrtPriceMath.sol

/// @title Functions based on Q64.96 sqrt price and liquidity
/// @notice Contains the math that uses square root of price as a Q64.96 and liquidity to compute deltas
library SqrtPriceMath {
    using SafeCast for uint256;

    error InvalidPriceOrLiquidity();
    error InvalidPrice();
    error NotEnoughLiquidity();
    error PriceOverflow();

    /// @notice Gets the next sqrt price given a delta of currency0
    /// @dev Always rounds up, because in the exact output case (increasing price) we need to move the price at least
    /// far enough to get the desired output amount, and in the exact input case (decreasing price) we need to move the
    /// price less in order to not send too much output.
    /// The most precise formula for this is liquidity * sqrtPX96 / (liquidity +- amount * sqrtPX96),
    /// if this is impossible because of overflow, we calculate liquidity / (liquidity / sqrtPX96 +- amount).
    /// @param sqrtPX96 The starting price, i.e. before accounting for the currency0 delta
    /// @param liquidity The amount of usable liquidity
    /// @param amount How much of currency0 to add or remove from virtual reserves
    /// @param add Whether to add or remove the amount of currency0
    /// @return The price after adding or removing amount, depending on add
    function getNextSqrtPriceFromAmount0RoundingUp(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        internal
        pure
        returns (uint160)
    {
        // we short circuit amount == 0 because the result is otherwise not guaranteed to equal the input price
        if (amount == 0) return sqrtPX96;
        uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;

        if (add) {
            unchecked {
                uint256 product = amount * sqrtPX96;
                if (product / amount == sqrtPX96) {
                    uint256 denominator = numerator1 + product;
                    if (denominator >= numerator1) {
                        // always fits in 160 bits
                        return uint160(FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator));
                    }
                }
            }
            // denominator is checked for overflow
            return uint160(UnsafeMath.divRoundingUp(numerator1, (numerator1 / sqrtPX96) + amount));
        } else {
            unchecked {
                uint256 product = amount * sqrtPX96;
                // if the product overflows, we know the denominator underflows
                // in addition, we must check that the denominator does not underflow
                // equivalent: if (product / amount != sqrtPX96 || numerator1 <= product) revert PriceOverflow();
                assembly ("memory-safe") {
                    if iszero(
                        and(
                            eq(div(product, amount), and(sqrtPX96, 0xffffffffffffffffffffffffffffffffffffffff)),
                            gt(numerator1, product)
                        )
                    ) {
                        mstore(0, 0xf5c787f1) // selector for PriceOverflow()
                        revert(0x1c, 0x04)
                    }
                }
                uint256 denominator = numerator1 - product;
                return FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator).toUint160();
            }
        }
    }

    /// @notice Gets the next sqrt price given a delta of currency1
    /// @dev Always rounds down, because in the exact output case (decreasing price) we need to move the price at least
    /// far enough to get the desired output amount, and in the exact input case (increasing price) we need to move the
    /// price less in order to not send too much output.
    /// The formula we compute is within <1 wei of the lossless version: sqrtPX96 +- amount / liquidity
    /// @param sqrtPX96 The starting price, i.e., before accounting for the currency1 delta
    /// @param liquidity The amount of usable liquidity
    /// @param amount How much of currency1 to add, or remove, from virtual reserves
    /// @param add Whether to add, or remove, the amount of currency1
    /// @return The price after adding or removing `amount`
    function getNextSqrtPriceFromAmount1RoundingDown(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        internal
        pure
        returns (uint160)
    {
        // if we're adding (subtracting), rounding down requires rounding the quotient down (up)
        // in both cases, avoid a mulDiv for most inputs
        if (add) {
            uint256 quotient =
                (amount <= type(uint160).max
                    ? (amount << FixedPoint96.RESOLUTION) / liquidity
                    : FullMath.mulDiv(amount, FixedPoint96.Q96, liquidity));

            return (uint256(sqrtPX96) + quotient).toUint160();
        } else {
            uint256 quotient =
                (amount <= type(uint160).max
                    ? UnsafeMath.divRoundingUp(amount << FixedPoint96.RESOLUTION, liquidity)
                    : FullMath.mulDivRoundingUp(amount, FixedPoint96.Q96, liquidity));

            // equivalent: if (sqrtPX96 <= quotient) revert NotEnoughLiquidity();
            assembly ("memory-safe") {
                if iszero(gt(and(sqrtPX96, 0xffffffffffffffffffffffffffffffffffffffff), quotient)) {
                    mstore(0, 0x4323a555) // selector for NotEnoughLiquidity()
                    revert(0x1c, 0x04)
                }
            }
            // always fits 160 bits
            unchecked {
                return uint160(sqrtPX96 - quotient);
            }
        }
    }

    /// @notice Gets the next sqrt price given an input amount of currency0 or currency1
    /// @dev Throws if price or liquidity are 0, or if the next price is out of bounds
    /// @param sqrtPX96 The starting price, i.e., before accounting for the input amount
    /// @param liquidity The amount of usable liquidity
    /// @param amountIn How much of currency0, or currency1, is being swapped in
    /// @param zeroForOne Whether the amount in is currency0 or currency1
    /// @return uint160 The price after adding the input amount to currency0 or currency1
    function getNextSqrtPriceFromInput(uint160 sqrtPX96, uint128 liquidity, uint256 amountIn, bool zeroForOne)
        internal
        pure
        returns (uint160)
    {
        // equivalent: if (sqrtPX96 == 0 || liquidity == 0) revert InvalidPriceOrLiquidity();
        assembly ("memory-safe") {
            if or(
                iszero(and(sqrtPX96, 0xffffffffffffffffffffffffffffffffffffffff)),
                iszero(and(liquidity, 0xffffffffffffffffffffffffffffffff))
            ) {
                mstore(0, 0x4f2461b8) // selector for InvalidPriceOrLiquidity()
                revert(0x1c, 0x04)
            }
        }

        // round to make sure that we don't pass the target price
        return zeroForOne
            ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountIn, true)
            : getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountIn, true);
    }

    /// @notice Gets the next sqrt price given an output amount of currency0 or currency1
    /// @dev Throws if price or liquidity are 0 or the next price is out of bounds
    /// @param sqrtPX96 The starting price before accounting for the output amount
    /// @param liquidity The amount of usable liquidity
    /// @param amountOut How much of currency0, or currency1, is being swapped out
    /// @param zeroForOne Whether the amount out is currency1 or currency0
    /// @return uint160 The price after removing the output amount of currency0 or currency1
    function getNextSqrtPriceFromOutput(uint160 sqrtPX96, uint128 liquidity, uint256 amountOut, bool zeroForOne)
        internal
        pure
        returns (uint160)
    {
        // equivalent: if (sqrtPX96 == 0 || liquidity == 0) revert InvalidPriceOrLiquidity();
        assembly ("memory-safe") {
            if or(
                iszero(and(sqrtPX96, 0xffffffffffffffffffffffffffffffffffffffff)),
                iszero(and(liquidity, 0xffffffffffffffffffffffffffffffff))
            ) {
                mstore(0, 0x4f2461b8) // selector for InvalidPriceOrLiquidity()
                revert(0x1c, 0x04)
            }
        }

        // round to make sure that we pass the target price
        return zeroForOne
            ? getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountOut, false)
            : getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountOut, false);
    }

    /// @notice Gets the amount0 delta between two prices
    /// @dev Calculates liquidity / sqrt(lower) - liquidity / sqrt(upper),
    /// i.e. liquidity * (sqrt(upper) - sqrt(lower)) / (sqrt(upper) * sqrt(lower))
    /// @param sqrtPriceAX96 A sqrt price
    /// @param sqrtPriceBX96 Another sqrt price
    /// @param liquidity The amount of usable liquidity
    /// @param roundUp Whether to round the amount up or down
    /// @return uint256 Amount of currency0 required to cover a position of size liquidity between the two passed prices
    function getAmount0Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        unchecked {
            if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

            // equivalent: if (sqrtPriceAX96 == 0) revert InvalidPrice();
            assembly ("memory-safe") {
                if iszero(and(sqrtPriceAX96, 0xffffffffffffffffffffffffffffffffffffffff)) {
                    mstore(0, 0x00bfc921) // selector for InvalidPrice()
                    revert(0x1c, 0x04)
                }
            }

            uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;
            uint256 numerator2 = sqrtPriceBX96 - sqrtPriceAX96;

            return roundUp
                ? UnsafeMath.divRoundingUp(
                    FullMath.mulDivRoundingUp(numerator1, numerator2, sqrtPriceBX96), sqrtPriceAX96
                )
                : FullMath.mulDiv(numerator1, numerator2, sqrtPriceBX96) / sqrtPriceAX96;
        }
    }

    /// @notice Equivalent to: `a >= b ? a - b : b - a`
    function absDiff(uint160 a, uint160 b) internal pure returns (uint256 res) {
        assembly ("memory-safe") {
            let diff :=
                sub(
                    and(a, 0xffffffffffffffffffffffffffffffffffffffff),
                    and(b, 0xffffffffffffffffffffffffffffffffffffffff)
                )
            // mask = 0 if a >= b else -1 (all 1s)
            let mask := sar(255, diff)
            // if a >= b, res = a - b = 0 ^ (a - b)
            // if a < b, res = b - a = ~~(b - a) = ~(-(b - a) - 1) = ~(a - b - 1) = (-1) ^ (a - b - 1)
            // either way, res = mask ^ (a - b + mask)
            res := xor(mask, add(mask, diff))
        }
    }

    /// @notice Gets the amount1 delta between two prices
    /// @dev Calculates liquidity * (sqrt(upper) - sqrt(lower))
    /// @param sqrtPriceAX96 A sqrt price
    /// @param sqrtPriceBX96 Another sqrt price
    /// @param liquidity The amount of usable liquidity
    /// @param roundUp Whether to round the amount up, or down
    /// @return amount1 Amount of currency1 required to cover a position of size liquidity between the two passed prices
    function getAmount1Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256 amount1)
    {
        uint256 numerator = absDiff(sqrtPriceAX96, sqrtPriceBX96);
        uint256 denominator = FixedPoint96.Q96;
        uint256 _liquidity = uint256(liquidity);

        /**
         * Equivalent to:
         *   amount1 = roundUp
         *       ? FullMath.mulDivRoundingUp(liquidity, sqrtPriceBX96 - sqrtPriceAX96, FixedPoint96.Q96)
         *       : FullMath.mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceAX96, FixedPoint96.Q96);
         * Cannot overflow because `type(uint128).max * type(uint160).max >> 96 < (1 << 192)`.
         */
        amount1 = FullMath.mulDiv(_liquidity, numerator, denominator);
        assembly ("memory-safe") {
            amount1 := add(amount1, and(gt(mulmod(_liquidity, numerator, denominator), 0), roundUp))
        }
    }

    /// @notice Helper that gets signed currency0 delta
    /// @param sqrtPriceAX96 A sqrt price
    /// @param sqrtPriceBX96 Another sqrt price
    /// @param liquidity The change in liquidity for which to compute the amount0 delta
    /// @return int256 Amount of currency0 corresponding to the passed liquidityDelta between the two prices
    function getAmount0Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, int128 liquidity)
        internal
        pure
        returns (int256)
    {
        unchecked {
            return liquidity < 0
                ? getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(-liquidity), false).toInt256()
                : -getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(liquidity), true).toInt256();
        }
    }

    /// @notice Helper that gets signed currency1 delta
    /// @param sqrtPriceAX96 A sqrt price
    /// @param sqrtPriceBX96 Another sqrt price
    /// @param liquidity The change in liquidity for which to compute the amount1 delta
    /// @return int256 Amount of currency1 corresponding to the passed liquidityDelta between the two prices
    function getAmount1Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, int128 liquidity)
        internal
        pure
        returns (int256)
    {
        unchecked {
            return liquidity < 0
                ? getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(-liquidity), false).toInt256()
                : -getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(liquidity), true).toInt256();
        }
    }
}

// lib/v4-core/src/libraries/SwapMath.sol

/// @title Computes the result of a swap within ticks
/// @notice Contains methods for computing the result of a swap within a single tick price range, i.e., a single tick.
library SwapMath {
    /// @notice the swap fee is represented in hundredths of a bip, so the max is 100%
    /// @dev the swap fee is the total fee on a swap, including both LP and Protocol fee
    uint256 internal constant MAX_SWAP_FEE = 1e6;

    /// @notice Computes the sqrt price target for the next swap step
    /// @param zeroForOne The direction of the swap, true for currency0 to currency1, false for currency1 to currency0
    /// @param sqrtPriceNextX96 The Q64.96 sqrt price for the next initialized tick
    /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this value
    /// after the swap. If one for zero, the price cannot be greater than this value after the swap
    /// @return sqrtPriceTargetX96 The price target for the next swap step
    function getSqrtPriceTarget(bool zeroForOne, uint160 sqrtPriceNextX96, uint160 sqrtPriceLimitX96)
        internal
        pure
        returns (uint160 sqrtPriceTargetX96)
    {
        assembly ("memory-safe") {
            // a flag to toggle between sqrtPriceNextX96 and sqrtPriceLimitX96
            // when zeroForOne == true, nextOrLimit reduces to sqrtPriceNextX96 >= sqrtPriceLimitX96
            // sqrtPriceTargetX96 = max(sqrtPriceNextX96, sqrtPriceLimitX96)
            // when zeroForOne == false, nextOrLimit reduces to sqrtPriceNextX96 < sqrtPriceLimitX96
            // sqrtPriceTargetX96 = min(sqrtPriceNextX96, sqrtPriceLimitX96)
            sqrtPriceNextX96 := and(sqrtPriceNextX96, 0xffffffffffffffffffffffffffffffffffffffff)
            sqrtPriceLimitX96 := and(sqrtPriceLimitX96, 0xffffffffffffffffffffffffffffffffffffffff)
            let nextOrLimit := xor(lt(sqrtPriceNextX96, sqrtPriceLimitX96), and(zeroForOne, 0x1))
            let symDiff := xor(sqrtPriceNextX96, sqrtPriceLimitX96)
            sqrtPriceTargetX96 := xor(sqrtPriceLimitX96, mul(symDiff, nextOrLimit))
        }
    }

    /// @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap
    /// @dev If the swap's amountSpecified is negative, the combined fee and input amount will never exceed the absolute value of the remaining amount.
    /// @param sqrtPriceCurrentX96 The current sqrt price of the pool
    /// @param sqrtPriceTargetX96 The price that cannot be exceeded, from which the direction of the swap is inferred
    /// @param liquidity The usable liquidity
    /// @param amountRemaining How much input or output amount is remaining to be swapped in/out
    /// @param feePips The fee taken from the input amount, expressed in hundredths of a bip
    /// @return sqrtPriceNextX96 The price after swapping the amount in/out, not to exceed the price target
    /// @return amountIn The amount to be swapped in, of either currency0 or currency1, based on the direction of the swap
    /// @return amountOut The amount to be received, of either currency0 or currency1, based on the direction of the swap
    /// @return feeAmount The amount of input that will be taken as a fee
    /// @dev feePips must be no larger than MAX_SWAP_FEE for this function. We ensure that before setting a fee using LPFeeLibrary.isValid.
    function computeSwapStep(
        uint160 sqrtPriceCurrentX96,
        uint160 sqrtPriceTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    ) internal pure returns (uint160 sqrtPriceNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) {
        unchecked {
            uint256 _feePips = feePips; // upcast once and cache
            bool zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceTargetX96;
            bool exactIn = amountRemaining < 0;

            if (exactIn) {
                uint256 amountRemainingLessFee =
                    FullMath.mulDiv(uint256(-amountRemaining), MAX_SWAP_FEE - _feePips, MAX_SWAP_FEE);
                amountIn = zeroForOne
                    ? SqrtPriceMath.getAmount0Delta(sqrtPriceTargetX96, sqrtPriceCurrentX96, liquidity, true)
                    : SqrtPriceMath.getAmount1Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, true);
                if (amountRemainingLessFee >= amountIn) {
                    // `amountIn` is capped by the target price
                    sqrtPriceNextX96 = sqrtPriceTargetX96;
                    feeAmount = _feePips == MAX_SWAP_FEE
                        ? amountIn  // amountIn is always 0 here, as amountRemainingLessFee == 0 and amountRemainingLessFee >= amountIn
                        : FullMath.mulDivRoundingUp(amountIn, _feePips, MAX_SWAP_FEE - _feePips);
                } else {
                    // exhaust the remaining amount
                    amountIn = amountRemainingLessFee;
                    sqrtPriceNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                        sqrtPriceCurrentX96, liquidity, amountRemainingLessFee, zeroForOne
                    );
                    // we didn't reach the target, so take the remainder of the maximum input as fee
                    feeAmount = uint256(-amountRemaining) - amountIn;
                }
                amountOut = zeroForOne
                    ? SqrtPriceMath.getAmount1Delta(sqrtPriceNextX96, sqrtPriceCurrentX96, liquidity, false)
                    : SqrtPriceMath.getAmount0Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, false);
            } else {
                amountOut = zeroForOne
                    ? SqrtPriceMath.getAmount1Delta(sqrtPriceTargetX96, sqrtPriceCurrentX96, liquidity, false)
                    : SqrtPriceMath.getAmount0Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, false);
                if (uint256(amountRemaining) >= amountOut) {
                    // `amountOut` is capped by the target price
                    sqrtPriceNextX96 = sqrtPriceTargetX96;
                } else {
                    // cap the output amount to not exceed the remaining output amount
                    amountOut = uint256(amountRemaining);
                    sqrtPriceNextX96 =
                        SqrtPriceMath.getNextSqrtPriceFromOutput(sqrtPriceCurrentX96, liquidity, amountOut, zeroForOne);
                }
                amountIn = zeroForOne
                    ? SqrtPriceMath.getAmount0Delta(sqrtPriceNextX96, sqrtPriceCurrentX96, liquidity, true)
                    : SqrtPriceMath.getAmount1Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, true);
                // `feePips` cannot be `MAX_SWAP_FEE` for exact out
                feeAmount = FullMath.mulDivRoundingUp(amountIn, _feePips, MAX_SWAP_FEE - _feePips);
            }
        }
    }
}

// lib/v4-core/src/interfaces/IHooks.sol

/// @notice V4 decides whether to invoke specific hooks by inspecting the least significant bits
/// of the address that the hooks contract is deployed to.
/// For example, a hooks contract deployed to address: 0x0000000000000000000000000000000000002400
/// has the lowest bits '10 0100 0000 0000' which would cause the 'before initialize' and 'after add liquidity' hooks to be used.
/// See the Hooks library for the full spec.
/// @dev Should only be callable by the v4 PoolManager.
interface IHooks {
    /// @notice The hook called before the state of a pool is initialized
    /// @param sender The initial msg.sender for the initialize call
    /// @param key The key for the pool being initialized
    /// @param sqrtPriceX96 The sqrt(price) of the pool as a Q64.96
    /// @return bytes4 The function selector for the hook
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4);

    /// @notice The hook called after the state of a pool is initialized
    /// @param sender The initial msg.sender for the initialize call
    /// @param key The key for the pool being initialized
    /// @param sqrtPriceX96 The sqrt(price) of the pool as a Q64.96
    /// @param tick The current tick after the state of a pool is initialized
    /// @return bytes4 The function selector for the hook
    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        returns (bytes4);

    /// @notice The hook called before liquidity is added
    /// @param sender The initial msg.sender for the add liquidity call
    /// @param key The key for the pool
    /// @param params The parameters for adding liquidity
    /// @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be passed on to the hook
    /// @return bytes4 The function selector for the hook
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4);

    /// @notice The hook called after liquidity is added
    /// @param sender The initial msg.sender for the add liquidity call
    /// @param key The key for the pool
    /// @param params The parameters for adding liquidity
    /// @param delta The caller's balance delta after adding liquidity; the sum of principal delta, fees accrued, and hook delta
    /// @param feesAccrued The fees accrued since the last time fees were collected from this position
    /// @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be passed on to the hook
    /// @return bytes4 The function selector for the hook
    /// @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta);

    /// @notice The hook called before liquidity is removed
    /// @param sender The initial msg.sender for the remove liquidity call
    /// @param key The key for the pool
    /// @param params The parameters for removing liquidity
    /// @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be be passed on to the hook
    /// @return bytes4 The function selector for the hook
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4);

    /// @notice The hook called after liquidity is removed
    /// @param sender The initial msg.sender for the remove liquidity call
    /// @param key The key for the pool
    /// @param params The parameters for removing liquidity
    /// @param delta The caller's balance delta after removing liquidity; the sum of principal delta, fees accrued, and hook delta
    /// @param feesAccrued The fees accrued since the last time fees were collected from this position
    /// @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be be passed on to the hook
    /// @return bytes4 The function selector for the hook
    /// @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta);

    /// @notice The hook called before a swap
    /// @param sender The initial msg.sender for the swap call
    /// @param key The key for the pool
    /// @param params The parameters for the swap
    /// @param hookData Arbitrary data handed into the PoolManager by the swapper to be be passed on to the hook
    /// @return bytes4 The function selector for the hook
    /// @return BeforeSwapDelta The hook's delta in specified and unspecified currencies. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    /// @return uint24 Optionally override the lp fee, only used if three conditions are met: 1. the Pool has a dynamic fee, 2. the value's 2nd highest bit is set (23rd bit, 0x400000), and 3. the value is less than or equal to the maximum fee (1 million)
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24);

    /// @notice The hook called after a swap
    /// @param sender The initial msg.sender for the swap call
    /// @param key The key for the pool
    /// @param params The parameters for the swap
    /// @param delta The amount owed to the caller (positive) or owed to the pool (negative)
    /// @param hookData Arbitrary data handed into the PoolManager by the swapper to be be passed on to the hook
    /// @return bytes4 The function selector for the hook
    /// @return int128 The hook's delta in unspecified currency. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128);

    /// @notice The hook called before donate
    /// @param sender The initial msg.sender for the donate call
    /// @param key The key for the pool
    /// @param amount0 The amount of token0 being donated
    /// @param amount1 The amount of token1 being donated
    /// @param hookData Arbitrary data handed into the PoolManager by the donor to be be passed on to the hook
    /// @return bytes4 The function selector for the hook
    function beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external returns (bytes4);

    /// @notice The hook called after donate
    /// @param sender The initial msg.sender for the donate call
    /// @param key The key for the pool
    /// @param amount0 The amount of token0 being donated
    /// @param amount1 The amount of token1 being donated
    /// @param hookData Arbitrary data handed into the PoolManager by the donor to be be passed on to the hook
    /// @return bytes4 The function selector for the hook
    function afterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external returns (bytes4);
}

// lib/v4-core/src/types/PoolId.sol

type PoolId is bytes32;

/// @notice Library for computing the ID of a pool
library PoolIdLibrary {
    /// @notice Returns value equal to keccak256(abi.encode(poolKey))
    function toId(PoolKey memory poolKey) internal pure returns (PoolId poolId) {
        assembly ("memory-safe") {
            // 0xa0 represents the total size of the poolKey struct (5 slots of 32 bytes)
            poolId := keccak256(poolKey, 0xa0)
        }
    }
}

// lib/v4-core/src/types/PoolKey.sol

using PoolIdLibrary for PoolKey global;

/// @notice Returns the key for identifying a pool
struct PoolKey {
    /// @notice The lower currency of the pool, sorted numerically
    Currency currency0;
    /// @notice The higher currency of the pool, sorted numerically
    Currency currency1;
    /// @notice The pool LP fee, capped at 1_000_000. If the highest bit is 1, the pool has a dynamic fee and must be exactly equal to 0x800000
    uint24 fee;
    /// @notice Ticks that involve positions must be a multiple of tick spacing
    int24 tickSpacing;
    /// @notice The hooks of the pool
    IHooks hooks;
}

// lib/v4-core/src/types/PoolOperation.sol

/// @notice Parameter struct for `ModifyLiquidity` pool operations
struct ModifyLiquidityParams {
    // the lower and upper tick of the position
    int24 tickLower;
    int24 tickUpper;
    // how to modify the liquidity
    int256 liquidityDelta;
    // a value to set if you want unique liquidity positions at the same range
    bytes32 salt;
}

/// @notice Parameter struct for `Swap` pool operations
struct SwapParams {
    /// Whether to swap token0 for token1 or vice versa
    bool zeroForOne;
    /// The desired input amount if negative (exactIn), or the desired output amount if positive (exactOut)
    int256 amountSpecified;
    /// The sqrt price at which, if reached, the swap will stop executing
    uint160 sqrtPriceLimitX96;
}

// lib/v4-core/src/interfaces/IProtocolFees.sol

/// @notice Interface for all protocol-fee related functions in the pool manager
interface IProtocolFees {
    /// @notice Thrown when protocol fee is set too high
    error ProtocolFeeTooLarge(uint24 fee);

    /// @notice Thrown when collectProtocolFees or setProtocolFee is not called by the controller.
    error InvalidCaller();

    /// @notice Thrown when collectProtocolFees is attempted on a token that is synced.
    error ProtocolFeeCurrencySynced();

    /// @notice Emitted when the protocol fee controller address is updated in setProtocolFeeController.
    event ProtocolFeeControllerUpdated(address indexed protocolFeeController);

    /// @notice Emitted when the protocol fee is updated for a pool.
    event ProtocolFeeUpdated(PoolId indexed id, uint24 protocolFee);

    /// @notice Given a currency address, returns the protocol fees accrued in that currency
    /// @param currency The currency to check
    /// @return amount The amount of protocol fees accrued in the currency
    function protocolFeesAccrued(Currency currency) external view returns (uint256 amount);

    /// @notice Sets the protocol fee for the given pool
    /// @param key The key of the pool to set a protocol fee for
    /// @param newProtocolFee The fee to set
    function setProtocolFee(PoolKey memory key, uint24 newProtocolFee) external;

    /// @notice Sets the protocol fee controller
    /// @param controller The new protocol fee controller
    function setProtocolFeeController(address controller) external;

    /// @notice Collects the protocol fees for a given recipient and currency, returning the amount collected
    /// @dev This will revert if the contract is unlocked
    /// @param recipient The address to receive the protocol fees
    /// @param currency The currency to withdraw
    /// @param amount The amount of currency to withdraw
    /// @return amountCollected The amount of currency successfully withdrawn
    function collectProtocolFees(address recipient, Currency currency, uint256 amount)
        external
        returns (uint256 amountCollected);

    /// @notice Returns the current protocol fee controller address
    /// @return address The current protocol fee controller address
    function protocolFeeController() external view returns (address);
}

// lib/v4-core/src/interfaces/IPoolManager.sol

/// @notice Interface for the PoolManager
interface IPoolManager is IProtocolFees, IERC6909Claims, IExtsload, IExttload {
    /// @notice Thrown when a currency is not netted out after the contract is unlocked
    error CurrencyNotSettled();

    /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();

    /// @notice Thrown when unlock is called, but the contract is already unlocked
    error AlreadyUnlocked();

    /// @notice Thrown when a function is called that requires the contract to be unlocked, but it is not
    error ManagerLocked();

    /// @notice Pools are limited to type(int16).max tickSpacing in #initialize, to prevent overflow
    error TickSpacingTooLarge(int24 tickSpacing);

    /// @notice Pools must have a positive non-zero tickSpacing passed to #initialize
    error TickSpacingTooSmall(int24 tickSpacing);

    /// @notice PoolKey must have currencies where address(currency0) < address(currency1)
    error CurrenciesOutOfOrderOrEqual(address currency0, address currency1);

    /// @notice Thrown when a call to updateDynamicLPFee is made by an address that is not the hook,
    /// or on a pool that does not have a dynamic swap fee.
    error UnauthorizedDynamicLPFeeUpdate();

    /// @notice Thrown when trying to swap amount of 0
    error SwapAmountCannotBeZero();

    ///@notice Thrown when native currency is passed to a non native settlement
    error NonzeroNativeValue();

    /// @notice Thrown when `clear` is called with an amount that is not exactly equal to the open currency delta.
    error MustClearExactPositiveDelta();

    /// @notice Emitted when a new pool is initialized
    /// @param id The abi encoded hash of the pool key struct for the new pool
    /// @param currency0 The first currency of the pool by address sort order
    /// @param currency1 The second currency of the pool by address sort order
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @param tickSpacing The minimum number of ticks between initialized ticks
    /// @param hooks The hooks contract address for the pool, or address(0) if none
    /// @param sqrtPriceX96 The price of the pool on initialization
    /// @param tick The initial tick of the pool corresponding to the initialized price
    event Initialize(
        PoolId indexed id,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing,
        IHooks hooks,
        uint160 sqrtPriceX96,
        int24 tick
    );

    /// @notice Emitted when a liquidity position is modified
    /// @param id The abi encoded hash of the pool key struct for the pool that was modified
    /// @param sender The address that modified the pool
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param liquidityDelta The amount of liquidity that was added or removed
    /// @param salt The extra data to make positions unique
    event ModifyLiquidity(
        PoolId indexed id, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt
    );

    /// @notice Emitted for swaps between currency0 and currency1
    /// @param id The abi encoded hash of the pool key struct for the pool that was modified
    /// @param sender The address that initiated the swap call, and that received the callback
    /// @param amount0 The delta of the currency0 balance of the pool
    /// @param amount1 The delta of the currency1 balance of the pool
    /// @param sqrtPriceX96 The sqrt(price) of the pool after the swap, as a Q64.96
    /// @param liquidity The liquidity of the pool after the swap
    /// @param tick The log base 1.0001 of the price of the pool after the swap
    /// @param fee The swap fee in hundredths of a bip
    event Swap(
        PoolId indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );

    /// @notice Emitted for donations
    /// @param id The abi encoded hash of the pool key struct for the pool that was donated to
    /// @param sender The address that initiated the donate call
    /// @param amount0 The amount donated in currency0
    /// @param amount1 The amount donated in currency1
    event Donate(PoolId indexed id, address indexed sender, uint256 amount0, uint256 amount1);

    /// @notice All interactions on the contract that account deltas require unlocking. A caller that calls `unlock` must implement
    /// `IUnlockCallback(msg.sender).unlockCallback(data)`, where they interact with the remaining functions on this contract.
    /// @dev The only functions callable without an unlocking are `initialize` and `updateDynamicLPFee`
    /// @param data Any data to pass to the callback, via `IUnlockCallback(msg.sender).unlockCallback(data)`
    /// @return The data returned by the call to `IUnlockCallback(msg.sender).unlockCallback(data)`
    function unlock(bytes calldata data) external returns (bytes memory);

    /// @notice Initialize the state for a given pool ID
    /// @dev A swap fee totaling MAX_SWAP_FEE (100%) makes exact output swaps impossible since the input is entirely consumed by the fee
    /// @param key The pool key for the pool to initialize
    /// @param sqrtPriceX96 The initial square root price
    /// @return tick The initial tick of the pool
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);

    /// @notice Modify the liquidity for the given pool
    /// @dev Poke by calling with a zero liquidityDelta
    /// @param key The pool to modify liquidity in
    /// @param params The parameters for modifying the liquidity
    /// @param hookData The data to pass through to the add/removeLiquidity hooks
    /// @return callerDelta The balance delta of the caller of modifyLiquidity. This is the total of both principal, fee deltas, and hook deltas if applicable
    /// @return feesAccrued The balance delta of the fees generated in the liquidity range. Returned for informational purposes
    /// @dev Note that feesAccrued can be artificially inflated by a malicious actor and integrators should be careful using the value
    /// For pools with a single liquidity position, actors can donate to themselves to inflate feeGrowthGlobal (and consequently feesAccrued)
    /// atomically donating and collecting fees in the same unlockCallback may make the inflated value more extreme
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued);

    /// @notice Swap against the given pool
    /// @param key The pool to swap in
    /// @param params The parameters for swapping
    /// @param hookData The data to pass through to the swap hooks
    /// @return swapDelta The balance delta of the address swapping
    /// @dev Swapping on low liquidity pools may cause unexpected swap amounts when liquidity available is less than amountSpecified.
    /// Additionally note that if interacting with hooks that have the BEFORE_SWAP_RETURNS_DELTA_FLAG or AFTER_SWAP_RETURNS_DELTA_FLAG
    /// the hook may alter the swap input/output. Integrators should perform checks on the returned swapDelta.
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta swapDelta);

    /// @notice Donate the given currency amounts to the in-range liquidity providers of a pool
    /// @dev Calls to donate can be frontrun adding just-in-time liquidity, with the aim of receiving a portion donated funds.
    /// Donors should keep this in mind when designing donation mechanisms.
    /// @dev This function donates to in-range LPs at slot0.tick. In certain edge-cases of the swap algorithm, the `sqrtPrice` of
    /// a pool can be at the lower boundary of tick `n`, but the `slot0.tick` of the pool is already `n - 1`. In this case a call to
    /// `donate` would donate to tick `n - 1` (slot0.tick) not tick `n` (getTickAtSqrtPrice(slot0.sqrtPriceX96)).
    /// Read the comments in `Pool.swap()` for more information about this.
    /// @param key The key of the pool to donate to
    /// @param amount0 The amount of currency0 to donate
    /// @param amount1 The amount of currency1 to donate
    /// @param hookData The data to pass through to the donate hooks
    /// @return BalanceDelta The delta of the caller after the donate
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        returns (BalanceDelta);

    /// @notice Writes the current ERC20 balance of the specified currency to transient storage
    /// This is used to checkpoint balances for the manager and derive deltas for the caller.
    /// @dev This MUST be called before any ERC20 tokens are sent into the contract, but can be skipped
    /// for native tokens because the amount to settle is determined by the sent value.
    /// However, if an ERC20 token has been synced and not settled, and the caller instead wants to settle
    /// native funds, this function can be called with the native currency to then be able to settle the native currency
    function sync(Currency currency) external;

    /// @notice Called by the user to net out some value owed to the user
    /// @dev Will revert if the requested amount is not available, consider using `mint` instead
    /// @dev Can also be used as a mechanism for free flash loans
    /// @param currency The currency to withdraw from the pool manager
    /// @param to The address to withdraw to
    /// @param amount The amount of currency to withdraw
    function take(Currency currency, address to, uint256 amount) external;

    /// @notice Called by the user to pay what is owed
    /// @return paid The amount of currency settled
    function settle() external payable returns (uint256 paid);

    /// @notice Called by the user to pay on behalf of another address
    /// @param recipient The address to credit for the payment
    /// @return paid The amount of currency settled
    function settleFor(address recipient) external payable returns (uint256 paid);

    /// @notice WARNING - Any currency that is cleared, will be non-retrievable, and locked in the contract permanently.
    /// A call to clear will zero out a positive balance WITHOUT a corresponding transfer.
    /// @dev This could be used to clear a balance that is considered dust.
    /// Additionally, the amount must be the exact positive balance. This is to enforce that the caller is aware of the amount being cleared.
    function clear(Currency currency, uint256 amount) external;

    /// @notice Called by the user to move value into ERC6909 balance
    /// @param to The address to mint the tokens to
    /// @param id The currency address to mint to ERC6909s, as a uint256
    /// @param amount The amount of currency to mint
    /// @dev The id is converted to a uint160 to correspond to a currency address
    /// If the upper 12 bytes are not 0, they will be 0-ed out
    function mint(address to, uint256 id, uint256 amount) external;

    /// @notice Called by the user to move value from ERC6909 balance
    /// @param from The address to burn the tokens from
    /// @param id The currency address to burn from ERC6909s, as a uint256
    /// @param amount The amount of currency to burn
    /// @dev The id is converted to a uint160 to correspond to a currency address
    /// If the upper 12 bytes are not 0, they will be 0-ed out
    function burn(address from, uint256 id, uint256 amount) external;

    /// @notice Updates the pools lp fees for the a pool that has enabled dynamic lp fees.
    /// @dev A swap fee totaling MAX_SWAP_FEE (100%) makes exact output swaps impossible since the input is entirely consumed by the fee
    /// @param key The key of the pool to update dynamic LP fees for
    /// @param newDynamicLPFee The new dynamic pool LP fee
    function updateDynamicLPFee(PoolKey memory key, uint24 newDynamicLPFee) external;
}

// lib/v4-core/test/utils/CurrencySettler.sol

/// @notice Library used to interact with PoolManager.sol to settle any open deltas.
/// To settle a positive delta (a credit to the user), a user may take or mint.
/// To settle a negative delta (a debt on the user), a user make transfer or burn to pay off a debt.
/// @dev Note that sync() is called before any erc-20 transfer in `settle`.
library CurrencySettler {
    /// @notice Settle (pay) a currency to the PoolManager
    /// @param currency Currency to settle
    /// @param manager IPoolManager to settle to
    /// @param payer Address of the payer, the token sender
    /// @param amount Amount to send
    /// @param burn If true, burn the ERC-6909 token, otherwise ERC20-transfer to the PoolManager
    function settle(Currency currency, IPoolManager manager, address payer, uint256 amount, bool burn) internal {
        // for native currencies or burns, calling sync is not required
        // short circuit for ERC-6909 burns to support ERC-6909-wrapped native tokens
        if (burn) {
            manager.burn(payer, currency.toId(), amount);
        } else if (currency.isAddressZero()) {
            manager.settle{value: amount}();
        } else {
            manager.sync(currency);
            if (payer != address(this)) {
                IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount);
            } else {
                IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), amount);
            }
            manager.settle();
        }
    }

    /// @notice Take (receive) a currency from the PoolManager
    /// @param currency Currency to take
    /// @param manager IPoolManager to take from
    /// @param recipient Address of the recipient, the token receiver
    /// @param amount Amount to receive
    /// @param claims If true, mint the ERC-6909 token, otherwise ERC20-transfer from the PoolManager to recipient
    function take(Currency currency, IPoolManager manager, address recipient, uint256 amount, bool claims) internal {
        claims ? manager.mint(recipient, currency.toId(), amount) : manager.take(currency, recipient, amount);
    }
}

// lib/v4-core/src/libraries/Hooks.sol

/// @notice V4 decides whether to invoke specific hooks by inspecting the least significant bits
/// of the address that the hooks contract is deployed to.
/// For example, a hooks contract deployed to address: 0x0000000000000000000000000000000000002400
/// has the lowest bits '10 0100 0000 0000' which would cause the 'before initialize' and 'after add liquidity' hooks to be used.
library Hooks {
    using LPFeeLibrary for uint24;
    using Hooks for IHooks;
    using SafeCast for int256;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using ParseBytes for bytes;
    using CustomRevert for bytes4;

    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE_FLAG = 1 << 12;

    uint160 internal constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY_FLAG = 1 << 10;

    uint160 internal constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_FLAG = 1 << 8;

    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 internal constant AFTER_SWAP_FLAG = 1 << 6;

    uint160 internal constant BEFORE_DONATE_FLAG = 1 << 5;
    uint160 internal constant AFTER_DONATE_FLAG = 1 << 4;

    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 0;

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

    /// @notice Thrown if the address will not lead to the specified hook calls being called
    /// @param hooks The address of the hooks contract
    error HookAddressNotValid(address hooks);

    /// @notice Hook did not return its selector
    error InvalidHookResponse();

    /// @notice Additional context for ERC-7751 wrapped error when a hook call fails
    error HookCallFailed();

    /// @notice The hook's delta changed the swap from exactIn to exactOut or vice versa
    error HookDeltaExceedsSwapAmount();

    /// @notice Utility function intended to be used in hook constructors to ensure
    /// the deployed hooks address causes the intended hooks to be called
    /// @param permissions The hooks that are intended to be called
    /// @dev permissions param is memory as the function will be called from constructors
    function validateHookPermissions(IHooks self, Permissions memory permissions) internal pure {
        if (
            permissions.beforeInitialize != self.hasPermission(BEFORE_INITIALIZE_FLAG)
                || permissions.afterInitialize != self.hasPermission(AFTER_INITIALIZE_FLAG)
                || permissions.beforeAddLiquidity != self.hasPermission(BEFORE_ADD_LIQUIDITY_FLAG)
                || permissions.afterAddLiquidity != self.hasPermission(AFTER_ADD_LIQUIDITY_FLAG)
                || permissions.beforeRemoveLiquidity != self.hasPermission(BEFORE_REMOVE_LIQUIDITY_FLAG)
                || permissions.afterRemoveLiquidity != self.hasPermission(AFTER_REMOVE_LIQUIDITY_FLAG)
                || permissions.beforeSwap != self.hasPermission(BEFORE_SWAP_FLAG)
                || permissions.afterSwap != self.hasPermission(AFTER_SWAP_FLAG)
                || permissions.beforeDonate != self.hasPermission(BEFORE_DONATE_FLAG)
                || permissions.afterDonate != self.hasPermission(AFTER_DONATE_FLAG)
                || permissions.beforeSwapReturnDelta != self.hasPermission(BEFORE_SWAP_RETURNS_DELTA_FLAG)
                || permissions.afterSwapReturnDelta != self.hasPermission(AFTER_SWAP_RETURNS_DELTA_FLAG)
                || permissions.afterAddLiquidityReturnDelta
                    != self.hasPermission(AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)
                || permissions.afterRemoveLiquidityReturnDelta
                    != self.hasPermission(AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        ) {
            HookAddressNotValid.selector.revertWith(address(self));
        }
    }

    /// @notice Ensures that the hook address includes at least one hook flag or dynamic fees, or is the 0 address
    /// @param self The hook to verify
    /// @param fee The fee of the pool the hook is used with
    /// @return bool True if the hook address is valid
    function isValidHookAddress(IHooks self, uint24 fee) internal pure returns (bool) {
        // The hook can only have a flag to return a hook delta on an action if it also has the corresponding action flag
        if (!self.hasPermission(BEFORE_SWAP_FLAG) && self.hasPermission(BEFORE_SWAP_RETURNS_DELTA_FLAG)) return false;
        if (!self.hasPermission(AFTER_SWAP_FLAG) && self.hasPermission(AFTER_SWAP_RETURNS_DELTA_FLAG)) return false;
        if (!self.hasPermission(AFTER_ADD_LIQUIDITY_FLAG) && self.hasPermission(AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG))
        {
            return false;
        }
        if (
            !self.hasPermission(AFTER_REMOVE_LIQUIDITY_FLAG)
                && self.hasPermission(AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        ) return false;

        // If there is no hook contract set, then fee cannot be dynamic
        // If a hook contract is set, it must have at least 1 flag set, or have a dynamic fee
        return address(self) == address(0)
            ? !fee.isDynamicFee()
            : (uint160(address(self)) & ALL_HOOK_MASK > 0 || fee.isDynamicFee());
    }

    /// @notice performs a hook call using the given calldata on the given hook that doesn't return a delta
    /// @return result The complete data returned by the hook
    function callHook(IHooks self, bytes memory data) internal returns (bytes memory result) {
        bool success;
        assembly ("memory-safe") {
            success := call(gas(), self, 0, add(data, 0x20), mload(data), 0, 0)
        }
        // Revert with FailedHookCall, containing any error message to bubble up
        if (!success) CustomRevert.bubbleUpAndRevertWith(address(self), bytes4(data), HookCallFailed.selector);

        // The call was successful, fetch the returned data
        assembly ("memory-safe") {
            // allocate result byte array from the free memory pointer
            result := mload(0x40)
            // store new free memory pointer at the end of the array padded to 32 bytes
            mstore(0x40, add(result, and(add(returndatasize(), 0x3f), not(0x1f))))
            // store length in memory
            mstore(result, returndatasize())
            // copy return data to result
            returndatacopy(add(result, 0x20), 0, returndatasize())
        }

        // Length must be at least 32 to contain the selector. Check expected selector and returned selector match.
        if (result.length < 32 || result.parseSelector() != data.parseSelector()) {
            InvalidHookResponse.selector.revertWith();
        }
    }

    /// @notice performs a hook call using the given calldata on the given hook
    /// @return int256 The delta returned by the hook
    function callHookWithReturnDelta(IHooks self, bytes memory data, bool parseReturn) internal returns (int256) {
        bytes memory result = callHook(self, data);

        // If this hook wasn't meant to return something, default to 0 delta
        if (!parseReturn) return 0;

        // A length of 64 bytes is required to return a bytes4, and a 32 byte delta
        if (result.length != 64) InvalidHookResponse.selector.revertWith();
        return result.parseReturnDelta();
    }

    /// @notice modifier to prevent calling a hook if they initiated the action
    modifier noSelfCall(IHooks self) {
        if (msg.sender != address(self)) {
            _;
        }
    }

    /// @notice calls beforeInitialize hook if permissioned and validates return value
    function beforeInitialize(IHooks self, PoolKey memory key, uint160 sqrtPriceX96) internal noSelfCall(self) {
        if (self.hasPermission(BEFORE_INITIALIZE_FLAG)) {
            self.callHook(abi.encodeCall(IHooks.beforeInitialize, (msg.sender, key, sqrtPriceX96)));
        }
    }

    /// @notice calls afterInitialize hook if permissioned and validates return value
    function afterInitialize(IHooks self, PoolKey memory key, uint160 sqrtPriceX96, int24 tick)
        internal
        noSelfCall(self)
    {
        if (self.hasPermission(AFTER_INITIALIZE_FLAG)) {
            self.callHook(abi.encodeCall(IHooks.afterInitialize, (msg.sender, key, sqrtPriceX96, tick)));
        }
    }

    /// @notice calls beforeModifyLiquidity hook if permissioned and validates return value
    function beforeModifyLiquidity(
        IHooks self,
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes calldata hookData
    ) internal noSelfCall(self) {
        if (params.liquidityDelta > 0 && self.hasPermission(BEFORE_ADD_LIQUIDITY_FLAG)) {
            self.callHook(abi.encodeCall(IHooks.beforeAddLiquidity, (msg.sender, key, params, hookData)));
        } else if (params.liquidityDelta <= 0 && self.hasPermission(BEFORE_REMOVE_LIQUIDITY_FLAG)) {
            self.callHook(abi.encodeCall(IHooks.beforeRemoveLiquidity, (msg.sender, key, params, hookData)));
        }
    }

    /// @notice calls afterModifyLiquidity hook if permissioned and validates return value
    function afterModifyLiquidity(
        IHooks self,
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal returns (BalanceDelta callerDelta, BalanceDelta hookDelta) {
        if (msg.sender == address(self)) return (delta, BalanceDeltaLibrary.ZERO_DELTA);

        callerDelta = delta;
        if (params.liquidityDelta > 0) {
            if (self.hasPermission(AFTER_ADD_LIQUIDITY_FLAG)) {
                hookDelta = BalanceDelta.wrap(
                    self.callHookWithReturnDelta(
                        abi.encodeCall(
                            IHooks.afterAddLiquidity, (msg.sender, key, params, delta, feesAccrued, hookData)
                        ),
                        self.hasPermission(AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)
                    )
                );
                callerDelta = callerDelta - hookDelta;
            }
        } else {
            if (self.hasPermission(AFTER_REMOVE_LIQUIDITY_FLAG)) {
                hookDelta = BalanceDelta.wrap(
                    self.callHookWithReturnDelta(
                        abi.encodeCall(
                            IHooks.afterRemoveLiquidity, (msg.sender, key, params, delta, feesAccrued, hookData)
                        ),
                        self.hasPermission(AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
                    )
                );
                callerDelta = callerDelta - hookDelta;
            }
        }
    }

    /// @notice calls beforeSwap hook if permissioned and validates return value
    function beforeSwap(IHooks self, PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        internal
        returns (int256 amountToSwap, BeforeSwapDelta hookReturn, uint24 lpFeeOverride)
    {
        amountToSwap = params.amountSpecified;
        if (msg.sender == address(self)) return (amountToSwap, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeeOverride);

        if (self.hasPermission(BEFORE_SWAP_FLAG)) {
            bytes memory result = callHook(self, abi.encodeCall(IHooks.beforeSwap, (msg.sender, key, params, hookData)));

            // A length of 96 bytes is required to return a bytes4, a 32 byte delta, and an LP fee
            if (result.length != 96) InvalidHookResponse.selector.revertWith();

            // dynamic fee pools that want to override the cache fee, return a valid fee with the override flag. If override flag
            // is set but an invalid fee is returned, the transaction will revert. Otherwise the current LP fee will be used
            if (key.fee.isDynamicFee()) lpFeeOverride = result.parseFee();

            // skip this logic for the case where the hook return is 0
            if (self.hasPermission(BEFORE_SWAP_RETURNS_DELTA_FLAG)) {
                hookReturn = BeforeSwapDelta.wrap(result.parseReturnDelta());

                // any return in unspecified is passed to the afterSwap hook for handling
                int128 hookDeltaSpecified = hookReturn.getSpecifiedDelta();

                // Update the swap amount according to the hook's return, and check that the swap type doesn't change (exact input/output)
                if (hookDeltaSpecified != 0) {
                    bool exactInput = amountToSwap < 0;
                    amountToSwap += hookDeltaSpecified;
                    if (exactInput ? amountToSwap > 0 : amountToSwap < 0) {
                        HookDeltaExceedsSwapAmount.selector.revertWith();
                    }
                }
            }
        }
    }

    /// @notice calls afterSwap hook if permissioned and validates return value
    function afterSwap(
        IHooks self,
        PoolKey memory key,
        SwapParams memory params,
        BalanceDelta swapDelta,
        bytes calldata hookData,
        BeforeSwapDelta beforeSwapHookReturn
    ) internal returns (BalanceDelta, BalanceDelta) {
        if (msg.sender == address(self)) {
            return (swapDelta, BalanceDeltaLibrary.ZERO_DELTA);
        }

        int128 hookDeltaSpecified = beforeSwapHookReturn.getSpecifiedDelta();
        int128 hookDeltaUnspecified = beforeSwapHookReturn.getUnspecifiedDelta();

        if (self.hasPermission(AFTER_SWAP_FLAG)) {
            hookDeltaUnspecified += self.callHookWithReturnDelta(
                    abi.encodeCall(IHooks.afterSwap, (msg.sender, key, params, swapDelta, hookData)),
                    self.hasPermission(AFTER_SWAP_RETURNS_DELTA_FLAG)
                )
                .toInt128();
        }

        BalanceDelta hookDelta;
        if (hookDeltaUnspecified != 0 || hookDeltaSpecified != 0) {
            hookDelta = (params.amountSpecified < 0 == params.zeroForOne)
                ? toBalanceDelta(hookDeltaSpecified, hookDeltaUnspecified)
                : toBalanceDelta(hookDeltaUnspecified, hookDeltaSpecified);

            // the caller has to pay for (or receive) the hook's delta
            swapDelta = swapDelta - hookDelta;
        }
        return (swapDelta, hookDelta);
    }

    /// @notice calls beforeDonate hook if permissioned and validates return value
    function beforeDonate(IHooks self, PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        internal
        noSelfCall(self)
    {
        if (self.hasPermission(BEFORE_DONATE_FLAG)) {
            self.callHook(abi.encodeCall(IHooks.beforeDonate, (msg.sender, key, amount0, amount1, hookData)));
        }
    }

    /// @notice calls afterDonate hook if permissioned and validates return value
    function afterDonate(IHooks self, PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        internal
        noSelfCall(self)
    {
        if (self.hasPermission(AFTER_DONATE_FLAG)) {
            self.callHook(abi.encodeCall(IHooks.afterDonate, (msg.sender, key, amount0, amount1, hookData)));
        }
    }

    function hasPermission(IHooks self, uint160 flag) internal pure returns (bool) {
        return uint160(address(self)) & flag != 0;
    }
}

// lib/v4-core/src/libraries/Pool.sol

/// @notice a library with all actions that can be performed on a pool
library Pool {
    using SafeCast for *;
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.State);
    using Position for Position.State;
    using Pool for State;
    using ProtocolFeeLibrary for *;
    using LPFeeLibrary for uint24;
    using CustomRevert for bytes4;

    /// @notice Thrown when tickLower is not below tickUpper
    /// @param tickLower The invalid tickLower
    /// @param tickUpper The invalid tickUpper
    error TicksMisordered(int24 tickLower, int24 tickUpper);

    /// @notice Thrown when tickLower is less than min tick
    /// @param tickLower The invalid tickLower
    error TickLowerOutOfBounds(int24 tickLower);

    /// @notice Thrown when tickUpper exceeds max tick
    /// @param tickUpper The invalid tickUpper
    error TickUpperOutOfBounds(int24 tickUpper);

    /// @notice For the tick spacing, the tick has too much liquidity
    error TickLiquidityOverflow(int24 tick);

    /// @notice Thrown when trying to initialize an already initialized pool
    error PoolAlreadyInitialized();

    /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();

    /// @notice Thrown when sqrtPriceLimitX96 on a swap has already exceeded its limit
    /// @param sqrtPriceCurrentX96 The invalid, already surpassed sqrtPriceLimitX96
    /// @param sqrtPriceLimitX96 The surpassed price limit
    error PriceLimitAlreadyExceeded(uint160 sqrtPriceCurrentX96, uint160 sqrtPriceLimitX96);

    /// @notice Thrown when sqrtPriceLimitX96 lies outside of valid tick/price range
    /// @param sqrtPriceLimitX96 The invalid, out-of-bounds sqrtPriceLimitX96
    error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96);

    /// @notice Thrown by donate if there is currently 0 liquidity, since the fees will not go to any liquidity providers
    error NoLiquidityToReceiveFees();

    /// @notice Thrown when trying to swap with max lp fee and specifying an output amount
    error InvalidFeeForExactOut();

    // info stored for each initialized individual tick
    struct TickInfo {
        // the total position liquidity that references this tick
        uint128 liquidityGross;
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
        int128 liquidityNet;
        // fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    /// @notice The state of a pool
    /// @dev Note that feeGrowthGlobal can be artificially inflated
    /// For pools with a single liquidity position, actors can donate to themselves to freely inflate feeGrowthGlobal
    /// atomically donating and collecting fees in the same unlockCallback may make the inflated value more extreme
    struct State {
        Slot0 slot0;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        uint128 liquidity;
        mapping(int24 tick => TickInfo) ticks;
        mapping(int16 wordPos => uint256) tickBitmap;
        mapping(bytes32 positionKey => Position.State) positions;
    }

    /// @dev Common checks for valid tick inputs.
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        if (tickLower >= tickUpper) TicksMisordered.selector.revertWith(tickLower, tickUpper);
        if (tickLower < TickMath.MIN_TICK) TickLowerOutOfBounds.selector.revertWith(tickLower);
        if (tickUpper > TickMath.MAX_TICK) TickUpperOutOfBounds.selector.revertWith(tickUpper);
    }

    function initialize(State storage self, uint160 sqrtPriceX96, uint24 lpFee) internal returns (int24 tick) {
        if (self.slot0.sqrtPriceX96() != 0) PoolAlreadyInitialized.selector.revertWith();

        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // the initial protocolFee is 0 so doesn't need to be set
        self.slot0 = Slot0.wrap(bytes32(0)).setSqrtPriceX96(sqrtPriceX96).setTick(tick).setLpFee(lpFee);
    }

    function setProtocolFee(State storage self, uint24 protocolFee) internal {
        self.checkPoolInitialized();
        self.slot0 = self.slot0.setProtocolFee(protocolFee);
    }

    /// @notice Only dynamic fee pools may update the lp fee.
    function setLPFee(State storage self, uint24 lpFee) internal {
        self.checkPoolInitialized();
        self.slot0 = self.slot0.setLpFee(lpFee);
    }

    struct ModifyLiquidityParams {
        // the address that owns the position
        address owner;
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity
        int128 liquidityDelta;
        // the spacing between ticks
        int24 tickSpacing;
        // used to distinguish positions of the same owner, at the same tick range
        bytes32 salt;
    }

    struct ModifyLiquidityState {
        bool flippedLower;
        uint128 liquidityGrossAfterLower;
        bool flippedUpper;
        uint128 liquidityGrossAfterUpper;
    }

    /// @notice Effect changes to a position in a pool
    /// @dev PoolManager checks that the pool is initialized before calling
    /// @param params the position details and the change to the position's liquidity to effect
    /// @return delta the deltas of the token balances of the pool, from the liquidity change
    /// @return feeDelta the fees generated by the liquidity range
    function modifyLiquidity(State storage self, ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta, BalanceDelta feeDelta)
    {
        int128 liquidityDelta = params.liquidityDelta;
        int24 tickLower = params.tickLower;
        int24 tickUpper = params.tickUpper;
        checkTicks(tickLower, tickUpper);

        {
            ModifyLiquidityState memory state;

            // if we need to update the ticks, do it
            if (liquidityDelta != 0) {
                (state.flippedLower, state.liquidityGrossAfterLower) =
                    updateTick(self, tickLower, liquidityDelta, false);
                (state.flippedUpper, state.liquidityGrossAfterUpper) = updateTick(self, tickUpper, liquidityDelta, true);

                // `>` and `>=` are logically equivalent here but `>=` is cheaper
                if (liquidityDelta >= 0) {
                    uint128 maxLiquidityPerTick = tickSpacingToMaxLiquidityPerTick(params.tickSpacing);
                    if (state.liquidityGrossAfterLower > maxLiquidityPerTick) {
                        TickLiquidityOverflow.selector.revertWith(tickLower);
                    }
                    if (state.liquidityGrossAfterUpper > maxLiquidityPerTick) {
                        TickLiquidityOverflow.selector.revertWith(tickUpper);
                    }
                }

                if (state.flippedLower) {
                    self.tickBitmap.flipTick(tickLower, params.tickSpacing);
                }
                if (state.flippedUpper) {
                    self.tickBitmap.flipTick(tickUpper, params.tickSpacing);
                }
            }

            {
                (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
                    getFeeGrowthInside(self, tickLower, tickUpper);

                Position.State storage position = self.positions.get(params.owner, tickLower, tickUpper, params.salt);
                (uint256 feesOwed0, uint256 feesOwed1) =
                    position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

                // Fees earned from LPing are calculated, and returned
                feeDelta = toBalanceDelta(feesOwed0.toInt128(), feesOwed1.toInt128());
            }

            // clear any tick data that is no longer needed
            if (liquidityDelta < 0) {
                if (state.flippedLower) {
                    clearTick(self, tickLower);
                }
                if (state.flippedUpper) {
                    clearTick(self, tickUpper);
                }
            }
        }

        if (liquidityDelta != 0) {
            Slot0 _slot0 = self.slot0;
            (int24 tick, uint160 sqrtPriceX96) = (_slot0.tick(), _slot0.sqrtPriceX96());
            if (tick < tickLower) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ currency0 (it's becoming more valuable) so user must provide it
                delta = toBalanceDelta(
                    SqrtPriceMath.getAmount0Delta(
                            TickMath.getSqrtPriceAtTick(tickLower),
                            TickMath.getSqrtPriceAtTick(tickUpper),
                            liquidityDelta
                        )
                        .toInt128(),
                    0
                );
            } else if (tick < tickUpper) {
                delta = toBalanceDelta(
                    SqrtPriceMath.getAmount0Delta(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta)
                        .toInt128(),
                    SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, liquidityDelta)
                        .toInt128()
                );

                self.liquidity = LiquidityMath.addDelta(self.liquidity, liquidityDelta);
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to
                // left, when we'll need _more_ currency1 (it's becoming more valuable) so user must provide it
                delta = toBalanceDelta(
                    0,
                    SqrtPriceMath.getAmount1Delta(
                            TickMath.getSqrtPriceAtTick(tickLower),
                            TickMath.getSqrtPriceAtTick(tickUpper),
                            liquidityDelta
                        )
                        .toInt128()
                );
            }
        }
    }

    // Tracks the state of a pool throughout a swap, and returns these values at the end of the swap
    struct SwapResult {
        // the current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the current liquidity in range
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
        // the global fee growth of the input token. updated in storage at the end of swap
        uint256 feeGrowthGlobalX128;
    }

    struct SwapParams {
        int256 amountSpecified;
        int24 tickSpacing;
        bool zeroForOne;
        uint160 sqrtPriceLimitX96;
        uint24 lpFeeOverride;
    }

    /// @notice Executes a swap against the state, and returns the amount deltas of the pool
    /// @dev PoolManager checks that the pool is initialized before calling
    function swap(State storage self, SwapParams memory params)
        internal
        returns (BalanceDelta swapDelta, uint256 amountToProtocol, uint24 swapFee, SwapResult memory result)
    {
        Slot0 slot0Start = self.slot0;
        bool zeroForOne = params.zeroForOne;

        uint256 protocolFee =
            zeroForOne ? slot0Start.protocolFee().getZeroForOneFee() : slot0Start.protocolFee().getOneForZeroFee();

        // the amount remaining to be swapped in/out of the input/output asset. initially set to the amountSpecified
        int256 amountSpecifiedRemaining = params.amountSpecified;
        // the amount swapped out/in of the output/input asset. initially set to 0
        int256 amountCalculated = 0;
        // initialize to the current sqrt(price)
        result.sqrtPriceX96 = slot0Start.sqrtPriceX96();
        // initialize to the current tick
        result.tick = slot0Start.tick();
        // initialize to the current liquidity
        result.liquidity = self.liquidity;

        // if the beforeSwap hook returned a valid fee override, use that as the LP fee, otherwise load from storage
        // lpFee, swapFee, and protocolFee are all in pips
        {
            uint24 lpFee = params.lpFeeOverride.isOverride()
                ? params.lpFeeOverride.removeOverrideFlagAndValidate()
                : slot0Start.lpFee();

            swapFee = protocolFee == 0 ? lpFee : uint16(protocolFee).calculateSwapFee(lpFee);
        }

        // a swap fee totaling MAX_SWAP_FEE (100%) makes exact output swaps impossible since the input is entirely consumed by the fee
        if (swapFee >= SwapMath.MAX_SWAP_FEE) {
            // if exactOutput
            if (params.amountSpecified > 0) {
                InvalidFeeForExactOut.selector.revertWith();
            }
        }

        // swapFee is the pool's fee in pips (LP fee + protocol fee)
        // when the amount swapped is 0, there is no protocolFee applied and the fee amount paid to the protocol is set to 0
        if (params.amountSpecified == 0) return (BalanceDeltaLibrary.ZERO_DELTA, 0, swapFee, result);

        if (zeroForOne) {
            if (params.sqrtPriceLimitX96 >= slot0Start.sqrtPriceX96()) {
                PriceLimitAlreadyExceeded.selector.revertWith(slot0Start.sqrtPriceX96(), params.sqrtPriceLimitX96);
            }
            // Swaps can never occur at MIN_TICK, only at MIN_TICK + 1, except at initialization of a pool
            // Under certain circumstances outlined below, the tick will preemptively reach MIN_TICK without swapping there
            if (params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
                PriceLimitOutOfBounds.selector.revertWith(params.sqrtPriceLimitX96);
            }
        } else {
            if (params.sqrtPriceLimitX96 <= slot0Start.sqrtPriceX96()) {
                PriceLimitAlreadyExceeded.selector.revertWith(slot0Start.sqrtPriceX96(), params.sqrtPriceLimitX96);
            }
            if (params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
                PriceLimitOutOfBounds.selector.revertWith(params.sqrtPriceLimitX96);
            }
        }

        StepComputations memory step;
        step.feeGrowthGlobalX128 = zeroForOne ? self.feeGrowthGlobal0X128 : self.feeGrowthGlobal1X128;

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        while (!(amountSpecifiedRemaining == 0 || result.sqrtPriceX96 == params.sqrtPriceLimitX96)) {
            step.sqrtPriceStartX96 = result.sqrtPriceX96;

            (step.tickNext, step.initialized) =
                self.tickBitmap.nextInitializedTickWithinOneWord(result.tick, params.tickSpacing, zeroForOne);

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.tickNext <= TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            }
            if (step.tickNext >= TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            (result.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                result.sqrtPriceX96,
                SwapMath.getSqrtPriceTarget(zeroForOne, step.sqrtPriceNextX96, params.sqrtPriceLimitX96),
                result.liquidity,
                amountSpecifiedRemaining,
                swapFee
            );

            // if exactOutput
            if (params.amountSpecified > 0) {
                unchecked {
                    amountSpecifiedRemaining -= step.amountOut.toInt256();
                }
                amountCalculated -= (step.amountIn + step.feeAmount).toInt256();
            } else {
                // safe because we test that amountSpecified > amountIn + feeAmount in SwapMath
                unchecked {
                    amountSpecifiedRemaining += (step.amountIn + step.feeAmount).toInt256();
                }
                amountCalculated += step.amountOut.toInt256();
            }

            // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
            if (protocolFee > 0) {
                unchecked {
                    // step.amountIn does not include the swap fee, as it's already been taken from it,
                    // so add it back to get the total amountIn and use that to calculate the amount of fees owed to the protocol
                    // cannot overflow due to limits on the size of protocolFee and params.amountSpecified
                    // this rounds down to favor LPs over the protocol
                    uint256 delta = (swapFee == protocolFee)
                        ? step.feeAmount  // lp fee is 0, so the entire fee is owed to the protocol instead
                        : (step.amountIn + step.feeAmount) * protocolFee / ProtocolFeeLibrary.PIPS_DENOMINATOR;
                    // subtract it from the total fee and add it to the protocol fee
                    step.feeAmount -= delta;
                    amountToProtocol += delta;
                }
            }

            // update global fee tracker
            if (result.liquidity > 0) {
                unchecked {
                    // FullMath.mulDiv isn't needed as the numerator can't overflow uint256 since tokens have a max supply of type(uint128).max
                    step.feeGrowthGlobalX128 += UnsafeMath.simpleMulDiv(
                        step.feeAmount, FixedPoint128.Q128, result.liquidity
                    );
                }
            }

            // Shift tick if we reached the next price, and preemptively decrement for zeroForOne swaps to tickNext - 1.
            // If the swap doesn't continue (if amountRemaining == 0 or sqrtPriceLimit is met), slot0.tick will be 1 less
            // than getTickAtSqrtPrice(slot0.sqrtPrice). This doesn't affect swaps, but donation calls should verify both
            // price and tick to reward the correct LPs.
            if (result.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = zeroForOne
                        ? (step.feeGrowthGlobalX128, self.feeGrowthGlobal1X128)
                        : (self.feeGrowthGlobal0X128, step.feeGrowthGlobalX128);
                    int128 liquidityNet =
                        Pool.crossTick(self, step.tickNext, feeGrowthGlobal0X128, feeGrowthGlobal1X128);
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }

                    result.liquidity = LiquidityMath.addDelta(result.liquidity, liquidityNet);
                }

                unchecked {
                    result.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
                }
            } else if (result.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                result.tick = TickMath.getTickAtSqrtPrice(result.sqrtPriceX96);
            }
        }

        self.slot0 = slot0Start.setTick(result.tick).setSqrtPriceX96(result.sqrtPriceX96);

        // update liquidity if it changed
        if (self.liquidity != result.liquidity) self.liquidity = result.liquidity;

        // update fee growth global
        if (!zeroForOne) {
            self.feeGrowthGlobal1X128 = step.feeGrowthGlobalX128;
        } else {
            self.feeGrowthGlobal0X128 = step.feeGrowthGlobalX128;
        }

        unchecked {
            // "if currency1 is specified"
            if (zeroForOne != (params.amountSpecified < 0)) {
                swapDelta = toBalanceDelta(
                    amountCalculated.toInt128(), (params.amountSpecified - amountSpecifiedRemaining).toInt128()
                );
            } else {
                swapDelta = toBalanceDelta(
                    (params.amountSpecified - amountSpecifiedRemaining).toInt128(), amountCalculated.toInt128()
                );
            }
        }
    }

    /// @notice Donates the given amount of currency0 and currency1 to the pool
    function donate(State storage state, uint256 amount0, uint256 amount1) internal returns (BalanceDelta delta) {
        uint128 liquidity = state.liquidity;
        if (liquidity == 0) NoLiquidityToReceiveFees.selector.revertWith();
        unchecked {
            // negation safe as amount0 and amount1 are always positive
            delta = toBalanceDelta(-(amount0.toInt128()), -(amount1.toInt128()));
            // FullMath.mulDiv is unnecessary because the numerator is bounded by type(int128).max * Q128, which is less than type(uint256).max
            if (amount0 > 0) {
                state.feeGrowthGlobal0X128 += UnsafeMath.simpleMulDiv(amount0, FixedPoint128.Q128, liquidity);
            }
            if (amount1 > 0) {
                state.feeGrowthGlobal1X128 += UnsafeMath.simpleMulDiv(amount1, FixedPoint128.Q128, liquidity);
            }
        }
    }

    /// @notice Retrieves fee growth data
    /// @param self The Pool state struct
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @return feeGrowthInside0X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries
    /// @return feeGrowthInside1X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries
    function getFeeGrowthInside(State storage self, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        TickInfo storage lower = self.ticks[tickLower];
        TickInfo storage upper = self.ticks[tickUpper];
        int24 tickCurrent = self.slot0.tick();

        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 = lower.feeGrowthOutside0X128 - upper.feeGrowthOutside0X128;
                feeGrowthInside1X128 = lower.feeGrowthOutside1X128 - upper.feeGrowthOutside1X128;
            } else if (tickCurrent >= tickUpper) {
                feeGrowthInside0X128 = upper.feeGrowthOutside0X128 - lower.feeGrowthOutside0X128;
                feeGrowthInside1X128 = upper.feeGrowthOutside1X128 - lower.feeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 =
                    self.feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128 - upper.feeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    self.feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128 - upper.feeGrowthOutside1X128;
            }
        }
    }

    /// @notice Updates a tick and returns true if the tick was flipped from initialized to uninitialized, or vice versa
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The tick that will be updated
    /// @param liquidityDelta A new amount of liquidity to be added (subtracted) when tick is crossed from left to right (right to left)
    /// @param upper true for updating a position's upper tick, or false for updating a position's lower tick
    /// @return flipped Whether the tick was flipped from initialized to uninitialized, or vice versa
    /// @return liquidityGrossAfter The total amount of liquidity for all positions that references the tick after the update
    function updateTick(State storage self, int24 tick, int128 liquidityDelta, bool upper)
        internal
        returns (bool flipped, uint128 liquidityGrossAfter)
    {
        TickInfo storage info = self.ticks[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        int128 liquidityNetBefore = info.liquidityNet;

        liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta);

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // by convention, we assume that all growth before a tick was initialized happened _below_ the tick
            if (tick <= self.slot0.tick()) {
                info.feeGrowthOutside0X128 = self.feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = self.feeGrowthGlobal1X128;
            }
        }

        // when the lower (upper) tick is crossed left to right, liquidity must be added (removed)
        // when the lower (upper) tick is crossed right to left, liquidity must be removed (added)
        int128 liquidityNet = upper ? liquidityNetBefore - liquidityDelta : liquidityNetBefore + liquidityDelta;
        assembly ("memory-safe") {
            // liquidityGrossAfter and liquidityNet are packed in the first slot of `info`
            // So we can store them with a single sstore by packing them ourselves first
            sstore(
                info.slot,
                // bitwise OR to pack liquidityGrossAfter and liquidityNet
                or(
                    // Put liquidityGrossAfter in the lower bits, clearing out the upper bits
                    and(liquidityGrossAfter, 0xffffffffffffffffffffffffffffffff),
                    // Shift liquidityNet to put it in the upper bits (no need for signextend since we're shifting left)
                    shl(128, liquidityNet)
                )
            )
        }
    }

    /// @notice Derives max liquidity per tick from given tick spacing
    /// @dev Executed when adding liquidity
    /// @param tickSpacing The amount of required tick separation, realized in multiples of `tickSpacing`
    ///     e.g., a tickSpacing of 3 requires ticks to be initialized every 3rd tick i.e., ..., -6, -3, 0, 3, 6, ...
    /// @return result The max liquidity per tick
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128 result) {
        // Equivalent to:
        // int24 minTick = (TickMath.MIN_TICK / tickSpacing);
        // if (TickMath.MIN_TICK  % tickSpacing != 0) minTick--;
        // int24 maxTick = (TickMath.MAX_TICK / tickSpacing);
        // uint24 numTicks = maxTick - minTick + 1;
        // return type(uint128).max / numTicks;
        int24 MAX_TICK = TickMath.MAX_TICK;
        int24 MIN_TICK = TickMath.MIN_TICK;
        // tick spacing will never be 0 since TickMath.MIN_TICK_SPACING is 1
        assembly ("memory-safe") {
            tickSpacing := signextend(2, tickSpacing)
            let minTick := sub(sdiv(MIN_TICK, tickSpacing), slt(smod(MIN_TICK, tickSpacing), 0))
            let maxTick := sdiv(MAX_TICK, tickSpacing)
            let numTicks := add(sub(maxTick, minTick), 1)
            result := div(sub(shl(128, 1), 1), numTicks)
        }
    }

    /// @notice Reverts if the given pool has not been initialized
    function checkPoolInitialized(State storage self) internal view {
        if (self.slot0.sqrtPriceX96() == 0) PoolNotInitialized.selector.revertWith();
    }

    /// @notice Clears tick data
    /// @param self The mapping containing all initialized tick information for initialized ticks
    /// @param tick The tick that will be cleared
    function clearTick(State storage self, int24 tick) internal {
        delete self.ticks[tick];
    }

    /// @notice Transitions to next tick as needed by price movement
    /// @param self The Pool state struct
    /// @param tick The destination tick of the transition
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1
    /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left)
    function crossTick(State storage self, int24 tick, uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128)
        internal
        returns (int128 liquidityNet)
    {
        unchecked {
            TickInfo storage info = self.ticks[tick];
            info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
            info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
            liquidityNet = info.liquidityNet;
        }
    }
}

// lib/v4-core/src/libraries/TransientStateLibrary.sol

/// @notice A helper library to provide state getters that use exttload
library TransientStateLibrary {
    /// @notice returns the reserves for the synced currency
    /// @param manager The pool manager contract.
    /// @return uint256 The reserves of the currency.
    /// @dev returns 0 if the reserves are not synced or value is 0.
    /// Checks the synced currency to only return valid reserve values (after a sync and before a settle).
    function getSyncedReserves(IPoolManager manager) internal view returns (uint256) {
        if (getSyncedCurrency(manager).isAddressZero()) return 0;
        return uint256(manager.exttload(CurrencyReserves.RESERVES_OF_SLOT));
    }

    function getSyncedCurrency(IPoolManager manager) internal view returns (Currency) {
        return Currency.wrap(address(uint160(uint256(manager.exttload(CurrencyReserves.CURRENCY_SLOT)))));
    }

    /// @notice Returns the number of nonzero deltas open on the PoolManager that must be zeroed out before the contract is locked
    function getNonzeroDeltaCount(IPoolManager manager) internal view returns (uint256) {
        return uint256(manager.exttload(NonzeroDeltaCount.NONZERO_DELTA_COUNT_SLOT));
    }

    /// @notice Get the current delta for a caller in the given currency
    /// @param target The credited account address
    /// @param currency The currency for which to lookup the delta
    function currencyDelta(IPoolManager manager, address target, Currency currency) internal view returns (int256) {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, and(target, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(32, and(currency, 0xffffffffffffffffffffffffffffffffffffffff))
            key := keccak256(0, 64)
        }
        return int256(uint256(manager.exttload(key)));
    }

    /// @notice Returns whether the contract is unlocked or not
    function isUnlocked(IPoolManager manager) internal view returns (bool) {
        return manager.exttload(Lock.IS_UNLOCKED_SLOT) != 0x0;
    }
}

// lib/v4-core/src/libraries/StateLibrary.sol

/// @notice A helper library to provide state getters that use extsload
library StateLibrary {
    /// @notice index of pools mapping in the PoolManager
    bytes32 public constant POOLS_SLOT = bytes32(uint256(6));

    /// @notice index of feeGrowthGlobal0X128 in Pool.State
    uint256 public constant FEE_GROWTH_GLOBAL0_OFFSET = 1;

    // feeGrowthGlobal1X128 offset in Pool.State = 2

    /// @notice index of liquidity in Pool.State
    uint256 public constant LIQUIDITY_OFFSET = 3;

    /// @notice index of TicksInfo mapping in Pool.State: mapping(int24 => TickInfo) ticks;
    uint256 public constant TICKS_OFFSET = 4;

    /// @notice index of tickBitmap mapping in Pool.State
    uint256 public constant TICK_BITMAP_OFFSET = 5;

    /// @notice index of Position.State mapping in Pool.State: mapping(bytes32 => Position.State) positions;
    uint256 public constant POSITIONS_OFFSET = 6;

    /**
     * @notice Get Slot0 of the pool: sqrtPriceX96, tick, protocolFee, lpFee
     * @dev Corresponds to pools[poolId].slot0
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @return sqrtPriceX96 The square root of the price of the pool, in Q96 precision.
     * @return tick The current tick of the pool.
     * @return protocolFee The protocol fee of the pool.
     * @return lpFee The swap fee of the pool.
     */
    function getSlot0(IPoolManager manager, PoolId poolId)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = _getPoolStateSlot(poolId);

        bytes32 data = manager.extsload(stateSlot);

        //   24 bits  |24bits|24bits      |24 bits|160 bits
        // 0x000000   |000bb8|000000      |ffff75 |0000000000000000fe3aa841ba359daa0ea9eff7
        // ---------- | fee  |protocolfee | tick  | sqrtPriceX96
        assembly ("memory-safe") {
            // bottom 160 bits of data
            sqrtPriceX96 := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            // next 24 bits of data
            tick := signextend(2, shr(160, data))
            // next 24 bits of data
            protocolFee := and(shr(184, data), 0xFFFFFF)
            // last 24 bits of data
            lpFee := and(shr(208, data), 0xFFFFFF)
        }
    }

    /**
     * @notice Retrieves the tick information of a pool at a specific tick.
     * @dev Corresponds to pools[poolId].ticks[tick]
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @param tick The tick to retrieve information for.
     * @return liquidityGross The total position liquidity that references this tick
     * @return liquidityNet The amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left)
     * @return feeGrowthOutside0X128 fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
     * @return feeGrowthOutside1X128 fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
     */
    function getTickInfo(IPoolManager manager, PoolId poolId, int24 tick)
        internal
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128
        )
    {
        bytes32 slot = _getTickInfoSlot(poolId, tick);

        // read all 3 words of the TickInfo struct
        bytes32[] memory data = manager.extsload(slot, 3);
        assembly ("memory-safe") {
            let firstWord := mload(add(data, 32))
            liquidityNet := sar(128, firstWord)
            liquidityGross := and(firstWord, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            feeGrowthOutside0X128 := mload(add(data, 64))
            feeGrowthOutside1X128 := mload(add(data, 96))
        }
    }

    /**
     * @notice Retrieves the liquidity information of a pool at a specific tick.
     * @dev Corresponds to pools[poolId].ticks[tick].liquidityGross and pools[poolId].ticks[tick].liquidityNet. A more gas efficient version of getTickInfo
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @param tick The tick to retrieve liquidity for.
     * @return liquidityGross The total position liquidity that references this tick
     * @return liquidityNet The amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left)
     */
    function getTickLiquidity(IPoolManager manager, PoolId poolId, int24 tick)
        internal
        view
        returns (uint128 liquidityGross, int128 liquidityNet)
    {
        bytes32 slot = _getTickInfoSlot(poolId, tick);

        bytes32 value = manager.extsload(slot);
        assembly ("memory-safe") {
            liquidityNet := sar(128, value)
            liquidityGross := and(value, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }
    }

    /**
     * @notice Retrieves the fee growth outside a tick range of a pool
     * @dev Corresponds to pools[poolId].ticks[tick].feeGrowthOutside0X128 and pools[poolId].ticks[tick].feeGrowthOutside1X128. A more gas efficient version of getTickInfo
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @param tick The tick to retrieve fee growth for.
     * @return feeGrowthOutside0X128 fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
     * @return feeGrowthOutside1X128 fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
     */
    function getTickFeeGrowthOutside(IPoolManager manager, PoolId poolId, int24 tick)
        internal
        view
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        bytes32 slot = _getTickInfoSlot(poolId, tick);

        // offset by 1 word, since the first word is liquidityGross + liquidityNet
        bytes32[] memory data = manager.extsload(bytes32(uint256(slot) + 1), 2);
        assembly ("memory-safe") {
            feeGrowthOutside0X128 := mload(add(data, 32))
            feeGrowthOutside1X128 := mload(add(data, 64))
        }
    }

    /**
     * @notice Retrieves the global fee growth of a pool.
     * @dev Corresponds to pools[poolId].feeGrowthGlobal0X128 and pools[poolId].feeGrowthGlobal1X128
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @return feeGrowthGlobal0 The global fee growth for token0.
     * @return feeGrowthGlobal1 The global fee growth for token1.
     * @dev Note that feeGrowthGlobal can be artificially inflated
     * For pools with a single liquidity position, actors can donate to themselves to freely inflate feeGrowthGlobal
     * atomically donating and collecting fees in the same unlockCallback may make the inflated value more extreme
     */
    function getFeeGrowthGlobals(IPoolManager manager, PoolId poolId)
        internal
        view
        returns (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1)
    {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = _getPoolStateSlot(poolId);

        // Pool.State, `uint256 feeGrowthGlobal0X128`
        bytes32 slot_feeGrowthGlobal0X128 = bytes32(uint256(stateSlot) + FEE_GROWTH_GLOBAL0_OFFSET);

        // read the 2 words of feeGrowthGlobal
        bytes32[] memory data = manager.extsload(slot_feeGrowthGlobal0X128, 2);
        assembly ("memory-safe") {
            feeGrowthGlobal0 := mload(add(data, 32))
            feeGrowthGlobal1 := mload(add(data, 64))
        }
    }

    /**
     * @notice Retrieves total the liquidity of a pool.
     * @dev Corresponds to pools[poolId].liquidity
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @return liquidity The liquidity of the pool.
     */
    function getLiquidity(IPoolManager manager, PoolId poolId) internal view returns (uint128 liquidity) {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = _getPoolStateSlot(poolId);

        // Pool.State: `uint128 liquidity`
        bytes32 slot = bytes32(uint256(stateSlot) + LIQUIDITY_OFFSET);

        liquidity = uint128(uint256(manager.extsload(slot)));
    }

    /**
     * @notice Retrieves the tick bitmap of a pool at a specific tick.
     * @dev Corresponds to pools[poolId].tickBitmap[tick]
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @param tick The tick to retrieve the bitmap for.
     * @return tickBitmap The bitmap of the tick.
     */
    function getTickBitmap(IPoolManager manager, PoolId poolId, int16 tick) internal view returns (uint256 tickBitmap) {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = _getPoolStateSlot(poolId);

        // Pool.State: `mapping(int16 => uint256) tickBitmap;`
        bytes32 tickBitmapMapping = bytes32(uint256(stateSlot) + TICK_BITMAP_OFFSET);

        // slot id of the mapping key: `pools[poolId].tickBitmap[tick]
        bytes32 slot = keccak256(abi.encodePacked(int256(tick), tickBitmapMapping));

        tickBitmap = uint256(manager.extsload(slot));
    }

    /**
     * @notice Retrieves the position information of a pool without needing to calculate the `positionId`.
     * @dev Corresponds to pools[poolId].positions[positionId]
     * @param poolId The ID of the pool.
     * @param owner The owner of the liquidity position.
     * @param tickLower The lower tick of the liquidity range.
     * @param tickUpper The upper tick of the liquidity range.
     * @param salt The bytes32 randomness to further distinguish position state.
     * @return liquidity The liquidity of the position.
     * @return feeGrowthInside0LastX128 The fee growth inside the position for token0.
     * @return feeGrowthInside1LastX128 The fee growth inside the position for token1.
     */
    function getPositionInfo(
        IPoolManager manager,
        PoolId poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal view returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) {
        // positionKey = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt))
        bytes32 positionKey = Position.calculatePositionKey(owner, tickLower, tickUpper, salt);

        (liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128) = getPositionInfo(manager, poolId, positionKey);
    }

    /**
     * @notice Retrieves the position information of a pool at a specific position ID.
     * @dev Corresponds to pools[poolId].positions[positionId]
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @param positionId The ID of the position.
     * @return liquidity The liquidity of the position.
     * @return feeGrowthInside0LastX128 The fee growth inside the position for token0.
     * @return feeGrowthInside1LastX128 The fee growth inside the position for token1.
     */
    function getPositionInfo(IPoolManager manager, PoolId poolId, bytes32 positionId)
        internal
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128)
    {
        bytes32 slot = _getPositionInfoSlot(poolId, positionId);

        // read all 3 words of the Position.State struct
        bytes32[] memory data = manager.extsload(slot, 3);

        assembly ("memory-safe") {
            liquidity := mload(add(data, 32))
            feeGrowthInside0LastX128 := mload(add(data, 64))
            feeGrowthInside1LastX128 := mload(add(data, 96))
        }
    }

    /**
     * @notice Retrieves the liquidity of a position.
     * @dev Corresponds to pools[poolId].positions[positionId].liquidity. More gas efficient for just retrieiving liquidity as compared to getPositionInfo
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @param positionId The ID of the position.
     * @return liquidity The liquidity of the position.
     */
    function getPositionLiquidity(IPoolManager manager, PoolId poolId, bytes32 positionId)
        internal
        view
        returns (uint128 liquidity)
    {
        bytes32 slot = _getPositionInfoSlot(poolId, positionId);
        liquidity = uint128(uint256(manager.extsload(slot)));
    }

    /**
     * @notice Calculate the fee growth inside a tick range of a pool
     * @dev pools[poolId].feeGrowthInside0LastX128 in Position.State is cached and can become stale. This function will calculate the up to date feeGrowthInside
     * @param manager The pool manager contract.
     * @param poolId The ID of the pool.
     * @param tickLower The lower tick of the range.
     * @param tickUpper The upper tick of the range.
     * @return feeGrowthInside0X128 The fee growth inside the tick range for token0.
     * @return feeGrowthInside1X128 The fee growth inside the tick range for token1.
     */
    function getFeeGrowthInside(IPoolManager manager, PoolId poolId, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = getFeeGrowthGlobals(manager, poolId);

        (uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128) =
            getTickFeeGrowthOutside(manager, poolId, tickLower);
        (uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128) =
            getTickFeeGrowthOutside(manager, poolId, tickUpper);
        (, int24 tickCurrent,,) = getSlot0(manager, poolId);
        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else if (tickCurrent >= tickUpper) {
                feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            }
        }
    }

    function _getPoolStateSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT));
    }

    function _getTickInfoSlot(PoolId poolId, int24 tick) internal pure returns (bytes32) {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = _getPoolStateSlot(poolId);

        // Pool.State: `mapping(int24 => TickInfo) ticks`
        bytes32 ticksMappingSlot = bytes32(uint256(stateSlot) + TICKS_OFFSET);

        // slot key of the tick key: `pools[poolId].ticks[tick]
        return keccak256(abi.encodePacked(int256(tick), ticksMappingSlot));
    }

    function _getPositionInfoSlot(PoolId poolId, bytes32 positionId) internal pure returns (bytes32) {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = _getPoolStateSlot(poolId);

        // Pool.State: `mapping(bytes32 => Position.State) positions;`
        bytes32 positionMapping = bytes32(uint256(stateSlot) + POSITIONS_OFFSET);

        // slot of the mapping key: `pools[poolId].positions[positionId]
        return keccak256(abi.encodePacked(positionId, positionMapping));
    }
}

// lib/v4-core/src/test/PoolTestBase.sol

abstract contract PoolTestBase is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function _fetchBalances(Currency currency, address user, address deltaHolder)
        internal
        view
        returns (uint256 userBalance, uint256 poolBalance, int256 delta)
    {
        userBalance = currency.balanceOf(user);
        poolBalance = currency.balanceOf(address(manager));
        delta = manager.currencyDelta(deltaHolder, currency);
    }
}

// lib/v4-core/src/ProtocolFees.sol

/// @notice Contract handling the setting and accrual of protocol fees
abstract contract ProtocolFees is IProtocolFees, Owned {
    using ProtocolFeeLibrary for uint24;
    using Pool for Pool.State;
    using CustomRevert for bytes4;

    /// @inheritdoc IProtocolFees
    mapping(Currency currency => uint256 amount) public protocolFeesAccrued;

    /// @inheritdoc IProtocolFees
    address public protocolFeeController;

    constructor(address initialOwner) Owned(initialOwner) {}

    /// @inheritdoc IProtocolFees
    function setProtocolFeeController(address controller) external onlyOwner {
        protocolFeeController = controller;
        emit ProtocolFeeControllerUpdated(controller);
    }

    /// @inheritdoc IProtocolFees
    function setProtocolFee(PoolKey memory key, uint24 newProtocolFee) external {
        if (msg.sender != protocolFeeController) InvalidCaller.selector.revertWith();
        if (!newProtocolFee.isValidProtocolFee()) ProtocolFeeTooLarge.selector.revertWith(newProtocolFee);
        PoolId id = key.toId();
        _getPool(id).setProtocolFee(newProtocolFee);
        emit ProtocolFeeUpdated(id, newProtocolFee);
    }

    /// @inheritdoc IProtocolFees
    function collectProtocolFees(address recipient, Currency currency, uint256 amount)
        external
        returns (uint256 amountCollected)
    {
        if (msg.sender != protocolFeeController) InvalidCaller.selector.revertWith();
        if (!currency.isAddressZero() && CurrencyReserves.getSyncedCurrency() == currency) {
            // prevent transfer between the sync and settle balanceOfs (native settle uses msg.value)
            ProtocolFeeCurrencySynced.selector.revertWith();
        }

        amountCollected = (amount == 0) ? protocolFeesAccrued[currency] : amount;
        protocolFeesAccrued[currency] -= amountCollected;
        currency.transfer(recipient, amountCollected);
    }

    /// @dev abstract internal function to allow the ProtocolFees contract to access the lock
    function _isUnlocked() internal virtual returns (bool);

    /// @dev abstract internal function to allow the ProtocolFees contract to access pool state
    /// @dev this is overridden in PoolManager.sol to give access to the _pools mapping
    function _getPool(PoolId id) internal virtual returns (Pool.State storage);

    function _updateProtocolFees(Currency currency, uint256 amount) internal {
        unchecked {
            protocolFeesAccrued[currency] += amount;
        }
    }
}

// lib/v4-core/src/test/PoolDonateTest.sol

contract PoolDonateTest is PoolTestBase {
    using CurrencySettler for Currency;
    using Hooks for IHooks;

    constructor(IPoolManager _manager) PoolTestBase(_manager) {}

    struct CallbackData {
        address sender;
        PoolKey key;
        uint256 amount0;
        uint256 amount1;
        bytes hookData;
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, key, amount0, amount1, hookData))), (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
        }
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        (,, int256 deltaBefore0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 deltaBefore1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        require(deltaBefore0 == 0, "deltaBefore0 is not 0");
        require(deltaBefore1 == 0, "deltaBefore1 is not 0");

        BalanceDelta delta = manager.donate(data.key, data.amount0, data.amount1, data.hookData);

        (,, int256 deltaAfter0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 deltaAfter1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        require(deltaAfter0 == -int256(data.amount0), "deltaAfter0 is not equal to -int256(data.amount0)");
        require(deltaAfter1 == -int256(data.amount1), "deltaAfter1 is not equal to -int256(data.amount1)");

        if (deltaAfter0 < 0) data.key.currency0.settle(manager, data.sender, uint256(-deltaAfter0), false);
        if (deltaAfter1 < 0) data.key.currency1.settle(manager, data.sender, uint256(-deltaAfter1), false);
        if (deltaAfter0 > 0) data.key.currency0.take(manager, data.sender, uint256(deltaAfter0), false);
        if (deltaAfter1 > 0) data.key.currency1.take(manager, data.sender, uint256(deltaAfter1), false);

        return abi.encode(delta);
    }
}

// lib/v4-core/src/test/PoolModifyLiquidityTest.sol

contract PoolModifyLiquidityTest is PoolTestBase {
    using CurrencySettler for Currency;
    using Hooks for IHooks;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    constructor(IPoolManager _manager) PoolTestBase(_manager) {}

    struct CallbackData {
        address sender;
        PoolKey key;
        ModifyLiquidityParams params;
        bytes hookData;
        bool settleUsingBurn;
        bool takeClaims;
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        delta = modifyLiquidity(key, params, hookData, false, false);
    }

    function modifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes memory hookData,
        bool settleUsingBurn,
        bool takeClaims
    ) public payable returns (BalanceDelta delta) {
        delta = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, key, params, hookData, settleUsingBurn, takeClaims))),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
        }
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        (uint128 liquidityBefore,,) = manager.getPositionInfo(
            data.key.toId(), address(this), data.params.tickLower, data.params.tickUpper, data.params.salt
        );

        (BalanceDelta delta,) = manager.modifyLiquidity(data.key, data.params, data.hookData);

        (uint128 liquidityAfter,,) = manager.getPositionInfo(
            data.key.toId(), address(this), data.params.tickLower, data.params.tickUpper, data.params.salt
        );

        (,, int256 delta0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 delta1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        require(
            int128(liquidityBefore) + data.params.liquidityDelta == int128(liquidityAfter), "liquidity change incorrect"
        );

        if (data.params.liquidityDelta < 0) {
            assert(delta0 > 0 || delta1 > 0);
            assert(!(delta0 < 0 || delta1 < 0));
        } else if (data.params.liquidityDelta > 0) {
            assert(delta0 < 0 || delta1 < 0);
            assert(!(delta0 > 0 || delta1 > 0));
        }

        if (delta0 < 0) data.key.currency0.settle(manager, data.sender, uint256(-delta0), data.settleUsingBurn);
        if (delta1 < 0) data.key.currency1.settle(manager, data.sender, uint256(-delta1), data.settleUsingBurn);
        if (delta0 > 0) data.key.currency0.take(manager, data.sender, uint256(delta0), data.takeClaims);
        if (delta1 > 0) data.key.currency1.take(manager, data.sender, uint256(delta1), data.takeClaims);

        return abi.encode(delta);
    }
}

// lib/v4-core/src/test/PoolSwapTest.sol

contract PoolSwapTest is PoolTestBase {
    using CurrencySettler for Currency;
    using Hooks for IHooks;

    constructor(IPoolManager _manager) PoolTestBase(_manager) {}

    error NoSwapOccurred();

    struct CallbackData {
        address sender;
        TestSettings testSettings;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    struct TestSettings {
        bool takeClaims;
        bool settleUsingBurn;
    }

    function swap(PoolKey memory key, SwapParams memory params, TestSettings memory testSettings, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, testSettings, key, params, hookData))), (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        (,, int256 deltaBefore0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 deltaBefore1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        require(deltaBefore0 == 0, "deltaBefore0 is not equal to 0");
        require(deltaBefore1 == 0, "deltaBefore1 is not equal to 0");

        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        (,, int256 deltaAfter0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 deltaAfter1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        if (data.params.zeroForOne) {
            if (data.params.amountSpecified < 0) {
                // exact input, 0 for 1
                require(
                    deltaAfter0 >= data.params.amountSpecified,
                    "deltaAfter0 is not greater than or equal to data.params.amountSpecified"
                );
                require(delta.amount0() == deltaAfter0, "delta.amount0() is not equal to deltaAfter0");
                require(deltaAfter1 >= 0, "deltaAfter1 is not greater than or equal to 0");
            } else {
                // exact output, 0 for 1
                require(deltaAfter0 <= 0, "deltaAfter0 is not less than or equal to zero");
                require(delta.amount1() == deltaAfter1, "delta.amount1() is not equal to deltaAfter1");
                require(
                    deltaAfter1 <= data.params.amountSpecified,
                    "deltaAfter1 is not less than or equal to data.params.amountSpecified"
                );
            }
        } else {
            if (data.params.amountSpecified < 0) {
                // exact input, 1 for 0
                require(
                    deltaAfter1 >= data.params.amountSpecified,
                    "deltaAfter1 is not greater than or equal to data.params.amountSpecified"
                );
                require(delta.amount1() == deltaAfter1, "delta.amount1() is not equal to deltaAfter1");
                require(deltaAfter0 >= 0, "deltaAfter0 is not greater than or equal to 0");
            } else {
                // exact output, 1 for 0
                require(deltaAfter1 <= 0, "deltaAfter1 is not less than or equal to 0");
                require(delta.amount0() == deltaAfter0, "delta.amount0() is not equal to deltaAfter0");
                require(
                    deltaAfter0 <= data.params.amountSpecified,
                    "deltaAfter0 is not less than or equal to data.params.amountSpecified"
                );
            }
        }

        if (deltaAfter0 < 0) {
            data.key.currency0.settle(manager, data.sender, uint256(-deltaAfter0), data.testSettings.settleUsingBurn);
        }
        if (deltaAfter1 < 0) {
            data.key.currency1.settle(manager, data.sender, uint256(-deltaAfter1), data.testSettings.settleUsingBurn);
        }
        if (deltaAfter0 > 0) {
            data.key.currency0.take(manager, data.sender, uint256(deltaAfter0), data.testSettings.takeClaims);
        }
        if (deltaAfter1 > 0) {
            data.key.currency1.take(manager, data.sender, uint256(deltaAfter1), data.testSettings.takeClaims);
        }

        return abi.encode(delta);
    }
}

// lib/v4-core/src/PoolManager.sol

//  4
//   44
//     444
//       444                   4444
//        4444            4444     4444
//          4444          4444444    4444                           4
//            4444        44444444     4444                         4
//             44444       4444444       4444444444444444       444444
//           4   44444     44444444       444444444444444444444    4444
//            4    44444    4444444         4444444444444444444444  44444
//             4     444444  4444444         44444444444444444444444 44  4
//              44     44444   444444          444444444444444444444 4     4
//               44      44444   44444           4444444444444444444 4 44
//                44       4444     44             444444444444444     444
//                444     4444                        4444444
//               4444444444444                     44                      4
//              44444444444                        444444     444444444    44
//             444444           4444               4444     4444444444      44
//             4444           44    44              4      44444444444
//            44444          444444444                   444444444444    4444
//            44444          44444444                  4444  44444444    444444
//            44444                                  4444   444444444    44444444
//           44444                                 4444     44444444    4444444444
//          44444                                4444      444444444   444444444444
//         44444                               4444        44444444    444444444444
//       4444444                             4444          44444444         4444444
//      4444444                            44444          44444444          4444444
//     44444444                           44444444444444444444444444444        4444
//   4444444444                           44444444444444444444444444444         444
//  444444444444                         444444444444444444444444444444   444   444
//  44444444444444                                      444444444         44444
// 44444  44444444444         444                       44444444         444444
// 44444  4444444444      4444444444      444444        44444444    444444444444
//  444444444444444      4444  444444    4444444       44444444     444444444444
//  444444444444444     444    444444     444444       44444444      44444444444
//   4444444444444     4444   444444        4444                      4444444444
//    444444444444      4     44444         4444                       444444444
//     44444444444           444444         444                        44444444
//      44444444            444444         4444                         4444444
//                          44444          444                          44444
//                          44444         444      4                    4444
//                          44444        444      44                   444
//                          44444       444      4444
//                           444444  44444        444
//                             444444444           444
//                                                  44444   444
//                                                      444

/// @title PoolManager
/// @notice Holds the state for all pools
contract PoolManager is IPoolManager, ProtocolFees, NoDelegateCall, ERC6909Claims, Extsload, Exttload {
    using SafeCast for *;
    using Pool for *;
    using Hooks for IHooks;
    using CurrencyDelta for Currency;
    using LPFeeLibrary for uint24;
    using CurrencyReserves for Currency;
    using CustomRevert for bytes4;

    int24 private constant MAX_TICK_SPACING = TickMath.MAX_TICK_SPACING;

    int24 private constant MIN_TICK_SPACING = TickMath.MIN_TICK_SPACING;

    mapping(PoolId id => Pool.State) internal _pools;

    /// @notice This will revert if the contract is locked
    modifier onlyWhenUnlocked() {
        if (!Lock.isUnlocked()) ManagerLocked.selector.revertWith();
        _;
    }

    constructor(address initialOwner) ProtocolFees(initialOwner) {}

    /// @inheritdoc IPoolManager
    function unlock(bytes calldata data) external override returns (bytes memory result) {
        if (Lock.isUnlocked()) AlreadyUnlocked.selector.revertWith();

        Lock.unlock();

        // the caller does everything in this callback, including paying what they owe via calls to settle
        result = IUnlockCallback(msg.sender).unlockCallback(data);

        if (NonzeroDeltaCount.read() != 0) CurrencyNotSettled.selector.revertWith();
        Lock.lock();
    }

    /// @inheritdoc IPoolManager
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external noDelegateCall returns (int24 tick) {
        // see TickBitmap.sol for overflow conditions that can arise from tick spacing being too large
        if (key.tickSpacing > MAX_TICK_SPACING) TickSpacingTooLarge.selector.revertWith(key.tickSpacing);
        if (key.tickSpacing < MIN_TICK_SPACING) TickSpacingTooSmall.selector.revertWith(key.tickSpacing);
        if (key.currency0 >= key.currency1) {
            CurrenciesOutOfOrderOrEqual.selector
                .revertWith(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        }
        if (!key.hooks.isValidHookAddress(key.fee)) Hooks.HookAddressNotValid.selector.revertWith(address(key.hooks));

        uint24 lpFee = key.fee.getInitialLPFee();

        key.hooks.beforeInitialize(key, sqrtPriceX96);

        PoolId id = key.toId();

        tick = _pools[id].initialize(sqrtPriceX96, lpFee);

        // event is emitted before the afterInitialize call to ensure events are always emitted in order
        // emit all details of a pool key. poolkeys are not saved in storage and must always be provided by the caller
        // the key's fee may be a static fee or a sentinel to denote a dynamic fee.
        emit Initialize(id, key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks, sqrtPriceX96, tick);

        key.hooks.afterInitialize(key, sqrtPriceX96, tick);
    }

    /// @inheritdoc IPoolManager
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        {
            Pool.State storage pool = _getPool(id);
            pool.checkPoolInitialized();

            key.hooks.beforeModifyLiquidity(key, params, hookData);

            BalanceDelta principalDelta;
            (principalDelta, feesAccrued) = pool.modifyLiquidity(
                Pool.ModifyLiquidityParams({
                    owner: msg.sender,
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidityDelta: params.liquidityDelta.toInt128(),
                    tickSpacing: key.tickSpacing,
                    salt: params.salt
                })
            );

            // fee delta and principal delta are both accrued to the caller
            callerDelta = principalDelta + feesAccrued;
        }

        // event is emitted before the afterModifyLiquidity call to ensure events are always emitted in order
        emit ModifyLiquidity(id, msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta, params.salt);

        BalanceDelta hookDelta;
        (callerDelta, hookDelta) = key.hooks.afterModifyLiquidity(key, params, callerDelta, feesAccrued, hookData);

        // if the hook doesn't have the flag to be able to return deltas, hookDelta will always be 0
        if (hookDelta != BalanceDeltaLibrary.ZERO_DELTA) _accountPoolBalanceDelta(key, hookDelta, address(key.hooks));

        _accountPoolBalanceDelta(key, callerDelta, msg.sender);
    }

    /// @inheritdoc IPoolManager
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta swapDelta)
    {
        if (params.amountSpecified == 0) SwapAmountCannotBeZero.selector.revertWith();
        PoolId id = key.toId();
        Pool.State storage pool = _getPool(id);
        pool.checkPoolInitialized();

        BeforeSwapDelta beforeSwapDelta;
        {
            int256 amountToSwap;
            uint24 lpFeeOverride;
            (amountToSwap, beforeSwapDelta, lpFeeOverride) = key.hooks.beforeSwap(key, params, hookData);

            // execute swap, account protocol fees, and emit swap event
            // _swap is needed to avoid stack too deep error
            swapDelta = _swap(
                pool,
                id,
                Pool.SwapParams({
                    tickSpacing: key.tickSpacing,
                    zeroForOne: params.zeroForOne,
                    amountSpecified: amountToSwap,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                    lpFeeOverride: lpFeeOverride
                }),
                params.zeroForOne ? key.currency0 : key.currency1 // input token
            );
        }

        BalanceDelta hookDelta;
        (swapDelta, hookDelta) = key.hooks.afterSwap(key, params, swapDelta, hookData, beforeSwapDelta);

        // if the hook doesn't have the flag to be able to return deltas, hookDelta will always be 0
        if (hookDelta != BalanceDeltaLibrary.ZERO_DELTA) _accountPoolBalanceDelta(key, hookDelta, address(key.hooks));

        _accountPoolBalanceDelta(key, swapDelta, msg.sender);
    }

    /// @notice Internal swap function to execute a swap, take protocol fees on input token, and emit the swap event
    function _swap(Pool.State storage pool, PoolId id, Pool.SwapParams memory params, Currency inputCurrency)
        internal
        returns (BalanceDelta)
    {
        (BalanceDelta delta, uint256 amountToProtocol, uint24 swapFee, Pool.SwapResult memory result) =
            pool.swap(params);

        // the fee is on the input currency
        if (amountToProtocol > 0) _updateProtocolFees(inputCurrency, amountToProtocol);

        // event is emitted before the afterSwap call to ensure events are always emitted in order
        emit Swap(
            id,
            msg.sender,
            delta.amount0(),
            delta.amount1(),
            result.sqrtPriceX96,
            result.liquidity,
            result.tick,
            swapFee
        );

        return delta;
    }

    /// @inheritdoc IPoolManager
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta delta)
    {
        PoolId poolId = key.toId();
        Pool.State storage pool = _getPool(poolId);
        pool.checkPoolInitialized();

        key.hooks.beforeDonate(key, amount0, amount1, hookData);

        delta = pool.donate(amount0, amount1);

        _accountPoolBalanceDelta(key, delta, msg.sender);

        // event is emitted before the afterDonate call to ensure events are always emitted in order
        emit Donate(poolId, msg.sender, amount0, amount1);

        key.hooks.afterDonate(key, amount0, amount1, hookData);
    }

    /// @inheritdoc IPoolManager
    function sync(Currency currency) external {
        // address(0) is used for the native currency
        if (currency.isAddressZero()) {
            // The reserves balance is not used for native settling, so we only need to reset the currency.
            CurrencyReserves.resetCurrency();
        } else {
            uint256 balance = currency.balanceOfSelf();
            CurrencyReserves.syncCurrencyAndReserves(currency, balance);
        }
    }

    /// @inheritdoc IPoolManager
    function take(Currency currency, address to, uint256 amount) external onlyWhenUnlocked {
        unchecked {
            // negation must be safe as amount is not negative
            _accountDelta(currency, -(amount.toInt128()), msg.sender);
            currency.transfer(to, amount);
        }
    }

    /// @inheritdoc IPoolManager
    function settle() external payable onlyWhenUnlocked returns (uint256) {
        return _settle(msg.sender);
    }

    /// @inheritdoc IPoolManager
    function settleFor(address recipient) external payable onlyWhenUnlocked returns (uint256) {
        return _settle(recipient);
    }

    /// @inheritdoc IPoolManager
    function clear(Currency currency, uint256 amount) external onlyWhenUnlocked {
        int256 current = currency.getDelta(msg.sender);
        // Because input is `uint256`, only positive amounts can be cleared.
        int128 amountDelta = amount.toInt128();
        if (amountDelta != current) MustClearExactPositiveDelta.selector.revertWith();
        // negation must be safe as amountDelta is positive
        unchecked {
            _accountDelta(currency, -(amountDelta), msg.sender);
        }
    }

    /// @inheritdoc IPoolManager
    function mint(address to, uint256 id, uint256 amount) external onlyWhenUnlocked {
        unchecked {
            Currency currency = CurrencyLibrary.fromId(id);
            // negation must be safe as amount is not negative
            _accountDelta(currency, -(amount.toInt128()), msg.sender);
            _mint(to, currency.toId(), amount);
        }
    }

    /// @inheritdoc IPoolManager
    function burn(address from, uint256 id, uint256 amount) external onlyWhenUnlocked {
        Currency currency = CurrencyLibrary.fromId(id);
        _accountDelta(currency, amount.toInt128(), msg.sender);
        _burnFrom(from, currency.toId(), amount);
    }

    /// @inheritdoc IPoolManager
    function updateDynamicLPFee(PoolKey memory key, uint24 newDynamicLPFee) external {
        if (!key.fee.isDynamicFee() || msg.sender != address(key.hooks)) {
            UnauthorizedDynamicLPFeeUpdate.selector.revertWith();
        }
        newDynamicLPFee.validate();
        PoolId id = key.toId();
        _pools[id].setLPFee(newDynamicLPFee);
    }

    // if settling native, integrators should still call `sync` first to avoid DoS attack vectors
    function _settle(address recipient) internal returns (uint256 paid) {
        Currency currency = CurrencyReserves.getSyncedCurrency();

        // if not previously synced, or the syncedCurrency slot has been reset, expects native currency to be settled
        if (currency.isAddressZero()) {
            paid = msg.value;
        } else {
            if (msg.value > 0) NonzeroNativeValue.selector.revertWith();
            // Reserves are guaranteed to be set because currency and reserves are always set together
            uint256 reservesBefore = CurrencyReserves.getSyncedReserves();
            uint256 reservesNow = currency.balanceOfSelf();
            paid = reservesNow - reservesBefore;
            CurrencyReserves.resetCurrency();
        }

        _accountDelta(currency, paid.toInt128(), recipient);
    }

    /// @notice Adds a balance delta in a currency for a target address
    function _accountDelta(Currency currency, int128 delta, address target) internal {
        if (delta == 0) return;

        (int256 previous, int256 next) = currency.applyDelta(target, delta);

        if (next == 0) {
            NonzeroDeltaCount.decrement();
        } else if (previous == 0) {
            NonzeroDeltaCount.increment();
        }
    }

    /// @notice Accounts the deltas of 2 currencies to a target address
    function _accountPoolBalanceDelta(PoolKey memory key, BalanceDelta delta, address target) internal {
        _accountDelta(key.currency0, delta.amount0(), target);
        _accountDelta(key.currency1, delta.amount1(), target);
    }

    /// @notice Implementation of the _getPool function defined in ProtocolFees
    function _getPool(PoolId id) internal view override returns (Pool.State storage) {
        return _pools[id];
    }

    /// @notice Implementation of the _isUnlocked function defined in ProtocolFees
    function _isUnlocked() internal view override returns (bool) {
        return Lock.isUnlocked();
    }
}

// src/Bundle.sol

// ───────────────────────────────────────────── IMDO test suite ─────────────────────────────────────────────

interface Vm {
    function prank(address msgSender) external;
    function prank(address msgSender, address txOrigin) external;
    function startPrank(address msgSender) external;
    function startPrank(address msgSender, address txOrigin) external;
    function stopPrank() external;
    function roll(uint256 newHeight) external;
    function deal(address account, uint256 newBalance) external;
    function etch(address target, bytes calldata newRuntimeBytecode) external;
    function chainId(uint256 newChainId) external;
    function assume(bool condition) external pure;
    function label(address account, string calldata newLabel) external;
    function load(address target, bytes32 slot) external view returns (bytes32);
}

/// @dev One transient slot, used to learn whether the harness ends a transaction after each top-level call a test
///      makes. forge 1.8 does (the slot reads 0 in the next call); forge 1.7 keeps transient storage for the whole
///      test function. The suite must pass under both, so nothing in it relies on either behaviour: multi-leg
///      transactions run inside one external self-call, expected fees are computed from the hook's own ledger as it
///      stands before the sell, and only the "gone after the transaction" checks are gated on this probe.
contract TransientProbe {
    function bump() external {
        assembly ("memory-safe") {
            tstore(0, add(tload(0), 1))
        }
    }

    function get() external view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(0)
        }
    }
}

interface IHookPermissions {
    function getHookPermissions() external pure returns (Hooks.Permissions memory);
}

/// @dev Assertion helpers. A failing assertion reverts with a message that carries both values.
abstract contract Asserts {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant TREASURY = 0xb1eC9d1C36974d05eb9889eBf8A150b05791E559;
    uint256 internal constant SUPPLY = 1_000_000_000 ether; // 10^27: one billion IMDO, 18 decimals
    uint256 internal constant PPM = 1_000_000;
    uint160 internal constant EXPECTED_FLAGS = 0x25d4;
    uint160 internal constant FLAG_MASK = (1 << 14) - 1;
    // PUSH1 0 PUSH1 0 REVERT: a contract that rejects every call and every ETH transfer.
    bytes internal constant REJECT_ALL = hex"60006000fd";

    function assertTrue(bool ok, string memory why) internal pure {
        if (!ok) revert(why);
    }

    function assertFalse(bool ok, string memory why) internal pure {
        if (ok) revert(why);
    }

    function assertEq(uint256 a, uint256 b, string memory why) internal pure {
        if (a != b) revert(string.concat(why, " [", _str(a), " != ", _str(b), "]"));
    }

    function assertEq(int256 a, int256 b, string memory why) internal pure {
        if (a != b) revert(string.concat(why, " [", _stri(a), " != ", _stri(b), "]"));
    }

    function assertEq(address a, address b, string memory why) internal pure {
        if (a != b) revert(why);
    }

    function assertEq(bytes32 a, bytes32 b, string memory why) internal pure {
        if (a != b) revert(why);
    }

    function assertGe(uint256 a, uint256 b, string memory why) internal pure {
        if (a < b) revert(string.concat(why, " [", _str(a), " < ", _str(b), "]"));
    }

    function assertLe(uint256 a, uint256 b, string memory why) internal pure {
        if (a > b) revert(string.concat(why, " [", _str(a), " > ", _str(b), "]"));
    }

    function assertGt(uint256 a, uint256 b, string memory why) internal pure {
        if (a <= b) revert(string.concat(why, " [", _str(a), " <= ", _str(b), "]"));
    }

    function assertLt(uint256 a, uint256 b, string memory why) internal pure {
        if (a >= b) revert(string.concat(why, " [", _str(a), " >= ", _str(b), "]"));
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (lo >= hi) return lo;
        if (x >= lo && x <= hi) return x;
        return lo + (x % (hi - lo + 1));
    }

    /// @dev The fee schedule from the brief, written independently of the hook's own arithmetic:
    ///      sold/reserve < 1% -> 0; [1%, 3%) -> 5,000 ppm; [3%, 5%) -> 10,000 ppm; >= 5% -> 20,000 ppm.
    function _expectedPpm(uint256 sold, uint256 reserve) internal pure returns (uint256) {
        if (sold == 0) return 0;
        if (reserve == 0) return 20_000;
        if (sold * 100 < reserve) return 0;
        if (sold * 100 < reserve * 3) return 5_000;
        if (sold * 100 < reserve * 5) return 10_000;
        return 20_000;
    }

    /// @dev Smallest sell that is at least `percent`% of `reserve` (the bracket boundary).
    function _atPercent(uint256 reserve, uint256 percent) internal pure returns (uint256) {
        return (reserve * percent + 99) / 100;
    }

    function _ceilFee(uint256 basis, uint256 ppm) internal pure returns (uint256) {
        return (basis * ppm + PPM - 1) / PPM;
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @dev True when every top-level call made by a test is its own transaction for transient storage.
    function _topLevelCallsAreTransactions() internal returns (bool) {
        TransientProbe probe = new TransientProbe();
        probe.bump();
        return probe.get() == 0;
    }

    /// @dev The reserve the next sell is sized against (README, "block snapshot"): the previous block's ledger, or
    ///      the ledger just before the swap when that is lower. On the first mutation of a block the snapshot rolls
    ///      to the current ledger, so both are the same number then.
    function _sizingReserve(IMDOFeeHook hook) internal view returns (uint256) {
        uint256 live = hook.tokenReserve();
        if (hook.reserveBlock() < block.number) return live;
        uint256 lagged = hook.laggedTokenReserve();
        return live < lagged ? live : lagged;
    }

    /// @dev The README's billing rule for one sell leg, written from the README and applied to the origin's ledger
    ///      `l` as it stood before the leg (updated in place). The origin owes the schedule on everything it sold in
    ///      the transaction; the leg collects the shortfall in the one currency it can charge (ETH for exact-input,
    ///      IMDO for exact-output, the other side converted at the leg's own realized price), but never more than
    ///      2% of its own basis. What does not fit stays owed in the ledger.
    function _billLeg(IMDOFeeHook.Ledger memory l, bool exactIn, uint256 legSold, uint256 legEth, uint256 reserve)
        internal
        pure
        returns (uint256 fee)
    {
        l.sold += legSold;
        if (exactIn) l.ethBasis += legEth;
        else l.tokenBasis += legSold;
        uint256 ppm = _expectedPpm(l.sold, reserve);
        return _collectLeg(l, exactIn, legSold, legEth, _ceilFee(l.ethBasis, ppm), _ceilFee(l.tokenBasis, ppm));
    }

    function _collectLeg(
        IMDOFeeHook.Ledger memory l,
        bool exactIn,
        uint256 legSold,
        uint256 legEth,
        uint256 ethDue,
        uint256 tokenDue
    ) private pure returns (uint256 fee) {
        uint256 own = exactIn ? ethDue - l.ethPaid : tokenDue - l.tokenPaid; // paid never exceeds due
        uint256 other = exactIn ? tokenDue - l.tokenPaid : ethDue - l.ethPaid;
        uint256 converted;
        if (other != 0 && legEth != 0) {
            converted = exactIn ? _ceilDiv(other * legEth, legSold) : _ceilDiv(other * legSold, legEth);
        }
        fee = _ceilFee(exactIn ? legEth : legSold, 20_000); // the per-swap cap
        if (own + converted <= fee) {
            fee = own + converted;
            if (exactIn || converted != 0) l.ethPaid = ethDue;
            if (!exactIn || converted != 0) l.tokenPaid = tokenDue;
        } else {
            if (own > fee) own = fee;
            other = fee - own; // part of the capped fee that pays the other side, in this leg's currency
            if (exactIn) {
                l.ethPaid += own;
                if (other != 0) l.tokenPaid += other * legSold / legEth;
            } else {
                l.tokenPaid += own;
                if (other != 0) l.ethPaid += other * legEth / legSold;
            }
        }
    }

    function _ledgerSum(IMDOFeeHook.Ledger memory l) internal pure returns (uint256) {
        return l.sold + l.ethBasis + l.tokenBasis + l.ethPaid + l.tokenPaid;
    }

    /// @dev |a - b| <= tolerance, with the values in the message.
    function assertClose(uint256 a, uint256 b, uint256 tolerance, string memory why) internal pure {
        uint256 diff = a > b ? a - b : b - a;
        if (diff > tolerance) revert(string.concat(why, " [", _str(a), " vs ", _str(b), "]"));
    }

    function _same(uint256 size, uint256 n) internal pure returns (uint256[] memory sizes) {
        sizes = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            sizes[i] = size;
        }
    }

    function _str(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t != 0; t /= 10) {
            len++;
        }
        bytes memory out = new bytes(len);
        while (v != 0) {
            out[--len] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(out);
    }

    function _stri(int256 v) internal pure returns (string memory) {
        if (v < 0) return string.concat("-", _str(uint256(-v)));
        return _str(uint256(v));
    }

    function _hasNoDelegatecallOrSelfdestruct(bytes memory code) internal pure returns (bool) {
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (op == 0xf4 || op == 0xf2 || op == 0xff) return false;
        }
        return true;
    }
}

/// @notice Stand-in for the launch factory: it deploys the token (so it holds the whole supply), CREATE2-deploys
/// the hook at the mined address, initializes the pool and seeds its own liquidity position in ONE transaction,
/// and later collects that position's pool fees to a fixed recipient. It talks to the manager directly, so the
/// position is owned by the factory exactly as a real factory position would be.
contract ModelFactory is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    PoolManager public immutable manager;
    IMDOToken public immutable token;
    address public immutable feeRecipient;

    struct Action {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        address recipient;
    }

    constructor(PoolManager manager_, address feeRecipient_) {
        manager = manager_;
        token = new IMDOToken();
        feeRecipient = feeRecipient_;
    }

    receive() external payable {}

    function launch(
        bytes32 salt,
        bytes memory hookCreationCode,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidity
    ) external payable returns (address hook) {
        if (hookCreationCode.length != 0) {
            assembly ("memory-safe") {
                hook := create2(0, add(hookCreationCode, 0x20), mload(hookCreationCode), salt)
            }
            require(hook != address(0), "hook create2 failed");
            require(hook == address(key.hooks), "hook address mismatch");
        }
        manager.initialize(key, sqrtPriceX96);
        if (liquidity != 0) _modify(key, tickLower, tickUpper, liquidity, address(this));
    }

    function modifyPosition(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        return _modify(key, tickLower, tickUpper, liquidityDelta, address(this));
    }

    /// @dev The factory's fee distribution: collect the position's accrued pool fees and pay them out.
    function collectFees(PoolKey memory key, int24 tickLower, int24 tickUpper)
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        return _modify(key, tickLower, tickUpper, 0, feeRecipient);
    }

    function transferTokens(address to, uint256 amount) external {
        require(token.transfer(to, amount), "transfer failed");
    }

    function _modify(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta, address recipient)
        internal
        returns (BalanceDelta, BalanceDelta)
    {
        bytes memory result = manager.unlock(abi.encode(Action(key, tickLower, tickUpper, liquidityDelta, recipient)));
        return abi.decode(result, (BalanceDelta, BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        Action memory a = abi.decode(data, (Action));
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = manager.modifyLiquidity(
            a.key, ModifyLiquidityParams(a.tickLower, a.tickUpper, a.liquidityDelta, bytes32(0)), ""
        );
        int128 d0 = callerDelta.amount0();
        int128 d1 = callerDelta.amount1();
        if (d0 < 0) manager.settle{value: uint256(uint128(-d0))}();
        if (d1 < 0) {
            manager.sync(a.key.currency1);
            require(token.transfer(address(manager), uint256(uint128(-d1))), "transfer failed");
            manager.settle();
        }
        if (d0 > 0) manager.take(a.key.currency0, a.recipient, uint256(uint128(d0)));
        if (d1 > 0) manager.take(a.key.currency1, a.recipient, uint256(uint128(d1)));
        return abi.encode(callerDelta, feesAccrued);
    }
}

/// @notice Model of the swarm's Merkle distributor: leaves are keccak256(index, account, amount), sorted-pair hashing.
contract ModelMerkleDistributor {
    IMDOToken public immutable token;
    bytes32 public immutable merkleRoot;
    mapping(uint256 => bool) public isClaimed;

    error AlreadyClaimed();
    error InvalidProof();

    constructor(IMDOToken token_, bytes32 root_) {
        token = token_;
        merkleRoot = root_;
    }

    function claim(uint256 index, address account, uint256 amount, bytes32[] calldata proof) external {
        if (isClaimed[index]) revert AlreadyClaimed();
        bytes32 node = keccak256(abi.encodePacked(index, account, amount));
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 p = proof[i];
            node = node < p ? keccak256(abi.encodePacked(node, p)) : keccak256(abi.encodePacked(p, node));
        }
        if (node != merkleRoot) revert InvalidProof();
        isClaimed[index] = true;
        require(token.transfer(account, amount), "transfer failed");
    }
}

/// @dev Shared v4 fixture: builds a universe (manager + factory + token + pool [+ hook] + routers).
abstract contract V4Fixture is Asserts {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Universe {
        PoolManager manager;
        ModelFactory factory;
        IMDOToken token;
        IMDOFeeHook hook;
        PoolKey key;
        PoolSwapTest swapRouter;
        PoolModifyLiquidityTest lpRouter;
        PoolDonateTest donateRouter;
    }

    int24 internal constant TICK_LOWER = -887_220;
    int24 internal constant TICK_UPPER = 887_220;
    int24 internal constant INIT_TICK = 69_060; // ~998 IMDO per ETH
    uint24 internal constant LP_FEE = 3_000;
    int24 internal constant TICK_SPACING = 60;

    uint160 internal immutable SQRT_PRICE = TickMath.getSqrtPriceAtTick(INIT_TICK);
    Deploy internal deployScript = new Deploy();
    bool internal pranking;

    receive() external payable {}

    function _build(
        Universe storage u,
        bool hooked,
        address feeRecipient,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal {
        u.manager = new PoolManager(address(this));
        u.factory = new ModelFactory(u.manager, feeRecipient);
        u.token = u.factory.token();
        bytes32 salt;
        bytes memory code;
        address hookAddr;
        if (hooked) {
            (salt, hookAddr) = deployScript.mine(address(u.factory), address(u.manager), address(u.token), 0, 200_000);
            code = deployScript.hookCreationCode(address(u.manager), address(u.token));
        }
        u.key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(u.token)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), amount0, amount1
        );
        vm.deal(address(u.factory), amount0 + 1 ether);
        u.factory.launch(salt, code, u.key, SQRT_PRICE, tickLower, tickUpper, int256(uint256(liquidity)));
        u.hook = IMDOFeeHook(hookAddr);
        u.swapRouter = new PoolSwapTest(u.manager);
        u.lpRouter = new PoolModifyLiquidityTest(u.manager);
        u.donateRouter = new PoolDonateTest(u.manager);
    }

    function _fund(Universe storage u, address user, uint256 tokens, uint256 eth) internal {
        if (tokens > 0) u.factory.transferTokens(user, tokens);
        if (eth > 0) vm.deal(user, eth);
        vm.startPrank(user);
        u.token.approve(address(u.swapRouter), type(uint256).max);
        u.token.approve(address(u.lpRouter), type(uint256).max);
        u.token.approve(address(u.donateRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Start a multi-call "transaction" from `user` (msg.sender and tx.origin).
    function _as(address user) internal {
        vm.startPrank(user, user);
        pranking = true;
    }

    function _done() internal {
        vm.stopPrank();
        pranking = false;
    }

    function _swap(Universe storage u, address user, SwapParams memory p, uint256 value)
        internal
        returns (BalanceDelta)
    {
        if (!pranking) vm.prank(user, user);
        return u.swapRouter.swap{value: value}(u.key, p, PoolSwapTest.TestSettings(false, false), "");
    }

    function _sellExactIn(Universe storage u, address user, uint256 tokens) internal returns (BalanceDelta) {
        return _swap(u, user, SwapParams(false, -int256(tokens), TickMath.MAX_SQRT_PRICE - 1), 0);
    }

    function _sellExactOut(Universe storage u, address user, uint256 ethOut) internal returns (BalanceDelta) {
        return _swap(u, user, SwapParams(false, int256(ethOut), TickMath.MAX_SQRT_PRICE - 1), 0);
    }

    function _buyExactIn(Universe storage u, address user, uint256 ethIn) internal returns (BalanceDelta) {
        return _swap(u, user, SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1), ethIn);
    }

    function _buyExactOut(Universe storage u, address user, uint256 tokensOut, uint256 maxEth)
        internal
        returns (BalanceDelta)
    {
        return _swap(u, user, SwapParams(true, int256(tokensOut), TickMath.MIN_SQRT_PRICE + 1), maxEth);
    }

    function _addLiquidity(Universe storage u, address user, int24 tl, int24 tu, int256 liquidity, uint256 value)
        internal
        returns (BalanceDelta)
    {
        if (!pranking) vm.prank(user, user);
        return u.lpRouter.modifyLiquidity{value: value}(u.key, ModifyLiquidityParams(tl, tu, liquidity, bytes32(0)), "");
    }

    function _donate(Universe storage u, address user, uint256 amount0, uint256 amount1) internal {
        if (!pranking) vm.prank(user, user);
        u.donateRouter.donate{value: amount0}(u.key, amount0, amount1, "");
    }

    /// @dev Rough ETH value of `tokens` at the pool's current price (only used to pick exact-output sizes).
    function _tokensToEth(Universe storage u, uint256 tokens) internal view returns (uint256) {
        (uint160 sqrtP,,,) = IPoolManager(address(u.manager)).getSlot0(u.key.toId());
        uint256 priceQ96 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 96); // token1 per token0, Q96
        return FullMath.mulDiv(tokens, 1 << 96, priceQ96);
    }

    /// @dev Deploys a hook for (manager, token) from this contract at a mined address.
    function _deployHook(address manager, address token) internal returns (IMDOFeeHook) {
        (bytes32 salt, address predicted) = deployScript.mine(address(this), manager, token, 0, 200_000);
        bytes memory code = deployScript.hookCreationCode(manager, token);
        address at;
        assembly ("memory-safe") {
            at := create2(0, add(code, 0x20), mload(code), salt)
        }
        assertEq(at, predicted, "hook landed somewhere else");
        return IMDOFeeHook(at);
    }

    /// @dev Unwraps the manager's ERC-7751 `WrappedError(target, selector, reason, details)` and returns the hook's reason.
    function _hookReason(bytes memory err) internal pure returns (bytes4) {
        assertTrue(err.length >= 4 && bytes4(err) == CustomRevert.WrappedError.selector, "not a wrapped hook error");
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = err[i + 4];
        }
        (,, bytes memory reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
        assertTrue(reason.length >= 4, "hook reverted without a reason");
        return bytes4(reason);
    }

    function _expectInitializeRejected(PoolManager manager, PoolKey memory key, string memory why) internal {
        (bool ok, bytes memory err) = address(manager).call(abi.encodeCall(IPoolManager.initialize, (key, SQRT_PRICE)));
        assertFalse(ok, why);
        assertTrue(_hookReason(err) == IMDOFeeHook.InvalidPool.selector, string.concat(why, ": wrong reason"));
    }
}

// ───────────────────────────────────────────── token ─────────────────────────────────────────────

contract IMDOTokenTest is Asserts {
    IMDOToken token;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        token = new IMDOToken();
    }

    function test_metadataAndFixedSupplyMintedToDeployer() public view {
        assertTrue(keccak256(bytes(token.name())) == keccak256("IMD Offsets"), "name");
        assertTrue(keccak256(bytes(token.symbol())) == keccak256("IMDO"), "symbol");
        assertEq(uint256(token.decimals()), 18, "decimals");
        assertEq(token.totalSupply(), SUPPLY, "supply");
        assertEq(token.totalSupply(), 1e27, "supply is exactly 10^27 (one billion tokens at 18 decimals)");
        assertEq(token.INITIAL_SUPPLY(), SUPPLY, "initial supply constant");
        assertEq(token.balanceOf(address(this)), SUPPLY, "deployer holds the whole supply");
    }

    function test_transferMovesExactlyWhatWasAsked() public {
        assertTrue(token.transfer(alice, 1234), "transfer returned false");
        assertEq(token.balanceOf(alice), 1234, "recipient amount");
        assertEq(token.balanceOf(address(this)), SUPPLY - 1234, "sender amount");
        assertEq(token.totalSupply(), SUPPLY, "supply unchanged by transfer");
        // zero-amount and self transfers are ordinary
        assertTrue(token.transfer(bob, 0), "zero transfer");
        vm.prank(alice);
        assertTrue(token.transfer(alice, 1234), "self transfer");
        assertEq(token.balanceOf(alice), 1234, "self transfer keeps balance");
    }

    function test_transferFailurePaths() public {
        (bool ok,) = address(token).call(abi.encodeCall(IMDOToken.transfer, (address(0), 1)));
        assertFalse(ok, "transfer to zero address must revert");
        vm.prank(alice);
        (ok,) = address(token).call(abi.encodeCall(IMDOToken.transfer, (bob, 1)));
        assertFalse(ok, "transfer above balance must revert");
        token.transfer(alice, 10);
        vm.prank(alice);
        (ok,) = address(token).call(abi.encodeCall(IMDOToken.transfer, (bob, 11)));
        assertFalse(ok, "transfer of balance + 1 must revert");
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10), "transfer of the exact balance works");
        assertEq(token.balanceOf(alice), 0, "alice emptied");
    }

    function test_approveAndTransferFrom() public {
        token.transfer(alice, 1000);
        vm.prank(alice);
        token.approve(bob, 600);
        assertEq(token.allowance(alice, bob), 600, "allowance set");
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 400), "transferFrom");
        assertEq(token.allowance(alice, bob), 200, "allowance decremented");
        assertEq(token.balanceOf(bob), 400, "bob received");
        vm.prank(bob);
        (bool ok,) = address(token).call(abi.encodeCall(IMDOToken.transferFrom, (alice, bob, 201)));
        assertFalse(ok, "transferFrom above allowance must revert");
        vm.prank(bob);
        (ok,) = address(token).call(abi.encodeCall(IMDOToken.transferFrom, (alice, address(0), 1)));
        assertFalse(ok, "transferFrom to zero must revert");
        (ok,) = address(token).call(abi.encodeCall(IMDOToken.approve, (address(0), 1)));
        assertFalse(ok, "approve of zero spender must revert");
        // allowance can be lowered to zero and then nothing can be pulled
        vm.prank(alice);
        token.approve(bob, 0);
        vm.prank(bob);
        (ok,) = address(token).call(abi.encodeCall(IMDOToken.transferFrom, (alice, bob, 1)));
        assertFalse(ok, "zero allowance blocks transferFrom");
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        token.transfer(alice, 1000);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, bob, 999);
        assertEq(token.allowance(alice, bob), type(uint256).max, "infinite allowance stays infinite");
    }

    function test_burnReducesSupplyAndOnlyOwnBalance() public {
        token.transfer(alice, 500);
        vm.prank(alice);
        token.burn(200);
        assertEq(token.balanceOf(alice), 300, "burner balance");
        assertEq(token.totalSupply(), SUPPLY - 200, "supply reduced");
        vm.prank(alice);
        (bool ok,) = address(token).call(abi.encodeCall(IMDOToken.burn, (301)));
        assertFalse(ok, "burn above balance must revert");
        vm.prank(bob);
        (ok,) = address(token).call(abi.encodeCall(IMDOToken.burn, (1)));
        assertFalse(ok, "burn with no balance must revert");
        vm.prank(alice);
        token.burn(0);
        assertEq(token.totalSupply(), SUPPLY - 200, "zero burn is a no-op");
        // burnt tokens are gone, not parked at address zero
        assertEq(token.balanceOf(address(0)), 0, "nothing at address zero");
    }

    function test_noPrivilegedOrSupplyChangingCalls() public {
        string[18] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "blacklist(address)",
            "setBlacklist(address,bool)",
            "setFee(uint256)",
            "setTradingEnabled(bool)",
            "owner()",
            "burnFrom(address,uint256)"
        ];
        address attacker = address(0xBEEF);
        for (uint256 i = 0; i < sigs.length; i++) {
            bytes memory data = abi.encodeWithSignature(sigs[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, sigs[i]);
            // also from the deployer (the factory), which is the only address a token could plausibly trust
            (ok,) = address(token).call(data);
            assertFalse(ok, string.concat("deployer: ", sigs[i]));
            assertEq(token.totalSupply(), SUPPLY, sigs[i]);
            assertEq(token.balanceOf(attacker), 0, sigs[i]);
        }
        (bool okFallback,) = address(token).call{value: 0}("");
        assertFalse(okFallback, "no fallback / receive");
    }

    function test_runtimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0, "no runtime code");
        assertLe(code.length, 24_576, "over EIP-170");
        assertTrue(_hasNoDelegatecallOrSelfdestruct(code), "token runtime has DELEGATECALL/CALLCODE/SELFDESTRUCT");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = _bound(amount, 0, SUPPLY);
        uint256 beforeTo = token.balanceOf(to);
        token.transfer(to, amount);
        if (to == address(this)) {
            assertEq(token.balanceOf(to), beforeTo, "self transfer");
        } else {
            assertEq(token.balanceOf(to), beforeTo + amount, "recipient");
            assertEq(token.balanceOf(address(this)), SUPPLY - amount, "sender");
        }
        assertEq(token.totalSupply(), SUPPLY, "supply");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_burnIsExact(uint256 held, uint256 burned) public {
        held = _bound(held, 0, SUPPLY);
        burned = _bound(burned, 0, SUPPLY);
        token.transfer(alice, held);
        vm.prank(alice);
        (bool ok,) = address(token).call(abi.encodeCall(IMDOToken.burn, (burned)));
        if (burned > held) {
            assertFalse(ok, "burn above balance reverts");
            assertEq(token.totalSupply(), SUPPLY, "supply untouched");
        } else {
            assertTrue(ok, "burn within balance succeeds");
            assertEq(token.totalSupply(), SUPPLY - burned, "supply");
            assertEq(token.balanceOf(alice), held - burned, "balance");
        }
    }
}

// ───────────────────────────────────────────── hook ─────────────────────────────────────────────

contract IMDOHookTest is V4Fixture {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Universe U; // launch pool with the hook
    Universe T; // identical pool, no hook (control)
    Universe V; // a second hooked copy, built on demand, for single-sell versus split comparisons

    address feeRecipientU = address(0xFEE1);
    address feeRecipientT = address(0xFEE2);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);
    address dave = address(0xDA4E);
    address mallory = address(0x3A1);
    uint256 R; // token reserve snapshot the hook will use for sells in the test block

    uint256 constant SEED_ETH = 200 ether;
    uint256 constant SEED_TOKENS = 200_000 ether;

    function setUp() public {
        vm.chainId(11155111);
        _build(U, true, feeRecipientU, TICK_LOWER, TICK_UPPER, SEED_ETH, SEED_TOKENS);
        _build(T, false, feeRecipientT, TICK_LOWER, TICK_UPPER, SEED_ETH, SEED_TOKENS);
        address[5] memory users = [alice, bob, carol, dave, mallory];
        for (uint256 i = 0; i < users.length; i++) {
            _fund(U, users[i], 60_000 ether, 1_000 ether);
            _fund(T, users[i], 60_000 ether, 1_000 ether);
        }
        vm.roll(block.number + 1);
        R = U.hook.tokenReserve();
    }

    function _user(uint256 i) internal returns (address user) {
        user = address(uint160(0x10000 + i));
        _fund(U, user, 60_000 ether, 1_000 ether);
        _fund(T, user, 60_000 ether, 1_000 ether);
    }

    // ---------- binding, permissions, access ----------

    function test_poolBoundAndConstantsFixed() public view {
        assertTrue(U.hook.initialized(), "bound");
        assertEq(U.hook.poolId(), PoolId.unwrap(U.key.toId()), "poolId is the v4 pool id");
        assertEq(address(U.hook.poolManager()), address(U.manager), "manager");
        assertEq(U.hook.token(), address(U.token), "token");
        assertEq(U.hook.TREASURY(), TREASURY, "treasury");
        assertEq(uint256(U.hook.MAX_FEE_PPM()), 20_000, "cap");
        assertEq(U.hook.PPM(), PPM, "ppm");
        assertEq(uint256(U.hook.FLAGS()), uint256(EXPECTED_FLAGS), "flags");
        assertEq(uint256(uint160(address(U.hook)) & FLAG_MASK), uint256(EXPECTED_FLAGS), "address bits");
        assertEq(
            U.token.balanceOf(address(U.factory)) + U.token.balanceOf(address(U.manager)) + 5 * 60_000 ether,
            SUPPLY,
            "factory keeps what the pool and users do not hold"
        );
        assertEq(address(U.hook).balance, 0, "hook holds no ETH");
        assertEq(U.token.balanceOf(address(U.hook)), 0, "hook holds no tokens");
    }

    function test_permissionsMatchDeclaredFlagsAndSpec() public view {
        Hooks.Permissions memory p = IHookPermissions(address(U.hook)).getHookPermissions();
        assertTrue(p.beforeInitialize, "launch hooks need an initialize callback");
        assertTrue(p.afterSwap && p.afterSwapReturnDelta, "fee is taken in afterSwap with a return delta");
        assertFalse(p.beforeSwapReturnDelta, "no NoOp surface");
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta, "no LP return deltas");
        assertFalse(p.beforeAddLiquidity || p.beforeRemoveLiquidity, "liquidity is never gated");
        uint160 implemented;
        if (p.beforeInitialize) implemented |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (p.afterInitialize) implemented |= Hooks.AFTER_INITIALIZE_FLAG;
        if (p.beforeAddLiquidity) implemented |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (p.afterAddLiquidity) implemented |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (p.beforeRemoveLiquidity) implemented |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (p.afterRemoveLiquidity) implemented |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (p.beforeSwap) implemented |= Hooks.BEFORE_SWAP_FLAG;
        if (p.afterSwap) implemented |= Hooks.AFTER_SWAP_FLAG;
        if (p.beforeDonate) implemented |= Hooks.BEFORE_DONATE_FLAG;
        if (p.afterDonate) implemented |= Hooks.AFTER_DONATE_FLAG;
        if (p.beforeSwapReturnDelta) implemented |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterSwapReturnDelta) implemented |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterAddLiquidityReturnDelta) implemented |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (p.afterRemoveLiquidityReturnDelta) implemented |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
        assertEq(uint256(implemented), uint256(EXPECTED_FLAGS), "getHookPermissions disagrees with FLAGS");
        assertEq(uint256(uint160(address(U.hook)) & Hooks.ALL_HOOK_MASK), uint256(implemented), "address disagrees");
        assertTrue(Hooks.isValidHookAddress(IHooks(address(U.hook)), LP_FEE), "v4 rejects the address");
    }

    function test_callbacksRefuseCallersOtherThanTheManager() public {
        PoolKey memory key = U.key;
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        SwapParams memory sp = SwapParams(false, -1 ether, TickMath.MAX_SQRT_PRICE - 1);
        BalanceDelta zero = BalanceDeltaLibrary.ZERO_DELTA;
        bytes[8] memory calls = [
            abi.encodeCall(IHooks.beforeInitialize, (address(this), key, SQRT_PRICE)),
            abi.encodeCall(IHooks.afterAddLiquidity, (address(this), key, lp, zero, zero, "")),
            abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), key, lp, zero, zero, "")),
            abi.encodeCall(IHooks.beforeSwap, (address(this), key, sp, "")),
            abi.encodeCall(IHooks.afterSwap, (address(this), key, sp, zero, "")),
            abi.encodeCall(IHooks.afterDonate, (address(this), key, 1, 1, "")),
            abi.encodeCall(IUnlockCallback.unlockCallback, ("")),
            abi.encodeCall(IMDOFeeHook.redeemETH, (1))
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok,) = address(U.hook).call(calls[i]);
            assertFalse(ok, string.concat("callback accepted a stranger: #", _str(i)));
        }
        (bool okBurn,) = address(U.hook).call(abi.encodeCall(IMDOFeeHook.takeAndBurn, (1, false)));
        assertFalse(okBurn, "takeAndBurn accepted a stranger");
        // The manager itself cannot drive unlockCallback outside a harvest.
        vm.prank(address(U.manager));
        (bool okUnlock,) = address(U.hook).call(abi.encodeCall(IUnlockCallback.unlockCallback, ("")));
        assertFalse(okUnlock, "unlockCallback outside harvest must revert");
        // Callbacks are also refused for a different pool key, even from the manager.
        PoolKey memory other = key;
        other.fee = 500;
        vm.prank(address(U.manager));
        (bool okOther,) = address(U.hook).call(abi.encodeCall(IHooks.beforeSwap, (address(this), other, sp, "")));
        assertFalse(okOther, "beforeSwap accepted an unbound pool");
    }

    function test_noFunctionCanChangeBracketsCapOrTreasury() public {
        string[22] memory sigs = [
            "setTreasury(address)",
            "setFee(uint24)",
            "setFee(uint256)",
            "setFeePpm(uint256)",
            "setMaxFee(uint24)",
            "setBrackets(uint256[])",
            "setBracket(uint256,uint256)",
            "setThresholds(uint256[])",
            "setToken(address)",
            "setPoolManager(address)",
            "setPool(bytes32)",
            "transferOwnership(address)",
            "owner()",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "withdraw()",
            "withdraw(uint256)",
            "rescue(address)",
            "sweep(address,uint256)"
        ];
        address attacker = address(0xBEEF);
        for (uint256 i = 0; i < sigs.length; i++) {
            vm.prank(attacker);
            (bool ok,) = address(U.hook).call(abi.encodeWithSignature(sigs[i], attacker, uint256(1)));
            assertFalse(ok, sigs[i]);
        }
        (bool okEth,) = address(U.hook).call{value: 1 wei}("");
        assertFalse(okEth, "hook must not accept plain ETH");
        assertEq(U.hook.TREASURY(), TREASURY, "treasury changed");
        assertEq(uint256(U.hook.MAX_FEE_PPM()), 20_000, "cap changed");
        assertEq(uint256(U.hook.feePpm(1, 1_000)), 0, "bracket 0 changed");
        assertEq(uint256(U.hook.feePpm(10, 1_000)), 5_000, "bracket 1 changed");
        assertEq(uint256(U.hook.feePpm(30, 1_000)), 10_000, "bracket 2 changed");
        assertEq(uint256(U.hook.feePpm(50, 1_000)), 20_000, "bracket 3 changed");
        bytes memory code = address(U.hook).code;
        assertLe(code.length, 24_576, "over EIP-170");
        assertTrue(_hasNoDelegatecallOrSelfdestruct(code), "hook runtime has DELEGATECALL/CALLCODE/SELFDESTRUCT");
    }

    function test_initialize_rejectsRebindingAndWrongPools() public {
        // 1. the bound hook refuses a second pool (different fee tier, same pair)
        PoolKey memory second = U.key;
        second.fee = 500;
        second.tickSpacing = 10;
        _expectInitializeRejected(U.manager, second, "hook bound a second pool");

        // 2. a fresh hook refuses a pool whose currency1 is not its token
        IMDOToken other = new IMDOToken();
        IMDOFeeHook h2 = _deployHook(address(U.manager), address(U.token));
        PoolKey memory wrongToken =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(other)), LP_FEE, 60, IHooks(address(h2)));
        _expectInitializeRejected(U.manager, wrongToken, "hook accepted a foreign token");

        // 3. refuses a pool whose currency0 is not native ETH
        (address lo, address hi) =
            address(other) < address(U.token) ? (address(other), address(U.token)) : (address(U.token), address(other));
        IMDOFeeHook h3 = _deployHook(address(U.manager), hi);
        PoolKey memory notEth = PoolKey(Currency.wrap(lo), Currency.wrap(hi), LP_FEE, 60, IHooks(address(h3)));
        _expectInitializeRejected(U.manager, notEth, "hook accepted a non-ETH quote");

        // 4. refuses fee tiers outside the launch policy, and the dynamic flag
        IMDOFeeHook h4 = _deployHook(address(U.manager), address(U.token));
        PoolKey memory badFee =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(U.token)), 100, 1, IHooks(address(h4)));
        _expectInitializeRejected(U.manager, badFee, "hook accepted fee 100");
        badFee.fee = 0;
        _expectInitializeRejected(U.manager, badFee, "hook accepted fee 0");
        badFee.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        _expectInitializeRejected(U.manager, badFee, "hook accepted a dynamic fee");
        assertFalse(h4.initialized(), "rejections must not bind");

        // 5. the listed tiers are accepted
        badFee.fee = 10_000;
        badFee.tickSpacing = 200;
        U.manager.initialize(badFee, SQRT_PRICE);
        assertTrue(h4.initialized(), "fee 10000 bound");
        IMDOFeeHook h5 = _deployHook(address(U.manager), address(U.token));
        PoolKey memory k5 =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(U.token)), 500, 10, IHooks(address(h5)));
        U.manager.initialize(k5, SQRT_PRICE);
        assertTrue(h5.initialized(), "fee 500 bound");
    }

    function test_constructorRejectsBadArguments() public {
        bytes memory code = deployScript.hookCreationCode(address(0), address(U.token));
        (bool ok,) = address(this).call(abi.encodeCall(this.deployRaw, (code)));
        assertFalse(ok, "zero manager accepted");
        code = deployScript.hookCreationCode(address(U.manager), address(0));
        (ok,) = address(this).call(abi.encodeCall(this.deployRaw, (code)));
        assertFalse(ok, "zero token accepted");
        // plain CREATE lands on an address without the permission bits: the constructor must refuse it
        code = deployScript.hookCreationCode(address(U.manager), address(U.token));
        (ok,) = address(this).call(abi.encodeCall(this.deployRaw, (code)));
        assertFalse(ok, "address without permission bits accepted");
    }

    function deployRaw(bytes memory code) external returns (address at) {
        require(msg.sender == address(this));
        assembly ("memory-safe") {
            at := create(0, add(code, 0x20), mload(code))
        }
        require(at != address(0), "create failed");
    }

    // ---------- reserve ledger ----------

    function test_reserveLedgerTracksPoolInventoryAndLagsOneBlock() public {
        assertEq(U.hook.tokenReserve(), U.token.balanceOf(address(U.manager)), "ledger == manager inventory");
        assertEq(U.hook.tokenReserve(), T.token.balanceOf(address(T.manager)), "control pool holds the same");
        assertEq(U.hook.laggedTokenReserve(), 0, "snapshot only rolls on the first mutation of a block");
        _sellExactIn(T, alice, 1 ether);
        _sellExactIn(U, alice, 1 ether);
        assertEq(U.hook.laggedTokenReserve(), R, "first mutation rolls the snapshot to last block's ledger");
        assertEq(U.hook.tokenReserve(), U.token.balanceOf(address(U.manager)), "ledger after sell");
        _buyExactIn(U, bob, 1 ether);
        assertEq(U.hook.laggedTokenReserve(), R, "snapshot is fixed within the block");
        assertEq(U.hook.tokenReserve(), U.token.balanceOf(address(U.manager)), "ledger after buy");
        _donate(U, carol, 0, 5 ether);
        assertEq(U.hook.tokenReserve(), U.token.balanceOf(address(U.manager)), "ledger after donate");
        (BalanceDelta d,) = U.factory.modifyPosition(U.key, TICK_LOWER, TICK_UPPER, -1e18);
        assertTrue(d.amount1() > 0, "removal pays out");
        assertEq(U.hook.tokenReserve(), U.token.balanceOf(address(U.manager)), "ledger after remove");
        U.factory.collectFees(U.key, TICK_LOWER, TICK_UPPER);
        assertEq(U.hook.tokenReserve(), U.token.balanceOf(address(U.manager)), "ledger after fee collection");
        uint256 ledgerEndOfBlock = U.hook.tokenReserve();
        vm.roll(block.number + 1);
        assertEq(U.hook.laggedTokenReserve(), R, "idle roll does not move the snapshot yet");
        _sellExactIn(U, bob, 1 ether);
        assertEq(U.hook.laggedTokenReserve(), ledgerEndOfBlock, "snapshot is exactly last block's ledger");
    }

    function test_reserveLedgerExcludesProtocolFees() public {
        U.manager.setProtocolFeeController(address(this));
        T.manager.setProtocolFeeController(address(this));
        uint24 protocolFee = (1000 << 12) | 1000; // 0.1% each direction, the v4 maximum
        U.manager.setProtocolFee(U.key, protocolFee);
        T.manager.setProtocolFee(T.key, protocolFee);
        _sellExactIn(T, alice, 3_000 ether);
        _sellExactIn(U, alice, 3_000 ether);
        _buyExactIn(T, bob, 2 ether);
        _buyExactIn(U, bob, 2 ether);
        uint256 accruedToken = U.manager.protocolFeesAccrued(U.key.currency1);
        assertGt(accruedToken, 0, "protocol fee accrued in tokens");
        assertEq(
            U.hook.tokenReserve(), U.token.balanceOf(address(U.manager)) - accruedToken, "ledger excludes protocol fees"
        );
        assertEq(accruedToken, T.manager.protocolFeesAccrued(T.key.currency1), "protocol fee identical to control");
        assertEq(
            U.manager.protocolFeesAccrued(U.key.currency0),
            T.manager.protocolFeesAccrued(T.key.currency0),
            "ETH protocol fee identical to control"
        );
        uint256 collected = U.manager.collectProtocolFees(address(0xF00), U.key.currency1, 0);
        assertEq(collected, accruedToken, "protocol fees still collectable");
        assertEq(U.hook.tokenReserve(), U.token.balanceOf(address(U.manager)), "ledger unaffected by collection");
    }

    // ---------- buys ----------

    function test_buysAreFree_exactIn() public {
        uint256 ethIn = 3 ether;
        BalanceDelta dt = _buyExactIn(T, alice, ethIn);
        uint256 treasuryBefore = TREASURY.balance;
        uint256 supplyBefore = U.token.totalSupply();
        uint256 tokBefore = U.token.balanceOf(alice);
        BalanceDelta du = _buyExactIn(U, alice, ethIn);
        assertEq(int256(du.amount0()), int256(dt.amount0()), "ETH paid identical to control");
        assertEq(int256(du.amount1()), int256(dt.amount1()), "tokens received identical to control");
        assertEq(int256(du.amount0()), -int256(ethIn), "exact input consumed");
        assertEq(U.token.balanceOf(alice) - tokBefore, uint256(uint128(du.amount1())), "user got the full output");
        assertEq(TREASURY.balance, treasuryBefore, "treasury untouched by a buy");
        assertEq(U.token.totalSupply(), supplyBefore, "nothing burned on a buy");
        assertEq(U.hook.pendingETH() + U.hook.pendingToken(), 0, "no claims accrued on a buy");
    }

    function test_buysAreFree_exactOut() public {
        uint256 tokensOut = 4_000 ether;
        BalanceDelta dt = _buyExactOut(T, alice, tokensOut, 100 ether);
        uint256 treasuryBefore = TREASURY.balance;
        uint256 ethBefore = alice.balance;
        BalanceDelta du = _buyExactOut(U, alice, tokensOut, 100 ether);
        assertEq(int256(du.amount0()), int256(dt.amount0()), "ETH paid identical to control");
        assertEq(int256(du.amount1()), int256(tokensOut), "exact output delivered");
        assertEq(ethBefore - alice.balance, uint256(uint128(-du.amount0())), "router refunded the rest");
        assertEq(TREASURY.balance, treasuryBefore, "treasury untouched by a buy");
        assertEq(U.token.totalSupply(), SUPPLY, "nothing burned on a buy");
    }

    // ---------- sells: exact fee per bracket ----------

    function test_sellExactIn_feePerBracket() public {
        uint256[7] memory sizes = [
            _atPercent(R, 1) - 1, // 0.99..% -> free
            _atPercent(R, 1), // exactly 1% -> 0.5%
            _atPercent(R, 3) - 1, // just under 3% -> 0.5%
            _atPercent(R, 3), // exactly 3% -> 1%
            _atPercent(R, 5) - 1, // just under 5% -> 1%
            _atPercent(R, 5), // exactly 5% -> 2%
            R / 8 // 12.5% -> 2% (cap)
        ];
        uint256[7] memory expectedPpm = [uint256(0), 5_000, 5_000, 10_000, 10_000, 20_000, 20_000];
        for (uint256 i = 0; i < sizes.length; i++) {
            address user = _user(i);
            uint256 s = sizes[i];
            assertEq(_expectedPpm(s, R), expectedPpm[i], "test's own schedule disagrees with the brief");
            BalanceDelta dt = _sellExactIn(T, user, s);
            uint256 gross = uint256(uint128(dt.amount0()));
            uint256 treasuryBefore = TREASURY.balance;
            uint256 ethBefore = user.balance;
            uint256 supplyBefore = U.token.totalSupply();
            BalanceDelta du = _sellExactIn(U, user, s);
            uint256 fee = TREASURY.balance - treasuryBefore;
            string memory tag = string.concat("bracket sample #", _str(i));
            assertEq(fee, _ceilFee(gross, expectedPpm[i]), string.concat(tag, ": treasury fee"));
            assertEq(user.balance - ethBefore, gross - fee, string.concat(tag, ": user receives gross minus fee"));
            assertEq(int256(du.amount0()), int256(gross - fee), string.concat(tag, ": settled delta"));
            assertEq(int256(du.amount1()), -int256(s), string.concat(tag, ": exact input consumed"));
            assertEq(uint256(U.hook.feePpm(s, R)), expectedPpm[i], string.concat(tag, ": quoted ppm"));
            assertEq(U.token.totalSupply(), supplyBefore, string.concat(tag, ": exact-in burns nothing"));
            assertEq(U.hook.pendingETH(), 0, string.concat(tag, ": paid directly, no claim"));
            assertEq(U.hook.laggedTokenReserve(), R, string.concat(tag, ": snapshot fixed"));
            assertEq(address(U.hook).balance, 0, string.concat(tag, ": hook holds no ETH"));
        }
        assertEq(U.token.totalSupply(), SUPPLY, "no token-side fee on exact-input sells");
    }

    function test_sellExactOut_feePerBracket() public {
        // ETH outputs chosen so the token input lands in each bracket; the bracket is asserted from the actual input.
        uint256[5] memory ethOuts = [
            _tokensToEth(U, R / 200), // ~0.5%
            _tokensToEth(U, R * 3 / 200), // ~1.5%
            _tokensToEth(U, R * 4 / 100), // ~4%
            _tokensToEth(U, R * 7 / 100), // ~7%
            _tokensToEth(U, R / 1000) // ~0.1%
        ];
        bool[4] memory seen;
        uint256 totalFee;
        for (uint256 i = 0; i < ethOuts.length; i++) {
            address user = _user(i);
            uint256 e = ethOuts[i];
            BalanceDelta dt = _sellExactOut(T, user, e);
            uint256 sold = uint256(uint128(-dt.amount1()));
            uint256 ppm = _expectedPpm(sold, R);
            seen[ppm / 5_000 == 4 ? 3 : ppm / 5_000] = true;
            uint256 treasuryBefore = TREASURY.balance;
            uint256 supplyBefore = U.token.totalSupply();
            uint256 tokBefore = U.token.balanceOf(user);
            uint256 ethBefore = user.balance;
            BalanceDelta du = _sellExactOut(U, user, e);
            string memory tag = string.concat("exact-out sample #", _str(i));
            uint256 paid = uint256(uint128(-du.amount1()));
            uint256 fee = paid - sold;
            assertEq(fee, _ceilFee(sold, ppm), string.concat(tag, ": token fee"));
            assertEq(int256(du.amount0()), int256(e), string.concat(tag, ": exact ETH output unchanged"));
            assertEq(int256(du.amount0()), int256(dt.amount0()), string.concat(tag, ": same ETH as control"));
            assertEq(user.balance - ethBefore, e, string.concat(tag, ": user got the ETH"));
            assertEq(tokBefore - U.token.balanceOf(user), paid, string.concat(tag, ": user paid input + fee"));
            // the IMDO fee is booked as an ERC-6909 claim during the swap and burned by harvest()
            totalFee += fee;
            assertEq(U.token.totalSupply(), supplyBefore, string.concat(tag, ": nothing leaves the manager mid-swap"));
            _assertTokenFeeClaimed(totalFee, tag);
            assertEq(TREASURY.balance, treasuryBefore, string.concat(tag, ": no ETH fee on exact-out"));
        }
        assertTrue(seen[0] && seen[1] && seen[2] && seen[3], "samples must cover all four brackets");
        uint256 supply = U.token.totalSupply();
        vm.prank(address(0xDEAD));
        U.hook.harvest();
        assertEq(supply - U.token.totalSupply(), totalFee, "harvest burns exactly the accrued token fees");
        assertEq(U.hook.pendingToken(), 0, "claim settled");
        assertEq(U.manager.balanceOf(address(U.hook), uint160(address(U.token))), 0, "claim burned");
        assertEq(U.token.balanceOf(address(U.hook)) + U.token.balanceOf(TREASURY), 0, "burned, not kept or forwarded");
    }

    function _assertTokenFeeClaimed(uint256 accrued, string memory tag) internal view {
        assertEq(U.hook.pendingToken(), accrued, string.concat(tag, ": fee accrued as a claim"));
        assertEq(
            U.manager.balanceOf(address(U.hook), uint160(address(U.token))),
            accrued,
            string.concat(tag, ": claim backed by ERC-6909")
        );
        assertEq(U.token.balanceOf(address(U.hook)), 0, string.concat(tag, ": hook holds no tokens"));
    }

    function test_feeIsHardCappedAtTwoPercent() public view {
        assertEq(uint256(U.hook.feePpm(type(uint128).max, 1)), 20_000, "cap");
        assertEq(uint256(U.hook.feePpm(1, 0)), 20_000, "no snapshot -> cap, never above");
        assertEq(uint256(U.hook.feePpm(0, 0)), 0, "nothing sold -> nothing");
        assertEq(uint256(U.hook.feePpm(R * 1000, R)), 20_000, "huge sells are capped");
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_feePpm_matchesScheduleAndCap(uint256 sold, uint256 reserve) public view {
        sold = _bound(sold, 0, type(uint120).max);
        reserve = _bound(reserve, 0, type(uint120).max);
        uint256 ppm = U.hook.feePpm(sold, reserve);
        assertLe(ppm, 20_000, "above cap");
        assertEq(ppm, _expectedPpm(sold, reserve), "schedule");
        if (sold < type(uint120).max) assertLe(ppm, U.hook.feePpm(sold + 1, reserve), "not monotone in size");
        if (reserve > 0) assertGe(ppm, U.hook.feePpm(sold, reserve + 1), "not monotone in reserve");
    }

    /// forge-config: default.fuzz.runs = 48
    function testFuzz_sellExactIn_feeMatchesBracket(uint256 tokens) public {
        tokens = _bound(tokens, 1, R / 12);
        BalanceDelta dt = _sellExactIn(T, alice, tokens);
        uint256 gross = uint256(uint128(dt.amount0()));
        uint256 treasuryBefore = TREASURY.balance;
        BalanceDelta du = _sellExactIn(U, alice, tokens);
        uint256 fee = TREASURY.balance - treasuryBefore;
        assertEq(fee, _ceilFee(gross, _expectedPpm(tokens, R)), "fee");
        assertEq(int256(du.amount0()), int256(gross - fee), "net output");
        assertLe(fee, _ceilFee(gross, 20_000), "cap");
    }

    /// forge-config: default.fuzz.runs = 48
    function testFuzz_sellExactOut_feeMatchesBracket(uint256 ethOut) public {
        ethOut = _bound(ethOut, 1e9, _tokensToEth(U, R / 12));
        BalanceDelta dt = _sellExactOut(T, alice, ethOut);
        uint256 sold = uint256(uint128(-dt.amount1()));
        uint256 supplyBefore = U.token.totalSupply();
        BalanceDelta du = _sellExactOut(U, alice, ethOut);
        uint256 fee = uint256(uint128(-du.amount1())) - sold;
        assertEq(fee, _ceilFee(sold, _expectedPpm(sold, R)), "token fee");
        assertEq(int256(du.amount0()), int256(ethOut), "exact output");
        assertEq(U.token.totalSupply(), supplyBefore, "claimed, not burned mid-swap");
        assertEq(U.hook.pendingToken(), fee, "accrued as a claim");
        U.hook.harvest();
        assertEq(supplyBefore - U.token.totalSupply(), fee, "burned by harvest");
        assertEq(U.hook.pendingToken(), 0, "claim settled");
    }

    // ---------- anti-splitting ----------
    //
    // Multi-leg scenarios run inside ONE external self-call: all legs share a transaction and a tx.origin, exactly
    // as a splitting bot would do it. Whether the harness also ends the transaction after each top-level call
    // differs between forge versions (see TransientProbe), so every scenario uses an origin that has not sold on the
    // hooked pool earlier in the same test, and no expectation depends on the ledger having been cleared.

    /// @dev `legs` exact-input sells of `leg` tokens by `user` in one transaction. Returns per-leg hook fees,
    ///      per-leg gross ETH output (from the control pool) and the hook's running counter at the end.
    function runSplitExactIn(address user, uint256 leg, uint256 legs)
        external
        returns (uint256[] memory fees, uint256[] memory gross, uint256 cumulative)
    {
        require(msg.sender == address(this));
        fees = new uint256[](legs);
        gross = new uint256[](legs);
        _as(user);
        for (uint256 i = 0; i < legs; i++) {
            gross[i] = uint256(uint128(_sellExactIn(T, user, leg).amount0()));
        }
        for (uint256 i = 0; i < legs; i++) {
            uint256 before = TREASURY.balance;
            _sellExactIn(U, user, leg);
            fees[i] = TREASURY.balance - before;
            assertEq(U.hook.cumulativeSold(user), leg * (i + 1), "counter after leg");
        }
        cumulative = U.hook.cumulativeSold(user);
        _done();
    }

    /// @dev Arbitrary exact-input legs by `user` in one transaction. Returns, per leg, the hook fee that reached the
    ///      treasury, the gross ETH output (control pool) and the net ETH the user received, plus the hook's
    ///      per-origin ledger as it stands at the end of the transaction.
    function runLegsExactIn(address user, uint256[] memory sizes)
        external
        returns (uint256[] memory fees, uint256[] memory gross, uint256[] memory net, IMDOFeeHook.Ledger memory ledger)
    {
        require(msg.sender == address(this));
        uint256 n = sizes.length;
        fees = new uint256[](n);
        gross = new uint256[](n);
        net = new uint256[](n);
        _as(user);
        for (uint256 i = 0; i < n; i++) {
            gross[i] = uint256(uint128(_sellExactIn(T, user, sizes[i]).amount0()));
        }
        for (uint256 i = 0; i < n; i++) {
            uint256 before = TREASURY.balance;
            uint256 ethBefore = user.balance;
            _sellExactIn(U, user, sizes[i]);
            fees[i] = TREASURY.balance - before;
            net[i] = user.balance - ethBefore;
        }
        ledger = U.hook.originLedger(user);
        _done();
    }

    /// @dev One exact-input leg followed by one exact-output leg, same transaction. Returns the first leg's gross
    ///      ETH output, the second leg's token fee (claimed for the burn) and token input, and the ledger at the end.
    function runSplitMixed(address user, uint256 leg, uint256 ethLeg)
        external
        returns (uint256 gross1, uint256 tokenFee2, uint256 sold2, IMDOFeeHook.Ledger memory ledger)
    {
        require(msg.sender == address(this));
        _as(user);
        gross1 = uint256(uint128(_sellExactIn(T, user, leg).amount0()));
        sold2 = uint256(uint128(-_sellExactOut(T, user, ethLeg).amount1()));
        _sellExactIn(U, user, leg);
        uint256 pendingBefore = U.hook.pendingToken();
        BalanceDelta u2 = _sellExactOut(U, user, ethLeg);
        tokenFee2 = uint256(uint128(-u2.amount1())) - sold2;
        assertEq(U.hook.pendingToken() - pendingBefore, tokenFee2, "token fee accrued as a claim for the burn");
        assertEq(int256(u2.amount0()), int256(ethLeg), "exact-out leg still delivers exactly the requested ETH");
        ledger = U.hook.originLedger(user);
        _done();
    }

    /// @dev One exact-output leg followed by one exact-input leg, same transaction.
    function runSplitMixedReverse(address user, uint256 ethLeg, uint256 leg)
        external
        returns (uint256 sold1, uint256 gross2, uint256 ethFee2, uint256 burned, IMDOFeeHook.Ledger memory ledger)
    {
        require(msg.sender == address(this));
        _as(user);
        sold1 = uint256(uint128(-_sellExactOut(T, user, ethLeg).amount1()));
        gross2 = uint256(uint128(_sellExactIn(T, user, leg).amount0()));
        uint256 supplyBefore = U.token.totalSupply();
        uint256 treasuryBefore = TREASURY.balance;
        _sellExactOut(U, user, ethLeg);
        assertEq(TREASURY.balance, treasuryBefore, "free exact-out leg pays no ETH");
        _sellExactIn(U, user, leg);
        ethFee2 = TREASURY.balance - treasuryBefore;
        burned = (supplyBefore - U.token.totalSupply()) + U.hook.pendingToken();
        ledger = U.hook.originLedger(user);
        _done();
    }

    /// @dev Two exact-output legs, same transaction. Returns per-leg token input (control) and token fee (claimed).
    function runSplitExactOut(address user, uint256 ethLeg)
        external
        returns (uint256[2] memory sold, uint256[2] memory tokenFee, IMDOFeeHook.Ledger memory ledger)
    {
        require(msg.sender == address(this));
        _as(user);
        for (uint256 i = 0; i < 2; i++) {
            sold[i] = uint256(uint128(-_sellExactOut(T, user, ethLeg).amount1()));
        }
        for (uint256 i = 0; i < 2; i++) {
            uint256 pendingBefore = U.hook.pendingToken();
            BalanceDelta d = _sellExactOut(U, user, ethLeg);
            tokenFee[i] = uint256(uint128(-d.amount1())) - sold[i];
            assertEq(U.hook.pendingToken() - pendingBefore, tokenFee[i], "token fee accrued as a claim for the burn");
        }
        ledger = U.hook.originLedger(user);
        _done();
    }

    /// @dev Two different origins each sell `leg` inside the same transaction (a bundle).
    function runTwoOriginsSameTx(address a, address b, uint256 leg)
        external
        returns (uint256 feeA, uint256 feeB, uint256 soldA, uint256 soldB)
    {
        require(msg.sender == address(this));
        uint256 before = TREASURY.balance;
        _as(a);
        _sellExactIn(U, a, leg);
        _done();
        feeA = TREASURY.balance - before;
        before = TREASURY.balance;
        _as(b);
        _sellExactIn(U, b, leg);
        _done();
        feeB = TREASURY.balance - before;
        soldA = U.hook.cumulativeSold(a);
        soldB = U.hook.cumulativeSold(b);
    }

    /// @dev `whale` sells `big`; then `minnow`, a different account, sells `little` under the SAME tx.origin (a
    ///      bundler or relayer settling two users in one transaction). Returns the second sell's gross output
    ///      (control pool), hook fee and net ETH received, and what the whale's own sell paid.
    function runSharedOrigin(address whale, address minnow, uint256 big, uint256 little)
        external
        returns (uint256 gross, uint256 fee, uint256 net, uint256 whaleFee)
    {
        require(msg.sender == address(this));
        _as(whale);
        _sellExactIn(T, whale, big);
        uint256 before = TREASURY.balance;
        _sellExactIn(U, whale, big);
        whaleFee = TREASURY.balance - before;
        vm.stopPrank();
        vm.startPrank(minnow, whale);
        gross = uint256(uint128(_sellExactIn(T, minnow, little).amount0()));
        before = TREASURY.balance;
        uint256 ethBefore = minnow.balance;
        _sellExactIn(U, minnow, little);
        fee = TREASURY.balance - before;
        net = minnow.balance - ethBefore;
        assertEq(U.hook.cumulativeSold(whale), big + little, "both sells are in the origin's ledger");
        assertEq(U.hook.cumulativeSold(minnow), 0, "the ledger is keyed by tx.origin, not by the seller");
        _done();
    }

    /// @dev The per-origin ledger lives in transient storage only: nothing is ever written to the hook's persistent
    ///      storage for it (checked with vm.load under every harness), and where the harness ends a transaction after
    ///      each top-level call the getters read zero again.
    function _assertLedgerIsTransient(address origin) internal {
        bytes32 base = keccak256(abi.encode(keccak256("IMDO.sold.by.origin"), origin));
        for (uint256 i = 0; i < 5; i++) {
            assertEq(
                uint256(vm.load(address(U.hook), bytes32(uint256(base) + i))), 0, "ledger written to persistent storage"
            );
        }
        if (_topLevelCallsAreTransactions()) {
            assertEq(U.hook.cumulativeSold(origin), 0, "counter is transient: gone once the transaction ends");
            assertEq(_ledgerSum(U.hook.originLedger(origin)), 0, "ledger gone");
        }
    }

    /// @dev Checks an exact-input run by an origin that had sold nothing before it, leg by leg:
    ///      - the fee is exactly the README's billing rule (schedule on the cumulative size, shortfall carried,
    ///        each leg bounded by 2% of its own output);
    ///      - no leg pays more than 2% of its own gross output, and the seller receives gross minus that fee;
    ///      - every leg pays at least its own output at the bracket the cumulative size has reached;
    ///      - the running total never exceeds the schedule on everything sold so far.
    function _checkLegs(
        uint256[] memory sizes,
        uint256[] memory fees,
        uint256[] memory gross,
        uint256[] memory net,
        IMDOFeeHook.Ledger memory l
    ) internal view returns (uint256 total, uint256 sumGross) {
        IMDOFeeHook.Ledger memory m;
        for (uint256 i = 0; i < sizes.length; i++) {
            string memory tag = string.concat("leg #", _str(i));
            assertEq(fees[i], _billLeg(m, true, sizes[i], gross[i], R), string.concat(tag, ": billing rule"));
            assertLe(fees[i], _ceilFee(gross[i], 20_000), string.concat(tag, ": above 2% of its own output"));
            assertEq(net[i], gross[i] - fees[i], string.concat(tag, ": seller receives gross minus this leg's fee"));
            uint256 ppm = _expectedPpm(m.sold, R);
            assertGe(fees[i] + 1, gross[i] * ppm / PPM, string.concat(tag, ": below its own cumulative bracket"));
            total += fees[i];
            sumGross += gross[i];
            assertLe(total, _ceilFee(sumGross, ppm), string.concat(tag, ": above the schedule on the total"));
        }
        assertEq(l.sold, m.sold, "ledger: everything sold");
        assertEq(l.ethBasis, sumGross, "ledger: gross ETH of the exact-input legs");
        assertEq(l.ethPaid, total, "ledger: ETH collected");
        assertEq(l.tokenBasis + l.tokenPaid, 0, "ledger: no token side on exact-input legs");
    }

    function test_splitSells_sameTx_secondLegRepricesTheFirst() public {
        uint256 leg = R * 6 / 1000; // 0.6% each; two legs cross 1%
        (uint256[] memory fees, uint256[] memory gross, uint256[] memory net, IMDOFeeHook.Ledger memory l) =
            this.runLegsExactIn(alice, _same(leg, 2));
        assertEq(fees[0], 0, "first 0.6% leg is under 1%: free");
        assertEq(net[0], gross[0], "first leg paid out in full");
        // cumulative 1.2% is in the 0.5% bracket: the second leg pays 0.5% of BOTH legs' gross output
        assertEq(fees[1], _ceilFee(gross[0] + gross[1], 5_000), "second leg bills the cumulative size");
        assertGt(fees[1], _ceilFee(gross[1], 5_000), "which is more than 0.5% of the second leg alone");
        assertEq(net[1], gross[1] - fees[1], "second leg paid out gross minus the fee");
        assertEq(l.sold, 2 * leg, "ledger: everything sold");
        assertEq(l.ethBasis, gross[0] + gross[1], "ledger: gross ETH of both exact-input legs");
        assertEq(l.ethPaid, fees[1], "ledger: ETH collected");
        assertEq(l.tokenBasis + l.tokenPaid, 0, "ledger: no token side on exact-input legs");
        _assertLedgerIsTransient(alice);

        // a different origin selling the same 0.6% in its own transaction is free
        uint256 before = TREASURY.balance;
        _sellExactIn(U, bob, leg);
        assertEq(TREASURY.balance, before, "separate origin is sized on its own");
    }

    function test_splitSells_threeSmallLegsCannotStayFree() public {
        uint256 leg = R * 4 / 1000; // 0.4% each; third leg crosses 1%
        (uint256[] memory fees, uint256[] memory gross,,) = this.runLegsExactIn(carol, _same(leg, 3));
        assertEq(fees[0] + fees[1], 0, "0.8% cumulative is still free");
        assertEq(fees[2], _ceilFee(gross[0] + gross[1] + gross[2], 5_000), "third leg bills all three at 0.5%");
    }

    function test_splitSells_manyLegsEscalateThroughEveryBracket() public {
        uint256 leg = R * 8 / 1000; // 0.8% each: cumulative 0.8, 1.6, 2.4, 3.2, 4.0, 4.8, 5.6 %
        (uint256[] memory fees, uint256[] memory gross, uint256[] memory net, IMDOFeeHook.Ledger memory l) =
            this.runLegsExactIn(alice, _same(leg, 7));
        uint256[7] memory ppm = [uint256(0), 5_000, 5_000, 10_000, 10_000, 10_000, 20_000];
        for (uint256 i = 0; i < 7; i++) {
            assertEq(_expectedPpm(leg * (i + 1), R), ppm[i], "test schedule");
        }
        _checkLegs(_same(leg, 7), fees, gross, net, l);
        assertEq(fees[0], 0, "only the first 0.8% is free");
        // leg #1 lifts the total into the 0.5% bracket and reprices leg #0 as well: 0.5% of both outputs
        assertEq(fees[1], _ceilFee(gross[0] + gross[1], 5_000), "leg #1 repriced leg #0");
        assertGt(fees[1], _ceilFee(gross[1], 5_000), "which is more than its own share");
        // a leg inside a bracket pays just its own share
        assertEq(fees[2], _ceilFee(sumGrossUpTo(gross, 2), 5_000) - _ceilFee(sumGrossUpTo(gross, 1), 5_000), "leg #2");
        // leg #3 lifts the total to 1%: repricing legs #0..#2 would take 2.5% of its output, so it pays its 2% cap
        assertEq(fees[3], _ceilFee(gross[3], 20_000), "leg #3 pays exactly its per-swap cap");
        assertLt(fees[0] + fees[1] + fees[2] + fees[3], _ceilFee(sumGrossUpTo(gross, 3), 10_000), "shortfall carried");
        // leg #4 stays in the 1% bracket and collects the carried shortfall: the origin has caught up with the schedule
        assertEq(
            fees[0] + fees[1] + fees[2] + fees[3] + fees[4],
            _ceilFee(sumGrossUpTo(gross, 4), 10_000),
            "leg #4 collects the carried shortfall"
        );
        assertEq(fees[5], _ceilFee(sumGrossUpTo(gross, 5), 10_000) - _ceilFee(sumGrossUpTo(gross, 4), 10_000), "leg #5");
        // leg #6 lifts the total to 2%: again bounded by 2% of its own output
        assertEq(fees[6], _ceilFee(gross[6], 20_000), "leg #6 pays exactly its per-swap cap");
    }

    function sumGrossUpTo(uint256[] memory gross, uint256 last) internal pure returns (uint256 s) {
        for (uint256 i = 0; i <= last; i++) {
            s += gross[i];
        }
    }

    /// @dev A split never pays MORE than one sell of the same total, and every leg pays at least its own output at
    ///      the bracket the cumulative size has reached. It can pay LESS than the single sell: the per-swap cap stops
    ///      a later leg from collecting the full repricing of the earlier ones (reported in .imd-findings.json; the
    ///      README documents it as the price of never charging a swap more than 2% of itself).
    function test_splitSells_neverPayMoreThanOneSellOfTheSameTotal() public {
        // A third, identical hooked universe takes the single sell, so both start from the same pool state.
        _build(V, true, address(0xFEE3), TICK_LOWER, TICK_UPPER, SEED_ETH, SEED_TOKENS);
        _fund(V, bob, 60_000 ether, 1_000 ether);
        vm.roll(block.number + 1);
        assertEq(V.hook.tokenReserve(), R, "same seed, same reserve");
        uint256 total = _atPercent(R, 5); // one 5% sell: 2% bracket
        uint256 treasuryBefore = TREASURY.balance;
        BalanceDelta single = _sellExactIn(V, bob, total);
        uint256 singleFee = TREASURY.balance - treasuryBefore;
        uint256 singleGross = uint256(uint128(single.amount0())) + singleFee;
        assertEq(singleFee, _ceilFee(singleGross, 20_000), "single sell pays 2% of its gross output");

        // the same total as 2.5% + 2.5%, as 0.99% + 4.01%, and as five 1% legs
        uint256[] memory a = new uint256[](2);
        a[0] = total / 2;
        a[1] = total - a[0];
        uint256[] memory b = new uint256[](2);
        b[0] = _atPercent(R, 1) - 1;
        b[1] = total - b[0];
        uint256[] memory c = _same(total / 5, 5);
        c[4] = total - 4 * (total / 5);
        uint256[3] memory totals = [_runAndSum(alice, a), _runAndSum(carol, b), _runAndSum(dave, c)];
        for (uint256 i = 0; i < 3; i++) {
            // the pool's own per-swap rounding moves the summed gross output by a few wei
            assertLe(totals[i], singleFee + 16, string.concat("split #", _str(i), " pays more than the single sell"));
            assertGt(totals[i], 0, string.concat("split #", _str(i), " is not free"));
        }
    }

    /// @dev Runs `sizes` as one transaction on a fresh copy of the pool state and returns the total fee paid; the
    ///      hooked and control pools are rebuilt first so every variant starts from the same reserve and price.
    function _runAndSum(address user, uint256[] memory sizes) internal returns (uint256 total) {
        _build(U, true, feeRecipientU, TICK_LOWER, TICK_UPPER, SEED_ETH, SEED_TOKENS);
        _build(T, false, feeRecipientT, TICK_LOWER, TICK_UPPER, SEED_ETH, SEED_TOKENS);
        _fund(U, user, 60_000 ether, 1_000 ether);
        _fund(T, user, 60_000 ether, 1_000 ether);
        vm.roll(block.number + 1);
        assertEq(U.hook.tokenReserve(), R, "rebuilt pool has the same reserve");
        (uint256[] memory fees, uint256[] memory gross, uint256[] memory net, IMDOFeeHook.Ledger memory l) =
            this.runLegsExactIn(user, sizes);
        (total,) = _checkLegs(sizes, fees, gross, net, l);
    }

    function test_splitSells_exactOutLegCollectsTheEarlierExactInLegsShortfallInTokens() public {
        uint256 leg = R * 6 / 1000; // 0.6% exact-in (free alone) ...
        uint256 ethLeg = _tokensToEth(U, leg); // ... then ~0.6% exact-out: cumulative ~1.2% -> 0.5%
        (uint256 gross1, uint256 tokenFee2, uint256 sold2, IMDOFeeHook.Ledger memory l) =
            this.runSplitMixed(alice, leg, ethLeg);
        assertEq(_expectedPpm(leg + sold2, R), 5_000, "cumulative lands in the 0.5% bracket");
        assertEq(l.sold, leg + sold2, "exact-out input accumulates too");
        // the exact-out leg can only charge IMDO: its own 0.5% in IMDO, plus the first leg's 0.5% of ETH converted to
        // IMDO at this leg's own realized price (sold2 IMDO per ethLeg wei), rounded up
        uint256 tokenDue = _ceilFee(sold2, 5_000);
        uint256 ethDue = _ceilFee(gross1, 5_000);
        uint256 converted = _ceilDiv(ethDue * sold2, ethLeg);
        assertEq(tokenFee2, tokenDue + converted, "second (exact-out) leg collects both shortfalls in IMDO");
        assertGt(converted, 0, "the conversion is live");
        assertEq(l.tokenPaid, tokenDue, "ledger: token side settled");
        assertEq(l.ethPaid, ethDue, "ledger: ETH side settled (in IMDO)");
        assertEq(l.ethBasis, gross1, "ledger: ETH basis is the exact-in leg's gross output");
        assertEq(l.tokenBasis, sold2, "ledger: token basis is the exact-out leg's input");
        assertEq(TREASURY.balance, 0, "no ETH moved in this transaction");
    }

    function test_splitSells_exactInLegCollectsTheEarlierExactOutLegsShortfallInEth() public {
        uint256 leg = R * 6 / 1000;
        uint256 ethLeg = _tokensToEth(U, leg); // ~0.6% exact-out (free alone), then 0.6% exact-in
        (uint256 sold1, uint256 gross2, uint256 ethFee2, uint256 burned, IMDOFeeHook.Ledger memory l) =
            this.runSplitMixedReverse(alice, ethLeg, leg);
        assertEq(_expectedPpm(sold1 + leg, R), 5_000, "cumulative lands in the 0.5% bracket");
        uint256 ethDue = _ceilFee(gross2, 5_000);
        uint256 tokenDue = _ceilFee(sold1, 5_000);
        uint256 converted = _ceilDiv(tokenDue * gross2, leg);
        assertEq(ethFee2, ethDue + converted, "exact-in leg collects both shortfalls in ETH");
        assertEq(burned, 0, "nothing burned or claimed in IMDO: the token shortfall was paid in ETH instead");
        assertEq(l.ethPaid, ethDue, "ledger: ETH side settled");
        assertEq(l.tokenPaid, tokenDue, "ledger: token side settled (in ETH)");
        assertEq(U.token.balanceOf(TREASURY), 0, "treasury gets ETH only");
        assertLe(ethFee2, gross2, "a leg never charges more than its own output");
    }

    function test_splitSells_twoExactOutLegsBilledCumulatively() public {
        uint256 ethLeg = _tokensToEth(U, R * 6 / 1000);
        (uint256[2] memory sold, uint256[2] memory tokenFee, IMDOFeeHook.Ledger memory l) =
            this.runSplitExactOut(alice, ethLeg);
        assertEq(_expectedPpm(sold[0], R), 0, "first leg alone is free");
        assertEq(_expectedPpm(sold[0] + sold[1], R), 5_000, "together they are in the 0.5% bracket");
        assertEq(tokenFee[0], 0, "first exact-out leg free");
        assertEq(tokenFee[1], _ceilFee(sold[0] + sold[1], 5_000), "second leg bills 0.5% of both legs' input");
        assertEq(l.tokenBasis, sold[0] + sold[1], "ledger basis");
        assertEq(l.tokenPaid, tokenFee[1], "ledger paid");
        assertEq(l.ethBasis + l.ethPaid, 0, "no ETH side");
    }

    function test_splitSells_differentOriginsInOneTransactionAreSeparate() public {
        uint256 leg = R * 6 / 1000; // 0.6% each: free for each origin, 1.2% if they were pooled
        (uint256 feeA, uint256 feeB, uint256 soldA, uint256 soldB) = this.runTwoOriginsSameTx(alice, bob, leg);
        assertEq(feeA + feeB, 0, "each origin is sized on its own volume");
        assertEq(soldA, leg, "alice's counter");
        assertEq(soldB, leg, "bob's counter");
    }

    function test_splitSells_dustLegPaysAtMostItsCapAndTheNextLegCollectsTheRemainder() public {
        uint256[] memory sizes = new uint256[](3);
        sizes[0] = _atPercent(R, 1) - 1; // one wei under 1%: free alone
        sizes[1] = 1e12; // dust that lifts the running total to 1%: owes 0.5% of ~2 ETH, outputs ~1e9 wei
        sizes[2] = R * 6 / 1000; // 0.6%: cumulative 1.6%, still 0.5%
        (uint256[] memory fees, uint256[] memory gross, uint256[] memory net, IMDOFeeHook.Ledger memory l) =
            this.runLegsExactIn(alice, sizes);
        _checkLegs(sizes, fees, gross, net, l);
        assertEq(fees[0], 0, "prefix is free");
        uint256 owedAfterDust = _ceilFee(gross[0] + gross[1], 5_000);
        assertGt(owedAfterDust, gross[1], "the dust leg could not cover what is owed even with its whole output");
        assertEq(fees[1], _ceilFee(gross[1], 20_000), "dust leg pays 2% of its own output, no more");
        assertEq(net[1], gross[1] - fees[1], "and its seller keeps the other 98%");
        uint256 owedAfterAll = _ceilFee(gross[0] + gross[1] + gross[2], 5_000);
        assertEq(fees[2], owedAfterAll - fees[1], "next leg collects the carried remainder plus its own share");
        assertEq(fees[0] + fees[1] + fees[2], owedAfterAll, "total is the schedule on everything sold");
        assertEq(l.ethPaid, owedAfterAll, "ledger settled");
    }

    function test_splitSells_dustLegWithoutASuccessor_neverCheaperThanThePrefixAlone() public {
        // Just under 3% (0.5% bracket) then dust lifting to 3% (1% bracket) with nothing after it. The dust leg is
        // bounded by 2% of its own output, so it cannot cover the repricing: what IS collected is never less than
        // the prefix alone would pay and never more than the schedule on the total. (README: per-swap cap.)
        uint256[] memory sizes = new uint256[](2);
        sizes[0] = _atPercent(R, 3) - 1;
        sizes[1] = 1e12;
        (uint256[] memory fees, uint256[] memory gross, uint256[] memory net, IMDOFeeHook.Ledger memory l) =
            this.runLegsExactIn(alice, sizes);
        (uint256 total,) = _checkLegs(sizes, fees, gross, net, l);
        assertEq(fees[0], _ceilFee(gross[0], 5_000), "prefix pays its own bracket");
        assertEq(fees[1], _ceilFee(gross[1], 20_000), "dust leg pays 2% of its own output");
        assertGe(total, _ceilFee(gross[0], 5_000), "never below the prefix alone");
        assertLe(total, _ceilFee(gross[0] + gross[1], 10_000), "never above the schedule on the total");
        assertEq(l.ethPaid, total, "ledger records exactly what was collected");
        assertEq(_ceilFee(l.ethBasis, 10_000) - l.ethPaid, _ceilFee(gross[0] + gross[1], 10_000) - total, "shortfall");
        _assertLedgerIsTransient(alice);
    }

    function test_splitSells_sharedOrigin_laterSellersLegNeverPaysMoreThanTwoPercentOfItself() public {
        // The whale's 4.99% sell pays 1%. A different seller's small sell, settled under the same tx.origin, lifts
        // the cumulative size to 5%: the origin now owes another 1% of the whale's output, far more than the small
        // sell is worth. The small sell is billed at the cumulative bracket but bounded by 2% of its own output.
        uint256 big = _atPercent(R, 5) - 1 ether;
        uint256 little = 2 ether;
        (uint256 gross, uint256 fee, uint256 net, uint256 whaleFee) = this.runSharedOrigin(alice, bob, big, little);
        assertEq(_expectedPpm(big, R), 10_000, "whale alone: 1% bracket");
        assertEq(_expectedPpm(big + little, R), 20_000, "together: 2% bracket");
        assertGt(whaleFee, 0, "whale paid its own bracket");
        assertGt(whaleFee, gross, "the repricing owed exceeds the small sell's whole output");
        assertEq(fee, _ceilFee(gross, 20_000), "small sell pays exactly 2% of its own output");
        assertEq(net, gross - fee, "and its seller receives the other 98%");
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_splitSells_threeLegsFollowTheBillingRuleAndItsBounds(uint256 a, uint256 b, uint256 c) public {
        // from dust to 3% of the reserve per leg: free legs, repricing legs, capped legs and carried shortfalls
        uint256[] memory sizes = new uint256[](3);
        sizes[0] = _bound(a, 1e12, R * 3 / 100);
        sizes[1] = _bound(b, 1e12, R * 3 / 100);
        sizes[2] = _bound(c, 1e12, R * 3 / 100);
        (uint256[] memory fees, uint256[] memory gross, uint256[] memory net, IMDOFeeHook.Ledger memory l) =
            this.runLegsExactIn(alice, sizes);
        _checkLegs(sizes, fees, gross, net, l);
        assertEq(address(U.hook).balance + U.token.balanceOf(address(U.hook)), 0, "hook holds nothing");
        assertEq(U.hook.pendingETH(), 0, "paid directly");
    }

    function test_cumulativeSoldIsVisibleWithinTheTransactionAndGoneAfter() public {
        uint256 leg = R * 6 / 1000;
        (uint256[] memory fees,, uint256 cumulative) = this.runSplitExactIn(alice, leg, 1);
        assertEq(fees[0], 0, "0.6% alone is free");
        assertEq(cumulative, leg, "visible within the transaction");
        _assertLedgerIsTransient(alice);
        uint256 before = TREASURY.balance;
        if (_topLevelCallsAreTransactions()) {
            _sellExactIn(U, alice, leg); // a new transaction: sized afresh
            assertEq(TREASURY.balance, before, "new transaction, 0.6% is free again");
        }
        _sellExactIn(U, bob, leg); // another origin never inherits alice's volume
        assertEq(TREASURY.balance, before, "separate origin, 0.6% is free");
    }

    // ---------- anti-manipulation ----------

    /// @dev In one transaction: inflate the pool's token inventory (`mode` 0: token-only liquidity far below the
    ///      price, 1: donation, 2: a buy that drains tokens instead), then sell `s`. Returns the control gross,
    ///      the hook fee, and the snapshot/ledger the hook saw at the moment of the sell.
    function runInflateAndSell(address user, uint256 extra, uint256 s, uint8 mode)
        external
        returns (uint256 gross, uint256 fee, uint256 snapshot, uint256 ledger)
    {
        require(msg.sender == address(this));
        uint128 liq = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(-887_220), TickMath.getSqrtPriceAtTick(INIT_TICK - 600), extra
        );
        _as(user);
        if (mode == 0) _addLiquidity(T, user, -887_220, INIT_TICK - 600, int256(uint256(liq)), 0);
        if (mode == 1) _donate(T, user, 0, extra);
        if (mode == 2) _buyExactIn(T, user, 20 ether);
        gross = uint256(uint128(_sellExactIn(T, user, s).amount0()));

        if (mode == 0) _addLiquidity(U, user, -887_220, INIT_TICK - 600, int256(uint256(liq)), 0);
        if (mode == 1) _donate(U, user, 0, extra);
        if (mode == 2) _buyExactIn(U, user, 20 ether);
        snapshot = U.hook.laggedTokenReserve();
        ledger = U.hook.tokenReserve();
        uint256 before = TREASURY.balance;
        _sellExactIn(U, user, s);
        fee = TREASURY.balance - before;
        _done();
    }

    function test_sameTxLiquidityInflation_doesNotLowerBracket() public {
        uint256 s = _atPercent(R, 4); // 4% of last block's reserve -> 1% bracket
        _fund(U, mallory, 2 * R + s, 0);
        _fund(T, mallory, 2 * R + s, 0);
        (uint256 gross, uint256 fee, uint256 snapshot, uint256 ledger) = this.runInflateAndSell(mallory, 2 * R, s, 0);
        assertGt(ledger, 3 * R - s, "ledger saw the inflation");
        assertEq(snapshot, R, "snapshot did not");
        assertEq(fee, _ceilFee(gross, 10_000), "sized against last block's reserve: 1% bracket, not free");
        assertLt(_expectedPpm(s, ledger), 10_000, "the inflated reserve would have put it in a lower bracket");

        // The lag is exactly one block: next block the (still inflated) ledger becomes the snapshot.
        uint256 inflated = U.hook.tokenReserve();
        vm.roll(block.number + 1);
        BalanceDelta dt2 = _sellExactIn(T, bob, s);
        uint256 before = TREASURY.balance;
        _sellExactIn(U, bob, s);
        assertEq(U.hook.laggedTokenReserve(), inflated, "next block uses the previous block's ledger");
        assertEq(
            TREASURY.balance - before,
            _ceilFee(uint256(uint128(dt2.amount0())), _expectedPpm(s, inflated)),
            "next block sized against the new snapshot"
        );
        assertLt(TREASURY.balance - before, fee, "and that bracket is lower, as a one-block lag allows");
    }

    /// @dev In one transaction: withdraw the token-only liquidity parked by `user` earlier, then sell `s`.
    function runWithdrawAndSell(address user, uint128 liq, uint256 s)
        external
        returns (uint256 gross, uint256 fee, uint256 snapshot, uint256 ledger)
    {
        require(msg.sender == address(this));
        _as(user);
        _addLiquidity(T, user, -887_220, INIT_TICK - 600, -int256(uint256(liq)), 0);
        gross = uint256(uint128(_sellExactIn(T, user, s).amount0()));
        _addLiquidity(U, user, -887_220, INIT_TICK - 600, -int256(uint256(liq)), 0);
        snapshot = U.hook.laggedTokenReserve();
        ledger = U.hook.tokenReserve();
        uint256 before = TREASURY.balance;
        _sellExactIn(U, user, s);
        fee = TREASURY.balance - before;
        _done();
    }

    function test_liquidityParkedAcrossABlockAndWithdrawnBeforeSelling_doesNotLowerBracket() public {
        // Park 2R of IMDO as out-of-range liquidity in one block so the next block's snapshot is 3R, then withdraw it
        // and sell 4% of R in the same transaction. Sized against the snapshot alone that sell would be ~1.3%
        // (0.5% bracket); the hook sizes against the lower of the snapshot and the reserve just before the swap.
        uint256 s = _atPercent(R, 4);
        _fund(U, mallory, 2 * R + s, 0);
        _fund(T, mallory, 2 * R + s, 0);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(-887_220), TickMath.getSqrtPriceAtTick(INIT_TICK - 600), 2 * R
        );
        _addLiquidity(T, mallory, -887_220, INIT_TICK - 600, int256(uint256(liq)), 0);
        _addLiquidity(U, mallory, -887_220, INIT_TICK - 600, int256(uint256(liq)), 0);
        uint256 parked = U.hook.tokenReserve();
        assertGt(parked, 3 * R - 1 ether, "inflation is in the ledger");
        vm.roll(block.number + 1);
        (uint256 gross, uint256 fee, uint256 snapshot, uint256 ledger) = this.runWithdrawAndSell(mallory, liq, s);
        assertEq(snapshot, parked, "the snapshot carries the parked liquidity");
        assertLe(ledger, R + 1 ether, "the withdrawal took it out of the ledger again");
        assertEq(_expectedPpm(s, snapshot), 5_000, "against the snapshot alone the sell would sit in the 0.5% bracket");
        assertEq(_expectedPpm(s, ledger), 10_000, "against the reserve it actually trades with: 1% bracket");
        assertEq(fee, _ceilFee(gross, 10_000), "billed at the uninflated bracket");
    }

    function test_sameTxDonation_doesNotLowerBracket() public {
        uint256 s = _atPercent(R, 3); // 3% -> 1% bracket
        _fund(U, mallory, 2 * R + s, 0);
        _fund(T, mallory, 2 * R + s, 0);
        (uint256 gross, uint256 fee, uint256 snapshot, uint256 ledger) = this.runInflateAndSell(mallory, 2 * R, s, 1);
        assertEq(snapshot, R, "donation does not move the snapshot");
        assertGt(ledger, 2 * R, "donation is in the ledger");
        assertEq(fee, _ceilFee(gross, 10_000), "still the 1% bracket");
    }

    function test_sameTxBuyThenSell_doesNotChangeBracket() public {
        // A buy drains tokens from the pool. The snapshot does not move within the block, and the sell is sized
        // against the lower of the two: never a lower bracket than the snapshot gives, possibly a higher one.
        uint256 s = _atPercent(R, 1);
        (uint256 gross, uint256 fee, uint256 snapshot, uint256 ledger) = this.runInflateAndSell(alice, 0, s, 2);
        assertEq(snapshot, R, "snapshot fixed");
        assertLt(ledger, R, "buy drained the ledger");
        assertEq(_expectedPpm(s, ledger), 5_000, "still the 0.5% bracket against the drained reserve");
        assertEq(fee, _ceilFee(gross, 5_000), "1% of the snapshot: 0.5% bracket");

        // just under 1% of the snapshot is free on its own, but not right after a buy drained the reserve
        uint256 under = _atPercent(R, 1) - 1;
        (gross, fee, snapshot, ledger) = this.runInflateAndSell(bob, 0, under, 2);
        assertEq(_expectedPpm(under, snapshot), 0, "free against the snapshot");
        assertEq(_expectedPpm(under, ledger), 5_000, "0.5% bracket against the drained reserve");
        assertEq(fee, _ceilFee(gross, 5_000), "sized against the lower of the two");
    }

    // ---------- factory compatibility ----------

    function _tradeRound(Universe storage u) internal {
        _buyExactIn(u, alice, 5 ether);
        _sellExactIn(u, bob, _atPercent(R, 5));
        _buyExactOut(u, carol, 2_500 ether, 50 ether);
        _sellExactOut(u, alice, 1 ether);
        _sellExactIn(u, carol, R / 500);
        _buyExactIn(u, bob, 1 ether);
    }

    function test_factoryPositionAndPoolState_identicalWithAndWithoutHook() public {
        _tradeRound(T);
        _tradeRound(U);
        assertGt(TREASURY.balance, 0, "the hook charged its own fee on the large sells");
        (uint128 liqU, uint256 fg0U, uint256 fg1U) = IPoolManager(address(U.manager))
            .getPositionInfo(U.key.toId(), address(U.factory), TICK_LOWER, TICK_UPPER, bytes32(0));
        (uint128 liqT, uint256 fg0T, uint256 fg1T) = IPoolManager(address(T.manager))
            .getPositionInfo(T.key.toId(), address(T.factory), TICK_LOWER, TICK_UPPER, bytes32(0));
        assertEq(uint256(liqU), uint256(liqT), "position liquidity identical");
        assertEq(fg0U, fg0T, "fee growth (ETH) identical");
        assertEq(fg1U, fg1T, "fee growth (IMDO) identical");
        _assertGlobalsIdentical();
    }

    function _assertGlobalsIdentical() internal view {
        (uint256 g0U, uint256 g1U) = IPoolManager(address(U.manager)).getFeeGrowthGlobals(U.key.toId());
        (uint256 g0T, uint256 g1T) = IPoolManager(address(T.manager)).getFeeGrowthGlobals(T.key.toId());
        assertEq(g0U, g0T, "global fee growth (ETH) identical");
        assertEq(g1U, g1T, "global fee growth (IMDO) identical");
        (uint160 pU, int24 tickU,,) = IPoolManager(address(U.manager)).getSlot0(U.key.toId());
        (uint160 pT, int24 tickT,,) = IPoolManager(address(T.manager)).getSlot0(T.key.toId());
        assertEq(uint256(pU), uint256(pT), "price identical");
        assertEq(int256(tickU), int256(tickT), "tick identical");
        assertEq(
            IPoolManager(address(U.manager)).getLiquidity(U.key.toId()),
            IPoolManager(address(T.manager)).getLiquidity(T.key.toId()),
            "active liquidity identical"
        );
    }

    function test_factoryFeeCollectionAndDistribution_unaffectedByHook() public {
        _tradeRound(T);
        _tradeRound(U);
        // The factory distributes: collects the position's pool fees and pays its recipient.
        (BalanceDelta cdU, BalanceDelta fU) = U.factory.collectFees(U.key, TICK_LOWER, TICK_UPPER);
        (BalanceDelta cdT, BalanceDelta fT) = T.factory.collectFees(T.key, TICK_LOWER, TICK_UPPER);
        assertTrue(fU.amount0() > 0 && fU.amount1() > 0, "LP fees accrued on both sides");
        assertEq(int256(fU.amount0()), int256(fT.amount0()), "ETH pool fee identical with and without hook");
        assertEq(int256(fU.amount1()), int256(fT.amount1()), "IMDO pool fee identical with and without hook");
        assertEq(BalanceDelta.unwrap(cdU), BalanceDelta.unwrap(cdT), "collection delta identical");
        assertEq(feeRecipientU.balance, feeRecipientT.balance, "recipient's ETH payout identical");
        assertEq(feeRecipientU.balance, uint256(uint128(fU.amount0())), "recipient got the full ETH pool fee");
        assertEq(
            U.token.balanceOf(feeRecipientU), T.token.balanceOf(feeRecipientT), "recipient's IMDO payout identical"
        );
        assertEq(
            U.token.balanceOf(feeRecipientU), uint256(uint128(fU.amount1())), "recipient got the full IMDO pool fee"
        );
        _assertHookTookNothingFromTheFactory();
    }

    function _assertHookTookNothingFromTheFactory() internal view {
        assertEq(U.token.balanceOf(address(U.hook)), 0, "hook holds no IMDO");
        assertEq(address(U.hook).balance, 0, "hook holds no ETH");
        uint256 claims =
            U.manager.balanceOf(address(U.hook), 0) + U.manager.balanceOf(address(U.hook), uint160(address(U.token)));
        assertEq(claims, 0, "no claims");
        assertEq(U.token.balanceOf(TREASURY), 0, "treasury receives ETH only, never IMDO");
        assertGt(TREASURY.balance, 0, "hook fee did reach the treasury");
    }

    function test_factoryWithdrawal_unaffectedByHook() public {
        _tradeRound(T);
        _tradeRound(U);
        (uint128 liqU,,) = IPoolManager(address(U.manager))
            .getPositionInfo(U.key.toId(), address(U.factory), TICK_LOWER, TICK_UPPER, bytes32(0));
        (BalanceDelta rU,) = U.factory.modifyPosition(U.key, TICK_LOWER, TICK_UPPER, -int256(uint256(liqU)) / 2);
        (BalanceDelta rT,) = T.factory.modifyPosition(T.key, TICK_LOWER, TICK_UPPER, -int256(uint256(liqU)) / 2);
        assertEq(BalanceDelta.unwrap(rU), BalanceDelta.unwrap(rT), "withdrawal identical");
        assertTrue(rU.amount0() > 0 && rU.amount1() > 0, "withdrawal paid out");
        assertEq(U.hook.tokenReserve(), U.token.balanceOf(address(U.manager)), "ledger follows the withdrawal");
        // the remaining half can go too; the hook never traps a position
        (uint128 left,,) = IPoolManager(address(U.manager))
            .getPositionInfo(U.key.toId(), address(U.factory), TICK_LOWER, TICK_UPPER, bytes32(0));
        U.factory.modifyPosition(U.key, TICK_LOWER, TICK_UPPER, -int256(uint256(left)));
        (uint128 none,,) = IPoolManager(address(U.manager))
            .getPositionInfo(U.key.toId(), address(U.factory), TICK_LOWER, TICK_UPPER, bytes32(0));
        assertEq(uint256(none), 0, "position fully withdrawn");
    }

    function test_lpFeeGoesToPosition_hookFeeGoesToTreasury() public {
        uint256 s = _atPercent(R, 5);
        BalanceDelta dt = _sellExactIn(T, bob, s);
        uint256 gross = uint256(uint128(dt.amount0()));
        _sellExactIn(U, bob, s);
        assertEq(TREASURY.balance, _ceilFee(gross, 20_000), "hook fee: 2% of gross ETH output, to the treasury");
        (, BalanceDelta f) = U.factory.collectFees(U.key, TICK_LOWER, TICK_UPPER);
        uint256 lpFee = uint256(uint128(f.amount1()));
        assertGe(lpFee, s * (LP_FEE - 1) / PPM, "pool fee: ~0.3% of the sold tokens, to the position");
        assertLe(lpFee, s * LP_FEE / PPM, "pool fee: not more than 0.3%");
        assertEq(int256(f.amount0()), 0, "no ETH pool fee on a token-input sell");
        assertEq(U.token.balanceOf(feeRecipientU), lpFee, "position fees reach the factory's recipient");
        assertEq(U.token.balanceOf(TREASURY), 0, "treasury gets no tokens");
    }

    function test_swarmMerkleDistributor_unaffected() public {
        uint256 a0 = 1_000 ether;
        uint256 a1 = 2_500 ether;
        address c0 = address(0xC0);
        address c1 = address(0xC1);
        bytes32 l0 = keccak256(abi.encodePacked(uint256(0), c0, a0));
        bytes32 l1 = keccak256(abi.encodePacked(uint256(1), c1, a1));
        bytes32 root = l0 < l1 ? keccak256(abi.encodePacked(l0, l1)) : keccak256(abi.encodePacked(l1, l0));
        ModelMerkleDistributor dist = new ModelMerkleDistributor(U.token, root);
        U.factory.transferTokens(address(dist), a0 + a1);
        _tradeRound(U); // trading through the hook in between changes nothing for the distributor
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = l1;
        dist.claim(0, c0, a0, proof);
        assertEq(U.token.balanceOf(c0), a0, "claim 0 paid exactly");
        (bool ok,) = address(dist).call(abi.encodeCall(ModelMerkleDistributor.claim, (0, c0, a0, proof)));
        assertFalse(ok, "double claim rejected");
        proof[0] = l0;
        (ok,) = address(dist).call(abi.encodeCall(ModelMerkleDistributor.claim, (1, c1, a1 + 1, proof)));
        assertFalse(ok, "wrong amount rejected");
        vm.prank(address(0xDEAD));
        dist.claim(1, c1, a1, proof);
        assertEq(U.token.balanceOf(c1), a1, "claim 1 paid exactly, by anyone");
        assertEq(U.token.balanceOf(address(dist)), 0, "distributor fully drained, no tax");
        // claimed tokens can be sold through the hooked pool like any other
        vm.prank(c0);
        U.token.approve(address(U.swapRouter), type(uint256).max);
        _sellExactIn(U, c0, a0);
        assertEq(U.token.balanceOf(c0), 0, "claimant sold through the pool");
    }

    // ---------- sells are never blocked; claims; harvest ----------

    function test_sellNotBlockedWhenTreasuryRejectsEth_claimThenHarvest() public {
        uint256 s = _atPercent(R, 5);
        BalanceDelta dt = _sellExactIn(T, alice, s);
        uint256 fee = _ceilFee(uint256(uint128(dt.amount0())), 20_000);
        vm.etch(TREASURY, REJECT_ALL);
        uint256 ethBefore = alice.balance;
        uint256 treasuryBefore = TREASURY.balance;
        BalanceDelta du = _sellExactIn(U, alice, s);
        assertEq(int256(du.amount0()), int256(uint256(uint128(dt.amount0())) - fee), "sell went through, fee withheld");
        assertEq(alice.balance - ethBefore, uint256(uint128(du.amount0())), "user paid out");
        assertEq(TREASURY.balance, treasuryBefore, "treasury could not take ETH");
        assertEq(U.hook.pendingETH(), fee, "fee accrued as a claim");
        assertEq(U.manager.balanceOf(address(U.hook), 0), fee, "ERC-6909 claim backs it");
        assertEq(address(U.hook).balance, 0, "hook holds no ETH");
        // harvest is permissionless; while the treasury still rejects ETH it leaves the claim alone and never reverts
        vm.prank(address(0xDEAD));
        U.hook.harvest();
        assertEq(U.hook.pendingETH(), fee, "claim untouched");
        assertEq(U.manager.balanceOf(address(U.hook), 0), fee, "claim still backed");
        // once the treasury can receive, anyone can move the accrued claim, and only that
        vm.etch(TREASURY, "");
        uint256 userEth = alice.balance;
        vm.prank(address(0xDEAD));
        U.hook.harvest();
        assertEq(TREASURY.balance, treasuryBefore + fee, "treasury received exactly the accrued fee");
        assertEq(U.hook.pendingETH(), 0, "claim settled");
        assertEq(U.manager.balanceOf(address(U.hook), 0), 0, "claim burned");
        assertEq(alice.balance, userEth, "harvest touched nobody else's funds");
        // a second harvest with nothing pending is a no-op
        U.hook.harvest();
        assertEq(TREASURY.balance, treasuryBefore + fee, "nothing more to harvest");
        // Later sells go straight to the treasury again.
        BalanceDelta dt2 = _sellExactIn(T, bob, s);
        _sellExactIn(U, bob, s);
        assertEq(
            TREASURY.balance, treasuryBefore + fee + _ceilFee(uint256(uint128(dt2.amount0())), 20_000), "direct again"
        );
        assertEq(U.hook.pendingETH(), 0, "no claim when the transfer works");
    }

    function test_harvestCannotBeAbusedToMoveUserClaims() public {
        // Someone minting unrelated ERC-6909 claims to the hook does not make harvest move them.
        uint256 s = _atPercent(R, 5);
        vm.etch(TREASURY, REJECT_ALL);
        _sellExactIn(U, alice, s);
        uint256 fee = U.hook.pendingETH();
        // the swap router can mint claims for a user: bob takes a (free, 0.2%) sell as claims and gifts them to the hook
        vm.prank(bob, bob);
        U.swapRouter
            .swap(
                U.key,
                SwapParams(false, -int256(R / 500), TickMath.MAX_SQRT_PRICE - 1),
                PoolSwapTest.TestSettings(true, false),
                ""
            );
        uint256 bobClaims = U.manager.balanceOf(bob, 0);
        assertGt(bobClaims, 0, "bob holds ETH claims");
        assertEq(U.hook.pendingETH(), fee, "a free sell accrues nothing");
        vm.prank(bob);
        U.manager.transfer(address(U.hook), 0, bobClaims);
        assertEq(U.manager.balanceOf(address(U.hook), 0), fee + bobClaims, "hook holds more claims than it accrued");
        vm.etch(TREASURY, "");
        U.hook.harvest();
        assertEq(TREASURY.balance, fee, "harvest moved only the accrued fee");
        assertEq(U.manager.balanceOf(address(U.hook), 0), bobClaims, "unsolicited claims stay where they were put");
        assertEq(U.hook.pendingETH(), 0, "accrued claim settled");
    }

    function test_sellsNeverBlocked_byRouterWithClaims() public {
        // settlement with ERC-6909 claims instead of tokens, and taking claims instead of ETH, both work
        vm.prank(alice, alice);
        U.swapRouter
            .swap(
                U.key,
                SwapParams(false, -int256(R / 500), TickMath.MAX_SQRT_PRICE - 1),
                PoolSwapTest.TestSettings(true, false),
                ""
            );
        assertGt(U.manager.balanceOf(alice, 0), 0, "ETH taken as claims");
        _buyExactIn(U, alice, 2 ether);
        vm.prank(alice);
        U.manager.setOperator(address(U.swapRouter), true);
        uint256 claims = U.manager.balanceOf(alice, 0);
        vm.prank(alice);
        U.swapRouter
            .swap(
                U.key,
                SwapParams(true, -int256(claims), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, true),
                ""
            );
        assertEq(U.manager.balanceOf(alice, 0), 0, "claims burned to pay for the buy");
        uint256 s = _atPercent(R, 5);
        uint256 before = TREASURY.balance;
        uint256 ethBefore = bob.balance;
        _sellExactIn(U, bob, s);
        uint256 fee = TREASURY.balance - before;
        uint256 gross = bob.balance - ethBefore + fee;
        assertEq(fee, _ceilFee(gross, 20_000), "fee unaffected by claim settlement");
        assertEq(U.hook.pendingETH(), 0, "paid directly");
    }

    function test_hookFeeNeverExceedsOutputAndIsWithinCapForLargeSells() public {
        // a 40% sell: enormous slippage, fee still exactly 2% of the gross output, output still positive
        uint256 s = R * 2 / 5;
        _fund(U, mallory, s, 0);
        _fund(T, mallory, s, 0);
        BalanceDelta dt = _sellExactIn(T, mallory, s);
        uint256 gross = uint256(uint128(dt.amount0()));
        uint256 before = TREASURY.balance;
        BalanceDelta du = _sellExactIn(U, mallory, s);
        assertEq(TREASURY.balance - before, _ceilFee(gross, 20_000), "cap bracket");
        assertGt(uint256(uint128(du.amount0())), gross * 97 / 100, "user keeps at least 98% minus rounding");
    }
}

// ───────────────────────────── edge pools: launch block, one-sided seeding ─────────────────────────────

contract IMDOHookEdgePoolsTest is V4Fixture {
    using BalanceDeltaLibrary for BalanceDelta;

    Universe U;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function test_launchBlock_sellsNotBlockedAndNeverAboveCap() public {
        _build(U, true, address(0xFEE1), TICK_LOWER, TICK_UPPER, 200 ether, 200_000 ether);
        _fund(U, alice, 10_000 ether, 100 ether);
        assertEq(U.hook.laggedTokenReserve(), 0, "no previous-block snapshot in the launch block");
        uint256 ethBefore = alice.balance;
        BalanceDelta d = _sellExactIn(U, alice, 100 ether); // 0.05% of the reserve
        uint256 received = alice.balance - ethBefore;
        assertGt(received, 0, "launch-block sell paid out");
        uint256 fee = TREASURY.balance;
        assertLe(fee, _ceilFee(received + fee, 20_000), "launch-block fee never above the 2% cap");
        assertEq(int256(d.amount1()), -100 ether, "input consumed");
        _buyExactIn(U, alice, 1 ether);
        assertEq(TREASURY.balance, fee, "launch-block buy is free");
    }

    function test_freshManager_tokenOnlyPool_buysWorkWithNoEthInManager() public {
        // Position entirely below the price: only IMDO is deposited. The manager starts with zero ETH.
        _build(U, true, address(0xFEE1), TICK_LOWER, INIT_TICK - 60, 0, 300_000 ether);
        assertEq(address(U.manager).balance, 0, "manager holds no ETH at launch");
        assertEq(U.token.balanceOf(address(U.manager)), U.hook.tokenReserve(), "token-only inventory tracked");
        _fund(U, alice, 0, 100 ether);
        _fund(U, bob, 20_000 ether, 100 ether);
        BalanceDelta d = _buyExactIn(U, alice, 5 ether);
        assertGt(uint256(uint128(d.amount1())), 0, "buy delivered tokens");
        assertEq(TREASURY.balance, 0, "buy is free");
        BalanceDelta d2 = _buyExactOut(U, alice, 1_000 ether, 10 ether);
        assertEq(int256(d2.amount1()), int256(1_000 ether), "exact-output buy delivered");
        assertEq(TREASURY.balance, 0, "buy is free");
        // next block, sells are sized against the previous block's reserve and the fee is paid from the manager's ETH
        vm.roll(block.number + 1);
        uint256 reserve = U.hook.tokenReserve();
        uint256 s = _atPercent(reserve, 1);
        uint256 ethBefore = bob.balance;
        _sellExactIn(U, bob, s);
        uint256 received = bob.balance - ethBefore;
        uint256 fee = TREASURY.balance;
        assertGt(fee, 0, "1% sell pays 0.5%");
        assertEq(fee, _ceilFee(received + fee, 5_000), "0.5% of gross, paid directly");
        assertEq(U.hook.pendingETH(), 0, "no claim needed");
    }

    function test_ethOnlyPool_exactOutSellTokenFeeIsAClaimAndBurnsOnHarvest() public {
        // Position entirely above the price: only ETH is deposited, so the manager holds no IMDO at all.
        _build(U, true, address(0xFEE1), INIT_TICK + 60, TICK_UPPER, 300 ether, 0);
        assertEq(U.token.balanceOf(address(U.manager)), 0, "manager holds no IMDO at launch");
        _fund(U, alice, 50_000 ether, 10 ether);
        _fund(U, bob, 50_000 ether, 10 ether);
        vm.roll(block.number + 1);
        uint256 supplyBefore = U.token.totalSupply();
        uint256 tokBefore = U.token.balanceOf(alice);
        BalanceDelta d = _sellExactOut(U, alice, 1 ether);
        uint256 paid = tokBefore - U.token.balanceOf(alice);
        assertEq(paid, uint256(uint128(-d.amount1())), "user paid input plus fee");
        assertEq(int256(d.amount0()), int256(1 ether), "exact output delivered");
        uint256 fee = U.hook.pendingToken();
        assertGt(fee, 0, "token fee accrued as a claim, although the manager held no IMDO before settlement");
        uint256 id = uint160(address(U.token));
        assertEq(U.manager.balanceOf(address(U.hook), id), fee, "claim backed by ERC-6909");
        assertEq(U.token.totalSupply(), supplyBefore, "not burned yet");
        assertEq(U.token.balanceOf(address(U.hook)), 0, "hook holds no tokens");
        // snapshot was empty (ETH-only pool): the sell is in the capped bracket
        assertEq(fee, _ceilFee(paid - fee, 20_000), "fee is 2% of the token input");
        vm.prank(address(0xDEAD));
        U.hook.harvest();
        assertEq(U.token.totalSupply(), supplyBefore - fee, "claim redeemed and burned");
        assertEq(U.hook.pendingToken(), 0, "claim settled");
        assertEq(U.manager.balanceOf(address(U.hook), id), 0, "claim burned");
        assertEq(U.token.balanceOf(address(U.hook)), 0, "hook holds nothing");
        assertEq(U.token.balanceOf(TREASURY), 0, "treasury never receives tokens");
        // the pool now has tokens: a later exact-out sell is still claimed during the swap and burned by harvest
        BalanceDelta d2 = _sellExactOut(U, bob, 0.5 ether);
        assertTrue(d2.amount1() < 0, "sold");
        uint256 fee2 = U.hook.pendingToken();
        assertGt(fee2, 0, "second fee accrued as a claim");
        assertEq(U.token.totalSupply(), supplyBefore - fee, "nothing burned mid-swap");
        U.hook.harvest();
        assertEq(U.token.totalSupply(), supplyBefore - fee - fee2, "second fee burned by harvest");
        assertEq(U.hook.pendingToken(), 0, "nothing left pending");
    }

    function test_cannotInitializeBeforeHookExists_butFactoryDoesItAtomically() public {
        // A pool keyed to a hook address with no code reverts in v4 (hook call to empty code fails);
        // the factory deploys the hook and initializes in the same transaction, so nobody can bind it first.
        PoolManager manager = new PoolManager(address(this));
        ModelFactory factory = new ModelFactory(manager, address(0xFEE1));
        (bytes32 salt, address predicted) =
            deployScript.mine(address(factory), address(manager), address(factory.token()), 0, 200_000);
        PoolKey memory key = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(factory.token())),
            LP_FEE,
            TICK_SPACING,
            IHooks(predicted)
        );
        (bool ok,) = address(manager).call(abi.encodeCall(IPoolManager.initialize, (key, SQRT_PRICE)));
        assertFalse(ok, "pool initialized while the hook has no code");
        bytes memory code = deployScript.hookCreationCode(address(manager), address(factory.token()));
        address hook = factory.launch(salt, code, key, SQRT_PRICE, 0, 0, 0);
        assertEq(hook, predicted, "deployed at the mined address");
        assertTrue(IMDOFeeHook(hook).initialized(), "bound in the launch transaction");
        assertEq(IMDOFeeHook(hook).reserveBlock(), block.number, "snapshot clock starts at launch");
    }
}

// ───────────────────────────────────────────── deploy script ─────────────────────────────────────────────

contract IMDODeployScriptTest is Asserts {
    Deploy deploy;
    PoolManager manager;
    IMDOToken token;

    function setUp() public {
        deploy = new Deploy();
        manager = new PoolManager(address(this));
        token = new IMDOToken();
    }

    function test_constantsAgreeWithTheHookAndTheBrief() public view {
        assertEq(deploy.CHAIN_ID(), 11155111, "sepolia");
        assertEq(uint256(deploy.HOOK_FLAGS()), uint256(EXPECTED_FLAGS), "flags");
        assertEq(uint256(deploy.ALL_HOOK_FLAGS()), uint256(FLAG_MASK), "mask");
        assertEq(deploy.TREASURY(), TREASURY, "treasury");
    }

    function test_run_refusesTheWrongChain() public {
        vm.chainId(1);
        (bool ok, bytes memory err) = address(deploy).call(abi.encodeCall(Deploy.run, ()));
        assertFalse(ok, "ran on mainnet");
        assertTrue(err.length > 4, "no reason");
        // Error(string) "expected chain 11155111"
        assertTrue(bytes4(err) == bytes4(keccak256("Error(string)")), "not a string revert");
    }

    function test_tokenCreationCodeMintsTheFixedSupplyToItsDeployer() public {
        bytes memory code = deploy.tokenCreationCode();
        address at;
        assembly ("memory-safe") {
            at := create(0, add(code, 0x20), mload(code))
        }
        assertTrue(at != address(0), "deploy failed");
        assertEq(IMDOToken(at).totalSupply(), SUPPLY, "supply");
        assertEq(IMDOToken(at).balanceOf(address(this)), SUPPLY, "minted to deployer");
        assertEq(at.codehash, address(token).codehash, "same runtime as the delivered token");
    }

    function test_mineFindsAnAddressWithTheDeclaredFlagsAndPredictsIt() public {
        (bytes32 salt, address predicted) = deploy.mine(address(this), address(manager), address(token), 0, 200_000);
        assertEq(uint256(uint160(predicted) & FLAG_MASK), uint256(EXPECTED_FLAGS), "mined bits");
        bytes memory code = deploy.hookCreationCode(address(manager), address(token));
        assertEq(deploy.predict(address(this), salt, keccak256(code)), predicted, "predict agrees with mine");
        address at;
        assembly ("memory-safe") {
            at := create2(0, add(code, 0x20), mload(code), salt)
        }
        assertEq(at, predicted, "CREATE2 landed on the prediction");
        IMDOFeeHook hook = IMDOFeeHook(at);
        assertEq(address(hook.poolManager()), address(manager), "manager baked in");
        assertEq(hook.token(), address(token), "token baked in");
        assertFalse(hook.initialized(), "not bound until a pool initializes");
        assertTrue(Hooks.isValidHookAddress(IHooks(at), 3_000), "v4 accepts the address");
        // mining again from the same start skips the now-used address
        (bytes32 salt2, address next) = deploy.mine(address(this), address(manager), address(token), 0, 200_000);
        assertTrue(salt2 != salt && next != at, "used address must be skipped");
        assertEq(uint256(uint160(next) & FLAG_MASK), uint256(EXPECTED_FLAGS), "next candidate has the bits too");
    }

    function test_mineFailurePaths() public {
        (bool ok,) =
            address(deploy).call(abi.encodeCall(Deploy.mine, (address(0), address(manager), address(token), 0, 10)));
        assertFalse(ok, "zero deployer accepted");
        // find a salt that does not match, then ask for a search of exactly that one salt
        bytes32 initHash = keccak256(deploy.hookCreationCode(address(manager), address(token)));
        uint256 start;
        while (uint160(deploy.predict(address(this), bytes32(start), initHash)) & FLAG_MASK == EXPECTED_FLAGS) start++;
        (ok,) = address(deploy)
            .call(abi.encodeCall(Deploy.mine, (address(this), address(manager), address(token), start, 1)));
        assertFalse(ok, "exhausted range must revert, not return garbage");
        (ok,) =
            address(deploy).call(abi.encodeCall(Deploy.mine, (address(this), address(manager), address(token), 0, 0)));
        assertFalse(ok, "empty range must revert");
    }

    function test_hookCreationCodeDependsOnBothConstructorArguments() public view {
        bytes32 a = keccak256(deploy.hookCreationCode(address(manager), address(token)));
        bytes32 b = keccak256(deploy.hookCreationCode(address(manager), address(0xBEEF)));
        bytes32 c = keccak256(deploy.hookCreationCode(address(0xBEEF), address(token)));
        assertTrue(a != b && a != c && b != c, "constructor args not encoded");
        bytes memory code = deploy.hookCreationCode(address(manager), address(token));
        assertEq(code.length, type(IMDOFeeHook).creationCode.length + 64, "creation code + two words of args");
    }
}

// ───────────────────────────────────────────── invariants ─────────────────────────────────────────────

/// @notice Random, bounded sequences of everything a live pool sees: buys, sells (both modes), liquidity adds and
/// removals by the factory and by strangers, donations, fee collection, harvests, holder burns and transfers,
/// block rolls, and a treasury that sometimes refuses ETH. Every sell is checked against the README's billing rule
/// applied to the origin's ledger as the hook holds it just before the sell, so the check is exact whether or not
/// the harness ends the transaction (and with it the transient ledger) between handler calls.
contract HookHandler is Asserts {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolManager public manager;
    ModelFactory public factory;
    IMDOToken public token;
    IMDOFeeHook public hook;
    PoolKey public key;
    PoolSwapTest public swapRouter;
    PoolModifyLiquidityTest public lpRouter;
    PoolDonateTest public donateRouter;
    int24 immutable tickLower;
    int24 immutable tickUpper;

    address[] public actors;
    address[] public holders; // every address that can hold IMDO

    uint256 public sellAttempts;
    uint256 public sellFailures;
    uint256 public buyAttempts;
    uint256 public feeMismatches;
    uint256 public ghostTreasuryFees; // ETH observed arriving at the treasury, per sell / harvest
    uint256 public ghostHolderBurns;
    uint256 public ghostHookBurns;
    bool public treasuryRejects;
    uint256 public calls;
    string public lastDiag; // what the most recent mismatch was, for the failure message

    function _mismatch(string memory what, uint256 got, uint256 want) internal {
        feeMismatches++;
        lastDiag =
            string.concat(what, " [", _str(got), " != ", _str(want), "] lagged=", _str(hook.laggedTokenReserve()));
    }

    constructor(
        PoolManager m,
        ModelFactory f,
        IMDOFeeHook h,
        PoolKey memory k,
        PoolSwapTest sr,
        PoolModifyLiquidityTest lr,
        PoolDonateTest dr,
        int24 tl,
        int24 tu,
        address[] memory actors_
    ) {
        manager = m;
        factory = f;
        token = f.token();
        hook = h;
        key = k;
        swapRouter = sr;
        lpRouter = lr;
        donateRouter = dr;
        tickLower = tl;
        tickUpper = tu;
        actors = actors_;
        for (uint256 i = 0; i < actors_.length; i++) {
            holders.push(actors_[i]);
        }
        holders.push(address(f));
        holders.push(address(m));
        holders.push(address(h));
        holders.push(TREASURY);
        holders.push(f.feeRecipient());
        holders.push(address(sr));
        holders.push(address(lr));
        holders.push(address(dr));
        holders.push(address(this));
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings(false, false);
    }

    /// @dev One exact-input sell by `a` (already pranked as msg.sender and tx.origin), checked against the billing
    ///      rule. `l` is the origin's ledger before the leg and is advanced by it. Returns false if the swap reverted.
    function _legExactIn(address a, uint256 amount, IMDOFeeHook.Ledger memory l) internal returns (bool) {
        uint256 reserve = _sizingReserve(hook);
        uint256[3] memory before = [TREASURY.balance, hook.pendingETH(), a.balance];
        try swapRouter.swap(
            key, SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1), _settings(), ""
        ) returns (
            BalanceDelta d
        ) {
            uint256 received = a.balance - before[2];
            uint256 fee = (TREASURY.balance - before[0]) + (hook.pendingETH() - before[1]);
            uint256 sold = uint256(uint128(-d.amount1()));
            uint256 expected = _billLeg(l, true, sold, received + fee, reserve);
            if (fee != expected) _mismatch("exact-in: fee", fee, expected);
            if (fee > _ceilFee(received + fee, 20_000)) _mismatch("exact-in: above the cap", fee, received + fee);
            if (uint256(uint128(d.amount0())) != received) _mismatch("exact-in: payout", received, 0);
            if (treasuryRejects && TREASURY.balance != before[0]) _mismatch("rejecting treasury was paid", 0, 0);
            ghostTreasuryFees += TREASURY.balance - before[0];
            return true;
        } catch {
            return false;
        }
    }

    function sellExactIn(uint256 seed, uint256 amount) external {
        calls++;
        address a = _actor(seed);
        uint256 inventory = token.balanceOf(address(manager));
        amount = _bound(amount, 1, inventory / 10 + 1);
        if (amount > token.balanceOf(a)) amount = token.balanceOf(a);
        if (amount == 0) return;
        uint256 supplyBefore = token.totalSupply();
        sellAttempts++;
        IMDOFeeHook.Ledger memory l = hook.originLedger(a);
        vm.startPrank(a, a);
        if (!_legExactIn(a, amount, l)) sellFailures++;
        vm.stopPrank();
        if (token.totalSupply() != supplyBefore) _mismatch("exact-in burned IMDO", token.totalSupply(), supplyBefore);
    }

    /// @dev Two exact-input legs by the same actor inside ONE transaction for the hook: the legs run inside one
    ///      external self-call, where they share a transaction under every harness, and the hook's running counter
    ///      is read there. Sizes run from dust to 3% of the reserve, so free, repricing and capped legs all occur.
    function sellSplitExactIn(uint256 seed, uint256 first, uint256 second) external {
        calls++;
        address a = _actor(seed);
        uint256 reserve = _sizingReserve(hook);
        first = _bound(first, 1e12, reserve * 3 / 100 + 1e12);
        second = _bound(second, 1e12, reserve * 3 / 100 + 1e12);
        if (first + second > token.balanceOf(a)) return;
        uint256 supplyBefore = token.totalSupply();
        sellAttempts++;
        (bool ok, uint256 counter, uint256 expectedCounter) = this.twoLegsExactIn(a, first, second);
        if (!ok) sellFailures++;
        else if (counter != expectedCounter) _mismatch("split: cumulative counter", counter, expectedCounter);
        if (token.totalSupply() != supplyBefore) _mismatch("exact-in burned IMDO", token.totalSupply(), supplyBefore);
    }

    /// @dev Self-call only: both legs and the counter read share one transaction. Not an invariant target.
    function twoLegsExactIn(address a, uint256 first, uint256 second)
        external
        returns (bool ok, uint256 counter, uint256 expectedCounter)
    {
        require(msg.sender == address(this), "self-call only");
        IMDOFeeHook.Ledger memory l = hook.originLedger(a);
        vm.startPrank(a, a);
        ok = _legExactIn(a, first, l) && _legExactIn(a, second, l);
        vm.stopPrank();
        counter = hook.cumulativeSold(a);
        expectedCounter = l.sold;
    }

    function sellExactOut(uint256 seed, uint256 ethOut) external {
        calls++;
        address a = _actor(seed);
        ethOut = _bound(ethOut, 1e6, address(manager).balance / 10 + 1e6);
        // keep the token input affordable: price * ethOut * 2 must fit the actor's balance
        (uint160 sqrtP,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        uint256 priceQ96 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 96);
        uint256 need = FullMath.mulDiv(ethOut, priceQ96, 1 << 96) * 2 + 1;
        uint256 bal = token.balanceOf(a);
        if (need > bal) {
            ethOut = FullMath.mulDiv(bal / 3, 1 << 96, priceQ96 == 0 ? 1 : priceQ96);
            if (ethOut == 0) return;
        }
        uint256[5] memory before =
            [TREASURY.balance, hook.pendingToken(), token.totalSupply(), a.balance, _sizingReserve(hook)];
        IMDOFeeHook.Ledger memory l = hook.originLedger(a);
        sellAttempts++;
        vm.prank(a, a);
        try swapRouter.swap(
            key, SwapParams(false, int256(ethOut), TickMath.MAX_SQRT_PRICE - 1), _settings(), ""
        ) returns (
            BalanceDelta d
        ) {
            _checkExactOut(a, d, before, l);
        } catch {
            sellFailures++;
        }
    }

    function _checkExactOut(address a, BalanceDelta d, uint256[5] memory before, IMDOFeeHook.Ledger memory l) internal {
        uint256 fee = hook.pendingToken() - before[1]; // booked as a claim; only harvest burns it
        uint256 sold = uint256(uint128(-d.amount1())) - fee;
        uint256 received = a.balance - before[3]; // the requested ETH, or less if the pool ran out (partial fill)
        uint256 expected = _billLeg(l, false, sold, received, before[4]);
        if (fee != expected) _mismatch("exact-out: fee", fee, expected);
        if (fee > _ceilFee(sold, 20_000)) _mismatch("exact-out: above the cap", fee, sold);
        if (uint256(uint128(d.amount0())) != received) _mismatch("exact-out: payout", received, 0);
        if (TREASURY.balance != before[0]) _mismatch("exact-out paid ETH", TREASURY.balance, before[0]);
        if (token.totalSupply() != before[2]) _mismatch("exact-out burned mid-swap", token.totalSupply(), before[2]);
    }

    function buyExactIn(uint256 seed, uint256 ethIn) external {
        calls++;
        address a = _actor(seed);
        ethIn = _bound(ethIn, 1e6, a.balance / 10 + 1e6);
        if (ethIn > a.balance) return;
        uint256 tBefore = TREASURY.balance;
        uint256 supplyBefore = token.totalSupply();
        uint256 pend = hook.pendingETH() + hook.pendingToken();
        buyAttempts++;
        vm.prank(a, a);
        try swapRouter.swap{value: ethIn}(
            key, SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1), _settings(), ""
        ) {
            if (TREASURY.balance != tBefore || token.totalSupply() != supplyBefore) feeMismatches++;
            if (hook.pendingETH() + hook.pendingToken() != pend) feeMismatches++;
        } catch {}
    }

    function buyExactOut(uint256 seed, uint256 tokensOut) external {
        calls++;
        address a = _actor(seed);
        tokensOut = _bound(tokensOut, 1, token.balanceOf(address(manager)) / 10 + 1);
        uint256 maxEth = a.balance / 2;
        if (maxEth == 0) return;
        uint256 tBefore = TREASURY.balance;
        uint256 supplyBefore = token.totalSupply();
        buyAttempts++;
        vm.prank(a, a);
        try swapRouter.swap{value: maxEth}(
            key, SwapParams(true, int256(tokensOut), TickMath.MIN_SQRT_PRICE + 1), _settings(), ""
        ) {
            if (TREASURY.balance != tBefore || token.totalSupply() != supplyBefore) feeMismatches++;
        } catch {}
    }

    function factoryAddLiquidity(uint256 liquidity) external {
        calls++;
        liquidity = _bound(liquidity, 1e15, 2e18);
        vm.deal(address(factory), address(factory).balance + 1_000 ether);
        try factory.modifyPosition(key, tickLower, tickUpper, int256(liquidity)) {} catch {}
    }

    function factoryRemoveLiquidity(uint256 liquidity) external {
        calls++;
        (uint128 current,,) = IPoolManager(address(manager))
            .getPositionInfo(key.toId(), address(factory), tickLower, tickUpper, bytes32(0));
        if (current < 2) return;
        liquidity = _bound(liquidity, 1, current / 2);
        try factory.modifyPosition(key, tickLower, tickUpper, -int256(liquidity)) {} catch {}
    }

    function factoryCollectFees() external {
        calls++;
        try factory.collectFees(key, tickLower, tickUpper) {} catch {}
    }

    function strangerAddLiquidity(uint256 seed, uint256 liquidity, uint256 width) external {
        calls++;
        address a = _actor(seed);
        liquidity = _bound(liquidity, 1e15, 5e17);
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        int24 half = int24(int256(_bound(width, 1, 200))) * 60;
        int24 tl = (tick / 60) * 60 - half;
        int24 tu = (tick / 60) * 60 + half;
        vm.prank(a, a);
        try lpRouter.modifyLiquidity{value: a.balance / 4}(
            key, ModifyLiquidityParams(tl, tu, int256(liquidity), bytes32(uint256(uint160(a)))), ""
        ) {}
            catch {}
    }

    function strangerRemoveLiquidity(uint256 seed, uint256 width) external {
        calls++;
        address a = _actor(seed);
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        int24 half = int24(int256(_bound(width, 1, 200))) * 60;
        int24 tl = (tick / 60) * 60 - half;
        int24 tu = (tick / 60) * 60 + half;
        (uint128 current,,) = IPoolManager(address(manager))
            .getPositionInfo(key.toId(), address(lpRouter), tl, tu, bytes32(uint256(uint160(a))));
        if (current == 0) return;
        vm.prank(a, a);
        try lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(tl, tu, -int256(uint256(current)), bytes32(uint256(uint160(a)))), ""
        ) {}
            catch {}
    }

    function donate(uint256 seed, uint256 amount0, uint256 amount1) external {
        calls++;
        address a = _actor(seed);
        amount0 = _bound(amount0, 0, a.balance / 20);
        amount1 = _bound(amount1, 0, token.balanceOf(a) / 20);
        if (amount0 + amount1 == 0) return;
        vm.prank(a, a);
        try donateRouter.donate{value: amount0}(key, amount0, amount1, "") {} catch {}
    }

    function harvest(uint256 seed) external {
        calls++;
        uint256 tBefore = TREASURY.balance;
        uint256 supplyBefore = token.totalSupply();
        uint256 pendEth = hook.pendingETH();
        uint256 pendTok = hook.pendingToken();
        vm.prank(_actor(seed), _actor(seed));
        hook.harvest();
        uint256 moved = TREASURY.balance - tBefore;
        uint256 burned = supplyBefore - token.totalSupply();
        if (moved > pendEth || burned > pendTok) feeMismatches++; // harvest moved more than was accrued
        if (treasuryRejects && moved != 0) feeMismatches++;
        ghostTreasuryFees += moved;
        ghostHookBurns += burned;
    }

    function toggleTreasury() external {
        calls++;
        treasuryRejects = !treasuryRejects;
        vm.etch(TREASURY, treasuryRejects ? REJECT_ALL : bytes(""));
    }

    function roll(uint256 blocks) external {
        calls++;
        vm.roll(block.number + _bound(blocks, 1, 3));
    }

    function burn(uint256 seed, uint256 amount) external {
        calls++;
        address a = _actor(seed);
        amount = _bound(amount, 0, token.balanceOf(a) / 50);
        vm.prank(a);
        token.burn(amount);
        ghostHolderBurns += amount;
    }

    function transfer(uint256 seed, uint256 toSeed, uint256 amount) external {
        calls++;
        address a = _actor(seed);
        address b = _actor(toSeed);
        amount = _bound(amount, 0, token.balanceOf(a) / 10);
        vm.prank(a);
        token.transfer(b, amount);
    }
}

contract IMDOHookInvariantTest is V4Fixture {
    using BalanceDeltaLibrary for BalanceDelta;

    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    Universe U;
    HookHandler handler;
    address feeRecipient = address(0xFEE1);

    function setUp() public {
        _build(U, true, feeRecipient, TICK_LOWER, TICK_UPPER, 300 ether, 300_000 ether);
        // protocol fees on, so the ledger's protocol-fee exclusion is exercised too
        U.manager.setProtocolFeeController(address(this));
        U.manager.setProtocolFee(U.key, (700 << 12) | 500);
        address[] memory actors = new address[](4);
        for (uint256 i = 0; i < actors.length; i++) {
            actors[i] = address(uint160(0xAC700 + i));
            _fund(U, actors[i], 80_000 ether, 2_000 ether);
        }
        handler = new HookHandler(
            U.manager,
            U.factory,
            U.hook,
            U.key,
            U.swapRouter,
            U.lpRouter,
            U.donateRouter,
            TICK_LOWER,
            TICK_UPPER,
            actors
        );
        vm.roll(block.number + 1);
    }

    function targetContracts() external view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(handler);
    }

    function targetSelectors() external view returns (FuzzSelector[] memory t) {
        bytes4[] memory s = new bytes4[](17);
        s[16] = HookHandler.sellSplitExactIn.selector;
        s[0] = HookHandler.sellExactIn.selector;
        s[1] = HookHandler.sellExactOut.selector;
        s[2] = HookHandler.buyExactIn.selector;
        s[3] = HookHandler.buyExactOut.selector;
        s[4] = HookHandler.factoryAddLiquidity.selector;
        s[5] = HookHandler.factoryRemoveLiquidity.selector;
        s[6] = HookHandler.factoryCollectFees.selector;
        s[7] = HookHandler.strangerAddLiquidity.selector;
        s[8] = HookHandler.strangerRemoveLiquidity.selector;
        s[9] = HookHandler.donate.selector;
        s[10] = HookHandler.harvest.selector;
        s[11] = HookHandler.toggleTreasury.selector;
        s[12] = HookHandler.roll.selector;
        s[13] = HookHandler.burn.selector;
        s[14] = HookHandler.transfer.selector;
        s[15] = HookHandler.sellExactIn.selector; // sells weighted a little heavier
        t = new FuzzSelector[](1);
        t[0] = FuzzSelector(address(handler), s);
    }

    function afterInvariant() public view {
        assertGt(handler.calls(), 0, "the campaign made no calls");
    }

    /// @dev Drives the handler deterministically through every path, so the ghost checks the invariants rely on
    ///      are shown to be live rather than vacuous.
    function test_handlerChecksAreLive() public {
        handler.sellExactIn(0, 20_000 ether); // ~6.7% of the reserve: 2% bracket, paid directly
        handler.sellExactOut(1, 3 ether); // token-side fee, booked as a claim until a harvest burns it
        assertGt(U.hook.pendingToken(), 0, "exact-out token fee accrued as a claim");
        handler.buyExactIn(2, 5 ether);
        handler.buyExactOut(3, 1_000 ether);
        handler.toggleTreasury();
        handler.sellExactIn(1, 20_000 ether); // treasury rejects ETH: fee becomes a claim, sell still goes through
        handler.harvest(0); // still rejecting: no ETH moves, no revert; the token claim is burned regardless
        assertGt(U.hook.pendingETH(), 0, "claim accrued while the treasury rejected ETH");
        assertEq(U.hook.pendingToken(), 0, "token claim burned although the ETH claim could not be paid");
        handler.toggleTreasury();
        handler.harvest(1); // moves exactly the claim
        handler.roll(1);
        handler.factoryAddLiquidity(1e18);
        handler.strangerAddLiquidity(2, 1e17, 10);
        handler.sellExactIn(2, 5_000 ether);
        handler.strangerRemoveLiquidity(2, 10);
        handler.factoryRemoveLiquidity(1e17);
        handler.factoryCollectFees();
        handler.donate(2, 1 ether, 100 ether);
        handler.burn(3, 100 ether);
        handler.transfer(0, 1, 50 ether);
        handler.sellSplitExactIn(0, 2_000 ether, 2_000 ether); // ~0.6% + ~0.6% in one tx: second leg bills both
        handler.sellSplitExactIn(3, 9_000 ether, 1e12); // ~2.9% then dust: the dust leg is bounded by its own cap
        assertEq(handler.sellAttempts(), 6, "sells attempted");
        assertEq(handler.sellFailures(), 0, "every sell went through");
        assertEq(handler.buyAttempts(), 2, "buys attempted");
        assertEq(handler.feeMismatches(), 0, string.concat("a fee did not match the schedule: ", handler.lastDiag()));
        assertGt(handler.ghostTreasuryFees(), 0, "treasury fees observed");
        assertEq(TREASURY.balance, handler.ghostTreasuryFees(), "ghost matches the treasury");
        assertEq(U.hook.pendingETH(), 0, "claim harvested");
        assertGt(handler.ghostHookBurns(), 0, "exact-out token fee burned by harvest");
        assertEq(handler.ghostHolderBurns(), 100 ether, "holder burn tracked");
        invariant_hookNeverHoldsFundsBeyondAccruedClaims();
        invariant_reserveLedgerEqualsPoolInventory();
        invariant_supplyOnlyFallsByBurnsAndBalancesSum();
        invariant_treasuryReceivesExactlyTheFeesInEth();
        invariant_sellsAreNeverBlocked();
    }

    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_hookNeverHoldsFundsBeyondAccruedClaims() public view {
        assertEq(address(U.hook).balance, 0, "hook holds ETH");
        assertEq(U.token.balanceOf(address(U.hook)), 0, "hook holds IMDO");
        assertEq(U.manager.balanceOf(address(U.hook), 0), U.hook.pendingETH(), "ETH claims != pendingETH");
        assertEq(
            U.manager.balanceOf(address(U.hook), uint160(address(U.token))),
            U.hook.pendingToken(),
            "token claims != pendingToken"
        );
    }

    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_reserveLedgerEqualsPoolInventory() public view {
        uint256 inventory = U.token.balanceOf(address(U.manager)) - U.manager.protocolFeesAccrued(U.key.currency1)
            - U.hook.pendingToken();
        assertEq(U.hook.tokenReserve(), inventory, "ledger drifted from the manager's pool inventory");
        assertLe(U.hook.laggedTokenReserve() == 0 ? 0 : 1, 1, "snapshot readable");
        assertLe(U.hook.reserveBlock(), block.number, "snapshot clock in the future");
    }

    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_supplyOnlyFallsByBurnsAndBalancesSum() public view {
        uint256 supply = U.token.totalSupply();
        assertEq(supply, SUPPLY - handler.ghostHolderBurns() - handler.ghostHookBurns(), "supply != initial - burns");
        uint256 sum;
        uint256 n = handler.holderCount();
        for (uint256 i = 0; i < n; i++) {
            sum += U.token.balanceOf(handler.holders(i));
        }
        assertEq(sum, supply, "balances do not sum to supply");
    }

    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_treasuryReceivesExactlyTheFeesInEth() public view {
        assertEq(TREASURY.balance, handler.ghostTreasuryFees(), "treasury balance != fees observed");
        assertEq(U.token.balanceOf(TREASURY), 0, "treasury received tokens");
        assertEq(
            handler.feeMismatches(),
            0,
            string.concat("a sell, buy or harvest was charged other than the schedule: ", handler.lastDiag())
        );
    }

    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_sellsAreNeverBlocked() public view {
        assertEq(handler.sellFailures(), 0, "a bounded sell reverted");
    }

    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_policyIsImmutable() public view {
        assertEq(U.hook.TREASURY(), TREASURY, "treasury");
        assertEq(uint256(U.hook.MAX_FEE_PPM()), 20_000, "cap");
        assertEq(U.hook.token(), address(U.token), "token");
        assertEq(address(U.hook.poolManager()), address(U.manager), "manager");
        assertEq(uint256(U.hook.feePpm(5, 100)), 20_000, "bracket");
        assertTrue(U.hook.initialized(), "binding");
    }
}

