// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MintableERC20 is ERC20 {
    uint8 immutable private _decimals;

    address public minter;
    address public vault;
    uint256 public mintQuota;

    constructor(address minter_, address vault_, string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        minter = minter_;
        vault = vault_;
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    modifier onlyMinter() {
        require(msg.sender == minter, "Require minter");
        _;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "Require vault");
        _;
    }

    event MinterTransferred(address indexed prevMinter, address indexed newMinter);

    function transferMinter(address newMinter) external onlyMinter {
        address prevMinter = minter;
        minter = newMinter;
        emit MinterTransferred(prevMinter, newMinter);
    }

    event VaultTransferred(address indexed prevVault, address indexed newVault);

    function transferVault(address newVault) external onlyVault {
        address prevVault = vault;
        vault = newVault;
        emit VaultTransferred(prevVault, newVault);
    }


    function updateMintQuota(uint256 delta) external onlyVault {
        mintQuota += delta;
    }

    function mint(address account, uint256 amount) external onlyMinter {
        if (account != vault) {
            mintQuota -= amount;
        }
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external onlyMinter {
        _burn(account, amount);
    }
}
