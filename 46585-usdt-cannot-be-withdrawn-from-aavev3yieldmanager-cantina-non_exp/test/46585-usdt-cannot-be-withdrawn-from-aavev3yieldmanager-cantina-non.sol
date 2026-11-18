// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Level Money — AaveV3YieldManager withdraw calls USDT.transfer through IERC20
    (Cantina, finding 46585). SYNTHETIC, cheatcode-free.
    USDT's transfer returns no bool. The ABI decode reverts, so 1000 USDT that
    the manager already holds cannot be sent to the withdrawer. (@> VULN) */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// USDT-shaped token: transfer moves balances and returns nothing.
contract NonReturningUSDT {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract AaveV3YieldManager {
    mapping(address => address) public underlyingToaToken;
    mapping(address => address) public tokenToWrapper;

    constructor(address usdt, address aToken, address wrapper) {
        underlyingToaToken[usdt] = aToken;
        tokenToWrapper[aToken] = wrapper;
    }

    uint256 public seenAToken;
    uint256 public seenWrapper;

    function withdraw(address token, uint256 amount) external {
        address aTokenAddress = underlyingToaToken[token];
        seenAToken = uint256(uint160(aTokenAddress)); // S2
        address wrapper = tokenToWrapper[aTokenAddress];
        seenWrapper = uint256(uint160(wrapper)); // S3
        uint256 bal = NonReturningUSDT(token).balanceOf(address(this)); // S4
        require(bal >= amount, "bal"); // S5
        IERC20(token).transfer(msg.sender, amount); // @> VULN: USDT.transfer returns no bool, so this ABI-decode reverts
        // FIX: SafeERC20.safeTransfer, which accepts an empty return
    }

    function withdrawSafe(address token, uint256 amount) external {
        uint256 bal = NonReturningUSDT(token).balanceOf(address(this));
        require(bal >= amount, "bal");
        NonReturningUSDT(token).transfer(msg.sender, amount);
    }
}

contract Exploit {
    NonReturningUSDT public usdt; // nonce 1
    AaveV3YieldManager public manager; // nonce 2

    uint256 public constant AMOUNT = 1000e6;

    constructor() {
        usdt = new NonReturningUSDT();
        manager = new AaveV3YieldManager(address(usdt), address(0xA11CE), address(0xB0B));
        usdt.mint(address(manager), AMOUNT);
    }

    function run() external {
        uint256 beforeBal = usdt.balanceOf(address(manager));
        (bool ok,) = address(manager).call(abi.encodeWithSignature("withdraw(address,uint256)", address(usdt), AMOUNT)); // S1
        require(!ok, "withdraw should revert"); // S6
        require(usdt.balanceOf(address(manager)) == beforeBal, "usdt left the manager");
        require(usdt.balanceOf(address(manager)) == AMOUNT, "1000 USDT stuck");
        require(usdt.balanceOf(address(this)) == 0, "user received nothing");
    }
}
