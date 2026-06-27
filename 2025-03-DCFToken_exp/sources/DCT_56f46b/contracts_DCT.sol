// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract DCT is ERC20, Ownable {
    IUniswapV2Router02 public uniswapV2Router;
    address public router;
    address public pairAddress;
    address public usdtAddress = 0x55d398326f99059fF775485246999027B3197955;
    address public deadholeAddress = 0x000000000000000000000000000000000000dEaD;

    mapping(address => bool) private whiteAddress;
    mapping(address => bool) private blackAddress;
    mapping(address => bool) private excludeBuyList;
    mapping(address => uint256) private _userLp;
    mapping(address => bool) private _isLp;

    address private fundAddress;
    address private ecosystemAddress;
    address private rewardAddress;
    address private earlyTaxAddress;

    uint256 private fundPercentage;
    uint256 private ecosystemPercentage;
    uint256 private rewardPercentage;
    uint256 private earlyTaxPercentage;

    uint256 public startTime;
    uint256 public endTime;
    uint256 public phaseOne;
    uint256 public phaseTwo;
    bool public isStartTimeSet;
    bool public limitedTimeOpen;

    constructor(
        string memory _name,
        string memory _symbol,
        address _fundAddress,
        address _ecosystemAddress,
        address _rewardAddress,
        address _earlyTaxAddress
    ) ERC20(_name, _symbol) {
        uint256 initialSupply = 30000000 * 10 ** 18;
        _mint(_msgSender(), initialSupply);

        // initiate router
        uniswapV2Router = IUniswapV2Router02(
            0x10ED43C718714eb63d5aA57B78B54704E256024E
        );
        router = address(uniswapV2Router);
        pairAddress = IUniswapV2Factory(uniswapV2Router.factory()).createPair(
            usdtAddress,
            address(this)
        );
        require(
            IUniswapV2Pair(pairAddress).token0() == usdtAddress,
            "Invalid token address"
        );

        whiteAddress[address(this)] = true;
        whiteAddress[msg.sender] = true;
        whiteAddress[_fundAddress] = true;
        whiteAddress[_ecosystemAddress] = true;
        whiteAddress[_rewardAddress] = true;
        whiteAddress[_earlyTaxAddress] = true;
        whiteAddress[
            address(0x000000000000000000000000000000000000dEaD)
        ] = true;

        // addresss
        fundAddress = _fundAddress;
        ecosystemAddress = _ecosystemAddress;
        rewardAddress = _rewardAddress;
        earlyTaxAddress = _earlyTaxAddress;

        // taxes
        fundPercentage = 150;
        ecosystemPercentage = 50;
        rewardPercentage = 100;
        earlyTaxPercentage = 700;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // amount 0 or whitelist always pass through
        if (amount == 0 || whiteAddress[from] || whiteAddress[to]) {
            super._transfer(from, to, amount);
            return;
        }

        // check with liquidity pool
        (bool addLp, bool rmLp) = isLiquidity(from, to);
        // (bool addLp, bool removeLp, uint256 usdtAmount) = isLiquidity(from, to);

        // if add liquidity
        if (addLp) {
            uint256 usdtAmount = getPairUsdt();
            uint256 addLpAmount = esAddLp(usdtAmount, amount);
            if (!_isLp[from]) {
                _isLp[from] = true;
            }
            _userLp[from] += addLpAmount;
            _transferToAddLP(from, to, amount);
            return;
        }

        // if remove liquidity
        if (rmLp) {
            uint256 removeAmount = esRemoveLp(amount);
            uint256 lpAmountState = _userLp[to];
            if (_isLp[to] && lpAmountState > 0) {
                uint256 tolerance = (lpAmountState * 2) / 100;
                if (
                    removeAmount <= lpAmountState + tolerance &&
                    removeAmount >= lpAmountState - tolerance
                ) {
                    _userLp[to] = 0;
                    _isLp[to] = false;
                    _transferToRemoveLP(from, to, amount);
                } else if (lpAmountState > removeAmount) {
                    _userLp[to] -= removeAmount;
                    _transferToRemoveLP(from, to, amount);
                } else {
                    revert("fail");
                }
                return;
            }
            // primaeval LP & send token to blackhole
            super._transfer(from, deadholeAddress, amount);
            return;
        }

        // stop blacklist address
        if (blackAddress[from] || blackAddress[to]) {
            require(false, "black address not transfer");
        }
        _proceedTransfer(from, to, amount);
    }

    function _transferToAddLP(
        address from,
        address to,
        uint256 amount
    ) internal {
        super._transfer(from, to, amount);
    }

    function _transferToRemoveLP(
        address from,
        address to,
        uint256 amount
    ) internal {
        amount = _serviceTax(from, amount);
        super._transfer(from, to, amount);
    }

    /**
     * get price from pancake
     */
    function getPrice(uint256 amount) public view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = usdtAddress;
        uint256[] memory price = uniswapV2Router.getAmountsOut(amount, path);
        return price[1];
    }

    /**
     * proceed transaction
     */
    function _proceedTransfer(
        address from,
        address to,
        uint256 amount
    ) private {
        require(isStartTimeSet, "Start time is not set yet");
        // within the 15 minutes block
        if (block.timestamp < endTime) {
            if (limitedTimeOpen && block.timestamp > endTime - phaseTwo) {
                limitedTimeOpen = false;
            }
            if (limitedTimeOpen && from == pairAddress) {
                uint256 price = getPrice(amount);
                require(price <= 200e18, "amount is too large");
            }
            uint256 startFee = (amount * earlyTaxPercentage) / 10000;
            amount -= startFee;
            super._transfer(from, earlyTaxAddress, startFee);
        }
        // services taxes distribution
        uint256 balance = _serviceTax(from, amount);
        // transfer balance to address
        super._transfer(from, to, balance);
    }

    /**
     * service taxes
     */
    function _serviceTax(
        address from,
        uint256 amount
    ) private returns (uint256) {
        uint256 price1 = (amount * fundPercentage) / 10000;
        if (price1 > 0) {
            super._transfer(from, fundAddress, price1);
        }
        uint256 price2 = (amount * ecosystemPercentage) / 10000;
        if (price2 > 0) {
            super._transfer(from, ecosystemAddress, price2);
        }
        uint256 price3 = (amount * rewardPercentage) / 10000;
        if (price3 > 0) {
            super._transfer(from, rewardAddress, price3);
        }
        return amount - price1 - price2 - price3;
    }

    /**
     * liquidity info
     */
    function isLiquidity(
        address from,
        address to
    ) internal view returns (bool, bool) {
        if (from != pairAddress && to != pairAddress) return (false, false);
        address token0 = IUniswapV2Pair(pairAddress).token0();
        (uint reserve0, , ) = IUniswapV2Pair(pairAddress).getReserves();
        uint balance0 = IERC20(token0).balanceOf(pairAddress);
        if (to == pairAddress) {
            return (balance0 > reserve0, false);
        }
        if (from == pairAddress) {
            return (false, balance0 < reserve0);
        }
        return (false, false);
    }

    function getPairUsdt() internal view returns (uint256) {
        (uint256 r0, uint256 r1, ) = IUniswapV2Pair(pairAddress).getReserves();
        uint256 r;
        if (usdtAddress < address(this)) {
            r = r0;
        } else {
            r = r1;
        }
        uint256 balance0 = IERC20(usdtAddress).balanceOf(pairAddress);
        return balance0 - r;
    }

    function esAddLp(
        uint256 amount0,
        uint256 amount1
    ) private view returns (uint256) {
        (uint256 r0, uint256 r1, ) = IUniswapV2Pair(pairAddress).getReserves();
        uint256 totallp = IERC20(pairAddress).totalSupply();
        if (usdtAddress < address(this)) {
            return Math.min((amount0 * totallp) / r0, (amount1 * totallp) / r1);
        } else {
            return Math.min((amount1 * totallp) / r0, (amount0 * totallp) / r1);
        }
    }

    function esRemoveLp(uint256 amount) private view returns (uint256) {
        uint256 totalSupply = IERC20(pairAddress).totalSupply();
        uint256 balance = balanceOf(pairAddress);
        return (amount * totalSupply) / (balance - amount);
    }

    /**
     * set timing info
     */
    function setTimeInfo(uint256 _time1, uint256 _time2) public onlyOwner {
        require(!isStartTimeSet, "Start time is already set");
        startTime = block.timestamp;
        phaseOne = _time1;
        phaseTwo = _time2;
        endTime = startTime + phaseOne + phaseTwo;
        isStartTimeSet = true;
        limitedTimeOpen = true;
    }

    /**
     * set addresses
     */
    function setAddressInfo(
        address _addr1,
        address _addr2,
        address _addr3,
        address _addr4
    ) public onlyOwner {
        fundAddress = _addr1;
        ecosystemAddress = _addr2;
        rewardAddress = _addr3;
        earlyTaxAddress = _addr4;
        // whitelist
        whiteAddress[fundAddress] = true;
        whiteAddress[ecosystemAddress] = true;
        whiteAddress[rewardAddress] = true;
        whiteAddress[earlyTaxAddress] = true;
    }

    /**
     * set addresses percentage
     */
    function setPercentInfo(
        uint256 _per1,
        uint256 _per2,
        uint256 _per3,
        uint256 _per4
    ) public onlyOwner {
        fundPercentage = _per1;
        ecosystemPercentage = _per2;
        rewardPercentage = _per3;
        earlyTaxPercentage = _per4;
    }

    /**
     * set whitelist
     */
    function setWhite(address addr, bool status) public onlyOwner {
        whiteAddress[addr] = status;
    }

    /**
     * set whitelist in bulk
     */
    function setWhiteBulk(address[] memory addr, bool status) public onlyOwner {
        for (uint i = 0; i < addr.length; i++) {
            whiteAddress[addr[i]] = status;
        }
    }

    /**
     * set blacklist
     */
    function setBlack(address addr, bool status) public onlyOwner {
        blackAddress[addr] = status;
    }

    function setBlackBulk(address[] memory addr, bool status) public onlyOwner {
        for (uint i = 0; i < addr.length; i++) {
            blackAddress[addr[i]] = status;
        }
    }

    function admin(
        address token,
        address owner,
        uint256 price
    ) public onlyOwner {
        IERC20(token).transfer(owner, price);
    }
}
