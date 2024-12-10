// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "forge-std-1.9.4/Script.sol";
import {Artcade} from "../src/Artcade.sol";

interface ICreate2Deployer {
    function deploy(uint256 value, bytes32 salt, bytes memory code) external;
    function computeAddress(bytes32 salt, bytes32 codeHash) external view returns (address);
}

address constant CREATE_2_DEPLOYER = 0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2;

contract DeployArtcade is Script {
    function run() external {
        // load environment variables
        bytes32 salt = vm.envBytes32("SALT");
        bytes memory constructorArgs = vm.envBytes("CONSTRUCTOR_ARGS");

        // get the creation code for Artcade with constructor args
        bytes memory creationCode = abi.encodePacked(type(Artcade).creationCode, constructorArgs);

        // start broadcasting transactions
        vm.startBroadcast();

        // deploy using CREATE2
        ICreate2Deployer(CREATE_2_DEPLOYER).deploy(
            0, // value - amount of ETH to send
            salt,
            creationCode
        );

        vm.stopBroadcast();

        // calculate and log the deployed address
        bytes32 codeHash = keccak256(creationCode);
        address deployedAddress = ICreate2Deployer(CREATE_2_DEPLOYER).computeAddress(salt, codeHash);
        console.log("Artcade deployed to:", deployedAddress);

        // write deployed address to file
        vm.writeFile("out.txt", vm.toString(deployedAddress));
    }
}
