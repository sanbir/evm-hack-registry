// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "./interfaces/IDeposit.sol";
import "./interfaces/IWETH.sol";
import "./LiquidUnstakePool.sol";
import "./Withdrawal.sol";

/// @title ETH staking manager and mpETH staking token
/// @author MetaPool
/// @notice Stake ETH and get mpETH as the representation of the portion owned through all the validators
/// @dev Implements ERC4626 and adapts some functions to simulate ETH native token as asset instead of an ERC20. Also allows the deposit of WETH
contract Staking is Initializable, ERC4626Upgradeable, AccessControlUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address payable;

    struct Node {
        bytes pubkey;
        bytes signature;
        bytes32 depositDataRoot;
    }

    struct EpochsReport {
        uint64 from;
        uint64 to;
        uint256 rewards;
        uint256 penalties;
    }

    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");
    bytes32 public constant ACTIVATOR_ROLE = keccak256("ACTIVATOR_ROLE");

    IDeposit public depositContract;
    address payable public liquidUnstakePool;
    address payable public withdrawal;
    address public treasury;

    uint256 public totalUnderlying;
    int public estimatedRewardsPerSecond;
    uint32 public totalNodesActivated;
    uint256 public submitReportUnlockTime;
    uint64 public constant SUBMIT_REPORT_TIMELOCK = 4 hours;
    uint64 public constant MIN_DEPOSIT = 0.01 ether;

    mapping(bytes => bool) public nodePubkeyUsed;
    mapping(address => bool) public whitelistedAccounts;
    bool public whitelistEnabled;

    uint16 public rewardsFee;
    uint16 public constant MAX_REWARDS_FEE = 2000; // 20%
    uint16 public depositFee;
    uint16 public constant MAX_DEPOSIT_FEE = 100; // 1%
    uint16 public acceptableUnderlyingChange;
    uint16 public constant MAX_ACCEPTABLE_UNDERLYING_CHANGE = 200; // 2%
    uint64 public lastEpochReported;

    bytes public withdrawalCredential;

    event Mint(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Stake(uint256 nodeId, bytes indexed pubkey);
    event UpdateNodeData(uint256 nodeId, Node data);
    event ReportEpochs(EpochsReport report, uint256 newTotalUnderlying);

    error UpdateTooBig(
        uint256 _currentTotalAssets,
        uint256 _newTotalUnderlying,
        uint256 _difference,
        uint256 _maxDifference
    );
    error DepositTooLow(uint256 _minAmount, uint256 _amountSent);
    error UserNotWhitelisted(address _user);
    error SubmitReportTimelocked(uint256 _unlockTimestamp, uint256 _currentTimestamp);
    error NotEnoughETHtoStake(
        uint256 _stakingBalance,
        uint256 _requestedToPool,
        uint256 _requestedToWithdrawal,
        uint256 _requiredBalance
    );
    error ZeroAddress(string _address);
    error FeeSentTooBig(uint16 _sentFee, uint16 _maxFee);
    error NodeAlreadyUsed(bytes _pubkey);
    error RewardsPerSecondTooBig(int _rewardsPerSecondSent, int _maxRewardsPerSecond);
    error InvalidEpochs(uint64 _from, uint64 _to);
    error InvalidEpochFrom(uint64 _from, uint64 _lastEpochReported);
    error AcceptableUnderlyingChangeTooBig(
        uint16 _acceptableUnderlyingChangeSent,
        uint16 _maxAcceptableUnderlyingChange
    );
    error DepositRootMismatch();

    modifier checkWhitelisting() {
        if (whitelistEnabled && !whitelistedAccounts[msg.sender])
            revert UserNotWhitelisted(msg.sender);
        _;
    }

    function initialize(
        address _liquidPool,
        address _withdrawal,
        address _depositContract,
        IERC20MetadataUpgradeable _weth,
        address _treasury,
        address _updater,
        address _activator
    ) external initializer {
        if (_treasury == address(0)) revert ZeroAddress("treasury");
        if (_depositContract == address(0)) revert ZeroAddress("depositContract");
        require(_weth.decimals() == 18, "wNative token error, implementation for 18 decimals");
        require(address(this).balance == 0, "Error initialize with no zero balance");
        __ERC4626_init(IERC20Upgradeable(_weth));
        __ERC20_init("MetaPoolETH", "mpETH");
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPDATER_ROLE, _updater);
        _grantRole(ACTIVATOR_ROLE, _activator);
        updateWithdrawal(payable(_withdrawal));
        updateLiquidPool(payable(_liquidPool));
        updateRewardsFee(500);
        treasury = _treasury;
        depositContract = IDeposit(_depositContract);
        submitReportUnlockTime = uint64(block.timestamp);
        acceptableUnderlyingChange = 100; // 1%
    }

    /// @dev Needed to receive ETH from WETH deposits and Withdrawal for new validators
    /// If sender is not WETH or Withdrawal, then assume it's an user deposit
    receive() external payable {
        if (msg.sender != asset() && msg.sender != withdrawal) depositETH(msg.sender);
    }

    /// @notice Calculate ETH held by vault + validators + estimatedRewards
    /// @return assets Returns total ETH in the protocol
    /// @dev To a more accurate balance also includes an estimation of the rewards generated by validators since the last updateNodesBalance
    function totalAssets() public view override returns (uint256 assets) {
        int rewardsSinceUpdate = estimatedRewardsPerSecond *
            int(block.timestamp - (submitReportUnlockTime - SUBMIT_REPORT_TIMELOCK));
        if (rewardsSinceUpdate >= 0) {
            assets = totalUnderlying + uint(rewardsSinceUpdate);
        } else {
            assets = totalUnderlying - uint(-rewardsSinceUpdate);
        }
    }

    function toggleWhitelistEnabled() external onlyRole(DEFAULT_ADMIN_ROLE) {
        whitelistEnabled = !whitelistEnabled;
    }

    function addToWhitelist(address[] calldata addresses) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 length = addresses.length;
        for (uint256 i = 0; i != length; ++i) whitelistedAccounts[addresses[i]] = true;
    }

    function removeFromWhitelist(
        address[] calldata addresses
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 length = addresses.length;
        for (uint256 i = 0; i != length; ++i) whitelistedAccounts[addresses[i]] = false;
    }

    /// @notice Update Withdrawal contract address
    /// @dev Admin function
    function updateWithdrawal(address payable _withdrawal) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_withdrawal == address(0)) revert ZeroAddress("withdrawal");
        bytes memory prefix = hex"010000000000000000000000";
        withdrawalCredential = abi.encodePacked(prefix, bytes20(address(_withdrawal)));
        withdrawal = _withdrawal;
    }

    /// @notice Update LiquidPool contract address
    /// @dev Admin function
    function updateLiquidPool(address payable _liquidPool) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_liquidPool == address(0)) revert ZeroAddress("liquidPool");
        liquidUnstakePool = _liquidPool;
    }

    /// @notice Update fee from rewards
    /// @dev Admin function
    function updateRewardsFee(uint16 _rewardsFee) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_rewardsFee > MAX_REWARDS_FEE) revert FeeSentTooBig(_rewardsFee, MAX_REWARDS_FEE);
        rewardsFee = _rewardsFee;
    }

    /// @notice Update fee from deposits
    /// @dev Admin function
    function updateDepositFee(uint16 _depositFee) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_depositFee > MAX_DEPOSIT_FEE) revert FeeSentTooBig(_depositFee, MAX_DEPOSIT_FEE);
        depositFee = _depositFee;
    }

    function updateAcceptableUnderlyingChange(
        uint16 _acceptableUnderlyingChange
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_acceptableUnderlyingChange > MAX_ACCEPTABLE_UNDERLYING_CHANGE)
            revert AcceptableUnderlyingChangeTooBig(
                _acceptableUnderlyingChange,
                MAX_ACCEPTABLE_UNDERLYING_CHANGE
            );
        acceptableUnderlyingChange = _acceptableUnderlyingChange;
    }

    function updateEstimatedRewardsPerSecond(
        int _estimatedRewardsPerSecond
    ) public onlyRole(UPDATER_ROLE) {
        uint256 maxEstimatedRewardsPerSecond = totalAssets() / 30000000; // 0,00003%
        if (
            _estimatedRewardsPerSecond > int(maxEstimatedRewardsPerSecond) ||
            _estimatedRewardsPerSecond < -int(maxEstimatedRewardsPerSecond)
        )
            revert RewardsPerSecondTooBig(
                _estimatedRewardsPerSecond,
                int(maxEstimatedRewardsPerSecond)
            );
        estimatedRewardsPerSecond = _estimatedRewardsPerSecond;
    }

    /// @notice Update report timelock
    modifier updateReportTimelock() {
        uint256 currentUnlockTime = submitReportUnlockTime;
        if (block.timestamp < currentUnlockTime)
            revert SubmitReportTimelocked(currentUnlockTime, block.timestamp);
        _;
        submitReportUnlockTime = block.timestamp + SUBMIT_REPORT_TIMELOCK;
    }

    /// @notice Check epochs from report are valid
    modifier validEpochs(EpochsReport memory _epochsReport) {
        if (_epochsReport.from > _epochsReport.to)
            revert InvalidEpochs(_epochsReport.from, _epochsReport.to);
        if (_epochsReport.from != lastEpochReported + 1 && lastEpochReported != 0)
            revert InvalidEpochFrom(_epochsReport.from, lastEpochReported);
        _;
        lastEpochReported = _epochsReport.to;
    }

    /// @notice Report staking results by epoch
    /// @param _epochsReport Total rewards and penalties for the given epochs
    /// @param _estimatedRewardsPerSecond Estimated rewards per second
    /// @dev Update the amount of ethers in the protocol, the estimated rewards per second and, if there are rewards, mint new mpETH to treasury
    function reportEpochs(
        EpochsReport memory _epochsReport,
        int _estimatedRewardsPerSecond
    ) external onlyRole(UPDATER_ROLE) updateReportTimelock validEpochs(_epochsReport) {
        uint256 currentTotalUnderlying = totalUnderlying;
        uint256 newTotalUnderlying = currentTotalUnderlying +
            _epochsReport.rewards -
            _epochsReport.penalties;

        bool balanceIncremented = newTotalUnderlying > currentTotalUnderlying;

        // Check balance difference
        uint256 diff = balanceIncremented
            ? newTotalUnderlying - currentTotalUnderlying
            : currentTotalUnderlying - newTotalUnderlying;

        uint256 maxDiff = (totalAssets() * acceptableUnderlyingChange) / 10000;
        if (diff > maxDiff) revert UpdateTooBig(totalAssets(), newTotalUnderlying, diff, maxDiff);

        // If the balance didn't increase there's no reward to get fees
        if (balanceIncremented) {
            uint256 assetsAsFee = (diff * rewardsFee) / 10000;
            uint256 shares = previewDeposit(assetsAsFee);
            _mint(treasury, shares);
        }

        totalUnderlying = newTotalUnderlying;
        updateEstimatedRewardsPerSecond(_estimatedRewardsPerSecond);
        emit ReportEpochs(_epochsReport, newTotalUnderlying);
    }

    /// @notice Stake ETH in contract to validators
    /// @param _nodes Nodes info for staking
    /// @param _requestPoolAmount ETH amount to take from LiquidUnstakePool
    /// @param _requestWithdrawalAmount ETH amount to take from Withdrawal
    /// @param _depositContractRoot Valid root state of the deposit contract to avoid front-running
    function pushToBeacon(
        Node[] memory _nodes,
        uint256 _requestPoolAmount,
        uint256 _requestWithdrawalAmount,
        bytes32 _depositContractRoot
    ) external onlyRole(ACTIVATOR_ROLE) {
        if (_depositContractRoot != depositContract.get_deposit_root())
            revert DepositRootMismatch();
        uint32 nodesLength = uint32(_nodes.length);
        {
            uint256 requiredBalance = nodesLength * 32 ether;
            uint256 stakingBalance = address(this).balance;
            if (stakingBalance + _requestPoolAmount + _requestWithdrawalAmount < requiredBalance)
                revert NotEnoughETHtoStake(
                    stakingBalance,
                    _requestPoolAmount,
                    _requestWithdrawalAmount,
                    requiredBalance
                );
        }
        if (_requestPoolAmount > 0)
            LiquidUnstakePool(liquidUnstakePool).getEthForValidator(_requestPoolAmount);
        if (_requestWithdrawalAmount > 0)
            Withdrawal(withdrawal).getEthForValidator(_requestWithdrawalAmount);

        uint32 _totalNodesActivated = totalNodesActivated;
        bytes memory _withdrawalCredential = withdrawalCredential;
        for (uint256 i = 0; i != nodesLength; ++i) {
            if (nodePubkeyUsed[_nodes[i].pubkey]) revert NodeAlreadyUsed(_nodes[i].pubkey);
            nodePubkeyUsed[_nodes[i].pubkey] = true;
            depositContract.deposit{value: 32 ether}(
                _nodes[i].pubkey,
                _withdrawalCredential,
                _nodes[i].signature,
                _nodes[i].depositDataRoot
            );
            _totalNodesActivated++;
            emit Stake(_totalNodesActivated, _nodes[i].pubkey);
        }

        totalNodesActivated = _totalNodesActivated;
    }

    /// @notice Request ETH from LiquidUnstakePool to Withdrawal
    /// @dev Request LiquidUnstakePool to deposit a certain amount of ETH and then send it to Withdrawal
    /// @param _requestedETH Amount of ETH to request
    function requestEthFromLiquidPoolToWithdrawal(
        uint256 _requestedETH
    ) external onlyRole(UPDATER_ROLE) {
        LiquidUnstakePool(liquidUnstakePool).getEthForValidator(_requestedETH);
        withdrawal.sendValue(_requestedETH);
    }

    /// @notice Deposit WETH
    /// @dev Same function as in ERC4626 but removes maxDeposit check and add validDeposit modifier who checks for minDeposit
    function deposit(uint256 _assets, address _receiver) public override returns (uint256) {
        uint256 _shares = previewDeposit(_assets);
        IERC20Upgradeable(asset()).safeTransferFrom(msg.sender, address(this), _assets);
        IWETH(asset()).withdraw(_assets);
        _deposit(msg.sender, _receiver, _assets, _shares);
        return _shares;
    }

    /// @notice Deposit ETH
    /// @dev Equivalent to deposit function but for native token
    function depositETH(address _receiver) public payable returns (uint256) {
        uint256 _shares = previewDeposit(msg.value);
        _deposit(msg.sender, _receiver, msg.value, _shares);
        return _shares;
    }

    /// @notice Confirm ETH or WETH deposit
    /// @dev Use ETH or get and convert WETH to ETH, get mpETH from pool and/or mint new mpETH
    function _deposit(
        address _caller,
        address _receiver,
        uint256 _assets,
        uint256 _shares
    ) internal override checkWhitelisting {
        if (_assets < MIN_DEPOSIT) revert DepositTooLow(MIN_DEPOSIT, _assets);
        (uint256 sharesFromPool, uint256 assetsToPool) = _getmpETHFromPool(_shares, address(this));
        uint256 sharesToMint = _shares - sharesFromPool;
        uint256 assetsToAdd = _assets - assetsToPool;

        if (sharesToMint > 0) _mint(address(this), sharesToMint);
        totalUnderlying += assetsToAdd;

        uint256 sharesToUser = _shares;

        if (msg.sender != liquidUnstakePool) {
            uint256 sharesToTreasury = (_shares * depositFee) / 10000;
            _transfer(address(this), treasury, sharesToTreasury);
            sharesToUser -= sharesToTreasury;
        }

        _transfer(address(this), _receiver, sharesToUser);

        emit Deposit(_caller, _receiver, _assets, _shares);
    }

    /// @notice Try to swap ETH for mpETH in the LiquidPool
    /// @dev Avoid try to get mpETH from LiquidPool if this is also the caller bcs LiquidPool.getEthForValidator called on pushToBeacon also calls depositETH, making a loop
    /// @return sharesFromPool Shares (mpETH) received from pool
    /// @return assetsToPool Assets (ETH) sent to pool to swap for shares
    function _getmpETHFromPool(
        uint256 _shares,
        address _receiver
    ) private returns (uint256 sharesFromPool, uint256 assetsToPool) {
        if (msg.sender != liquidUnstakePool) {
            sharesFromPool = MathUpgradeable.min(balanceOf(liquidUnstakePool), _shares);

            if (sharesFromPool > 0) {
                assetsToPool = previewMint(sharesFromPool);
                assert(
                    LiquidUnstakePool(liquidUnstakePool).swapETHFormpETH{value: assetsToPool}(
                        _receiver
                    ) == sharesFromPool
                );
            }
        }
    }

    /// @dev Same function as in ERC4626 implementation but instead of transfer assets set pending withdraw on withdrawal contract
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        _burn(owner, shares);
        totalUnderlying -= assets;
        Withdrawal(withdrawal).requestWithdraw(assets, caller, receiver);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }
}