// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Interface/IReferralRegistryLisa.sol";

contract NodeSubscriptionLisa is Ownable {

    uint256 public constant MAX_NODES = 300;

    uint256 public constant TOTAL_LISA_PER_NODE = 2000 * 10**18;

    uint256 public constant RELEASE_AMOUNT = 200 * 10**18;

    uint256 public constant RELEASE_INTERVAL = 2592000;

    uint256 public constant TOTAL_RELEASES = 10;

    uint256 public constant NODE_PRICE = 500 * 10**18;

    IERC20 public lisaToken;

    IERC20 public immutable usdtToken;

    IReferralRegistryLisa public immutable referralRegistry;

    bool public isSubscriptionOpen;

    bool public isReleaseStarted;

    uint256 public releaseStartTime;

    address[] public nodes;
    mapping(address => bool) public isNode;
    mapping(address => uint256) public userReleasedCount;
    mapping(address => uint256) public userReferralRewards;


    event SubscriptionOpened();
    event SubscriptionClosed();
    event ReleaseStarted(uint256 indexed startTime);
    event LisaTokenSet(address indexed tokenAddress);
    event NodeSubscribed(address indexed user, address indexed referrer, uint256 indexed timestamp);
    event LisaClaimed(address indexed user, uint256 amount);
    event ReferralRewardClaimed(address indexed user, uint256 amount);
    event UsdtWithdrawn(address indexed recipient, uint256 amount);
    event LisaWithdrawn(address indexed recipient, uint256 amount);

    error LisaTokenNotSet();
    error LisaTokenAlreadySet();
    error SubscriptionNotOpen();
    error SubscriptionAlreadyOpen();
    error ReleaseNotStarted();
    error ReleaseAlreadyStarted();
    error MaxNodesReached();
    error AlreadyANode();
    error NotANode();
    error NoReferrer();
    error TransferFailed();
    error NoClaimableLisa();
    error NoClaimableRewards();
    error OnlyWhitelisted();
    error InsufficientBalance();
    error AlreadyHasReferrer();
    error HasDirectReferrals();

    constructor(
        address _usdtToken,
        address _referralRegistry
    ) Ownable(msg.sender) {
        require(_usdtToken != address(0), "Invalid USDT token address");
        require(_referralRegistry != address(0), "Invalid referral registry address");

        usdtToken = IERC20(_usdtToken);
        referralRegistry = IReferralRegistryLisa(_referralRegistry);

        isSubscriptionOpen = false;
        isReleaseStarted = false;
    }

    function setLisaToken(address _lisaToken) external onlyOwner {
        if (address(lisaToken) != address(0)) revert LisaTokenAlreadySet();
        if (_lisaToken == address(0)) revert LisaTokenNotSet();
        lisaToken = IERC20(_lisaToken);
        emit LisaTokenSet(_lisaToken);
    }

    function openSubscription() external onlyOwner {
        if (isSubscriptionOpen) revert SubscriptionAlreadyOpen();
        isSubscriptionOpen = true;
        emit SubscriptionOpened();
    }

    function closeSubscription() external onlyOwner {
        if (!isSubscriptionOpen) revert SubscriptionNotOpen();
        isSubscriptionOpen = false;
        emit SubscriptionClosed();
    }

    function startRelease() external onlyOwner {
        if (address(lisaToken) == address(0)) revert LisaTokenNotSet();
        if (isReleaseStarted) revert ReleaseAlreadyStarted();
        isReleaseStarted = true;
        releaseStartTime = block.timestamp;
        emit ReleaseStarted(releaseStartTime);
    }

    function withdrawUsdt(address _recipient, uint256 _amount) external onlyOwner {
        require(_recipient != address(0), "Invalid recipient");
        require(_amount > 0, "Amount must be greater than 0");
        if (usdtToken.balanceOf(address(this)) < _amount) revert InsufficientBalance();
        bool success = usdtToken.transfer(_recipient, _amount);
        if (!success) revert TransferFailed();

        emit UsdtWithdrawn(_recipient, _amount);
    }

    function withdrawLisa(address _recipient, uint256 _amount) external onlyOwner {
        if (address(lisaToken) == address(0)) revert LisaTokenNotSet();
        require(_recipient != address(0), "Invalid recipient");
        require(_amount > 0, "Amount must be greater than 0");
        if (lisaToken.balanceOf(address(this)) < _amount) revert InsufficientBalance();
        bool success = lisaToken.transfer(_recipient, _amount);
        if (!success) revert TransferFailed();

        emit LisaWithdrawn(_recipient, _amount);
    }
    
    function bindReferrer(address _referrer) external {
        require(_referrer != address(0), "Invalid referrer");
        if (!isSubscriptionOpen) revert SubscriptionNotOpen();
        (bool hasReferrer, ) = referralRegistry.getReferrer(msg.sender);
        if (hasReferrer) revert AlreadyHasReferrer();
        uint256 directReferralCount = referralRegistry.getDirectReferralCount(msg.sender);
        if (directReferralCount > 0) revert HasDirectReferrals();

        referralRegistry.bind(_referrer,msg.sender);
    }

    function gethasReferrer(address user) external view returns (bool, address) {
        return referralRegistry.getReferrer(user);
    }

    function subscribeNode() external {
        if (!isSubscriptionOpen) revert SubscriptionNotOpen();
        if (nodes.length >= MAX_NODES) revert MaxNodesReached();
        if (isNode[msg.sender]) revert AlreadyANode();
        (bool hasReferrer, address referrer) = referralRegistry.getReferrer(msg.sender);
        if (!hasReferrer || referrer == address(0)) revert NoReferrer();

        bool paymentSuccess = usdtToken.transferFrom(msg.sender, address(this), NODE_PRICE);
        if (!paymentSuccess) revert TransferFailed();

        isNode[msg.sender] = true;
        nodes.push(msg.sender);

        if (referrer != address(0)) {
            uint256 rewardAmount = (NODE_PRICE * 15) / 100; 
            userReferralRewards[referrer] += rewardAmount;
        }

        emit NodeSubscribed(msg.sender, referrer, block.timestamp);
    }

    function claimLisa() external {
        if (address(lisaToken) == address(0)) revert LisaTokenNotSet();
        if (!isReleaseStarted) revert ReleaseNotStarted();
        if (!isNode[msg.sender]) revert NotANode();

        uint256 elapsedTime = block.timestamp - releaseStartTime;
        uint256 totalReleasable = elapsedTime / RELEASE_INTERVAL;
        totalReleasable = totalReleasable > TOTAL_RELEASES ? TOTAL_RELEASES : totalReleasable;

        uint256 userReleasable = totalReleasable - userReleasedCount[msg.sender];
        if (userReleasable <= 0) revert NoClaimableLisa();

        uint256 claimAmount = userReleasable * RELEASE_AMOUNT;
        if(lisaToken.balanceOf(address(this)) < claimAmount) revert InsufficientBalance();

        userReleasedCount[msg.sender] = totalReleasable;
        bool success = lisaToken.transfer(msg.sender, claimAmount);
        if (!success) revert TransferFailed();

        emit LisaClaimed(msg.sender, claimAmount);
    }

    function claimReferralReward() external {
        if (!isNode[msg.sender]) revert NotANode();

        uint256 rewardAmount = userReferralRewards[msg.sender];
        if (rewardAmount <= 0) revert NoClaimableRewards();
        if(usdtToken.balanceOf(address(this)) < rewardAmount) revert InsufficientBalance();
        userReferralRewards[msg.sender] = 0;

        bool success = usdtToken.transfer(msg.sender, rewardAmount);
        if (!success) revert TransferFailed();

        emit ReferralRewardClaimed(msg.sender, rewardAmount);
    }

    function getNodeList() external view returns (address[] memory) {
        if (!referralRegistry.isWhitelisted(msg.sender)) revert OnlyWhitelisted();
        return nodes;
    }

    function getNodeCount() external view returns (uint256) {
        return nodes.length;
    }

    function getClaimableLisa(address _user) external view returns (uint256) {
        if (address(lisaToken) == address(0) || !isReleaseStarted || !isNode[_user]) {
            return 0;
        }
        uint256 elapsedTime = block.timestamp - releaseStartTime;
        uint256 totalReleasable = elapsedTime / RELEASE_INTERVAL;
        totalReleasable = totalReleasable > TOTAL_RELEASES ? TOTAL_RELEASES : totalReleasable;

        uint256 userReleasable = totalReleasable - userReleasedCount[_user];
        return userReleasable * RELEASE_AMOUNT;
    }

}