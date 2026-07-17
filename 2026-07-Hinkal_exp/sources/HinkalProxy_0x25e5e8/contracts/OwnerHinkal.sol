// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract OwnerHinkal is Ownable2Step {
    function renounceOwnership() public view override onlyOwner {
        revert("The Ownership cannot be renounced");
    }
}
