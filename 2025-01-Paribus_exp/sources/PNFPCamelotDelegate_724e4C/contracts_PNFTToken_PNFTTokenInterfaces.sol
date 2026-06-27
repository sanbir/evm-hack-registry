// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;
pragma experimental ABIEncoderV2;

import "../Comptroller/ComptrollerInterfaces.sol";
import "../InterestRateModels/InterestRateModelInterface.sol";
import "../ErrorReporter.sol";
import "openzeppelin2/token/ERC721/IERC721Receiver.sol";
import "./../Interfaces/LPInterfaces.sol";

contract PNFTTokenDelegationStorage {
    /// @notice Implementation address for this contract
    address public implementation;

    /// @notice Administrator for this contract
    address payable public admin;

    /// @notice Pending administrator for this contract
    address payable public pendingAdmin;
}

contract PNFTTokenDelegatorInterface is PNFTTokenDelegationStorage {
    /// @notice Emitted when implementation is changed
    event NewImplementation(address oldImplementation, address newImplementation);

    /**
     * @notice Called by the admin to update the implementation of the delegator
     * @param newImplementation The address of the new implementation for delegation
     * @param allowResign Flag to indicate whether to call _resignImplementation on the old implementation
     * @param becomeImplementationData The encoded bytes data to be passed to _becomeImplementation
     */
    function _setImplementation(address newImplementation, bool allowResign, bytes memory becomeImplementationData) public;
}

contract PNFTTokenStorage is PNFTTokenDelegationStorage {
    /// @dev Guard variable for reentrancy checks
    bool internal _notEntered;

    /// @notice EIP-721 token name for this token
    string public name;

    /// @notice EIP-721 token symbol for this token
    string public symbol;

    /// @notice Contract which oversees inter-PNFTToken operations
    ComptrollerNFTInterface public comptroller;

    /// @notice Mapping from token ID to owner address
    mapping(uint => address) internal tokensOwners;

    /// @notice Mapping owner address to token count
    mapping(address => uint) internal accountTokens;

    /// @notice Mapping from token ID to approved address
    mapping(uint => address) internal transferAllowances;

    /// @notice Mapping from owner to operator approvals
    mapping(address => mapping(address => bool)) internal operatorApprovals;

    /// @notice Mapping from owner to list of owned token IDs
    mapping(address => uint[]) internal ownedTokens;

    /// @notice Mapping from token ID to index of the owner tokens list
    mapping(uint => uint) internal ownedTokensIndex;

    /// @notice Array with all token ids, used for enumeration
    uint[] internal allTokens;

    /// @notice Mapping from token id to position in the allTokens array
    mapping(uint => uint) internal allTokensIndex;

    /// @notice Underlying asset for this PNFTToken
    address public underlying;

    int public NFTXioVaultId;

    address public sudoswapLSSVMPairAddress; // underlying NFT -> ETH pool
}

contract PNFPStorage {
    mapping(address=>bool) public whitelistedPools;
}

contract PNFTTokenInterface is ErrorReporter, PNFTTokenStorage {
    /// @notice Indicator that this is a PNFTToken contract (for inspection)
    bool public constant isPNFTToken = true;

    /*** Market Events ***/

    /// @notice Event emitted when tokens are minted
    event Mint(address indexed minter, uint indexed tokenId);

    /// @notice Event emitted when tokens are redeemed
    event Redeem(address indexed redeemer, uint indexed tokenId);

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
    event Transfer(address indexed from, address indexed to, uint indexed tokenId);

    /// @notice EIP721 Approval event
    event Approval(address indexed owner, address indexed approved, uint indexed tokenId);

    /// @notice EIP721 ApprovalForAll event
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /// @notice Event emitted when pool address is whitelisted for pnfp markets
    event WhitelistedPool(address indexed poolAddress, bool isWhitelisted);

    /*** ERC165 Functions ***/

    function supportsInterface(bytes4 interfaceId) external view returns (bool);

    /*** EIP721 Functions ***/

    function transferFrom(address src, address dst, uint tokenId) external;
    function safeTransferFrom(address src, address dst, uint tokenId, bytes memory data) public;
    function safeTransferFrom(address src, address dst, uint tokenId) external;
    function approve(address to, uint tokenId) external;
    function setApprovalForAll(address operator, bool _approved) external;
    function getApproved(uint tokenId) external view returns (address operator);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function balanceOf(address owner) external view returns (uint);
    function ownerOf(uint tokenId) external view returns (address);
    function tokenOfOwnerByIndex(address owner, uint index) external view returns (uint);
    function totalSupply() public view returns (uint);
    function tokenByIndex(uint index) public view returns (uint);

    /*** User Interface ***/

    function balanceOfUnderlying(address owner) external view returns (uint);
    function getCash() external view returns (uint);
    function liquidateCollateral(address borrower, uint tokenId, address NFTLiquidationExchangePTokenAddress) external returns (Error);
    function liquidateSeizeCollateral(address borrower, uint tokenId, address NFTLiquidationExchangePTokenAddress) external returns (Error);
    function mint(uint tokenId) external returns (Error);
    function safeMint(uint tokenId) external returns (Error);
    function safeMint(uint tokenId, bytes calldata data) external returns (Error);
    function redeem(uint tokenId) external;

    /*** Admin Functions ***/

    function _setPendingAdmin(address payable newPendingAdmin) external;
    function _acceptAdmin() external;
    function _setComptroller(address newComptroller) public;
    function _setNFTXioVaultId(int newNFTXioVaultId) external;
    function _setSudoswapLSSVMPairAddress(address newSudoswapLSSVMPairAddress) external;
}

contract PErc721Interface is PNFTTokenInterface, IERC721Receiver { }

contract PNFTTokenDelegateInterface is PNFTTokenInterface {
    /**
     * @notice Called by the delegator on a delegate to initialize it for duty
     * @dev Should revert if any issues arise which make it unfit for delegation
     * @param data The encoded bytes data for any initialization
     */
    function _becomeImplementation(bytes calldata data) external;

    /// @notice Called by the delegator on a delegate to forfeit its responsibility
    function _resignImplementation() external;
}
