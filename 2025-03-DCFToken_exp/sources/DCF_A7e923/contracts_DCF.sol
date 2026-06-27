// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract LiquidityHelper is Ownable {
    IUniswapV2Router02 public uniswapV2Router;
    address public token;
    address public DCT = 0x56f46bD073E9978Eb6984C0c3e5c661407c3A447;
    address public USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address private liquidityReceiveAddress;

    constructor(
        address _token,
        address _liquidityReceiveAddress
    ) {
        // initiate router
        uniswapV2Router = IUniswapV2Router02(router);
        token = _token;
        liquidityReceiveAddress = _liquidityReceiveAddress;
        router = address(uniswapV2Router);
    }

    function addLiquidity(uint256 _usdtAmount) external onlyOwner {
        uint256 half = _usdtAmount / 2;
        uint256 otherHalf = _usdtAmount - half;

        uint256 initialDcfBalance = ERC20(DCT).balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = DCT;
        ERC20(USDT).approve(router, half);
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            half,
            0,
            path,
            address(this),
            block.timestamp
        );
        uint256 newDctBalance = ERC20(DCT).balanceOf(address(this)) -
            initialDcfBalance;

        ERC20(DCT).approve(router, newDctBalance);
        ERC20(USDT).approve(router, otherHalf);
        uniswapV2Router.addLiquidity(
            USDT,
            DCT,
            otherHalf,
            newDctBalance,
            0,
            0,
            liquidityReceiveAddress,
            block.timestamp
        );
    }

    function withdrawToken(address _token, address _account) public onlyOwner {
        uint256 bal = IERC20(_token).balanceOf(address(this));
        require(bal > 0);
        IERC20(_token).transfer(_account, bal);
    }

    function setLiquidityReceiveAddress(address _addr) public onlyOwner {
        liquidityReceiveAddress = _addr;
    }
}

contract DCF is ERC20, Ownable {
    LiquidityHelper private liquidityHelper;
    IUniswapV2Router02 public uniswapV2Router;

    address public pairAddress;
    address public helperAddress;
    address public router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public USDT = 0x55d398326f99059fF775485246999027B3197955;

    uint256 deadCfg = 2;
    bool private swapping;
    uint256 private initTime;
    uint256 distributeAmount = 2000 * 1e18;

    address private cfo;
    address private distributeAddress;
    address private rewardAddress;
    address private liquidityReceiveAddress;
    mapping(address => bool) private whiteAddress;
    mapping(address => bool) private blackAddress;

    constructor(address _liquidityReceiveAddress) ERC20("DCF Token", "DCF") {
        uint256 initialSupply = 2000000 * 1e18;
        _mint(_msgSender(), initialSupply);
        // initiate router
        uniswapV2Router = IUniswapV2Router02(router);
        // initialize liquidity helper
        liquidityHelper = new LiquidityHelper(
            address(this),
            _liquidityReceiveAddress
        );
        // create lp address
        pairAddress = IUniswapV2Factory(uniswapV2Router.factory()).createPair(
            USDT,
            address(this)
        );
        router = address(uniswapV2Router);
        helperAddress = address(liquidityHelper);
        liquidityReceiveAddress = _liquidityReceiveAddress;
        whiteAddress[msg.sender] = true;
        whiteAddress[address(this)] = true;
        whiteAddress[_liquidityReceiveAddress] = true;
    }

    modifier onlyCaller() {
        require(_msgSender() == cfo, "onlyCaller");
        _;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(
            !blackAddress[from] || !blackAddress[to],
            "black address not transfer"
        );

        if (amount == 0 || whiteAddress[from] || whiteAddress[to]) {
            super._transfer(from, to, amount);
            return;
        }

        // buying restriction
        if (from == pairAddress) {
            require(false, "buy error");
        }

        // swap token for usdt
        if (to == pairAddress && !swapping) {
            swapping = true;
            uint256 fee = (amount * 5) / 100; // 5%
            uint256 deadAmount = (amount - fee) / deadCfg;
            amount -= fee;
            super._transfer(from, address(this), fee);

            uint256 initialUsdtBalance = IERC20(USDT).balanceOf(helperAddress);
            swapTokensForUSDT(fee, helperAddress);
            uint256 newUsdtBalance = IERC20(USDT).balanceOf(helperAddress) -
                initialUsdtBalance;
            liquidityHelper.addLiquidity(newUsdtBalance);
            swapping = false;
            if (balanceOf(pairAddress) > deadAmount) {
                burnPair(deadAmount);
            }
        }

        // proceed transfer
        super._transfer(from, to, amount);
    }

    function swapTokensForUSDT(uint256 _tokenAmount, address _to) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = USDT;
        _approve(address(this), router, _tokenAmount);
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _tokenAmount,
            0,
            path,
            _to,
            block.timestamp
        );
    }

    function burnPair(uint256 _deadAmount) private {
        if (_deadAmount > 0) {
            _burn(pairAddress, _deadAmount);
        }
        IUniswapV2Pair(pairAddress).sync();
    }

    function distributeTokenPeriodic() public {
        uint256 nowTime = block.timestamp;
        require(nowTime > initTime, "Not within the execution time range");
        initTime = nowTime + 64800;
        // distribute
        uint256 balance = balanceOf(address(this));
        require(
            distributeAddress != address(0),
            "distribute address is not set"
        );
        require(balance >= distributeAmount, "Insufficient token balance");
        super._transfer(address(this), distributeAddress, distributeAmount);
    }

    function distributeToken() public onlyCaller {
        uint256 balance = balanceOf(address(this));
        require(
            distributeAddress != address(0),
            "distribute address is not set"
        );
        require(balance >= distributeAmount, "Insufficient token balance");
        super._transfer(address(this), distributeAddress, distributeAmount);
    }

    function setDistributeAddress(
        address _addr
    ) public onlyCaller {
        distributeAddress = _addr;
    }

    function withdrawHelperToken(
        address _token,
        address _account
    ) public onlyCaller {
        liquidityHelper.withdrawToken(_token, _account);
    }

    function setLiquidityReceiveAddress(address _addr) public onlyCaller {
        whiteAddress[_addr] = true;
        liquidityReceiveAddress = _addr;
        liquidityHelper.setLiquidityReceiveAddress(_addr);
    }

    function setWhite(address _addr, bool _status) public onlyCaller {
        whiteAddress[_addr] = _status;
    }

    function setWhiteBulk(
        address[] memory _addr,
        bool _status
    ) public onlyCaller {
        for (uint i = 0; i < _addr.length; i++) {
            whiteAddress[_addr[i]] = _status;
        }
    }

    function setBlack(address _addr, bool status) public onlyCaller {
        blackAddress[_addr] = status;
    }

    function setBlackBulk(
        address[] memory _addr,
        bool status
    ) public onlyCaller {
        for (uint i = 0; i < _addr.length; i++) {
            blackAddress[_addr[i]] = status;
        }
    }

    function setCaller(address _cfo) public onlyOwner {
        require(_cfo != address(0));
        cfo = _cfo;
    }

    function setCfg(uint256 _deadCfg) public onlyCaller {
        require(_deadCfg > 0);
        deadCfg = _deadCfg;
    }
}
