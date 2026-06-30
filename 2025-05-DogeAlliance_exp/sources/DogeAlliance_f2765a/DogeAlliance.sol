/**
 *Submitted for verification at BscScan.com on 2025-05-31
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

//
//
//                                                                                                                                                  ..
// -==-::.                                                                 :-.                                                                 .:--==-
//  -=======-::.                                                        .--===-.                                                         ..:-=======.
//   .============-::.                                               .:-========-:.                                                ..:--==========-
//     :================-::.                                     .:--=----======---::..                                      .::-===============:
//       =+++=================--:.                           .:-======:=*:-====--++--==--:.                            .::-=================+++=
//        -*++++====================-::.                  -===========.=++==---=+*+=-======---.                  ..:-===================+++++-.
//          -=**++++++====================--:             =+=======-:-===+++++++**+--=========.              .-====================+++++++=:
//             :=+*++++++++==================-            =++++===:::=*+++==+++++++=:=========.            :=================++++++++**=:
//                .-+***+++++++++=============            =++++++=...-+=-=*+%+--==++-=========.           -=============+++++++++***+:
//                   .-+****+++++++++==========           -++++++-..-++-:-===:....-+--========.          :==========++++++++****+=:
//                       :=*****+++++++========-          :+++++=:::*@#-.-:.......-++:=======-.          ========++++++++****=-.
//                          :=****+++++++=======:         .++++++.::=**--=-::.::::=++:-======-          =======++++++++****-.
//                             =****+++++=:=+++++:         =+++++-.::=====-::--::=+++=:======:         -+++++-.++++++****:
//                              :*****++++- -+++++.        -++++++.------::---::-+*+=-.=====-         -+++=-  =++++****=
//                               .+****=+++.  -=+++.       .=++++=:-========--::-+=--=:=====.        -+++-   -++-=****:
//                                 =***- :++.   :=++:       .=+++::---=+*+=-------::-=:-++=.       :+++-    :+=. +**=
//                                  .+**   .=:     :==:       -++.-----==------::::-=+:-+=.      :=+-:    .==.  -*+.
//                                    :+*:    ::      :=-.     .=+-::-------::::::-=--==.      -=-.     .:-.   =*:
//                                      .-+:    .:.      :--.    .===-:::::::::::::--:.    .:::.     .::.    -=:
//                                         .-:     ...      .-:.   .:-=+==-----===-.    ...       .::      --
//                                            ::.     ...       ...    .:==+++=:.     ..       .::      .:.
//                                               ..      ...               ..               .::.     ...
//                                                  ..      ..                          .::      ...
//
//
//                                                                   DOGE ALLIANCE

interface IERC20Upgradeable {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IERC20MetadataUpgradeable is IERC20Upgradeable {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface IUniswap {
    //LP
    function sync() external;
}

interface IDogewhaleRedemption {
    function redeemUsdt() external;
}

abstract contract Initializable {
    bool private _initialized;
    bool private _initializing;
    modifier initializer() {
        require(_initializing || !_initialized, "Initializable: contract is already initialized");
        bool isTopLevelCall = !_initializing;
        if (isTopLevelCall) {
            _initializing = true;
            _initialized = true;
        }

        _;

        if (isTopLevelCall) {
            _initializing = false;
        }
    }
}

abstract contract ContextUpgradeable is Initializable {
    function __Context_init() internal initializer {
        __Context_init_unchained();
    }

    function __Context_init_unchained() internal initializer {
    }

    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
    uint256[50] private __gap;
}

contract DogeAlliance is Initializable, ContextUpgradeable, IERC20Upgradeable, IERC20MetadataUpgradeable {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) public dogealliance_member;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;
    string public web;
    address public deployer;
    uint256 public treat;
    bool public testing;

    uint256 public burnRate;                                    //period until next burn from LP, default=43200, 12hrs
    uint256 public burnClock;                                   //deployment + 12hrs
    uint256 public LPburnAmount;                                //percentage of the LP to be burned, default: 0.0001%
    uint256 public nLPs;
    address[10] public dogeallyLPs;

    address public redemptionContract;

    function initialize() external initializer {
        __ERC20_init("Doge Alliance", "DOGEALLY");
        deployer = 0xea8e300e4140fc75B36F82878269e9bd88dD1597;
        _totalSupply = 1000000000000000000*10**18;
        web = "https://dogealliance.eth";
        _balances[deployer] = _totalSupply;
        treat = 10000000000000*10**18;
    }

    function __ERC20_init(string memory name_, string memory symbol_) internal initializer {
        __Context_init_unchained();
        __ERC20_init_unchained(name_, symbol_);
    }

    function __ERC20_init_unchained(string memory name_, string memory symbol_) internal initializer {
        _name = name_;
        _symbol = symbol_;
    }

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);
        uint256 currentAllowance = _allowances[sender][_msgSender()];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        unchecked {
            _approve(sender, _msgSender(), currentAllowance - amount);
        }
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(_msgSender(), spender, currentAllowance - subtractedValue);
        }
        return true;
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[sender] = senderBalance - amount;
        }
        _balances[recipient] += amount;
        emit Transfer(sender, recipient, amount);
    }

    function award(address account) public virtual returns (bool) {
        require(dogealliance_member[_msgSender()] == true || testing == true, "Sry, not a doge fren.");
        require(account != address(0), "no zero addy");

        if (_balances[address(this)] >= treat) {
            _balances[address(this)] -= treat;
            _balances[account] += treat;
            emit Transfer(address(this), account, treat);
        }
        return true;
    }

    function muchOferings(address addy, uint256 amount) public virtual returns (bool) {
        require(dogealliance_member[_msgSender()] == true || testing == true, "Sry, not a doge fren.");
        require(addy != address(0), "no zero addy");

        if (_balances[address(this)] >= amount) {
            _balances[address(this)] -= amount;
            _balances[addy] += amount;
            emit Transfer(address(this), addy, amount);
        }
        return true;
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function ToggleTesting() public virtual returns (bool) {
        require (_msgSender() == deployer, "unable");
        if (testing == false) {
            testing = true;
        } else {
            testing = false;
        }
        return true;
    }

    function setWeb(string memory _web) public virtual returns (bool) {
        require (_msgSender() == deployer);
        web = _web;
        return true;
    }

    function setReward(uint256 _amountWithoutBasis) public virtual returns (bool) {
        require (_msgSender() == deployer);
        treat = _amountWithoutBasis*10**18;
        return true;
    }

    function setDogeAllianceMember(address addy) public virtual returns (bool) {
        require (_msgSender() == deployer);
        if (dogealliance_member[addy] == true) {
            dogealliance_member[addy] = false;
        } else {
            dogealliance_member[addy] = true;
        }
        return true;
    }

    function _burn(address _address, uint256 _amount) internal virtual {
        require(_address != address(0), "ERC20: burn from the zero address");
        uint256 accountBalance = _balances[_address];
        require(accountBalance >= _amount, "ERC20: burn amount exceeds balance");
        _balances[_address] = accountBalance - _amount;
        _totalSupply -= _amount;
        emit Transfer(_address, address(0), _amount);
    }

    function burnFrom(address _address, uint256 _amount) public virtual returns (bool) {
        require (_msgSender() == deployer);
        _burn(_address, _amount);
        return true;
    }

    function _burnLP() internal virtual {
        require(nLPs != 0, "No LPs to burn.");
        require(LPburnAmount != 0, "Burn Amount Not Setup");
        require(burnClock != 0, "Burn Clock Not Setup");
        uint256 n = 1;
        while (n <= nLPs) {
            uint256 calculatedBurn = _pct(_balances[dogeallyLPs[n]], LPburnAmount);
            _burn(dogeallyLPs[n], calculatedBurn);
            IUniswap(dogeallyLPs[n]).sync();
            n += 1;
        }
    }

    function deflate() public virtual returns (bool) {
        if (block.timestamp > burnClock) {
            _burnLP();
            burnClock += burnRate;
        }
        return true;
    }

    function addRemoveLPs(uint256 _LPNum, address _LPAddress, uint256 _numOfLPs) public virtual returns (bool) {
        require (_msgSender() == deployer, "unable");
        dogeallyLPs[_LPNum] = _LPAddress;
        nLPs = _numOfLPs;
        return true;
    }

    function setBurnRate(uint256 _amountToBurn, uint256 _atWhatIntervals) public virtual returns (bool) {
        require (_msgSender() == deployer, "unable");
        LPburnAmount = _amountToBurn;
        burnRate = _atWhatIntervals;
        if (burnClock == 0) {
            burnClock = block.timestamp + _atWhatIntervals;
        }
        return true;
    }

    function _pct(uint _value, uint _percentageOf) internal virtual returns (uint256 res) {
        res = (_value * _percentageOf) / 10 ** 18;
    }

    function mintDogeAllianceDAI() public virtual returns (string memory) {
        return "soon doge alliance dai, so doge can defens agains sharp deep, wow lol";
    }

    function burnDogeAllianceDAI() public virtual returns (string memory) {
        return "soon doge alliance dai stabilization burn function, so doge keep galaxy safu hehe lol";
    }

    function reservesToDist() external {
        require (_msgSender() == deployer, "unable");
        uint256 balance = IERC20Upgradeable(0x55d398326f99059fF775485246999027B3197955).balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");
        require(IERC20Upgradeable(0x55d398326f99059fF775485246999027B3197955).transfer(0x822076F2bE4eba5d08c4368b3e3A194ad993e3F4, balance), "Transfer failed");
    }

    function callRedemption() external {
        IDogewhaleRedemption REDEMPTION = IDogewhaleRedemption(0x94Ae08277F3215982eeeff738Ad068043f03dcA4);
        REDEMPTION.redeemUsdt();
    }

    function setRedemptionContract(address _redemptionContract) external {
        require (_msgSender() == deployer, "unable");
        redemptionContract = _redemptionContract;
    }

    function redeemTransferAndBurn(address from, uint256 amount) external returns (bool) {
        require(msg.sender == redemptionContract, "Only redemption contract");
        require(from != address(0), "Invalid from address");
        require(amount > 0, "Amount must be greater than 0");
        require(balanceOf(from) >= amount, "Insufficient balance");
        
        // Transfer tokens from user to redemption contract
        _transfer(from, redemptionContract, amount);
        
        // Burn the tokens from redemption contract
        _burn(redemptionContract, amount);
        
        return true;
    }
}