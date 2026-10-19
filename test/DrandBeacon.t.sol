// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DrandBeacon} from "src/DrandBeacon.sol";

/// @dev Real drand evmnet rounds, fetched from api.drand.sh/v2/beacons/evmnet/rounds/<n>.
contract DrandBeaconTest is Test {
    DrandBeacon beacon = new DrandBeacon();

    bytes constant SIG_21600000 =
        hex"082d388f72a25dd3f8c84e81e52b0e08947a446276ce12fbcb7b0e9ec4ae16a80cf2e660d385c5b3f7c407fe69bb67c00c5333c6169a3c5b2863e29f6100b9c9";
    bytes constant SIG_21600636 =
        hex"13ec4901e510bd45547817bf277b0170588fefe85055fe282c65d1d4e9237e640e8eee3d8ef0745e35fc28a905825de70f8dc096b85e62a391fb14ffcf4f0254";

    function test_verifiesRealRounds() public {
        bytes32 r = beacon.prove(21600000, SIG_21600000);
        assertEq(r, sha256(SIG_21600000));
        assertEq(beacon.randomness(21600000), r);

        beacon.prove(21600636, SIG_21600636);
        assertEq(beacon.randomness(21600636), sha256(SIG_21600636));
    }

    function test_rejectsWrongRound() public {
        vm.expectRevert(DrandBeacon.InvalidSignature.selector);
        beacon.prove(21600001, SIG_21600000);
    }

    function test_idempotent() public {
        uint256 g = gasleft();
        beacon.prove(21600000, SIG_21600000);
        uint256 firstCall = g - gasleft();
        g = gasleft();
        beacon.prove(21600000, SIG_21600000);
        uint256 secondCall = g - gasleft();
        // A proven round is returned from storage: no pairing, a small fraction of the first call.
        assertEq(beacon.randomness(21600000), sha256(SIG_21600000));
        assertLt(secondCall, firstCall / 5);
    }

    function test_gas() public {
        uint256 g = gasleft();
        beacon.prove(21600000, SIG_21600000);
        emit log_named_uint("prove gas", g - gasleft());
    }
}
