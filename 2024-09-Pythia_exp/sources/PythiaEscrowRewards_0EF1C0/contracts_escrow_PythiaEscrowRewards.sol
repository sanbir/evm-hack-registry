// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./lib/FullMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PythiaEscrowRewards is Ownable {
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeERC20 for IERC20;

    struct Lock {
        uint256 id;
        address owner;
        uint256 amount;
        uint256 lockDate;
        uint256 unlockedAmount;
    }

    Lock[] private _locks;
    mapping(address => EnumerableSet.UintSet) private _userNormalLockIds;
    mapping(address => bool) private stakingContOnly;
    address public token;
    uint256 public vestedBps;
    uint256 public vestingCycle;

    event LockAdded(
        uint256 id,
        address lockedBy,
        address owner,
        uint256 amount
    );
    event LockRemoved(
        uint256 id,
        address owner,
        uint256 amount,
        uint256 unlockedAt
    );
    event LockVested(
        uint256 id,
        address owner,
        uint256 amount,
        uint256 remaining,
        uint256 timestamp
    );

    modifier validLock(uint256 lockId) {
        require(lockId < _locks.length,"Invalid ID");
        _;
    }

    constructor(uint256 _vestCycle, uint256 _vestBps) Ownable(msg.sender) {
        vestedBps = _vestBps;
        vestingCycle = _vestCycle;
    }

    function vestingLock(
        address owner,
        uint256 amount
    ) external returns (uint256 id) {
        require(stakingContOnly[msg.sender], "invalid caller");
        require(token != address(0), "Invalid token");
        require(amount > 0, "Amount should be greater than 0");
        id = _createLock(
            owner,
            amount
        );
        _safeTransferFromEnsureExactAmount(
            msg.sender,
            address(this),
            amount
        );
        emit LockAdded(id, msg.sender, owner, amount);
        return id;
    }

    function _createLock(
        address owner,
        uint256 amount
    ) internal returns (uint256 id) {
            id = _registerLock(
                owner,
                amount
            );
        _userNormalLockIds[owner].add(id);
        return id;
    }

    function _registerLock(
        address owner,
        uint256 amount
    ) private returns (uint256 id) {
        id = _locks.length;
        Lock memory newLock = Lock({
            id: id,
            owner: owner,
            amount: amount,
            lockDate: block.timestamp,
            unlockedAmount: 0
        });
        _locks.push(newLock);
    }

    function unlock(uint256 lockId) external validLock(lockId) {
        Lock storage userLock = _locks[lockId];
        require(
            userLock.owner == msg.sender,
            "You are not the owner of this lock"
        );
        _vestingUnlock(userLock);
    }

    function _vestingUnlock(Lock storage userLock) internal {
        uint256 withdrawable = _withdrawableTokens(userLock);
        uint256 newTotalUnlockAmount = userLock.unlockedAmount + withdrawable;
        require(
            withdrawable > 0 && newTotalUnlockAmount <= userLock.amount,
            "Nothing to unlock"
        );

        if (newTotalUnlockAmount == userLock.amount) {
                _userNormalLockIds[msg.sender].remove(userLock.id);
            emit LockRemoved(
                userLock.id,
                msg.sender,
                newTotalUnlockAmount,
                block.timestamp
            );
        }
        userLock.unlockedAmount = newTotalUnlockAmount;

        IERC20(token).safeTransfer(userLock.owner, withdrawable);

        emit LockVested(
            userLock.id,
            msg.sender,
            withdrawable,
            userLock.amount - userLock.unlockedAmount,
            block.timestamp
        );
    }

    function withdrawableTokens(uint256 lockId)
        external
        view
        returns (uint256)
    {
        Lock memory userLock = getLockById(lockId);
        return _withdrawableTokens(userLock);
    }

    function _withdrawableTokens(Lock memory userLock)
        internal
        view
        returns (uint256)
    {
        if (userLock.amount == 0) return 0;
        if (userLock.unlockedAmount >= userLock.amount) return 0;
        uint256 cycleReleaseAmount = FullMath.mulDiv(
            userLock.amount,
            vestedBps,
            10_000
        );
        uint256 currentTotal = 0;
        if (block.timestamp >= userLock.lockDate) {
            currentTotal =
                (((block.timestamp - userLock.lockDate) / vestingCycle) *
                    cycleReleaseAmount); // Truncation is expected here
        }
        uint256 withdrawable = 0;
        if (currentTotal > userLock.amount) {
            withdrawable = userLock.amount - userLock.unlockedAmount;
        } else {
            withdrawable = currentTotal - userLock.unlockedAmount;
        }
        return withdrawable;
    }

    function updateToken(address _newAddr) external onlyOwner {
        require(_newAddr != address(0), "zero address");
        token = _newAddr;
    }
    
    function setStakeContract(address _addr, bool _flag) external onlyOwner {
        require(_addr != address(0), "zero address");
        stakingContOnly[_addr] = _flag;
    }

    function isStakingContract(address _addr) external view returns(bool) {
        return stakingContOnly[_addr];
    }

    function _safeTransferFromEnsureExactAmount(
        address sender,
        address recipient,
        uint256 amount
    ) internal {
        uint256 oldRecipientBalance = IERC20(token).balanceOf(recipient);
        IERC20(token).safeTransferFrom(sender, recipient, amount);
        uint256 newRecipientBalance = IERC20(token).balanceOf(recipient);
        require(
            newRecipientBalance - oldRecipientBalance == amount,
            "Not enough token was transfered"
        );
    }

    function updateCycleTime(uint256 _cycle) external onlyOwner {
        require(_cycle != 0, "zero");
        vestingCycle = _cycle;
    }

    function updateCycleBps (uint256 _bps) external onlyOwner {
        require(_bps != 0 && _bps <= 10000, "invalid bps");
        vestedBps = _bps;
    }

    function getTotalLockCount() external view returns (uint256) {
        // Returns total lock count, regardless of whether it has been unlocked or not
        return _locks.length;
    }

    function getLockAt(uint256 index) external view returns (Lock memory) {
        return _locks[index];
    }

    function getLockById(uint256 lockId) public view returns (Lock memory) {
        return _locks[lockId];
    }

    function normalLockCountForUser(address user)
        public
        view
        returns (uint256)
    {
        return _userNormalLockIds[user].length();
    }

    function normalLocksForUser(address user)
        external
        view
        returns (Lock[] memory)
    {
        uint256 length = _userNormalLockIds[user].length();
        Lock[] memory userLocks = new Lock[](length);

        for (uint256 i = 0; i < length; i++) {
            userLocks[i] = getLockById(_userNormalLockIds[user].at(i));
        }
        return userLocks;
    }

    function normalLockForUserAtIndex(address user, uint256 index)
        external
        view
        returns (Lock memory)
    {
        require(normalLockCountForUser(user) > index, "Invalid index");
        return getLockById(_userNormalLockIds[user].at(index));
    }

    function rescueTokens(uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    function totalLockCountForUser(address user)
        external
        view
        returns (uint256)
    {
        return normalLockCountForUser(user);
    }
}