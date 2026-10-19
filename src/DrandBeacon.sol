// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BLS} from "./vendor/bls/BLS.sol";
import {IGammaBeacon} from "./interfaces/IGammaBeacon.sol";

/// @title DrandBeacon
/// @notice Permissionless store of drand evmnet randomness. Anyone submits a round's BLS signature; it is
/// verified on BN254 against the League of Entropy's public key, so nobody (including the submitter) can bias it.
contract DrandBeacon is IGammaBeacon {
    /// @dev drand evmnet, chain hash 04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3.
    uint64 public constant GENESIS = 1727521075;
    uint64 public constant PERIOD = 3;
    string public constant DST = "BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_";

    mapping(uint64 round => bytes32) public randomness;

    event RoundProven(uint64 indexed round, bytes32 randomness);

    error InvalidSignature();

    function genesis() external pure returns (uint64) {
        return GENESIS;
    }

    function period() external pure returns (uint64) {
        return PERIOD;
    }

    function publicKey() public pure returns (BLS.PointG2 memory) {
        return BLS.PointG2(
            [
                0x557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f,
                0x7e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b382
            ],
            [
                0x297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b,
                0x95685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6
            ]
        );
    }

    function prove(uint64 round, bytes calldata signature) external returns (bytes32 r) {
        r = randomness[round];
        if (r != bytes32(0)) return r;

        (bool callSuccess, bool pairingSuccess) = BLS.verifySingle(
            BLS.g1Unmarshal(signature),
            publicKey(),
            BLS.hashToPoint(bytes(DST), abi.encodePacked(keccak256(abi.encodePacked(round))))
        );
        if (!callSuccess || !pairingSuccess) revert InvalidSignature();

        r = sha256(signature);
        randomness[round] = r;
        emit RoundProven(round, r);
    }
}
