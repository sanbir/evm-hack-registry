// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * Presale
 */
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "safeTransfer failed");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "safeTransfer failed");
    }
}

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface IReferral {
    function record(address user, uint256 amount) external;
    function distribute(address user, uint256 amount) external;
    function deductPerformance(address user, uint256 amount, uint8 reason) external;
}

interface IOldPresale {
    function contributed(address user) external view returns (uint256);
    function expectedTokens(address user) external view returns (uint256);
}

contract Presale {

    using SafeERC20 for IERC20;

    IERC20 public usdt;
    IERC20 public token;
    IReferral public referral;

    address public owner;
    address public pendingOwner;
    uint256 public ownerTimelock;
    uint256 public constant OWNERSHIP_DELAY = 48 hours;
    address public treasury;
    address public keeper;

    bool public paused = false;
    bool public claimEnabled = false;

    // Price: $0.35 AIS/USDT
    uint256 public price = 35e15;
    uint256 public hardcap = 150000e18;
    uint256 public minBuy = 100e18;
    uint256 public maxBuy = 10000e18;

    uint256 public totalRaised;
    uint256 public startTime;
    uint256 public endTime;
    uint256 public maxReferralReward = 1000e18;

    // contributed in USDT (1e6)
    mapping(address => uint256) public contributed;
    // expected tokens in AIS (1e18)
    mapping(address => uint256) public expectedTokens;
    // already claimed flag
    mapping(address => bool) public hasClaimed;

    // migration from old Presale
    mapping(address => bool) public hasMigrated;
    // tracks if user has engaged (staked/mined/node) before selling presale tokens
    mapping(address => bool) public hasEngagedPresale;
    // whitelisted contracts that can mark user as engaged (Staking/LiquidityMining/GenesisNode)
    mapping(address => bool) public authorizedEngagementContracts;
    uint256 public migratedCount;

    event Buy(address indexed user, uint256 usdtAmount, uint256 tokenAmount);
    event Claim(address indexed user, uint256 tokenAmount);
    event Sell(address indexed user, uint256 tokenAmount, uint256 usdtAmount);
    event Withdraw(address indexed to, uint256 amount);
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event PausedToggled(bool indexed paused, address indexed by);
    event ClaimEnabledToggled(bool indexed enabled);
    event KeeperSet(address indexed oldKeeper, address indexed newKeeper);
    event ReferralReward(address indexed user, uint256 reward);
    event MigrationStarted(address indexed oldPresale);
    event UserMigrated(address indexed user, uint256 contributed_, uint256 expectedTokens_, uint256 migratedCount);
    event MigrationCompleted(uint256 totalUsers);
    event MigratedClaimed(address indexed user, uint256 tokenAmount);
    event UserEngaged(address indexed user);  // emitted when user stakes/mines/buys node
    event Funded(address indexed from, uint256 amount, uint256 newBalance);
    event TokenSet(address indexed oldToken, address indexed newToken);
    event ReferralSet(address indexed oldReferral, address indexed newReferral);
    event MaxReferralRewardSet(uint256 oldMax, uint256 newMax);
    event LimitsSet(uint256 minBuy, uint256 maxBuy, uint256 hardcap);
    event TimeWindowSet(uint256 startTime, uint256 endTime);
    event TreasurySet(address indexed oldTreasury, address indexed newTreasury);
    event OwnershipTransferProposed(address indexed currentOwner, address indexed pendingOwner, uint256 effectiveTime);
    event OwnershipTransferCancelled();
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }
    modifier onlyKeeperOrOwner() { require(msg.sender == keeper || msg.sender == owner, "not authorized"); _; }
    modifier whenNotPaused() { require(!paused, "paused"); _; }

    constructor(address _usdt, address _token, address _referral, address _treasury, address _keeper) {
        require(_usdt != address(0) && _token != address(0), "zero token");
        require(_treasury != address(0), "zero treasury");
        usdt = IERC20(_usdt);
        token = IERC20(_token);
        referral = IReferral(_referral);
        treasury = _treasury;
        keeper = _keeper;
        owner = msg.sender;
    }

    // ===== USER OPERATIONS =====

    /// @notice User sells back claimed presale tokens at the same price
    /// @dev If user claimed presale but never staked/mined/bought node, referrer's performance is deducted
    function sell(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        require(token.balanceOf(msg.sender) >= amount, "insufficient balance");

        uint256 usdtAmount = amount * price / 1e18;
        require(usdt.balanceOf(address(this)) >= usdtAmount, "insufficient treasury");

        token.safeTransferFrom(msg.sender, address(this), amount);
        usdt.safeTransfer(msg.sender, usdtAmount);

        // Deduct referrer performance only if user sold without engaging (no stake/mine/node)
        if (!hasEngagedPresale[msg.sender] && hasClaimed[msg.sender]) {
            uint256 contributedAmt = contributed[msg.sender];
            if (contributedAmt > 0) {
                _safeDeductPerformance(msg.sender, contributedAmt, 2);
            }
        }

        emit Sell(msg.sender, amount, usdtAmount);
    }

    /// @notice New presale buy (USDT -> AIS tokens, no vesting)
    /// @param amount USDT amount
    function buy(uint256 amount) external whenNotPaused {
        require(startTime == 0 || block.timestamp >= startTime, "not started");
        require(endTime == 0 || block.timestamp <= endTime, "ended");
        require(amount >= minBuy, "too small");
        require(contributed[msg.sender] + amount <= maxBuy, "exceed max");
        require(totalRaised + amount <= hardcap, "hardcap reached");

        usdt.safeTransferFrom(msg.sender, address(this), amount);

        uint256 tokenAmount = amount * 1e18 / price;

        contributed[msg.sender] += amount;
        totalRaised += amount;
        expectedTokens[msg.sender] += tokenAmount;

        emit Buy(msg.sender, amount, tokenAmount);
        _safeRecord(msg.sender, amount);
    }

    /// @notice New presale user claims tokens (one-time, no vesting)
    /// @dev Marks user as having claimed presale — if they sell without staking/mining/node, referrer performance is deducted
    function claim() external whenNotPaused {
        require(claimEnabled, "claim not enabled");
        require(expectedTokens[msg.sender] > 0, "no tokens to claim");
        require(!hasClaimed[msg.sender], "already claimed");

        uint256 tokenAmount = expectedTokens[msg.sender];
        hasClaimed[msg.sender] = true;
        token.safeTransfer(msg.sender, tokenAmount);

        uint256 contributedAmt = contributed[msg.sender];
        if (contributedAmt > 0) {
            uint256 referralReward = contributedAmt * 5 / 100;
            _safeDistribute(msg.sender, referralReward);
            // hasEngagedPresale is NOT reset here. Reason:
            //   1. Default value is false — no need to explicitly set it.
            //   2. If user previously engaged (flag = true), they already earned referrer rewards,
            //      and selling after that should NOT deduct again — correct behavior preserved.
            //   3. Keeping the flag unchanged avoids an on-chain state-change observable by MEV
            //      attackers who could front-run a subsequent staking tx during the false window.
        }

        emit Claim(msg.sender, tokenAmount);
    }

    /// @notice Migrated user claims all tokens at once
    /// @dev Marks user as having claimed presale — if they sell without staking/mining/node, referrer performance is deducted
    function claimMigrated() external whenNotPaused {
        require(claimEnabled, "claim not enabled");
        require(hasMigrated[msg.sender], "not migrated");
        require(!hasClaimed[msg.sender], "already claimed");
        require(expectedTokens[msg.sender] > 0, "nothing to claim");

        uint256 tokenAmount = expectedTokens[msg.sender];
        hasClaimed[msg.sender] = true;
        token.safeTransfer(msg.sender, tokenAmount);

        uint256 contributedAmt = contributed[msg.sender];
        if (contributedAmt > 0) {
            uint256 referralReward = contributedAmt * 5 / 100;
            _safeDistribute(msg.sender, referralReward);
            // hasEngagedPresale is NOT reset here. Reason:
            //   1. Default value is false — no need to explicitly set it.
            //   2. If user previously engaged (flag = true), they already earned referrer rewards,
            //      and selling after that should NOT deduct again — correct behavior preserved.
            //   3. Keeping the flag unchanged avoids an on-chain state-change observable by MEV
            //      attackers who could front-run a subsequent staking tx during the false window.
        }

        emit MigratedClaimed(msg.sender, tokenAmount);
    }

    // ===== MIGRATION =====

    /// @notice Owner signals migration from old presale (emit event only)
    function startMigration(address _oldPresale) external onlyOwner {
        require(_oldPresale != address(0), "zero address");
        emit MigrationStarted(_oldPresale);
    }

    /// @notice Migrate single user from DB data (manual mode)
    /// @dev Supports re-migration: if already migrated, new data must be >= old data (fixes under-migration)
    function migrateUser(address user, uint256 _contributed, uint256 _expectedTokens) external onlyOwner {
        require(_contributed > 0 || _expectedTokens > 0, "nothing to migrate");

        if (hasMigrated[user]) {
            // Allow upgrade only — new data must be >= old data (prevents abuse)
            require(_contributed >= contributed[user], "cannot reduce contributed");
            require(_expectedTokens >= expectedTokens[user], "cannot reduce tokens");
            // No change — skip
            if (_contributed == contributed[user] && _expectedTokens == expectedTokens[user]) return;
            // upgraded in-place below
        } else {
            hasMigrated[user] = true;
            migratedCount++;
        }

        contributed[user] = _contributed;
        expectedTokens[user] = _expectedTokens;
        emit UserMigrated(user, _contributed, _expectedTokens, migratedCount);
    }

    /// @notice Migrate batch from DB data (max 50 per tx)
    /// @dev Idempotent: skips already migrated, allows upgrade with larger data
    function migrateUsersBatch(
        address[] calldata users,
        uint256[] calldata contributed_,
        uint256[] calldata expectedTokens_
    ) external onlyOwner {
        uint256 len = users.length;
        require(len == contributed_.length && len == expectedTokens_.length, "array length mismatch");
        require(len <= 50, "batch too large");

        uint256 count = 0;
        for (uint256 i = 0; i < len; i++) {
            address user = users[i];
            uint256 newContrib = contributed_[i];
            uint256 newTokens = expectedTokens_[i];
            if (newContrib == 0 && newTokens == 0) continue;

            if (hasMigrated[user]) {
                // Allow upgrade only — new >= old
                if (newContrib < contributed[user] || newTokens < expectedTokens[user]) continue;
                if (newContrib == contributed[user] && newTokens == expectedTokens[user]) continue;
            } else {
                hasMigrated[user] = true;
                count++;
            }

            contributed[user] = newContrib;
            expectedTokens[user] = newTokens;
        }
        migratedCount += count;
        emit MigrationCompleted(migratedCount);
    }

    /// @notice Pull migration directly from old Presale contract (max 50 per tx)
    /// @dev Idempotent: skips already migrated and zero records
    function pullMigration(address oldPresale, address[] calldata users) external onlyOwner {
        require(oldPresale != address(0), "zero old presale");
        require(users.length <= 50, "batch too large");

        uint256 count = 0;
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            if (hasMigrated[user]) continue;

            uint256 oldContributed = IOldPresale(oldPresale).contributed(user);
            uint256 oldExpected = IOldPresale(oldPresale).expectedTokens(user);
            if (oldContributed == 0 && oldExpected == 0) continue;

            hasMigrated[user] = true;
            contributed[user] = oldContributed;
            expectedTokens[user] = oldExpected;
            count++;
        }
        migratedCount += count;
        emit MigrationCompleted(migratedCount);
    }

    // ===== ADMIN =====

    function enableClaim() external onlyOwner {
        require(!claimEnabled, "already enabled");
        claimEnabled = true;
        emit ClaimEnabledToggled(true);
    }

    function withdrawToTreasury() external onlyOwner {
        uint256 balance = usdt.balanceOf(address(this));
        require(balance > 0, "zero balance");
        usdt.safeTransfer(treasury, balance);
        emit Withdraw(treasury, balance);
    }

    function setPrice(uint256 _price) external onlyOwner {
        require(_price > 0, "zero price");
        uint256 oldPrice = price;
        price = _price;
        emit PriceUpdated(oldPrice, _price);
    }

    function setLimits(uint256 _minBuy, uint256 _maxBuy, uint256 _hardcap) external onlyOwner {
        require(_minBuy > 0 && _maxBuy >= _minBuy, "invalid limits");
        minBuy = _minBuy;
        maxBuy = _maxBuy;
        hardcap = _hardcap;
        emit LimitsSet(_minBuy, _maxBuy, _hardcap);
    }

    function setTimeWindow(uint256 _startTime, uint256 _endTime) external onlyOwner {
        require(_endTime > _startTime, "invalid time");
        startTime = _startTime;
        endTime = _endTime;
        emit TimeWindowSet(_startTime, _endTime);
    }

    function setReferral(address _referral) external onlyOwner {
        address oldReferral = address(referral);
        referral = IReferral(_referral);
        emit ReferralSet(oldReferral, _referral);
    }

    function setMaxReferralReward(uint256 _max) external onlyOwner {
        require(_max > 0, "zero max");
        uint256 oldMax = maxReferralReward;
        maxReferralReward = _max;
        emit MaxReferralRewardSet(oldMax, _max);
    }

    function setKeeper(address _keeper) external onlyOwner {
        require(_keeper != address(0), "zero keeper");
        address oldKeeper = keeper;
        keeper = _keeper;
        emit KeeperSet(oldKeeper, _keeper);
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "zero address");
        address oldTreasury = treasury;
        treasury = _treasury;
        emit TreasurySet(oldTreasury, _treasury);
    }

    function setToken(address _token) external onlyOwner {
        require(_token != address(0), "zero token");
        address oldToken = address(token);
        token = IERC20(_token);
        emit TokenSet(oldToken, _token);
    }

    // ===== INTERNAL HELPERS =====

    function _safeRecord(address user, uint256 amount) internal {
        if (address(referral) != address(0) && amount > 0) {
            try referral.record(user, amount) {} catch {}
        }
    }

    function _safeDistribute(address user, uint256 reward) internal {
        if (reward > maxReferralReward) reward = maxReferralReward;
        if (address(referral) != address(0) && reward > 0) {
            try referral.distribute(user, reward) {} catch {}
            emit ReferralReward(user, reward);
        }
    }

    function _safeDeductPerformance(address user, uint256 amount, uint8 reason) internal {
        if (address(referral) != address(0) && amount > 0) {
            try referral.deductPerformance(user, amount, reason) {} catch {}
        }
    }

    function togglePause() external onlyOwner {
        paused = !paused;
        emit PausedToggled(paused, msg.sender);
    }

    /// @notice Authorize a contract (Staking/LiquidityMining/GenesisNode) to mark users as engaged
    function setAuthorizedEngagementContract(address _contract, bool _authorized) external onlyOwner {
        authorizedEngagementContracts[_contract] = _authorized;
    }

    /// @notice Called by authorized contracts (Staking/LiquidityMining/GenesisNode)
    /// when user stakes/mines/buys node — marks user as engaged, protecting referrer performance
    function markUserEngaged(address user) external {
        require(authorizedEngagementContracts[msg.sender], "not authorized");
        if (!hasEngagedPresale[user]) {
            hasEngagedPresale[user] = true;
            emit UserEngaged(user);
        }
    }

    function transferOwnership(address _owner) external onlyOwner {
        require(_owner != address(0), "zero address");
        pendingOwner = _owner;
        ownerTimelock = block.timestamp + OWNERSHIP_DELAY;
        emit OwnershipTransferProposed(owner, _owner, ownerTimelock);
    }

    function claimOwnership() external {
        require(msg.sender == pendingOwner, "not pending");
        require(block.timestamp >= ownerTimelock, "timelock");
        address oldOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        ownerTimelock = 0;
        emit OwnershipTransferred(oldOwner, owner);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        pendingOwner = address(0);
        ownerTimelock = 0;
        emit OwnershipTransferCancelled();
    }

    /// @notice Owner funds this contract with AIS tokens for migrated presale claims
    function fundForMigration(uint256 amount) external onlyOwner {
        require(amount > 0, "zero amount");
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount, token.balanceOf(address(this)));
    }

    /// @notice Owner manually resets hasClaimed (fix migration edge cases)
    function resetHasClaimed(address user) external onlyOwner {
        hasClaimed[user] = false;
    }

    /// @notice Owner manually resets hasMigrated (re-migrate stuck users)
    function resetHasMigrated(address user) external onlyOwner {
        hasMigrated[user] = false;
    }

    function rescueToken(address tokenAddr, address to) external onlyOwner {
        require(to != address(0), "zero address");
        uint256 balance = IERC20(tokenAddr).balanceOf(address(this));
        require(balance > 0, "zero balance");
        IERC20(tokenAddr).safeTransfer(to, balance);
    }

    // ===== VIEWS =====

    function getTokenAmount(uint256 usdtAmount) external view returns (uint256) {
        return usdtAmount * 1e18 / price;
    }

    function getClaimStatus(address user) external view returns (
        uint256 expectedTokenAmount,
        bool claimed,
        bool migrated,
        bool canClaim
    ) {
        expectedTokenAmount = expectedTokens[user];
        claimed = hasClaimed[user];
        migrated = hasMigrated[user];
        canClaim = claimEnabled && expectedTokenAmount > 0 && !claimed;
    }
}