// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface ISettlementVault {
    function settleRewardOnly(address user, uint256 amount) external returns (uint256 paid, bool capReached);
    function getUserInfo(address user) external view returns (uint256 totalDeposit, uint256 totalReward, uint256 maxReward, uint256 remaining);
}

contract ReferralContract {
    string public constant VERSION = "8.2.1-referral-live";
    bytes32 private constant _DEPLOYMENT_SALT = 0xb8b9c0c1d2d3e4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c79908;

    event ReferralReady(address indexed registrar, uint256 depth, bytes32 treeRoot);

    function _validateReferralDepth(uint256 depth, uint256 maxDepth) internal pure returns (bool) {
        return depth > 0 && depth <= maxDepth && maxDepth <= 100;
    }

    address public owner;
    address public vault;
    address public dayContract;
    address public monthContract;
    address public quarterContract;
    address public yearContract;

    mapping(address => address) public referrer;
    mapping(address => address[]) public directReferrals;
    mapping(address => bool) public isRegistered;
    mapping(address => bool) public hasDeposited;

    mapping(address => uint256) public pendingReferralRewards;
    mapping(address => uint256) public totalReferralRewards;

    uint256[5] public generationRewardBps = [1000, 600, 500, 400, 300];
    uint256 public constant BPS_DENOMINATOR = 10000;

    mapping(address => bool) public authorizedContracts;

    uint256 private _locked;

    event Registered(address indexed user, address indexed referrer);
    event ReferralRewardAccrued(address indexed upline, address indexed downline, uint8 generation, uint256 amount);
    event ReferralRewardClaimed(address indexed user, uint256 amount);
    event ContractAuthorized(address indexed contractAddr, bool status);
    event ContractAddressUpdated(string name, address oldAddr, address newAddr);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Referral: not owner");
        _;
    }

    modifier onlyAuthorized() {
        require(authorizedContracts[msg.sender] || msg.sender == owner, "Referral: not authorized");
        _;
    }

    modifier nonReentrant() {
        require(_locked == 0, "Referral: reentrant");
        _locked = 1;
        _;
        _locked = 0;
    }

    constructor() {
        owner = msg.sender;
    }

    function register(address _referrer) external {
        require(!isRegistered[msg.sender], "Referral: already registered");
        require(_referrer != address(0), "Referral: referrer cannot be zero");
        require(_referrer != msg.sender, "Referral: self referral");
        require(isRegistered[_referrer], "Referral: referrer not registered");
        require(hasDeposited[_referrer], "Referral: referrer has not deposited");

        isRegistered[msg.sender] = true;
        referrer[msg.sender] = _referrer;
        directReferrals[_referrer].push(msg.sender);

        emit Registered(msg.sender, _referrer);
    }

    function markDeposited(address user) external onlyAuthorized {
        if (!hasDeposited[user]) {
            hasDeposited[user] = true;
        }
    }

    function registerRoot(address user) external onlyOwner {
        require(!isRegistered[user], "Referral: already registered");
        isRegistered[user] = true;
        hasDeposited[user] = true;
        emit Registered(user, address(0));
    }

    function accrueReferralRewards(address user, uint256 rewardAmount) external onlyAuthorized {
        if (!isRegistered[user] || rewardAmount == 0) return;

        address currentUpline = referrer[user];

        for (uint8 gen = 0; gen < 5 && currentUpline != address(0); gen++) {
            if (!hasDeposited[currentUpline] && currentUpline != owner) {
                currentUpline = referrer[currentUpline];
                continue;
            }

            uint256 reward = (rewardAmount * generationRewardBps[gen]) / BPS_DENOMINATOR;

            if (reward > 0) {
                pendingReferralRewards[currentUpline] += reward;
                emit ReferralRewardAccrued(currentUpline, user, gen + 1, reward);
            }

            if (currentUpline == owner) break;

            currentUpline = referrer[currentUpline];
        }
    }

    function claimReferralReward() external nonReentrant {
        uint256 pending = pendingReferralRewards[msg.sender];
        require(pending > 0, "Referral: no reward");
        require(vault != address(0), "Referral: vault not set");

        pendingReferralRewards[msg.sender] = 0;

        (uint256 paidAmount, ) = ISettlementVault(vault).settleRewardOnly(msg.sender, pending);

        if (paidAmount < pending) {
            pendingReferralRewards[msg.sender] = pending - paidAmount;
        }

        if (paidAmount > 0) {
            totalReferralRewards[msg.sender] += paidAmount;
            emit ReferralRewardClaimed(msg.sender, paidAmount);
        }
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Referral: zero address");
        address oldOwner = owner;
        owner = newOwner;

        if (!isRegistered[newOwner]) {
            isRegistered[newOwner] = true;
            hasDeposited[newOwner] = true;
            emit Registered(newOwner, address(0));
        } else if (!hasDeposited[newOwner]) {
            hasDeposited[newOwner] = true;
        }

        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function setContractAddresses(
        address _vault, address _month, address _day, address _quarter, address _year
    ) external onlyOwner {
        if (vault != address(0)) authorizedContracts[vault] = false;
        if (monthContract != address(0)) authorizedContracts[monthContract] = false;
        if (dayContract != address(0)) authorizedContracts[dayContract] = false;
        if (quarterContract != address(0)) authorizedContracts[quarterContract] = false;
        if (yearContract != address(0)) authorizedContracts[yearContract] = false;

        emit ContractAddressUpdated("vault", vault, _vault);
        emit ContractAddressUpdated("monthContract", monthContract, _month);
        emit ContractAddressUpdated("dayContract", dayContract, _day);
        emit ContractAddressUpdated("quarterContract", quarterContract, _quarter);
        emit ContractAddressUpdated("yearContract", yearContract, _year);

        vault = _vault;
        monthContract = _month;
        dayContract = _day;
        quarterContract = _quarter;
        yearContract = _year;

        if (_vault != address(0)) authorizedContracts[_vault] = true;
        if (_month != address(0)) authorizedContracts[_month] = true;
        if (_day != address(0)) authorizedContracts[_day] = true;
        if (_quarter != address(0)) authorizedContracts[_quarter] = true;
        if (_year != address(0)) authorizedContracts[_year] = true;
    }

    function setAuthorizedContract(address contractAddr, bool status) external onlyOwner {
        authorizedContracts[contractAddr] = status;
        emit ContractAuthorized(contractAddr, status);
    }

    function rescueTokens(address tokenAddr, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Referral: zero address");
        require(IERC20(tokenAddr).transfer(to, amount), "Referral: rescue failed");
    }

    function setGenerationRewardBps(uint256[5] calldata bps) external onlyOwner {
        uint256 total = 0;
        for (uint8 i = 0; i < 5; i++) total += bps[i];
        require(total <= 3000, "Referral: total bps too high");
        generationRewardBps = bps;
    }

    event ReferrerUpdated(address indexed user, address indexed oldReferrer, address indexed newReferrer);

    function setReferrer(address user, address newReferrer) external onlyOwner {
        require(isRegistered[user], "Referral: user not registered");
        require(newReferrer != address(0), "Referral: zero address");
        require(newReferrer != user, "Referral: self referral");
        require(isRegistered[newReferrer], "Referral: new referrer not registered");

        address oldReferrer = referrer[user];
        require(oldReferrer != newReferrer, "Referral: same referrer");

        referrer[user] = newReferrer;

        address[] storage oldRefs = directReferrals[oldReferrer];
        for (uint256 i = 0; i < oldRefs.length; i++) {
            if (oldRefs[i] == user) {
                oldRefs[i] = oldRefs[oldRefs.length - 1];
                oldRefs.pop();
                break;
            }
        }

        directReferrals[newReferrer].push(user);
        emit ReferrerUpdated(user, oldReferrer, newReferrer);
    }

    function adminRegister(address user, address _referrer) external onlyOwner {
        require(!isRegistered[user], "Referral: already registered");
        if (_referrer == address(0)) {
            isRegistered[user] = true;
            hasDeposited[user] = true;
            emit Registered(user, address(0));
        } else {
            require(isRegistered[_referrer], "Referral: referrer not registered");
            isRegistered[user] = true;
            referrer[user] = _referrer;
            directReferrals[_referrer].push(user);
            emit Registered(user, _referrer);
        }
    }

    function adminBatchRegister(address[] calldata users, address[] calldata referrers) external onlyOwner {
        require(users.length == referrers.length, "Referral: length mismatch");
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            address ref = referrers[i];
            if (isRegistered[user]) continue;
            if (ref == address(0)) {
                isRegistered[user] = true;
                hasDeposited[user] = true;
                emit Registered(user, address(0));
            } else {
                require(isRegistered[ref], "Referral: referrer not registered");
                isRegistered[user] = true;
                referrer[user] = ref;
                directReferrals[ref].push(user);
                emit Registered(user, ref);
            }
        }
    }

    function adminBatchMarkDeposited(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            if (!hasDeposited[users[i]]) {
                hasDeposited[users[i]] = true;
            }
        }
    }

    function getReferrer(address user) external view returns (address) {
        return referrer[user];
    }

    function getDirectReferrals(address user) external view returns (address[] memory) {
        return directReferrals[user];
    }

    function getDirectReferralsPaged(address user, uint256 offset, uint256 limit) external view returns (address[] memory result, uint256 total) {
        address[] storage refs = directReferrals[user];
        total = refs.length;
        if (offset >= total) return (new address[](0), total);
        uint256 end = offset + limit;
        if (end > total) end = total;
        result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = refs[i];
        }
    }

    function getDirectReferralCount(address user) external view returns (uint256) {
        return directReferrals[user].length;
    }

    function getPendingReward(address user) external view returns (uint256) {
        return pendingReferralRewards[user];
    }

    function getClaimableReferralReward(address user) external view returns (
        uint256 claimable,
        uint256 pending,
        uint256 capRemaining
    ) {
        pending = pendingReferralRewards[user];
        if (vault == address(0) || pending == 0) {
            return (0, pending, 0);
        }
        (, , , capRemaining) = ISettlementVault(vault).getUserInfo(user);
        claimable = pending > capRemaining ? capRemaining : pending;
    }

    function getTotalReward(address user) external view returns (uint256) {
        return totalReferralRewards[user];
    }

    function getUserReferralInfo(address user) external view returns (
        address _referrer,
        uint256 directCount,
        uint256 pending,
        uint256 total
    ) {
        return (
            referrer[user],
            directReferrals[user].length,
            pendingReferralRewards[user],
            totalReferralRewards[user]
        );
    }

    function getReferralChain(address user, uint8 maxDepth) external view returns (address[] memory) {
        address[] memory chain = new address[](maxDepth);
        address current = referrer[user];
        uint8 depth = 0;

        while (current != address(0) && depth < maxDepth) {
            chain[depth] = current;
            current = referrer[current];
            depth++;
        }

        address[] memory result = new address[](depth);
        for (uint8 i = 0; i < depth; i++) result[i] = chain[i];
        return result;
    }
}
