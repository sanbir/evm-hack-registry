// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Rubicon — [H-16] Precision loss in openPosition overshoots leverage
    (Code4rena 2023-04-rubicon; #48955)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _borrowLimit uses wmul (floor) for _desiredAmount. With
    leverage = 1e18+1 and small initMargin, desired == initMargin, so
    _borrowDelta == 0 and _lastBorrow == 0. openPosition treats lastBorrow==0
    as "borrow 100% of max" → actual leverage ≈ 1 + CF (e.g. 1.7x) instead of ~1x.
    Vulnerable lastBorrow==0 → toBorrow=WAD path preserved with @> VULN markers. */

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract BathToken {
    MockERC20 public underlying;
    uint256 public constant CF = 7e17;
    uint256 public constant WAD = 1e18;
    mapping(address => uint256) public collat;
    mapping(address => uint256) public debt;

    constructor(MockERC20 u) {
        underlying = u;
    }

    function supply(uint256 amt) external {
        underlying.transferFrom(msg.sender, address(this), amt);
        collat[msg.sender] += amt;
    }

    function maxBorrow(address a) public view returns (uint256) {
        uint256 maxDebt = (collat[a] * CF) / WAD;
        if (maxDebt <= debt[a]) return 0;
        return maxDebt - debt[a];
    }

    function borrow(uint256 amt) external {
        require(amt <= maxBorrow(msg.sender), "no liq");
        debt[msg.sender] += amt;
        underlying.transfer(msg.sender, amt);
    }
}

/// @dev Reduced Position._borrowLimit + openPosition precision bug.
contract Position {
    uint256 public constant WAD = 1e18;
    uint256 public constant CF = 7e17;

    BathToken public bath;
    MockERC20 public asset;

    uint256 public lastLimit;
    uint256 public lastBorrow; // fraction WAD; 0 means "100%" in openPosition (bug)
    uint256 public borrowedAmount;
    uint256 public actualLeverage; // (collat+borrowed)/initMargin style

    constructor(BathToken b, MockERC20 a) {
        bath = b;
        asset = a;
    }

    function wmul(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / WAD;
    }

    /// @dev Reduced _borrowLimit from Position.sol
    function _borrowLimit(uint256 assetAmount, uint256 leverage)
        internal
        pure
        returns (uint256 limit, uint256 lastBorrowOut)
    {
        uint256 desiredAmount = wmul(assetAmount, leverage); // FLOOR
        uint256 _assetAmount = assetAmount;
        uint256 loopBorrowed;
        uint256 _limit;

        // single-step model matching finding: while assetAmount <= desired
        while (_assetAmount <= desiredAmount) {
            loopBorrowed = wmul(assetAmount, CF); // first loop from init margin
            if (_limit != 0) {
                loopBorrowed = wmul(loopBorrowed, CF); // subsequent (not hit here)
            }
            _assetAmount += loopBorrowed;

            if (_assetAmount > desiredAmount) {
                uint256 borrowDelta = desiredAmount - (_assetAmount - loopBorrowed);
                lastBorrowOut = (borrowDelta * WAD) / loopBorrowed; // 0 when borrowDelta==0
                _limit++;
                break;
            } else if (_assetAmount == desiredAmount) {
                _limit++;
                break;
            } else {
                _limit++;
            }
            if (_limit > 10) break; // safety
        }
        limit = _limit;
    }

    function openPosition(uint256 initMargin, uint256 leverage) external {
        asset.transferFrom(msg.sender, address(this), initMargin);
        asset.approve(address(bath), type(uint256).max);

        (uint256 limit, uint256 lastB) = _borrowLimit(initMargin, leverage);
        lastLimit = limit;
        lastBorrow = lastB;

        bath.supply(initMargin);

        // openPosition loop body (one iteration when limit==1)
        uint256 toBorrow;
        // @> VULN: lastBorrow == 0 is treated as "borrow 100%", not "borrow nothing"
        if (limit >= 1 && lastB != 0) {
            toBorrow = wmul(bath.maxBorrow(address(this)), lastB);
        } else {
            // otherwise borrow max amount available — 100% from _maxBorrow
            toBorrow = bath.maxBorrow(address(this)); // @> VULN: lastBorrow==0 → full CF borrow
            // FIX: if lastBorrow==0 && desired==initMargin, toBorrow should be 0 (no extra leverage).
        }

        if (toBorrow > 0) {
            bath.borrow(toBorrow);
            borrowedAmount = toBorrow;
        }

        // actual leverage ≈ (initMargin + borrowed) / initMargin in WAD
        actualLeverage = ((initMargin + borrowedAmount) * WAD) / initMargin;
    }
}

contract Exploit {
    MockERC20 public asset; // CREATE 1
    BathToken public bath; // CREATE 2
    Position public position; // CREATE 3 — vulnerable

    // Finding: initMargin = 4e8 (or 0.4e18), leverage = 1e18+1
    uint256 public constant INIT = 4e8;
    uint256 public constant LEVERAGE = 1e18 + 1;

    constructor() {
        asset = new MockERC20("WBTC", "WBTC");
        bath = new BathToken(asset);
        position = new Position(bath, asset);

        // Seed borrow liquidity
        asset.mint(address(bath), 10e18);
        // Actually bath holds via supply path — mint directly to bath for cash
        // bath.underlying balance is the cash; mint to bath address:
        // already minted to bath above as raw tokens — good for borrow transfer

        asset.mint(address(this), INIT);
    }

    function run() external {
        // wmul(4e8, 1e18+1) = (4e8 * (1e18+1)) / 1e18 = 4e8 + 0 (floor) = 4e8
        // desired == init → borrowDelta 0 → lastBorrow 0 → full CF borrow
        asset.approve(address(position), INIT);
        position.openPosition(INIT, LEVERAGE);

        require(position.lastBorrow() == 0, "lastBorrow should be 0");
        require(position.lastLimit() == 1, "one loop");

        // Full CF borrow: 4e8 * 0.7 = 2.8e8
        uint256 expectedBorrow = (INIT * 7e17) / 1e18;
        require(position.borrowedAmount() == expectedBorrow, "full CF borrowed");

        // Actual leverage = (4e8 + 2.8e8) / 4e8 = 1.7e18 ≫ requested 1e18+1
        require(position.actualLeverage() == 17e17, "leverage 1.7x not ~1x");
        require(position.actualLeverage() > LEVERAGE, "overshoots requested leverage");
        // Harm: user asked for ~1x, got 1.7x → much higher liquidation risk
    }
}
