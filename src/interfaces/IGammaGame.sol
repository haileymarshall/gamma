// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/src/types/Currency.sol";

interface IGammaGame {
    /// @notice Called by the hook after it sent a trading fee to the game.
    /// @notice When the game started (0 before initialize).
    function genesis() external view returns (uint64);

    function onHookFee(Currency currency, uint256 amount) external;
}
