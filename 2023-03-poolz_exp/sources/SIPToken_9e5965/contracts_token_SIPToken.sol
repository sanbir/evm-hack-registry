//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "../common/BlackList.sol";
import "../interfaces/IBP.sol";
import "../BP/interfaces/IBotPrevention.sol";

/**
 * @title Configurable
 * @dev Configurable varriables of the contract
 **/
contract Configurable {
    uint256 public constant cap = 1_000_000_000 * 10**18;
}

contract SIPToken is ERC20, BlackList, Pausable, Configurable {
    uint256 public _burntAmount;
    uint256 public _dirtyFunds;
    uint256 public _tax;
    address public _feeKeeper;
    address public _miningAddr;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // address of bot prevention
    address public _bpAddr;
    bool public _isEnableBP;

    // store pair address
    mapping(address => bool) public _isPair;

    // excluded tax addresses
    mapping(address => bool) public _excludedTax;

    // events to track onchain-offchain relationships
    event __issue(bytes32 offchain);

    // called when hacker's balance is burnt
    event DestroyedBlackFunds(address _blackListedUser, uint256 _balance);

    constructor(
        address strategicPartner,
        address privateSale,
        address preIdo,
        address ido,
        address team,
        address advisory,
        address marketing,
        address mining,
        address play2Earn,
        address reserve,
        address liquidity,
        address bpAddr
    ) ERC20("Space SIP", "SIP") {
        _miningAddr = mining;
        _feeKeeper = _msgSender();
        _excludedTax[_msgSender()] = true;
        _bpAddr = bpAddr;
        _isEnableBP = true;
        _tax = 200; // 2%

        _mint(strategicPartner, 20_000_000 * 10**18);
        _mint(privateSale, 100_000_000 * 10**18);
        _mint(preIdo, 20_000_000 * 10**18);
        _mint(ido, 10_000_000 * 10**18);
        _mint(team, 150_000_000 * 10**18);
        _mint(advisory, 10_000_000 * 10**18);
        _mint(marketing, 60_000_000 * 10**18);
        _mint(mining, 150_000_000 * 10**18);
        _mint(play2Earn, 350_000_000 * 10**18);
        _mint(reserve, 90_000_000 * 10**18);
        _mint(liquidity, 40_000_000 * 10**18);
    }

    // Function to enable/disable bot prevention
    function setEnableBP(bool isEnableBP) external onlyOwner {
        _isEnableBP = isEnableBP;
    }

    // Function to update bot prevention address
    function setBPAddress(address bpAddr) external onlyOwner {
        _bpAddr = bpAddr;
    }

    // Function to update fee keeper address
    function setFeeKeeperAddress(address feeKeeper) external onlyOwner {
        _feeKeeper = feeKeeper;
    }

    // Function to update tax
    function setTax(uint256 tax) external onlyOwner {
        _tax = tax;
    }

    // Function to add a pair
    function addPair(address _address) external onlyOwner {
        _isPair[_address] = true;
    }

    // Function to remove a pair
    function removePair(address _address) external onlyOwner {
        _isPair[_address] = false;
    }

    // Function to add an excluded tax address
    function addExcludedTaxAddress(address _address) external onlyOwner {
        _excludedTax[_address] = true;
    }

    // Function to remove an excluded tax address
    function removeExcludedTaxAddress(address _address) external onlyOwner {
        _excludedTax[_address] = false;
    }

    /**
     * @dev function to mint SIP token that was hacked by hacker and send it to reward pool
     */
    function issueBlackFunds(bytes32 offchain) external virtual onlyOwner {
        require(_dirtyFunds > 0, "SIP:EDF"); // empty dirty funds
        _mint(_miningAddr, _dirtyFunds);
        _dirtyFunds = 0;
        emit __issue(offchain);
    }

    /**
     * @dev function to burn SIP of hacker
     * @param _blackListedUser the account whose SIP will be burnt
     */
    function destroyBlackFunds(address _blackListedUser) external virtual onlyOwner {
        require(isBlackListed[_blackListedUser], "SIP:IB"); // in blacklist
        uint256 funds = balanceOf(_blackListedUser);
        _burn(_blackListedUser, funds);
        _dirtyFunds += funds;
        emit DestroyedBlackFunds(_blackListedUser, funds);
    }

    function mint(address _to) external virtual onlyOwner {
        require(totalSupply() + _burntAmount <= cap, "SIP:EC"); // exceed cap
        _mint(_to, _burntAmount);
        _burntAmount = 0;
    }

    /**
     * @dev called by the owner to pause, triggers stopped state
     */
    function pause() external virtual onlyOwner whenNotPaused {
        _pause();
    }

    /**
     * @dev called by the owner to unpause, returns to normal state
     */
    function unpause() external virtual onlyOwner whenPaused {
        _unpause();
    }

    function transfer(address _to, uint256 _value) public virtual override whenNotPaused returns (bool) {
        require(!isBlackListed[_msgSender()]);
        _transfer(_msgSender(), _to, _value);
        return true;
    }

    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    ) public virtual override whenNotPaused returns (bool) {
        require(!isBlackListed[_from]);

        uint256 currentAllowance = allowance(_from, _msgSender());
        require(currentAllowance >= _value, "ERC20:EA"); // exceed allowance
        unchecked {
            _approve(_from, _msgSender(), currentAllowance - _value);
        }

        _transfer(_from, _to, _value);
        return true;
    }

    /// @dev overrides transfer function to meet tokenomics of SIP
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override {
        require(amount > 0, "SIP:AO"); // amount is zero

        if (recipient == BURN_ADDRESS) {
            // Burn all the amount
            super._burn(sender, amount);
            _burntAmount += amount;
            return;
        }

        if (_isEnableBP && _bpAddr != address(0x0)) {
            IBotPrevention(_bpAddr).protect(sender, recipient, amount);
        }

        if (_excludedTax[sender]) {
            // Transfer all the amount
            super._transfer(sender, recipient, amount);
            return;
        }

        if (_isPair[recipient] && _feeKeeper != address(0x0)) {
            uint256 taxAmount = (amount * _tax) / 10000; // 100%
            super._transfer(sender, _feeKeeper, taxAmount);
            amount = amount - taxAmount;
        }

        // Transfer all the amount
        super._transfer(sender, recipient, amount);
    }
}
