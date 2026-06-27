// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol';
import '@openzeppelin/contracts/access/AccessControlEnumerable.sol';
import '@openzeppelin/contracts/utils/Context.sol';

import '../libraries/ERC20FlashMintUpgradeable.sol';

/**
 * @title USP
 * @notice Platypuses can make use of their collateral to mint USP
 * @dev PlatypusTreasure has `MINTER_ROLE` to mint tokens
 */
contract USP is OwnableUpgradeable, ERC20Upgradeable, ERC20BurnableUpgradeable, ERC20FlashMintUpgradeable {
    address public minter;

    function initialize(address _minter, address _flashLoanFeeTo) external initializer {
        require(_minter != address(0), 'zero address');
        require(_flashLoanFeeTo != address(0), 'zero address');

        __Ownable_init();
        __ERC20_init_unchained('USP', 'USP');
        __ERC20Burnable_init_unchained();
        __ERC20FlashMint_init_unchained(50_000_000e18, 9, _flashLoanFeeTo); // max flashloan amount = 50m; fee = 9 b.p.

        minter = _minter;
    }

    /**
     * @notice Change the minter
     */
    function setMinter(address _minter) external onlyOwner {
        minter = _minter;
    }

    function mint(address to, uint256 _amount) external {
        require(msg.sender == minter, 'USP: not minter');
        _mint(to, _amount);
    }

    /**
     * Gas optimization: If the value allowance is `type(uint256).max`, infinite approval is assumed.
     */
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = allowance(sender, _msgSender());
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, 'ERC20: transfer amount exceeds allowance');
            unchecked {
                _approve(sender, _msgSender(), currentAllowance - amount);
            }
        }
        return true;
    }
}
