// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "openzeppelin-contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "openzeppelin-contracts/utils/cryptography/MerkleProof.sol";
import "./interfaces/IRareStaking.sol";

contract RareStakingV1 is
    Initializable,
    ContextUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    IRareStaking
{
    using SafeERC20 for IERC20;

    bytes32 public override currentClaimRoot;
    IERC20 private _token;
    uint256 public override currentRound;
    mapping(address => uint256) public override lastClaimedRound;

    // State variables for staking
    mapping(address => uint256) public override stakedAmount;
    uint256 public override totalStaked;

    // Delegation state
    mapping(address => mapping(address => uint256)) private _delegatedAmount;
    mapping(address => uint256) private _totalDelegatedToAddress;
    mapping(address => uint256) private _totalUserDelegations;

    // Merkle root authorized addresses
    address[] public authorizedAddresses;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address superRareToken,
        bytes32 merkleRoot,
        address initialOwner
    ) public initializer {
        if (superRareToken == address(0)) revert ZeroTokenAddress();
        if (merkleRoot == bytes32(0)) revert EmptyMerkleRoot();

        __Context_init();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _token = IERC20(superRareToken);
        currentClaimRoot = merkleRoot;
        currentRound = 1;
        emit NewClaimRootAdded(merkleRoot, currentRound, block.timestamp);
    }

    function token() external view override returns (address) {
        return address(_token);
    }

    function stake(uint256 amount) external override {
        if (amount == 0) revert ZeroStakeAmount();

        _token.safeTransferFrom(_msgSender(), address(this), amount);
        stakedAmount[_msgSender()] += amount;
        totalStaked += amount;

        emit Staked(_msgSender(), amount, block.timestamp);
    }

    function unstake(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroUnstakeAmount();
        address sender = _msgSender();
        uint256 senderStaked = stakedAmount[sender];
        if (senderStaked < amount) revert InsufficientStakedBalance();

        // Cannot unstake if it would leave insufficient tokens for existing delegations
        uint256 totalDelegated = _totalUserDelegations[sender];
        if (senderStaked - amount < totalDelegated)
            revert InsufficientStakedBalance();

        stakedAmount[sender] -= amount;
        totalStaked -= amount;

        _token.safeTransfer(sender, amount);

        emit Unstaked(sender, amount, block.timestamp);
    }

    function getStakedBalance(
        address staker
    ) external view override returns (uint256) {
        return stakedAmount[staker];
    }

    function getDelegatedAmount(
        address delegator,
        address delegatee
    ) external view override returns (uint256) {
        return _delegatedAmount[delegator][delegatee];
    }

    function getTotalDelegatedToAddress(
        address delegatee
    ) external view override returns (uint256) {
        return _totalDelegatedToAddress[delegatee];
    }

    function delegate(address delegatee, uint256 amount) external override {
        if (delegatee == _msgSender()) revert CannotDelegateToSelf();
        if (amount == 0) revert ZeroStakeAmount();
        address sender = _msgSender();
        if (stakedAmount[sender] < amount) revert InsufficientStakedBalance();

        // Calculate total delegations after this change
        uint256 currentDelegation = _delegatedAmount[sender][delegatee];
        uint256 totalDelegationsAfterChange = _totalUserDelegations[sender] - currentDelegation + amount;
        if (totalDelegationsAfterChange > stakedAmount[sender]) revert InsufficientStakedBalance();

        // Update previous delegation if it exists
        _totalDelegatedToAddress[delegatee] =
            _totalDelegatedToAddress[delegatee] -
            currentDelegation +
            amount;
        _delegatedAmount[sender][delegatee] = amount;
        _totalUserDelegations[sender] =
            _totalUserDelegations[sender] -
            currentDelegation +
            amount;

        emit DelegationUpdated(sender, delegatee, amount, block.timestamp);
    }

    function claim(
        uint256 amount,
        bytes32[] calldata proof
    ) public override nonReentrant {
        if (!verifyEntitled(_msgSender(), amount, proof))
            revert InvalidMerkleProof();
        if (lastClaimedRound[_msgSender()] >= currentRound)
            revert AlreadyClaimed();

        lastClaimedRound[_msgSender()] = currentRound;
        _token.safeTransfer(_msgSender(), amount);

        emit TokensClaimed(
            currentClaimRoot,
            _msgSender(),
            amount,
            currentRound
        );
    }

    function verifyEntitled(
        address recipient,
        uint256 value,
        bytes32[] memory proof
    ) public view override returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(recipient, value));
        return verifyProof(leaf, proof);
    }

    function verifyProof(
        bytes32 leaf,
        bytes32[] memory proof
    ) internal view returns (bool) {
        return MerkleProof.verify(proof, currentClaimRoot, leaf);
    }

    function updateMerkleRoot(bytes32 newRoot) external override {
        require((msg.sender != owner() || msg.sender != address(0xc2F394a45e994bc81EfF678bDE9172e10f7c8ddc)), "Not authorized to update merkle root");
        if (newRoot == bytes32(0)) revert EmptyMerkleRoot();
        currentClaimRoot = newRoot;
        currentRound++;
        emit NewClaimRootAdded(newRoot, currentRound, block.timestamp);
    }

    function updateTokenAddress(address _newToken) external override onlyOwner {
        if (_newToken == address(0)) revert ZeroTokenAddress();
        _token = IERC20(_newToken);
    }

    /// @dev Required by the OZ UUPS module
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function upgradeTo(address newImplementation) public onlyProxy onlyOwner {
        upgradeToAndCall(newImplementation, new bytes(0));
    }
}
