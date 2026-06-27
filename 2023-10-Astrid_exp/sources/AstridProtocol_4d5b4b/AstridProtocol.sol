// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./helpers/Utils.sol";
import "./interfaces/IRestakedETH.sol";
import "./interfaces/IDelegator.sol";
import "./eigenlayer/interfaces/IStrategyManager.sol";
import "./eigenlayer/interfaces/IStrategy.sol";
import "./eigenlayer/interfaces/ISlasher.sol";
import "./eigenlayer/interfaces/IDelegationManager.sol";

contract AstridProtocol is Initializable, UUPSUpgradeable, PausableUpgradeable, AccessControlUpgradeable, ReentrancyGuard {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant REBASER_ROLE = keccak256("REBASER_ROLE");

    struct StakedTokenMapping {
        bool whitelisted;
        address restakedTokenAddress;
        address eigenLayerStrategyAddress;
    }
    mapping(address => StakedTokenMapping) public stakedTokens;

    address public eigenLayerStrategyManagerAddress;

    /* LEGACY STORAGE */
    struct ReStakeInfo {
        address staker;
        address stakedTokenAddress;
        uint256 amount;
        uint256 stakedAt;
        uint256 shares;
    }

    struct WithdrawalInfo {
        address withdrawer;
        address restakedTokenAddress;
        uint256 amount;
        uint256 shares;
        bool pending;
        uint32 withdrawalStartBlock;
        uint256 withdrawInitiatedAt;
        uint256 withdrawCompletedAt;
        uint256 nonce;
        bytes32 withdrawalRoot;
    }

    mapping(address => ReStakeInfo[]) public restakes;
    mapping(address => WithdrawalInfo[]) public withdrawals;
    uint96 public withdrawalsNonce;
    /* END LEGACY STORAGE */

    struct DepositInfo {
        address staker;
        address stakedTokenAddress;
        uint256 amount;
        uint256 stakedAt;
    }

    enum WithdrawalStatus{ REQUESTED, PROCESSED, CLAIMED }
    struct WithdrawalRequest {
        address withdrawer;
        address restakedTokenAddress;
        uint256 amount;
        uint256 requestedRestakedTokenShares;
        uint256 claimableStakedTokenAmount;
        WithdrawalStatus status;
        uint32 withdrawalStartBlock;
        uint256 withdrawRequestedAt;
        uint256 withdrawProcessedAt;
        uint256 withdrawClaimedAt;
        uint256 withdrawalRequestsIndex;
        uint256 withdrawalRequestsByUserIndex;
    }

    struct ReBaseInfo {
        uint256 restakedTokenTotalSupply;
        uint256 stakedTokenBackedSupply;
        uint32 currentBlock;
        uint256 currentTimestamp;
    }

    IDelegator[] public delegators;
    mapping(address => DepositInfo[]) public deposits;
    mapping(address => uint256) public totalWithdrawalRequests; // restakedTokenAddress => shares
    WithdrawalRequest[] public withdrawalRequests;
    uint256 public withdrawalProcessingCurrentIndex;
    mapping(address => WithdrawalRequest[]) public withdrawalRequestsByUser;
    mapping(address => uint256) public totalClaimableWithdrawals; // stakedTokenAddress => amount
    bool public processWithdrawalsOnWithdraw;
    uint32 public maxDelegators;

    event EigenLayerStrategyManagerAddressSet(address oldAddress, address newAddress);
    event StakedTokenMappingSet(address stakedTokenAddress, bool whitelisted, address restakedTokenAddress, address eigenLayerStrategyAddress);
    event ProcessWithdrawalsOnWithdrawSet(bool value);
    event MaxDelegatorsSet(uint32 oldValue, uint32 newValue);
    event DelegatorAdded(address indexed delegator);
    event DelegatorRemoved(address indexed delegator);
    event DelegatorRestaked(address indexed delegator, address stakedTokenAddress, uint256 amount, uint256 shares);
    event DelegatorWithdrawalQueued(address indexed delegator, address stakedTokenAddress, uint96 nonce);
    event DelegatorWithdrawalCompleted(address indexed delegator, uint96 withdrawalIndex);
    event DelegatorPulled(address indexed delegator, address token, uint256 balance);
    event DelegatorETHPulled(address indexed delegator, uint256 balance);
    event DepositPerformed(address indexed from, address stakedTokenAddress, uint256 amount);
    event WithdrawalRequested(address indexed to, address restakedTokenAddress, uint256 amount, uint256 shares);
    event WithdrawalProcessed(uint256 withdrawalRequestsIndex);
    event WithdrawalClaimed(address indexed to, uint256 withdrawalRequestsIndex);
    event RebasePerformed(address indexed restakedTokenAddress, uint256 currentTimestamp, uint256 totalSupply, bool isRebasePositive, uint256 supplyDelta);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _governanceAddr, address _eigenLayerStrategyManagerAddr, uint32 _maxDelegators) initializer public {
        require(_governanceAddr != address(0), "AstridProtocol: Governance cannot be zero address");
        require(Utils.contractExists(_eigenLayerStrategyManagerAddr), "AstridProtocol: Contract does not exist");

        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _governanceAddr);
        _grantRole(PAUSER_ROLE, _governanceAddr);
        _grantRole(UPGRADER_ROLE, _governanceAddr);
        _grantRole(REBASER_ROLE, _governanceAddr);

        eigenLayerStrategyManagerAddress = _eigenLayerStrategyManagerAddr;
        maxDelegators = _maxDelegators;
    }

    function setEigenLayerStrategyManagerAddress(
        address _eigenLayerStrategyManagerAddr
    ) public whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        require(Utils.contractExists(_eigenLayerStrategyManagerAddr), "AstridProtocol: Contract does not exist");

        emit EigenLayerStrategyManagerAddressSet(eigenLayerStrategyManagerAddress, _eigenLayerStrategyManagerAddr);

        eigenLayerStrategyManagerAddress = _eigenLayerStrategyManagerAddr;
    }

    function setStakedTokenMapping(
        address _stakedTokenAddr,
        bool _whitelisted,
        address _restakedTokenAddr,
        address _eigenLayerStrategyAddr
    ) public whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        require(Utils.contractExists(_stakedTokenAddr), "AstridProtocol: Contract does not exist");
        require(Utils.contractExists(_restakedTokenAddr), "AstridProtocol: Contract does not exist");
        require(Utils.contractExists(_eigenLayerStrategyAddr), "AstridProtocol: Contract does not exist");

        stakedTokens[_stakedTokenAddr] = StakedTokenMapping({
            whitelisted: _whitelisted,
            restakedTokenAddress: _restakedTokenAddr,
            eigenLayerStrategyAddress: _eigenLayerStrategyAddr
        });

        emit StakedTokenMappingSet(_stakedTokenAddr, _whitelisted, _restakedTokenAddr, _eigenLayerStrategyAddr);
    }

    function setProcessWithdrawalsOnWithdraw(
        bool _value
    ) public whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        processWithdrawalsOnWithdraw = _value;
        emit ProcessWithdrawalsOnWithdrawSet(_value);
    }

    function setMaxDelegators(
        uint32 _maxDelegators
    ) public whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_maxDelegators >= delegators.length, "AstridProtocol: _maxDelegators less than delegators.length");

        emit MaxDelegatorsSet(maxDelegators, _maxDelegators);

        maxDelegators = _maxDelegators;
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Method used for upgrading the proxy implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal onlyRole(UPGRADER_ROLE) override {
    }

    function _delegatorExists(
        address _delegatorAddress
    ) internal view returns (bool) {
        for (uint256 i; i < delegators.length; i++) {
            if (_delegatorAddress == address(delegators[i])) {
                return true;
            }
        }
        return false;
    }

    function addDelegators(
        IDelegator[] calldata _delegatorContracts
    ) public whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        require(delegators.length + _delegatorContracts.length <= maxDelegators, "AstridProtocol: Max delegators length exceeded");

        for (uint256 i; i < _delegatorContracts.length; i++) {
            address delegatorAddress = address(_delegatorContracts[i]);
            require(Utils.contractExists(delegatorAddress), "AstridProtocol: Contract does not exist");
            require(!_delegatorExists(delegatorAddress), "AstridProtocol: Duplicate delegator address");

            delegators.push(_delegatorContracts[i]);
            emit DelegatorAdded(delegatorAddress);
        }
    }

    function removeDelegator(
        uint16 _delegatorIndex
    ) public whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_delegatorIndex < delegators.length, "AstridProtocol: _delegatorIndex out of bounds");

        address delegatorAddress = address(delegators[_delegatorIndex]);
        delegators[_delegatorIndex] = delegators[delegators.length - 1];
        delegators.pop();

        emit DelegatorRemoved(delegatorAddress);
    }

    function delegatorsLength() public view returns (uint256) {
        return delegators.length;
    }

    function restakeDelegator(
        uint16 _delegatorIndex,
        address _stakedTokenAddress,
        uint256 _amount
    ) public whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
        require(_delegatorIndex < delegators.length, "AstridProtocol: _delegatorIndex out of bounds");
        require(Utils.contractExists(_stakedTokenAddress), "AstridProtocol: Contract does not exist");
        require(
            IERC20(_stakedTokenAddress).balanceOf(address(this)) >=
            totalClaimableWithdrawals[_stakedTokenAddress] + _amount,
            "AstridProtocol: Insufficient staked token available balance"
        );

        address delegator = address(delegators[_delegatorIndex]);

        bool sent = Utils.payDirect(delegator, _amount, _stakedTokenAddress);
        require(sent, "AstridProtocol: Failed to send staked token");

        uint256 shares = IDelegator(delegator).restake(
            _stakedTokenAddress,
            eigenLayerStrategyManagerAddress,
            stakedTokens[_stakedTokenAddress].eigenLayerStrategyAddress
        );

        emit DelegatorRestaked(delegator, _stakedTokenAddress, _amount, shares);

        return shares;
    }

    function queueWithdrawalDelegator(
        uint16 _delegatorIndex,
        address _stakedTokenAddress
    ) public whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) returns (uint96) {
        require(_delegatorIndex < delegators.length, "AstridProtocol: _delegatorIndex out of bounds");
        require(Utils.contractExists(_stakedTokenAddress), "AstridProtocol: Contract does not exist");

        uint96 nonce = delegators[_delegatorIndex].queueWithdrawal(
            _stakedTokenAddress,
            eigenLayerStrategyManagerAddress,
            stakedTokens[_stakedTokenAddress].eigenLayerStrategyAddress
        );

        emit DelegatorWithdrawalQueued(address(delegators[_delegatorIndex]), _stakedTokenAddress, nonce);

        return nonce;
    }

    function completeQueuedWithdrawalDelegator(
        uint16 _delegatorIndex,
        uint96 _withdrawalIndex,
        uint256 _middlewareTimesIndex
    ) public whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_delegatorIndex < delegators.length, "AstridProtocol: _delegatorIndex out of bounds");

        IDelegator delegator = delegators[_delegatorIndex];
        address _stakedTokenAddress = delegator.getStakedTokenAddressAtWithdrawalsIndex(_withdrawalIndex);
        delegator.completeQueuedWithdrawal(
            _withdrawalIndex,
            _middlewareTimesIndex,
            eigenLayerStrategyManagerAddress,
            stakedTokens[_stakedTokenAddress].eigenLayerStrategyAddress
        );

        emit DelegatorWithdrawalCompleted(address(delegator), _withdrawalIndex);
    }

    function pullDelegator(
        uint16 _delegatorIndex,
        address _token
    ) public whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 balance) {
        require(_delegatorIndex < delegators.length, "AstridProtocol: _delegatorIndex out of bounds");
        require(Utils.contractExists(_token), "AstridProtocol: Contract does not exist");

        balance = delegators[_delegatorIndex].pull(_token);
        emit DelegatorPulled(address(delegators[_delegatorIndex]), _token, balance);
    }

    function rebaseInfo(address _stakedTokenAddress) public view returns (ReBaseInfo memory) {
        require(Utils.contractExists(_stakedTokenAddress), "AstridProtocol: Contract does not exist");

        StakedTokenMapping memory stakedTokenMapping = stakedTokens[_stakedTokenAddress];

        uint256 _stakedTokenBackedSupply;
        for (uint256 i; i < delegators.length; i++) {
            _stakedTokenBackedSupply += delegators[i].getAssetBalance(_stakedTokenAddress, stakedTokenMapping.eigenLayerStrategyAddress);
        }
        _stakedTokenBackedSupply += IERC20(_stakedTokenAddress).balanceOf(address(this));
        _stakedTokenBackedSupply -= totalClaimableWithdrawals[_stakedTokenAddress];

        ReBaseInfo memory info = ReBaseInfo({
            restakedTokenTotalSupply: IRestakedETH(stakedTokenMapping.restakedTokenAddress).totalSupply(),
            stakedTokenBackedSupply: _stakedTokenBackedSupply,
            currentBlock: uint32(block.number),
            currentTimestamp: block.timestamp
        });

        return info;
    }

    function rebase(address _stakedTokenAddress) public whenNotPaused onlyRole(REBASER_ROLE) returns (uint256 _totalSupply) {
        require(Utils.contractExists(_stakedTokenAddress), "AstridProtocol: Contract does not exist");
        ReBaseInfo memory info = rebaseInfo(_stakedTokenAddress);
        require(info.restakedTokenTotalSupply != info.stakedTokenBackedSupply, "AstridProtocol: restakedTokenTotalSupply = stakedTokenBackedSupply");

        address _restakedTokenAddress = stakedTokens[_stakedTokenAddress].restakedTokenAddress;
        uint256 _supplyDelta;
        bool _isRebasePositive;

        if (info.restakedTokenTotalSupply < info.stakedTokenBackedSupply) {
            _supplyDelta = info.stakedTokenBackedSupply - info.restakedTokenTotalSupply;
            _isRebasePositive = true;
        } else {
            _supplyDelta = info.restakedTokenTotalSupply - info.stakedTokenBackedSupply;
            _isRebasePositive = false;
        }

        _totalSupply = IRestakedETH(_restakedTokenAddress).rebase(info.currentTimestamp, _isRebasePositive, _supplyDelta);
        emit RebasePerformed(_restakedTokenAddress, info.currentTimestamp, _totalSupply, _isRebasePositive, _supplyDelta);
    }

    function depositsLength(address staker) public view returns (uint256) {
        return deposits[staker].length;
    }

    function withdrawalRequestsLength() public view returns (uint256) {
        return withdrawalRequests.length;
    }

    function withdrawalRequestsByUserLength(address withdrawer) public view returns (uint256) {
        return withdrawalRequestsByUser[withdrawer].length;
    }

    function deposit(address _stakedTokenAddress, uint256 amount) public nonReentrant whenNotPaused {
        require(Utils.contractExists(_stakedTokenAddress), "AstridProtocol: Contract does not exist");
        require(amount > 0, "AstridProtocol: Amount must be greater than 0");
        StakedTokenMapping memory stakedTokenMapping = stakedTokens[_stakedTokenAddress];

        require(stakedTokenMapping.whitelisted, "AstridProtocol: Staked token not whitelisted");
        require(IERC20(_stakedTokenAddress).balanceOf(msg.sender) >= amount, "AstridProtocol: Insufficient balance of staked token");
        require(IERC20(_stakedTokenAddress).allowance(msg.sender, address(this)) >= amount, "AstridProtocol: Insufficient allowance of staked token");

        // receive staked token from user
        bool amountSent = Utils.payMe(msg.sender, amount, _stakedTokenAddress);
        require(amountSent, "AstridProtocol: Failed to send staked token");

        // mint restaked token to user
        IRestakedETH(stakedTokenMapping.restakedTokenAddress).mint(msg.sender, amount);

        // save stake info
        deposits[msg.sender].push(DepositInfo({
            staker: msg.sender,
            stakedTokenAddress: _stakedTokenAddress,
            amount: amount,
            stakedAt: block.timestamp
        }));

        // emit staked performed event
        emit DepositPerformed(msg.sender, _stakedTokenAddress, amount);
    }

    function withdraw(address _restakedTokenAddress, uint256 amount) public nonReentrant whenNotPaused {
        require(Utils.contractExists(_restakedTokenAddress), "AstridProtocol: Contract does not exist");
        require(amount > 0, "AstridProtocol: Amount must be greater than 0");
        require(IERC20(_restakedTokenAddress).balanceOf(msg.sender) >= amount, "AstridProtocol: Insufficient balance of restaked token");
        require(IERC20(_restakedTokenAddress).allowance(msg.sender, address(this)) >= amount, "AstridProtocol: Insufficient allowance of restaked token");

        uint256 sharesBefore = IRestakedETH(_restakedTokenAddress).scaledBalanceOf(address(this));

        // receive restaked token from user to "lock" it
        bool amountSent = Utils.payMe(msg.sender, amount, _restakedTokenAddress);
        require(amountSent, "AstridProtocol: Failed to send restaked token");

        uint256 sharesAfter = IRestakedETH(_restakedTokenAddress).scaledBalanceOf(address(this));
        uint256 shares = sharesAfter.sub(sharesBefore); // we store shares of restakedETH to ensure that it is still subject to rebase when locked

        WithdrawalRequest memory request = WithdrawalRequest({
            withdrawer: msg.sender,
            restakedTokenAddress: _restakedTokenAddress,
            amount: amount,
            requestedRestakedTokenShares: shares,
            claimableStakedTokenAmount: 0, // placeholder
            status: WithdrawalStatus.REQUESTED,
            withdrawalStartBlock: uint32(block.number),
            withdrawRequestedAt: block.timestamp,
            withdrawProcessedAt: 0,
            withdrawClaimedAt: 0,
            withdrawalRequestsIndex: withdrawalRequests.length,
            withdrawalRequestsByUserIndex: withdrawalRequestsByUser[msg.sender].length
        });

        totalWithdrawalRequests[_restakedTokenAddress] += shares;
        withdrawalRequests.push(request);
        withdrawalRequestsByUser[msg.sender].push(request);

        emit WithdrawalRequested(msg.sender, _restakedTokenAddress, amount, shares);

        if (processWithdrawalsOnWithdraw) {
            _processWithdrawals();
        }
    }

    function processWithdrawals() public nonReentrant whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        _processWithdrawals();
    }

    function _processWithdrawals() internal whenNotPaused {
        uint256 _withdrawalRequestsLength = withdrawalRequests.length;
        while(withdrawalProcessingCurrentIndex < _withdrawalRequestsLength) {
            WithdrawalRequest memory request = withdrawalRequests[withdrawalProcessingCurrentIndex];
            require(request.status == WithdrawalStatus.REQUESTED, "AstridProtocol: Withdrawal status mismatch");

            address _restakedTokenAddress = request.restakedTokenAddress;
            address _stakedTokenAddress = IRestakedETH(_restakedTokenAddress).stakedTokenAddress();
            uint256 requestedAmount = IRestakedETH(_restakedTokenAddress).scaledBalanceToBalance(request.requestedRestakedTokenShares);
            if (requestedAmount > IERC20(_stakedTokenAddress).balanceOf(address(this)) - totalClaimableWithdrawals[_stakedTokenAddress]) {
                break;
            }

            totalWithdrawalRequests[_restakedTokenAddress] -= request.requestedRestakedTokenShares;
            IRestakedETH(_restakedTokenAddress).burn(address(this), requestedAmount);
            totalClaimableWithdrawals[_stakedTokenAddress] += requestedAmount;

            withdrawalRequests[withdrawalProcessingCurrentIndex].claimableStakedTokenAmount = requestedAmount;
            withdrawalRequests[withdrawalProcessingCurrentIndex].status = WithdrawalStatus.PROCESSED;
            withdrawalRequests[withdrawalProcessingCurrentIndex].withdrawProcessedAt = block.timestamp;

            uint256 withdrawerIndex = request.withdrawalRequestsByUserIndex;
            withdrawalRequestsByUser[request.withdrawer][withdrawerIndex].claimableStakedTokenAmount = requestedAmount;
            withdrawalRequestsByUser[request.withdrawer][withdrawerIndex].status = WithdrawalStatus.PROCESSED;
            withdrawalRequestsByUser[request.withdrawer][withdrawerIndex].withdrawProcessedAt = block.timestamp;

            emit WithdrawalProcessed(withdrawalProcessingCurrentIndex);

            withdrawalProcessingCurrentIndex += 1;
        }
    }

    function claim(uint256 withdrawerIndex) public nonReentrant whenNotPaused {
        require(withdrawerIndex < withdrawalRequestsByUser[msg.sender].length, "AstridProtocol: withdrawerIndex out of bounds");
        WithdrawalRequest memory request = withdrawalRequestsByUser[msg.sender][withdrawerIndex];

        require(request.status == WithdrawalStatus.PROCESSED, "AstridProtocol: Withdrawal status mismatch");
        require(request.withdrawer == msg.sender, "AstridProtocol: Invalid withdrawer");

        address _stakedTokenAddress = IRestakedETH(request.restakedTokenAddress).stakedTokenAddress();

        withdrawalRequests[request.withdrawalRequestsIndex].status = WithdrawalStatus.CLAIMED;
        withdrawalRequests[request.withdrawalRequestsIndex].withdrawClaimedAt = block.timestamp;
        withdrawalRequestsByUser[msg.sender][withdrawerIndex].status = WithdrawalStatus.CLAIMED;
        withdrawalRequestsByUser[msg.sender][withdrawerIndex].withdrawClaimedAt = block.timestamp;

        totalClaimableWithdrawals[_stakedTokenAddress] -= request.claimableStakedTokenAmount;

        bool sent = Utils.payDirect(msg.sender, request.claimableStakedTokenAmount, _stakedTokenAddress);
        require(sent, "AstridProtocol: Failed to send staked token");

        emit WithdrawalClaimed(msg.sender, request.withdrawalRequestsIndex);
    }

    /* TO BE DEPRECATED */
    function restakesLength(address staker) public view returns (uint256) {
        return restakes[staker].length + deposits[staker].length;
    }

    function withdrawalsLength(address withdrawer) public view returns (uint256) {
        return withdrawals[withdrawer].length;
    }

    event WithdrawCompleted(address indexed to, uint96 withdrawalIndex);

    // Supports completion of old withdrawals
    function completeQueuedWithdrawal(uint96 withdrawalIndex, uint256 middlewareTimesIndex) public nonReentrant whenNotPaused {
        require(withdrawalIndex < withdrawals[msg.sender].length, "AstridProtocol: withdrawalIndex out of bounds");
        WithdrawalInfo memory withdrawalInfo = withdrawals[msg.sender][withdrawalIndex];

        require(withdrawalInfo.withdrawCompletedAt == 0, "AstridProtocol: Withdrawal already completed");
        require(withdrawalInfo.withdrawer == msg.sender, "AstridProtocol: Invalid withdrawer");

        address _stakedTokenAddress = IRestakedETH(withdrawalInfo.restakedTokenAddress).stakedTokenAddress();

        IStrategy[] memory strategiesArr = new IStrategy[](1);
        strategiesArr[0] = IStrategy(stakedTokens[_stakedTokenAddress].eigenLayerStrategyAddress);
        uint256[] memory sharesArr = new uint256[](1);
        sharesArr[0] = withdrawalInfo.shares;

        address operator = IDelegationManager(IStrategyManager(eigenLayerStrategyManagerAddress).delegation()).delegatedTo(address(this));

        IStrategyManager.QueuedWithdrawal memory queuedWithdrawal = IStrategyManager.QueuedWithdrawal({
            strategies: strategiesArr,
            shares: sharesArr,
            depositor: address(this),
            withdrawerAndNonce: IStrategyManager.WithdrawerAndNonce({
                withdrawer: address(this),
                nonce: uint96(withdrawalInfo.nonce)
            }),
            withdrawalStartBlock: withdrawalInfo.withdrawalStartBlock,
            delegatedAddress: operator
        });

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(_stakedTokenAddress);

        uint256 balanceBefore = IERC20(_stakedTokenAddress).balanceOf(address(this));
        IStrategyManager(eigenLayerStrategyManagerAddress).completeQueuedWithdrawal(
            queuedWithdrawal,
            tokens,
            middlewareTimesIndex,
            true
        );
        uint256 balanceAfter = IERC20(_stakedTokenAddress).balanceOf(address(this));

        withdrawals[msg.sender][withdrawalIndex].pending = false;
        withdrawals[msg.sender][withdrawalIndex].withdrawCompletedAt = block.timestamp;

        bool sent = Utils.payDirect(msg.sender, balanceAfter.sub(balanceBefore), _stakedTokenAddress);
        require(sent, "AstridProtocol: Failed to send staked token");

        emit WithdrawCompleted(msg.sender, withdrawalIndex);
    }
    /* END TO BE DEPRECATED */

}