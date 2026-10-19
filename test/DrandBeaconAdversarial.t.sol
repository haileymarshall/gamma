// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DrandBeacon} from "src/DrandBeacon.sol";

contract DrandBeaconAdversarialTest is Test {
    DrandBeacon internal beacon;
    uint64 internal constant ROUND = 21_600_000;
    bytes internal constant SIGNATURE =
        hex"082d388f72a25dd3f8c84e81e52b0e08947a446276ce12fbcb7b0e9ec4ae16a80cf2e660d385c5b3f7c407fe69bb67c00c5333c6169a3c5b2863e29f6100b9c9";

    function setUp() public {
        beacon = new DrandBeacon();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_rejectsEveryNoncanonicalLength(uint8 lengthSeed, uint64 round) public {
        uint256 length = bound(lengthSeed, 0, 127);
        if (length >= 64) ++length;
        vm.expectRevert(bytes("Invalid G1 bytes length"));
        beacon.prove(round, new bytes(length));
        assertEq(beacon.randomness(round), bytes32(0), "rejected proof wrote randomness");
    }

    function test_rejectsInfinity() public {
        vm.expectRevert(DrandBeacon.InvalidSignature.selector);
        beacon.prove(ROUND, new bytes(64));
        assertEq(beacon.randomness(ROUND), bytes32(0));
    }

    function test_rejectsOffCurveCoordinates() public {
        vm.expectRevert(DrandBeacon.InvalidSignature.selector);
        beacon.prove{gas: 2_000_000}(ROUND, abi.encode(uint256(1), uint256(1)));
        assertEq(beacon.randomness(ROUND), bytes32(0));
    }

    function test_rejectsCoordinatesOutsideBaseField() public {
        uint256 field = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
        vm.expectRevert(DrandBeacon.InvalidSignature.selector);
        beacon.prove{gas: 2_000_000}(ROUND, abi.encode(field, uint256(2)));
        assertEq(beacon.randomness(ROUND), bytes32(0));
    }

    function test_rejectedProofDoesNotPreventLaterValidSubmission() public {
        vm.expectRevert(DrandBeacon.InvalidSignature.selector);
        beacon.prove(ROUND, abi.encode(uint256(1), uint256(2)));
        assertEq(beacon.randomness(ROUND), bytes32(0));
        vm.prank(makeAddr("permissionless prover"));
        assertEq(beacon.prove(ROUND, SIGNATURE), sha256(SIGNATURE));
    }

    function test_roundIsolationAndCacheCannotBeOverwritten() public {
        vm.recordLogs();
        vm.prank(makeAddr("first prover"));
        bytes32 result = beacon.prove(ROUND, SIGNATURE);
        assertEq(vm.getRecordedLogs().length, 1, "first proof emits once");

        vm.recordLogs();
        vm.prank(makeAddr("second prover"));
        assertEq(beacon.prove(ROUND, hex"ff"), result, "cached round is immutable");
        assertEq(vm.getRecordedLogs().length, 0, "cache hit must not re-emit");
        assertEq(beacon.randomness(ROUND + 1), bytes32(0));
        vm.expectRevert(DrandBeacon.InvalidSignature.selector);
        beacon.prove(ROUND + 1, SIGNATURE);
        assertEq(beacon.randomness(ROUND), sha256(SIGNATURE));
        assertEq(beacon.randomness(ROUND + 1), bytes32(0));
    }

    function test_cannotAppendBytesToBiasRandomness() public {
        vm.expectRevert(bytes("Invalid G1 bytes length"));
        beacon.prove(ROUND, bytes.concat(SIGNATURE, hex"01"));
        assertEq(beacon.randomness(ROUND), bytes32(0));
        assertEq(beacon.prove(ROUND, SIGNATURE), sha256(SIGNATURE));
    }
}
