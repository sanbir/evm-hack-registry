// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Peapods LeverageManager — Sherlock H-6, contest 2025-01.
    removeLeverage swaps pTKN with the user's slippage floor instead of the
    exact repay shortfall. _borrowAmtRemaining ignores that extra output, so
    the surplus borrowed tokens stay in the manager.
*/

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public DEX_HANDLER;

    constructor(string memory sym) {
        symbol = sym;
    }

    function setDex(address dex) external {
        DEX_HANDLER = dex;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function safeIncreaseAllowance(address spender, uint256 amount) external {
        allowance[msg.sender][spender] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IDecentralizedIndex {
    function DEX_HANDLER() external view returns (address);
}

interface IDexAdapter {
    function swapV2SingleExactOut(address pod, address targetToken, uint256 podAmt, uint256 amountOut, address to) external;
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function safeIncreaseAllowance(address spender, uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract Dex {
    Token public borrowToken;

    constructor(Token _borrow) {
        borrowToken = _borrow;
    }

    function swapV2SingleExactOut(address pod, address, uint256, uint256 amountOut, address to) external {
        require(Token(pod).transferFrom(msg.sender, address(this), amountOut), "pod");
        require(borrowToken.transfer(to, amountOut), "borrow");
    }
}

contract LeverageManager {
    Token public pod;
    Token public borrowToken;
    Dex public dex;
    address public flashSource;

    event RemoveLeverage(uint256 positionId, address owner, uint256 collateralRemoved);

    constructor(Token _pod, Token _borrow, Dex _dex, address _flash) {
        pod = _pod;
        borrowToken = _borrow;
        dex = _dex;
        flashSource = _flash;
    }

    function _swapPodForBorrowToken(
        address _pod,
        address _targetToken,
        uint256 _podAmt,
        uint256 _targetNeededAmt,
        uint256 _podSwapAmtOutMin
    ) internal returns (uint256 _podRemainingAmt) {
        IDexAdapter _dexAdapter = IDexAdapter(IDecentralizedIndex(_pod).DEX_HANDLER());
        uint256 _balBefore = IERC20Like(_pod).balanceOf(address(this));
        IERC20Like(_pod).safeIncreaseAllowance(address(_dexAdapter), _podAmt);
        _dexAdapter.swapV2SingleExactOut(
            _pod, _targetToken, _podAmt, _podSwapAmtOutMin == 0 ? _targetNeededAmt : _podSwapAmtOutMin, address(this)
        );
        _podRemainingAmt = _podAmt - (_balBefore - IERC20Like(_pod).balanceOf(address(this)));
    }

    function removeLeverage(
        uint256 positionId,
        uint256 podAmt,
        uint256 pairedAmtReceived,
        uint256 repayAmount,
        uint256 podSwapAmtOutMin
    ) external returns (uint256 podAmtRemaining, uint256 borrowAmtRemaining) {
        require(pod.transferFrom(msg.sender, address(this), podAmt), "pod");
        require(borrowToken.transferFrom(msg.sender, address(this), pairedAmtReceived), "paired");
        if (pairedAmtReceived < repayAmount) {
            podAmtRemaining = _swapPodForBorrowToken(
                address(pod), address(borrowToken), podAmt, repayAmount - pairedAmtReceived, podSwapAmtOutMin
            );
        }
        require(borrowToken.transfer(flashSource, repayAmount), "repay");
        // @> VULN: surplus borrowed tokens from the slippage swap are not included, so they stay in the manager
        borrowAmtRemaining = pairedAmtReceived > repayAmount ? pairedAmtReceived - repayAmount : 0;
        if (borrowAmtRemaining > 0) require(borrowToken.transfer(msg.sender, borrowAmtRemaining), "dust");
        if (podAmtRemaining > 0) require(pod.transfer(msg.sender, podAmtRemaining), "pods");
        emit RemoveLeverage(positionId, msg.sender, podAmt);
    }
}

contract LeverageManagerFixed {
    Token public pod;
    Token public borrowToken;
    Dex public dex;
    address public flashSource;

    constructor(Token _pod, Token _borrow, Dex _dex, address _flash) {
        pod = _pod;
        borrowToken = _borrow;
        dex = _dex;
        flashSource = _flash;
    }

    function removeLeverage(uint256 podAmt, uint256 pairedAmtReceived, uint256 repayAmount, uint256 podSwapAmtOutMin)
        external
        returns (uint256 returnedBorrow)
    {
        require(pod.transferFrom(msg.sender, address(this), podAmt), "pod");
        require(borrowToken.transferFrom(msg.sender, address(this), pairedAmtReceived), "paired");
        uint256 amountOut = podSwapAmtOutMin == 0 ? repayAmount - pairedAmtReceived : podSwapAmtOutMin;
        pod.safeIncreaseAllowance(address(dex), podAmt);
        dex.swapV2SingleExactOut(address(pod), address(borrowToken), podAmt, amountOut, address(this));
        require(borrowToken.transfer(flashSource, repayAmount), "repay");
        returnedBorrow = borrowToken.balanceOf(address(this));
        if (returnedBorrow > 0) require(borrowToken.transfer(msg.sender, returnedBorrow), "back");
        uint256 podsLeft = pod.balanceOf(address(this));
        if (podsLeft > 0) require(pod.transfer(msg.sender, podsLeft), "pods");
    }
}

contract Exploit {
    uint256 public constant POD_AMT = 100 ether;
    uint256 public constant PAIRED = 100 ether;
    uint256 public constant REPAY = 120 ether;
    uint256 public constant MIN_OUT = 95 ether;
    address public constant FLASH = 0xF1a5111111111111111111111111111111111111;

    Token public pod;
    Token public borrowToken;
    Dex public dex;
    LeverageManager public manager;
    uint256 public stuck;
    uint256 public userBorrow;

    constructor() {
        pod = new Token("pTKN");
        borrowToken = new Token("BORROW");
        dex = new Dex(borrowToken);
        pod.setDex(address(dex));
        manager = new LeverageManager(pod, borrowToken, dex, FLASH);
    }

    function run() external {
        pod.mint(address(this), POD_AMT);
        borrowToken.mint(address(this), PAIRED);
        borrowToken.mint(address(dex), MIN_OUT);
        pod.approve(address(manager), POD_AMT);
        borrowToken.approve(address(manager), PAIRED);
        manager.removeLeverage(1, POD_AMT, PAIRED, REPAY, MIN_OUT);
        stuck = borrowToken.balanceOf(address(manager));
        userBorrow = borrowToken.balanceOf(address(this));
        require(stuck == 75 ether, "stuck");
        require(userBorrow == 0, "returned");
        require(borrowToken.balanceOf(FLASH) == REPAY, "flash");
    }
}
