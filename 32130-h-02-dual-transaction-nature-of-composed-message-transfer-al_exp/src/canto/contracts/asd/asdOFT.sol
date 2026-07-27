// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal token-side double for the LayerZero OFT dependency. The
/// audited ASDRouter is vendored unchanged; this double only supplies the
/// `mint` and local `transfer` calls used by its compose path.
contract ASDOFT is ERC20 {
    IERC20 public immutable note;

    constructor(IERC20 note_) ERC20("ASD", "ASD") {
        note = note_;
    }

    function mint(uint256 amount) external {
        note.transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
    }
}
