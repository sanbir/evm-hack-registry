// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "../Comptroller/ComptrollerInterfaces.sol";
import "../InterestRateModels/InterestRateModelInterface.sol";
import "../Interfaces/EIP20NonStandardInterface.sol";

contract PNFTTokenStorage {
    /// @dev Guard variable for reentrancy checks
    bool internal _notEntered;

    /// @notice EIP-721 token name for this token
    string public name;

    /// @notice EIP-721 token symbol for this token
    string public symbol;

    /// @notice Administrator for this contract
    address payable public admin;

    /// @notice Pending administrator for this contract
    address payable public pendingAdmin;

    /// @notice Contract which oversees inter-PNFTToken operations
    ComptrollerNFTInterface public comptroller;

    /// @notice Mapping from token ID to owner address
    mapping(uint256 => address) internal tokensOwners;

    /// @notice Mapping owner address to token count
    mapping (address => uint) internal accountTokens;

    /// @notice Mapping from token ID to approved address
    mapping(uint256 => address) internal transferAllowances;

    /// @notice Mapping from owner to operator approvals
    mapping(address => mapping(address => bool)) internal operatorApprovals;

    /// @notice Mapping from owner to list of owned token IDs
    mapping(address => uint256[]) internal ownedTokens;

    /// @notice Mapping from token ID to index of the owner tokens list
    mapping(uint256 => uint256) internal ownedTokensIndex;

    /// @notice Array with all token ids, used for enumeration
    uint256[] internal allTokens;

    /// @notice Mapping from token id to position in the allTokens array
    mapping(uint256 => uint256) internal allTokensIndex;

    /// @notice Underlying asset for this PNFTToken
    address public underlying;

    int public NFTXioVaultId = -1;

    address public SudoswapLSSVMPairAddress;
}

contract PNFTTokenInterface is PNFTTokenStorage {
    /// @notice Indicator that this is a PNFTToken contract (for inspection)
    bool public constant isPNFTToken = true;

    /*** Market Events ***/

    /// @notice Event emitted when tokens are minted
    event Mint(address indexed minter, uint256 indexed tokenId);

    /// @notice Event emitted when tokens are redeemed
    event Redeem(address indexed redeemer, uint256 indexed tokenId);

    /// @notice Event emitted when borrower's collateral is liquidated
    event LiquidateCollateral(address indexed liquidator, address indexed borrower, uint indexed tokenId, address NFTLiquidationExchangePToken);

    /*** Admin Events ***/

    /// @notice Event emitted when pendingAdmin is changed
    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);

    /// @notice Event emitted when pendingAdmin is accepted, which means admin is updated
    event NewAdmin(address oldAdmin, address newAdmin);

    /// @notice Event emitted when comptroller is changed
    event NewComptroller(address oldComptroller, address newComptroller);

    /// @notice Event emitted when the reserve factor is changed
    event NewReserveFactor(uint oldReserveFactorMantissa, uint newReserveFactorMantissa);

    /// @notice EIP721 Transfer event
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /// @notice EIP721 Approval event
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    /// @notice EIP721 ApprovalForAll event
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /// @notice Failure event
    event Failure(uint error, uint info, uint detail);

    /*** ERC165 Functions ***/

    function supportsInterface(bytes4 interfaceId) external view returns (bool);

    /*** EIP721 Functions ***/

    function transferFrom(address src, address dst, uint tokenId) external;
    function safeTransferFrom(address src, address dst, uint256 tokenId, bytes memory data) public;
    function safeTransferFrom(address src, address dst, uint256 tokenId) external;
    function approve(address to, uint tokenId) external;
    function setApprovalForAll(address operator, bool _approved) external;
    function getApproved(uint256 tokenId) external view returns (address operator);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function balanceOf(address owner) external view returns (uint);
    function ownerOf(uint tokenId) external view returns (address);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function totalSupply() public view returns (uint256);
    function tokenByIndex(uint256 index) public view returns (uint256);

    /*** User Interface ***/

    function balanceOfUnderlying(address owner) external view returns (uint);
    function getCash() external view returns (uint);
    function liquidateCollateral(address borrower, uint tokenId, address NFTLiquidationExchangePTokenAddress) external returns (uint);
    function liquidateSeizeCollateral(address borrower, uint tokenId, address NFTLiquidationExchangePTokenAddress) external returns (uint);
    function mint(uint tokenId) external;
    function safeMint(uint256 tokenId) external;
    function safeMint(uint256 tokenId, bytes calldata data) external;
    function redeem(uint tokenId) external;

    /*** Admin Functions ***/

    function _setPendingAdmin(address payable newPendingAdmin) external;
    function _acceptAdmin() external;
    function _setComptroller(address newComptroller) public;
    function _setNFTXioVaultId(int newNFTXioVaultId) external;
    function _setSudoswapLSSVMPairAddress(address newSudoswapLSSVMPairAddress) external;
}

contract PErc721Interface is PNFTTokenInterface {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

contract PNFTTokenDelegationStorage {
    /// @notice Implementation address for this contract
    address public implementation;
}

contract PNFTTokenDelegatorInterface is PNFTTokenDelegationStorage {
    /// @notice Emitted when implementation is changed
    event NewImplementation(address oldImplementation, address newImplementation);

    /**
     * @notice Called by the admin to update the implementation of the delegator
     * @param implementation_ The address of the new implementation for delegation
     * @param allowResign Flag to indicate whether to call _resignImplementation on the old implementation
     * @param becomeImplementationData The encoded bytes data to be passed to _becomeImplementation
     */
    function _setImplementation(address implementation_, bool allowResign, bytes memory becomeImplementationData) public;
}

contract PNFTTokenDelegateInterface is PNFTTokenInterface, PNFTTokenDelegationStorage {
    /**
     * @notice Called by the delegator on a delegate to initialize it for duty
     * @dev Should revert if any issues arise which make it unfit for delegation
     * @param data The encoded bytes data for any initialization
     */
    function _becomeImplementation(bytes calldata data) external;

    /// @notice Called by the delegator on a delegate to forfeit its responsibility
    function _resignImplementation() external;
}
