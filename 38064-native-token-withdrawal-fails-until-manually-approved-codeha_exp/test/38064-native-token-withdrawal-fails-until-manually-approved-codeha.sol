// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Tadle TokenManager — CodeHawks.
    _transfer asks the capital pool to approve address(this), the token manager,
    instead of the token. CapitalPool.approve then calls approve on a contract
    that is not an ERC-20 and reverts ApproveFailed. The maker refund stays in
    the pool. Approving the token address lets the same withdrawal pay out.
*/

contract Token {
    string public symbol = "WETH";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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

contract CapitalPool {
    address public tokenManager;

    function setManager(address mgr) external {
        tokenManager = mgr;
    }

    function approve(address token) external {
        require(msg.sender == tokenManager, "mgr");
        (bool ok,) = token.call(
            abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), tokenManager, type(uint256).max)
        );
        require(ok, "ApproveFailed");
    }
}

contract TokenManager {
    Token public token;
    CapitalPool public pool;
    mapping(address => uint256) public makerRefund;

    constructor(Token _token, CapitalPool _pool) {
        token = _token;
        pool = _pool;
    }

    function credit(address user, uint256 amount) external {
        require(token.transferFrom(msg.sender, address(pool), amount), "pull");
        makerRefund[user] += amount;
    }

    function _transfer(address _token, address _from, address _to, uint256 _amount, address _capitalPoolAddr)
        internal
    {
        uint256 fromBalanceBef = Token(_token).balanceOf(_from);
        uint256 toBalanceBef = Token(_token).balanceOf(_to);
        if (_from == _capitalPoolAddr && Token(_token).allowance(_from, address(this)) == 0) {
            // @> VULN: CapitalPool.approve is given the token manager, not the token, so the inner approve reverts
            CapitalPool(_capitalPoolAddr).approve(address(this));
        }
        require(fromBalanceBef >= _amount && toBalanceBef == toBalanceBef, "snap");
        require(Token(_token).transferFrom(_from, _to, _amount), "move");
    }

    function withdraw(address _token) external {
        uint256 amount = makerRefund[msg.sender];
        require(amount > 0, "none");
        makerRefund[msg.sender] = 0;
        _transfer(_token, address(pool), msg.sender, amount, address(pool));
    }
}

contract TokenManagerFixed {
    Token public token;
    CapitalPool public pool;
    mapping(address => uint256) public makerRefund;

    constructor(Token _token, CapitalPool _pool) {
        token = _token;
        pool = _pool;
    }

    function credit(address user, uint256 amount) external {
        require(token.transferFrom(msg.sender, address(pool), amount), "pull");
        makerRefund[user] += amount;
    }

    function withdraw(address _token) external {
        uint256 amount = makerRefund[msg.sender];
        makerRefund[msg.sender] = 0;
        if (Token(_token).allowance(address(pool), address(this)) == 0) {
            pool.approve(_token);
        }
        require(Token(_token).transferFrom(address(pool), msg.sender, amount), "move");
    }
}

contract Exploit {
    uint256 public constant REFUND = 1000 ether;

    Token public token;
    CapitalPool public pool;
    TokenManager public mgr;
    bool public withdrawReverted;
    uint256 public stuck;

    constructor() {
        token = new Token();
        pool = new CapitalPool();
        mgr = new TokenManager(token, pool);
        pool.setManager(address(mgr));
    }

    function run() external {
        token.mint(address(this), REFUND);
        token.approve(address(mgr), REFUND);
        mgr.credit(address(this), REFUND);
        (bool ok,) = address(mgr).call(abi.encodeWithSelector(mgr.withdraw.selector, address(token)));
        withdrawReverted = !ok;
        stuck = token.balanceOf(address(pool));
        require(withdrawReverted, "paid");
        require(token.balanceOf(address(this)) == 0, "user");
        require(stuck == REFUND, "stuck");
        require(mgr.makerRefund(address(this)) == REFUND, "credited");
    }
}
