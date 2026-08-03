// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interface/ILpdFi.sol";

contract LpdBasic is Ownable {
    using SafeERC20 for IERC20;

    error NoRight();
    error IssueExceedsNow();
    error AlreadyUpdated();
    error IssueNotUpdated();
    error AlreadyClaimed();
    error InvalidProof();
    error AmountExceedsTotal();
    error ZeroAddress();
    error NoStart();

    event NewDividend(uint256 issue, bytes32 merkleRoot, uint256 totalAmount);

    event DividendClaimed(
        address indexed account,
        uint256 issue,
        uint256 amount
    );

    struct Dividend {
        bytes32 merkleRoot;
        uint256 totalAmount;
        uint256 claimedAmount;
    }

    mapping(uint256 => Dividend) public dividendPerIssue;
    mapping(address => mapping(uint256 => bool))
        public dividendClaimedPerAccount;
    mapping(uint256 => uint256) public dispersedAmountPerIssue;

    address public nftRewards;
    address public immutable fi;

    constructor(address _r, address _fi) Ownable(_r) {       
        nftRewards = _r;
        fi = _fi;
    }

    function changeNftRewards(address newR) external {
        if (msg.sender != nftRewards) {
            revert NoRight();
        }
        if(newR == address(0)){
            revert ZeroAddress();
        }
        nftRewards = newR;
    }

    function setDisperse(uint256 issue,uint256 amount) external{
        if (msg.sender != fi) {
            revert NoRight();
        }
        dispersedAmountPerIssue[issue] = amount;
    }

    function updateDividend(
        uint256 issue,
        bytes32 merkleRoot,
        uint256 totalAmount
    ) external {
         if(msg.sender != nftRewards){
            revert NoRight();
        }
        if(ILpdFi(fi).fiStartTime() == 0) {
            revert NoStart();
        }
        if (
            issue >
            (block.timestamp - ILpdFi(fi).fiStartTime()) /
                ILpdFi(fi).ISSUE_PERIOD()
        ) {
            revert IssueExceedsNow();
        }
        if (dividendPerIssue[issue].merkleRoot != bytes32(0)) {
            revert AlreadyUpdated();
        }
        if(totalAmount > dispersedAmountPerIssue[issue]){
            revert AmountExceedsTotal();
        }
        dividendPerIssue[issue] = Dividend(merkleRoot, totalAmount, 0);
        emit NewDividend(issue, merkleRoot, totalAmount);
    }

    function checkMerkleRoot(
        address account,
        uint256 issue,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) public view {
        Dividend memory d = dividendPerIssue[issue];
        if (d.merkleRoot == bytes32(0)) {
            revert IssueNotUpdated();
        }
        if (dividendClaimedPerAccount[account][issue]) {
            revert AlreadyClaimed();
        }
        bytes32 leaf = keccak256(abi.encodePacked(account, amount, issue));
        if (!MerkleProof.verify(merkleProof, d.merkleRoot, leaf)) {
            revert InvalidProof();
        }
    }

    function claim(address account, uint256 issue, uint256 amount) external {
        if (msg.sender != fi) {
            revert NoRight();
        }
        if (
            dividendPerIssue[issue].claimedAmount + amount >
            dividendPerIssue[issue].totalAmount
        ) {
            revert AmountExceedsTotal();
        }
        dividendClaimedPerAccount[account][issue] = true;
        dividendPerIssue[issue].claimedAmount += amount;
        emit DividendClaimed(account, issue, amount);
    }
}
