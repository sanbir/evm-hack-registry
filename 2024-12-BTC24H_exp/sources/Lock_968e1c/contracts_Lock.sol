// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

contract Lock {
    using SafeERC20 for IERC20;

    struct Claim {
        uint256 amount;
        uint256 releaseDate;
        bool claimed;
    }

    IERC20 public token;
    address public owner;
    Claim private claims;

    modifier onlyOwner() {
        require(msg.sender == owner, 'Not authorized');
        _;
    }

    modifier onlyOnOrAfter(uint256 date) {
        require(block.timestamp >= date, 'Too early to claim');
        _;
    }

    constructor(IERC20 _token) {
        token = _token;
        owner = msg.sender;
    }

    function deposit() external {
        uint256 totalAmount = 110000;

        token.safeTransferFrom(
            msg.sender,
            address(this),
            totalAmount * 1 ether
        );

        claims = Claim({
            amount: 110000 * 1 ether,
            releaseDate: 1734220800,
            claimed: false
        });
    }

    function claim() external onlyOnOrAfter(claims.releaseDate) {
        require(!claims.claimed, 'Already claimed');

        claims.claimed = true;
        uint256 claimAmount = claims.amount;
        token.safeTransfer(msg.sender, claimAmount);
    }
    function timeUntilClaim() external view returns (uint256) {
        Claim storage claimData = claims;
        if (block.timestamp >= claimData.releaseDate) {
            return 0;
        } else {
            return claimData.releaseDate - block.timestamp;
        }
    }

    function getClaimDetails()
        external
        view
        returns (uint256 amount, uint256 releaseDate, bool claimed)
    {
        Claim storage claimData = claims;
        return (claimData.amount, claimData.releaseDate, claimData.claimed);
    }
}
