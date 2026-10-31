// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {MADToken} from "../src/MADToken.sol";

/// @title Local / development deployment of MADToken.
/// @notice The production launch is performed by the IdentityMD factory from the compiled bytecode;
///         it does not run this script. This script exists for local forks and developer testing.
/// @dev `deploy()` takes no configuration: the token has no constructor arguments, and whoever
///      sends the deployment transaction receives the whole supply. Tests call `deploy()` directly,
///      so nothing here reads the environment.
contract DeployMADToken is Script {
    /// @notice Deploys the token. The caller of the deployment transaction receives the supply.
    function deploy() public returns (MADToken token) {
        token = new MADToken();
    }

    /// @notice Entry point for `forge script`. Broadcasts `deploy()` with the configured signer.
    function run() external returns (MADToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
