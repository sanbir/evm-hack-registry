// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Radiant UniV3PoolHelper.zapWETH — no approval to UniV3TokenizedLp
    (Pashov Audit Group, Radiant June review, finding C-01).

    SYNTHETIC, cheatcode-free reduction. zapWETH pulls WETH into the helper,
    then calls TokenizedLp.deposit. deposit pulls that WETH with transferFrom.
    The helper never approves TokenizedLp, so the pull reverts and the whole
    zap rolls back. The caller's WETH stays put and no LP is minted.
    The control approves TokenizedLp and the caller receives the LP. */

interface IERC20 {
    function safeTransferFrom(address from, address to, uint256 amount) external;
}

contract Weth is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function safeTransferFrom(address from, address to, uint256 amount) external {
        _pull(from, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _pull(from, to, amount);
        return true;
    }

    function _pull(address from, address to, uint256 amount) internal {
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract TokenizedLp {
    Weth public weth;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(Weth weth_) {
        weth = weth_;
    }

    function deposit(uint256 token0Amt, uint256 token1Amt, address to) external returns (uint256 liquidity) {
        uint256 amount = token0Amt + token1Amt;
        weth.transferFrom(msg.sender, address(this), amount);
        liquidity = amount;
        balanceOf[to] += liquidity;
        totalSupply += liquidity;
    }
}

contract Helper {
    Weth public weth;
    TokenizedLp public tokenizedLpToken;
    address public weth9Addr;
    address public token0;
    address public token1;
    address public lockZap;

    modifier onlyLockZap() {
        require(msg.sender == lockZap, "lock");
        _;
    }

    constructor(Weth weth_, TokenizedLp lp_, address lockZap_) {
        weth = weth_;
        tokenizedLpToken = lp_;
        weth9Addr = address(weth_);
        token0 = address(weth_);
        token1 = address(1);
        lockZap = lockZap_;
    }

    function zapWETH(uint256 amount) public virtual onlyLockZap returns (uint256 liquidity) {
        IERC20(weth9Addr).safeTransferFrom(msg.sender, address(this), amount);
        uint256 token0Amt = token0 == weth9Addr ? amount : 0;
        uint256 token1Amt = token1 == weth9Addr ? amount : 0;
        // @> VULN: helper never approves tokenizedLpToken, so deposit's transferFrom reverts
        liquidity = tokenizedLpToken.deposit(token0Amt, token1Amt, msg.sender);
        // FIX: weth.approve(address(tokenizedLpToken), amount) before deposit
    }

    function allowanceToLp() external view returns (uint256) {
        return weth.allowance(address(this), address(tokenizedLpToken));
    }
}

contract HelperFixed is Helper {
    constructor(Weth weth_, TokenizedLp lp_, address lockZap_) Helper(weth_, lp_, lockZap_) {}

    function zapWETH(uint256 amount) public override onlyLockZap returns (uint256 liquidity) {
        IERC20(weth9Addr).safeTransferFrom(msg.sender, address(this), amount);
        weth.approve(address(tokenizedLpToken), amount);
        uint256 token0Amt = token0 == weth9Addr ? amount : 0;
        uint256 token1Amt = token1 == weth9Addr ? amount : 0;
        liquidity = tokenizedLpToken.deposit(token0Amt, token1Amt, msg.sender);
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 100 ether;

    Weth public weth;
    TokenizedLp public lp;
    Helper public helper;
    bool public zapReverted;
    uint256 public kept;
    uint256 public lpMinted;

    constructor() {
        weth = new Weth();
        lp = new TokenizedLp(weth);
        helper = new Helper(weth, lp, address(this));
    }

    function run() external {
        weth.mint(address(this), AMOUNT);
        weth.approve(address(helper), AMOUNT);
        try helper.zapWETH(AMOUNT) returns (uint256) {
            zapReverted = false;
        } catch {
            zapReverted = true;
        }
        kept = weth.balanceOf(address(this));
        lpMinted = lp.balanceOf(address(this));
        require(zapReverted, "zap");
        require(helper.allowanceToLp() == 0, "approval");
        require(kept == AMOUNT, "stayed");
        require(weth.balanceOf(address(helper)) == 0, "helper");
        require(lpMinted == 0, "lp");
    }
}
