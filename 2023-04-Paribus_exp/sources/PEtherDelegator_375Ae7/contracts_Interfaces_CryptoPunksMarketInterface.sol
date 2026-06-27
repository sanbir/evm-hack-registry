// SPDX-License-Identifier: MIT
pragma solidity ^0.5.17;

contract CryptoPunksMarketInterface {
    string public imageHash; // You can use this hash to verify the image file containing all the punks
    address public owner;
    string public standard;
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    uint public nextPunkIndexToAssign;
    bool public allPunksAssigned;
    uint public punksRemainingToAssign;
    mapping(uint => address) public punkIndexToAddress;
    mapping(address => uint256) public balanceOf; // This creates an array with all balances

    struct Offer {
        bool isForSale;
        uint punkIndex;
        address seller;
        uint minValue; // in ether
        address onlySellTo; // specify to sell only to a specific person
    }

    struct Bid {
        bool hasBid;
        uint punkIndex;
        address bidder;
        uint value;
    }

    // A record of punks that are offered for sale at a specific minimum value, and perhaps to a specific person
    mapping(uint => Offer) public punksOfferedForSale;
    mapping(uint => Bid) public punkBids; // A record of the highest punk bid
    mapping(address => uint) public pendingWithdrawals;

    event Assign(address indexed to, uint256 punkIndex);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event PunkTransfer(address indexed from, address indexed to, uint256 punkIndex);
    event PunkOffered(uint indexed punkIndex, uint minValue, address indexed toAddress);
    event PunkBidEntered(uint indexed punkIndex, uint value, address indexed fromAddress);
    event PunkBidWithdrawn(uint indexed punkIndex, uint value, address indexed fromAddress);
    event PunkBought(uint indexed punkIndex, uint value, address indexed fromAddress, address indexed toAddress);
    event PunkNoLongerForSale(uint indexed punkIndex);

    // Initializes contract with initial supply tokens to the creator of the contract
    function CryptoPunksMarket() public payable;

    function setInitialOwner(address to, uint punkIndex) public;

    function setInitialOwners(address[] memory addresses, uint[] memory indices) public;

    function allInitialOwnersAssigned() public;

    function getPunk(uint punkIndex) public;

    // Transfer ownership of a punk to another user without requiring payment
    function transferPunk(address to, uint punkIndex) public;

    function punkNoLongerForSale(uint punkIndex) public;

    function offerPunkForSale(uint punkIndex, uint minSalePriceInWei) public;

    function offerPunkForSaleToAddress(uint punkIndex, uint minSalePriceInWei, address toAddress) public;

    function buyPunk(uint punkIndex) public payable;

    function withdraw() public;

    function enterBidForPunk(uint punkIndex) public payable;

    function acceptBidForPunk(uint punkIndex, uint minPrice) public;

    function withdrawBidForPunk(uint punkIndex) public;
}
