// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMDOToken, IMDOFeeHook, IPoolManager} from "../src/IMDOFeeHook.sol";

interface DeploymentVm {
    function envAddress(string calldata name) external view returns (address);
    function envBytes(string calldata name) external view returns (bytes memory);
    function envBytes32(string calldata name) external view returns (bytes32);
    function envOr(string calldata name, address fallbackValue) external view returns (address);
    function envOr(string calldata name, uint256 fallbackValue) external view returns (uint256);
    function startBroadcast() external;
    function stopBroadcast() external;
}

/// @notice Prepare and submit one atomic launch through the configured launch factory.
/// @dev The factory ABI is deliberately configuration, not an invented replacement factory.
/// Run without --broadcast to rehearse. Signing is supplied by Foundry's account options.
contract Deploy {
    DeploymentVm private constant VM = DeploymentVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 public constant CHAIN_ID = 11155111;
    uint160 public constant HOOK_FLAGS = 0x25d4;
    uint160 public constant ALL_HOOK_FLAGS = (1 << 14) - 1;
    address public constant TREASURY = address(bytes20(hex"b1ec9d1c36974d05eb9889ebf8a150b05791e559"));

    event LaunchPrepared(
        address indexed factory,
        address indexed token,
        address indexed hook,
        address poolManager,
        address hookDeployer,
        bytes32 hookSalt,
        bytes32 tokenCreationCodeHash,
        bytes32 hookCreationCodeHash,
        bytes32 factoryCalldataHash
    );
    event LaunchVerified(
        address indexed token,
        address indexed hook,
        bytes32 poolId,
        bytes32 tokenRuntimeCodeHash,
        bytes32 hookRuntimeCodeHash
    );

    /// @notice Returns the constructor-free token creation code to embed in the factory launch.
    function tokenCreationCode() public pure returns (bytes memory) {
        return type(IMDOToken).creationCode;
    }

    /// @notice Encode the immutable manager and predicted factory-created token into hook initcode.
    function hookCreationCode(address manager, address launchToken) public pure returns (bytes memory) {
        return abi.encodePacked(type(IMDOFeeHook).creationCode, abi.encode(IPoolManager(manager), launchToken));
    }

    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @notice Off-chain helper; use the actual CREATE2 creator, which may differ from the factory.
    /// @dev A bounded search allows callers to resume at the next start value without changing code.
    function mine(address deployer, address manager, address launchToken, uint256 start, uint256 attempts)
        external
        view
        returns (bytes32 salt, address hook)
    {
        require(deployer != address(0), "zero CREATE2 deployer");
        bytes32 initCodeHash = keccak256(hookCreationCode(manager, launchToken));
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            hook = predict(deployer, salt, initCodeHash);
            if (uint160(hook) & ALL_HOOK_FLAGS == HOOK_FLAGS && hook.code.length == 0) return (salt, hook);
        }
        revert("no matching unused address in search range");
    }

    /// @notice Required environment: POOL_MANAGER, LAUNCH_FACTORY, TOKEN, HOOK_SALT, LAUNCH_CALLDATA.
    /// Optional HOOK_DEPLOYER defaults to LAUNCH_FACTORY; LAUNCH_VALUE defaults to zero wei.
    /// TOKEN is the factory's predicted token address. Factory calldata must create that token,
    /// create the mined hook, initialize their ETH pool, and perform the existing factory launch.
    function run() external returns (IMDOToken launchToken, IMDOFeeHook hook) {
        require(block.chainid == CHAIN_ID, "expected chain 11155111");
        address manager = VM.envAddress("POOL_MANAGER");
        address factory = VM.envAddress("LAUNCH_FACTORY");
        address tokenAddress = VM.envAddress("TOKEN");
        address hookDeployer = VM.envOr("HOOK_DEPLOYER", factory);
        bytes32 salt = VM.envBytes32("HOOK_SALT");
        bytes memory factoryCalldata = VM.envBytes("LAUNCH_CALLDATA");
        uint256 value = VM.envOr("LAUNCH_VALUE", uint256(0));

        require(manager.code.length != 0 && factory.code.length != 0, "manager/factory has no code");
        require(tokenAddress != address(0) && tokenAddress.code.length == 0, "expected fresh launch token");
        require(hookDeployer != address(0) && factoryCalldata.length >= 4, "incomplete launch configuration");

        bytes32 hookInitHash = keccak256(hookCreationCode(manager, tokenAddress));
        address hookAddress = predict(hookDeployer, salt, hookInitHash);
        require(uint160(hookAddress) & ALL_HOOK_FLAGS == HOOK_FLAGS, "salt has incorrect hook permissions");
        require(hookAddress.code.length == 0, "hook address already used");

        emit LaunchPrepared(
            factory,
            tokenAddress,
            hookAddress,
            manager,
            hookDeployer,
            salt,
            keccak256(tokenCreationCode()),
            hookInitHash,
            keccak256(factoryCalldata)
        );

        VM.startBroadcast();
        (bool success, bytes memory reason) = factory.call{value: value}(factoryCalldata);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
        VM.stopBroadcast();

        launchToken = IMDOToken(tokenAddress);
        hook = IMDOFeeHook(payable(hookAddress));
        require(tokenAddress.codehash == keccak256(type(IMDOToken).runtimeCode), "unexpected token implementation");
        require(hookAddress.code.length != 0, "factory did not deploy expected hook");
        require(
            address(hook.poolManager()) == manager && hook.token() == tokenAddress, "wrong hook constructor arguments"
        );
        require(hook.TREASURY() == TREASURY && hook.FLAGS() == HOOK_FLAGS, "wrong immutable hook policy");
        require(hook.initialized(), "factory did not initialize attached pool");
        require(
            launchToken.totalSupply() == 1_000_000 ether && launchToken.decimals() == 18, "wrong token supply/decimals"
        );
        emit LaunchVerified(tokenAddress, hookAddress, hook.poolId(), tokenAddress.codehash, hookAddress.codehash);
    }
}
