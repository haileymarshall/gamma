// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IGammaGame} from "./IGammaGame.sol";

/// @notice The part of GammaHook the game reads when it is wired to the pool.
interface IGammaHook {
    /// @notice The game this hook sends its fees to.
    function game() external view returns (IGammaGame);

    /// @notice keccak256(abi.encode(key)) of the one pool the hook was initialized with, zero before that.
    function poolId() external view returns (bytes32);
}
