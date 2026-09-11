//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IERC404 {
    event Approval(address indexed owner, address indexed spender, uint256 valueOrId);
    event ERC20Approval(address owner, address spender, uint256 value);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event ERC721Approval(address indexed owner, address indexed spender, uint256 indexed id);
    event Transfer(address indexed from, address indexed to, uint256 indexed valueOrId);
    event ERC20Transfer(address indexed from, address indexed to, uint256 amount);
    event ERC721Transfer(address indexed from, address indexed to, uint256 indexed id);

    error NotFound();
    error InvalidId();
    error AlreadyExists();
    error InvalidRecipient();
    error InvalidSender();
    error InvalidSpender();
    error InvalidOperator();
    error UnsafeRecipient();
    error NotWhitelisted();
    error Unauthorized();
    error InsufficientAllowance();
    error InsufficientBalance();
    error MaxERC20SupplyReached();
    error MaxERC721SupplyReached();
    error DecimalsTooLow();
    error CannotRemoveFromWhitelist();

    function ownerOf(uint256 id_) external view returns (address nftOwner);
    function tokenURI(uint256 id_) external view returns (string memory);
    function approve(address spender_, uint256 valueOrId) external returns (bool);
    function setApprovalForAll(address operator_, bool approved_) external;
    function transferFrom(address from_, address to, uint256 valueOrId_) external returns (bool);
    function transfer(address to_, uint256 amount_) external returns (bool);
    function safeTransferFrom(address from_, address to_, uint256 id_) external;
    function safeTransferFrom(address from, address to, uint256 id, bytes calldata data) external;
}
