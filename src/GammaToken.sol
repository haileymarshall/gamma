// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title GammaToken
/// @notice Plain launch ERC-20: 1,000,000,000 tokens minted once to the deploying factory, no mint function.
contract GammaToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000e18;

    constructor() ERC20("Gamma", "GAMMA", 18) {
        _mint(msg.sender, SUPPLY);
    }
}
