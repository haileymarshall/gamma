// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/src/types/Currency.sol";

interface IGammaGame {
    /// @notice Called by the hook after it sent a trading fee to the game.
    function onHookFee(Currency currency, uint256 amount) external;
}
