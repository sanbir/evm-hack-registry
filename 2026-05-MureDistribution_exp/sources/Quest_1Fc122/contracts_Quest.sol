// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

contract Quest is ERC20, Ownable, Pausable {
    constructor(
        string memory name,
        string memory symbol,
        uint256 supply,
        address treasury,
        address owner
    )
        ERC20(name, symbol)
        Ownable(owner)
    {
        _mint(treasury, supply);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @inheritdoc ERC20
    function transfer(address to, uint256 value) public virtual override whenNotPaused returns (bool) {
        return super.transfer(to, value);
    }

    /// @inheritdoc ERC20
    function transferFrom(
        address from,
        address to,
        uint256 value
    )
        public
        virtual
        override
        whenNotPaused
        returns (bool)
    {
        return super.transferFrom(from, to, value);
    }

    /// @inheritdoc ERC20
    function approve(address spender, uint256 value) public virtual override whenNotPaused returns (bool) {
        return super.approve(spender, value);
    }

    /**
     * @dev Pauses all token transfers.
     * See {Pausable-_pause}.
     * Requirements:
     * - The caller must be the owner.
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @dev Unpauses all token transfers.
     * See {Pausable-_unpause}.
     * Requirements:
     * - The caller must be the owner.
     */
    function unpause() public onlyOwner {
        _unpause();
    }
}
