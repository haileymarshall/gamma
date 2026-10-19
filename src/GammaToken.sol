// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title GammaToken
/// @notice Plain ERC-20, 1,000,000,000 minted once, no mint function. On the IMD launch the network's factory
/// deploys an identical fixed token; this one is for local and testnet runs.
contract GammaToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000e18;

    constructor(address recipient) ERC20("Gamma", "GAMMA", 18) {
        _mint(recipient, SUPPLY);
    }
}
