// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/// @notice Simple single owner authorization mixin.
/// @author modified from Solmate (https://github.com/Rari-Capital/solmate/blob/main/src/auth/Owned.sol)
abstract contract OwnedUpgradeable {
    error Unauthorized();

    event OwnerUpdated(address indexed user, address indexed newOwner);

    address public owner;

    modifier onlyOwner() virtual {
        checkOwner();
        _;
    }

    function checkOwner() internal view {
        if (msg.sender != owner) revert Unauthorized();
    }

    function __Owned_init() internal {
        owner = msg.sender;
    }

    function setOwner(address newOwner) public virtual onlyOwner {
        owner = newOwner;

        emit OwnerUpdated(msg.sender, newOwner);
    }

    uint256[49] private __gap;
}
