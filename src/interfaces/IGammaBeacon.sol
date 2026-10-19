// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice A public randomness beacon indexed by round, such as drand.
interface IGammaBeacon {
    /// @notice Timestamp of round 1.
    function genesis() external view returns (uint64);

    /// @notice Seconds between rounds.
    function period() external view returns (uint64);

    /// @notice Randomness of a proven round, zero while unproven.
    function randomness(uint64 round) external view returns (bytes32);

    /// @notice Verifies a round's signature and stores its randomness. Idempotent.
    function prove(uint64 round, bytes calldata signature) external returns (bytes32);
}
