// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @title GammaEmission
/// @notice The Reserve's fixed release schedule, in closed form so any range of epochs costs O(log n).
/// Year 1 releases exactly 500M GAMMA, halving every 120 days. After that the Reserve releases a fixed
/// fraction of the 300M it still holds every epoch (0.1327% a day), forever, starting at year 1's last rate.
library GammaEmission {
    uint256 internal constant RAY = 1e27;

    uint256 internal constant YEAR1_EPOCHS = 365 * 144;
    uint256 internal constant YEAR1 = 500_000_000e18;
    uint256 internal constant TAIL = 300_000_000e18;
    uint256 internal constant TOTAL = YEAR1 + TAIL;

    /// @dev 2^(-1/17280): per-epoch decay, halving every 120 days of 144 epochs.
    uint256 internal constant K = 999959888120442772275535077;
    /// @dev K^YEAR1_EPOCHS.
    uint256 internal constant K_YEAR1 = 121441492644200733592911176;
    /// @dev (1 - 0.001327)^(1/144): the share of the tail the Reserve keeps each epoch.
    uint256 internal constant G = 999990778644987833034485414;

    /// @notice Total GAMMA released by the start of epoch `n`.
    function released(uint256 n) internal pure returns (uint256) {
        if (n >= YEAR1_EPOCHS) {
            uint256 kept = FixedPointMathLib.rpow(G, n - YEAR1_EPOCHS, RAY);
            return YEAR1 + TAIL - FixedPointMathLib.mulDivUp(TAIL, kept, RAY);
        }
        return FixedPointMathLib.mulDivDown(YEAR1, RAY - FixedPointMathLib.rpow(K, n, RAY), RAY - K_YEAR1);
    }

    /// @notice GAMMA released for epochs [from, to).
    function between(uint256 from, uint256 to) internal pure returns (uint256) {
        if (to <= from) return 0;
        uint256 a = released(from);
        uint256 b = released(to);
        return b > a ? b - a : 0;
    }
}
