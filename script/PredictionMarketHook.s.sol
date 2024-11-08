// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract PredictionMarketHookHackathonDeployer is Script {
    
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    address constant POOL_MANAGER = address(0xC81462Fec8B23319F288047f8A03A57682a35C1A);

    function run() external {
        // deploy the hook
        uint24 fee = 500;

        // hook contracts must have specific flags encoded in the address
        uint160 permissions = uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG 
        ); 

        // Mine a salt that will produce a hook address with the correct permissions
        bytes memory constructorArgs = abi.encode(POOL_MANAGER, fee);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, permissions, type(PredictionMarketHook).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.broadcast();
        PredictionMarketHook hook = new PredictionMarketHook{salt: salt}(IPoolManager(POOL_MANAGER), fee);

        require(address(hook) == hookAddress, "PredictionMarketHook: hook address mismatch");
    }
}