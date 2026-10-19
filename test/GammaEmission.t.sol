// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GammaEmission} from "src/libraries/GammaEmission.sol";

contract EmissionHarness {
    function released(uint256 n) external pure returns (uint256) {
        return GammaEmission.released(n);
    }

    function between(uint256 a, uint256 b) external pure returns (uint256) {
        return GammaEmission.between(a, b);
    }
}

contract GammaEmissionTest is Test {
    EmissionHarness h = new EmissionHarness();
    uint256 constant N = 365 * 144;

    function test_startsAtZero() public view {
        assertEq(h.released(0), 0);
    }

    function test_year1IsExactly500M() public view {
        assertEq(h.released(N), 500_000_000e18);
        assertLt(h.released(N - 1), 500_000_000e18);
    }

    function test_day0Rate() public view {
        // 32.78 a day in the original ×100,000.
        uint256 day0 = h.released(144);
        assertApproxEqRel(day0, 3_281_000e18, 0.005e18);
        assertApproxEqRel(h.between(0, 1), 22_828e18, 0.001e18);
    }

    function test_halvesEvery120Days() public view {
        uint256 a = h.between(0, 1);
        uint256 b = h.between(120 * 144, 120 * 144 + 1);
        assertApproxEqRel(b * 2, a, 0.0001e18);
    }

    function test_noJumpIntoTail() public view {
        uint256 lastYear1 = h.between(N - 2, N - 1);
        uint256 firstTail = h.between(N, N + 1);
        assertApproxEqRel(firstTail, lastYear1, 0.005e18);
    }

    function test_tailHalvesEvery522Days() public view {
        uint256 a = h.between(N, N + 1);
        uint256 b = h.between(N + 522 * 144, N + 522 * 144 + 1);
        assertApproxEqRel(b * 2, a, 0.001e18);
    }

    function test_neverExceedsReserve() public view {
        assertLe(h.released(type(uint64).max), 800_000_000e18);
        assertApproxEqRel(h.released(N + 144 * 365 * 100), 800_000_000e18, 0.001e18);
    }

    function testFuzz_monotonic(uint32 a, uint32 b) public view {
        (uint256 lo, uint256 hi) = a < b ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
        assertLe(h.released(lo), h.released(hi));
    }

    function testFuzz_betweenAdds(uint32 a, uint32 b, uint32 c) public view {
        uint256[3] memory v = [uint256(a), uint256(b), uint256(c)];
        // sort
        for (uint256 i; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (v[j] < v[i]) (v[i], v[j]) = (v[j], v[i]);
            }
        }
        assertEq(h.between(v[0], v[1]) + h.between(v[1], v[2]), h.between(v[0], v[2]));
    }
}
