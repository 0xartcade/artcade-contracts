// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "forge-std-1.9.4/Test.sol";

contract GameEIP712 is Test {
    bytes32 public constant VERIFIED_SCORE_TYPEHASH =
        keccak256("VerifiedScore(address player,uint256 score,bytes32 nonce)");

    // Cache the domain separator
    bytes32 internal immutable _DOMAIN_SEPARATOR;
    string internal constant VERSION = "1";

    constructor(string memory name, address verifyingContract) {
        _DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(VERSION)),
                block.chainid,
                verifyingContract
            )
        );
    }

    function getTypedDataHash(address player, uint256 score, bytes32 nonce) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(VERIFIED_SCORE_TYPEHASH, player, score, nonce));
        return keccak256(abi.encodePacked("\x19\x01", _DOMAIN_SEPARATOR, structHash));
    }

    function signScore(uint256 signerPrivateKey, address player, uint256 score, bytes32 nonce)
        public
        view
        returns (bytes memory)
    {
        bytes32 digest = getTypedDataHash(player, score, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
