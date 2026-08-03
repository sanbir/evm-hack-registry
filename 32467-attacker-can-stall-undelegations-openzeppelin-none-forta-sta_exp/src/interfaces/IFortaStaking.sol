// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

uint8 constant UNDEFINED_SUBJECT = 255;
uint8 constant SCANNER_SUBJECT = 0;
uint8 constant AGENT_SUBJECT = 1;
uint8 constant SCANNER_POOL_SUBJECT = 2;
uint8 constant DELEGATOR_SCANNER_POOL_SUBJECT = 3;

interface IFortaStaking {
    type SubjectStakeAgency is uint8;

    error AmountTooLarge(uint256 amount, uint256 max);
    error AmountTooSmall(uint256 amount, uint256 min);
    error ForbiddenForType(uint8 subjectType, SubjectStakeAgency provided, SubjectStakeAgency expected);
    error FrozenSubject();
    error InvalidSubjectType(uint8 subjectType);
    error MissingRole(bytes32 role, address account);
    error NoActiveShares();
    error NoInactiveShares();
    error SlashingOver90Percent();
    error StakeInactiveOrSubjectNotFound();
    error UnsupportedInterface(string name);
    error WithdrawalNotReady();
    error WithdrawalSharesNotTransferible();
    error ZeroAddress(string name);

    event AccessManagerUpdated(address indexed newAddressManager);
    event AdminChanged(address previousAdmin, address newAdmin);
    event ApprovalForAll(address indexed account, address indexed operator, bool approved);
    event BeaconUpgraded(address indexed beacon);
    event DelaySet(uint256 newWithdrawalDelay);
    event Froze(uint8 indexed subjectType, uint256 indexed subject, address indexed by, bool isFrozen);
    event Initialized(uint8 version);
    event MaxStakeReached(uint8 indexed subjectType, uint256 indexed subject);
    event RouterUpdated(address indexed router);
    event SlashDelegatorsPercentSet(uint256 percent);
    event Slashed(uint8 indexed subjectType, uint256 indexed subject, address indexed by, uint256 value);
    event SlashedShareSent(uint8 indexed subjectType, uint256 indexed subject, address indexed by, uint256 value);
    event StakeDeposited(uint8 indexed subjectType, uint256 indexed subject, address indexed account, uint256 amount);
    event StakeHelpersConfigured(address indexed subjectGateway, address indexed allocator);
    event TokensSwept(address indexed token, address to, uint256 amount);
    event TransferBatch(
        address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values
    );
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    event TreasurySet(address newTreasury);
    event URI(string value, uint256 indexed id);
    event Upgraded(address indexed implementation);
    event WithdrawalExecuted(uint8 indexed subjectType, uint256 indexed subject, address indexed account);
    event WithdrawalInitiated(
        uint8 indexed subjectType, uint256 indexed subject, address indexed account, uint64 deadline
    );

    function MAX_SLASHABLE_PERCENT() external view returns (uint256);
    function MAX_WITHDRAWAL_DELAY() external view returns (uint256);
    function MIN_WITHDRAWAL_DELAY() external view returns (uint256);
    function activeSharesToStake(uint256 activeSharesId, uint256 amount) external view returns (uint256);
    function activeStakeFor(uint8 subjectType, uint256 subject) external view returns (uint256);
    function allocator() external view returns (address);
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function balanceOfBatch(address[] memory accounts, uint256[] memory ids) external view returns (uint256[] memory);
    function configureStakeHelpers(address _subjectGateway, address _allocator) external;
    function deposit(uint8 subjectType, uint256 subject, uint256 stakeValue) external returns (uint256);
    function disableRouter() external;
    function exists(uint256 id) external view returns (bool);
    function freeze(uint8 subjectType, uint256 subject, bool frozen) external;
    function getDelegatedSubjectType(uint8 subjectType) external pure returns (uint8);
    function getDelegatorSubjectType(uint8 subjectType) external pure returns (uint8);
    function getSubjectTypeAgency(uint8 subjectType) external pure returns (SubjectStakeAgency);
    function inactiveSharesOf(uint8 subjectType, uint256 subject, address account) external view returns (uint256);
    function inactiveSharesToStake(uint256 inactiveSharesId, uint256 amount) external view returns (uint256);
    function inactiveStakeFor(uint8 subjectType, uint256 subject) external view returns (uint256);
    function initialize(
        address __manager,
        address __stakedToken,
        uint64 __withdrawalDelay,
        address __treasury
    )
        external;
    function initiateWithdrawal(uint8 subjectType, uint256 subject, uint256 sharesValue) external returns (uint64);
    function isApprovedForAll(address account, address operator) external view returns (bool);
    function isFrozen(uint8 subjectType, uint256 subject) external view returns (bool);
    function migrate(
        uint8 oldSubjectType,
        uint256 oldSubject,
        uint8 newSubjectType,
        uint256 newSubject,
        address staker
    )
        external;
    function multicall(bytes[] memory data) external returns (bytes[] memory results);
    function openProposals(uint256) external view returns (uint256);
    function proxiableUUID() external view returns (bytes32);
    function relayPermit(uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    )
        external;
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes memory data) external;
    function setAccessManager(address newManager) external;
    function setApprovalForAll(address operator, bool approved) external;
    function setDelay(uint64 newDelay) external;
    function setName(address ensRegistry, string memory ensName) external;
    function setReentrancyGuard() external;
    function setSlashDelegatorsPercent(uint256 percent) external;
    function setTreasury(address newTreasury) external;
    function setURI(string memory newUri) external;
    function sharesOf(uint8 subjectType, uint256 subject, address account) external view returns (uint256);
    function slash(
        uint8 subjectType,
        uint256 subject,
        uint256 stakeValue,
        address proposer,
        uint256 proposerPercent
    )
        external
        returns (uint256);
    function slashDelegatorsPercent() external view returns (uint256);
    function stakeToActiveShares(uint256 activeSharesId, uint256 amount) external view returns (uint256);
    function stakeToInactiveShares(uint256 inactiveSharesId, uint256 amount) external view returns (uint256);
    function stakedToken() external view returns (address);
    function subjectGateway() external view returns (address);
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
    function sweep(address token, address recipient) external returns (uint256);
    function totalActiveStake() external view returns (uint256);
    function totalInactiveShares(uint8 subjectType, uint256 subject) external view returns (uint256);
    function totalInactiveStake() external view returns (uint256);
    function totalShares(uint8 subjectType, uint256 subject) external view returns (uint256);
    function totalSupply(uint256 id) external view returns (uint256);
    function treasury() external view returns (address);
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable;
    function uri(uint256) external view returns (string memory);
    function version() external view returns (string memory);
    function withdraw(uint8 subjectType, uint256 subject) external returns (uint256);
}
