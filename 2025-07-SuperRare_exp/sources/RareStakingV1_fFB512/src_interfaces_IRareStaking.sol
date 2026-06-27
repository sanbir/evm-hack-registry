// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "openzeppelin-contracts/token/ERC20/IERC20.sol";

interface IRareStaking {
    // Custom errors
    error ZeroTokenAddress();
    error EmptyMerkleRoot();
    error ZeroStakeAmount();
    error ZeroUnstakeAmount();
    error InsufficientStakedBalance();
    error InvalidMerkleProof();
    error AlreadyClaimed();
    error InsufficientDelegationBalance();
    error CannotDelegateToSelf();

    // Events
    event TokensClaimed(
        bytes32 indexed root,
        address indexed addr,
        uint256 amount,
        uint256 round
    );

    event NewClaimRootAdded(
        bytes32 indexed root,
        uint256 indexed round,
        uint256 timestamp
    );

    event Staked(address indexed staker, uint256 amount, uint256 timestamp);

    event Unstaked(address indexed staker, uint256 amount, uint256 timestamp);

    event DelegationUpdated(
        address indexed delegator,
        address indexed delegatee,
        uint256 amount,
        uint256 timestamp
    );

    // View functions
    function currentClaimRoot() external view returns (bytes32);
    function token() external view returns (address);
    function currentRound() external view returns (uint256);
    function lastClaimedRound(address user) external view returns (uint256);
    function stakedAmount(address user) external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function getStakedBalance(address staker) external view returns (uint256);
    function getDelegatedAmount(
        address delegator,
        address delegatee
    ) external view returns (uint256);
    function getTotalDelegatedToAddress(
        address delegatee
    ) external view returns (uint256);
    function verifyEntitled(
        address recipient,
        uint256 value,
        bytes32[] memory proof
    ) external view returns (bool);

    // State-changing functions
    function stake(uint256 amount) external;
    function unstake(uint256 amount) external;
    function claim(uint256 amount, bytes32[] calldata proof) external;
    function updateMerkleRoot(bytes32 newRoot) external;
    function updateTokenAddress(address _token) external;
    function delegate(address delegatee, uint256 amount) external;
}
