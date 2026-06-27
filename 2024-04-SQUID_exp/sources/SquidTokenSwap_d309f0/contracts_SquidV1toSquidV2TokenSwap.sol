/*

SQUID Swap Contract : 
This swap contract incorporates a pioneering trustless feature to uphold the essence of decentralization.

   SQUID V1  0x87230146E138d3F296a9a77e497A2A83012e9Bc5
   SQUID V2  0xFAfb7581a65A1f554616Bf780fC8a8aCd2Ab8c9b

Trustless Swap Contract: 
We've eliminated manual admin withdrawals for swapping SQUID V1 to SQUID V1 LP. 
The swapTokens function  enables SQUID V1 holders to effortlessly convert their SQUID V1 into SQUID V2, 
with the swapped SQUID V1 securely stored in the swap contract.

Innovative Sell/Swap Feature: 
The sellSwappedTokens function introduces a groundbreaking trustless mechanism, 
allowing anyone to initiate the sale or swap of swapped old tokens. 
This process swaps SQUID V1  stored in the swap contract for SQUID V2 via the Pancake Router 
and then burns the acquired SQUID V2, contributing to the appreciation of SQUID V2's value. 
This feature is open to everyone(anyone can execute this function), further decentralizing the process.

*/

// Website: https://www.squidgametoken.vip/
// or its alias domain name: https://SQUIDGameHolders.Club

// Twitter: https://twitter.com/SQUIDCryptoCoin
// Telegram: https://t.me/squidcrypt
// CMC: https://coinmarketcap.com/currencies/squid-game/

/*
    A Proclamation from the SQUID Game Visionary

    "In the grand arena of life, we decree that victory belongs not to the few, but to all who dare to dream. 
    In unity, we stand, a formidable legion against the tempests of chance and challenge. Together, we embark 
    on a quest not just for glory, but for the fulfillment of every aspiration that beats in our hearts. 
    Let this be our collective crusade, where every stride forward is a testament to our indomitable spirit.
    
    Join us, brave souls, in a boundless journey where every individual's triumph is a beacon of our shared resilience. 
    Here, within the SQUID Game realm, we forge not just a game, but a destiny where every participant is an architect 
    of their fate. Together, we are invincible, bound by a common purpose and propelled by our shared dreams.

    Let this be our vow: to unite, to conquer, and to emerge not just as players, but as pioneers of our collective future.
    For in the heart of SQUID Game, every dream has the power to transcend reality. Together, we rise!"
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IPancakeRouter {
    function getAmountsOut(uint amountIn, address[] memory path) external view returns (uint[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

contract SquidTokenSwap is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable oldSquidToken;
    IERC20 public immutable newSquidToken;
    IPancakeRouter public immutable pancakeRouter;
    uint256 public immutable deploymentTime;
    bool private locked = false; // Mutex state

    // IERC20 public immutable oldSquidToken = IERC20(0x87230146E138d3F296a9a77e497A2A83012e9Bc5);
    // IERC20 public immutable newSquidToken = IERC20(0xFAfb7581a65A1f554616Bf780fC8a8aCd2Ab8c9b);

    mapping(address => bool) public blacklist;
    uint256 public totalSwapped;
    uint256 public totalSwappedToSell;
    address private constant addressWBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    bool public swapEnabled = false; // Initially, swapping is disabled
    uint256 public constant DEFAULT_SELL_AMOUNT = 500000 ether; // Default sell amount
    uint256 public constant ALTERNATIVE_SELL_AMOUNT = 100000 ether; // Alternative sell amount to minimize price impact

    event Swap(address indexed user, uint256 oldAmount, uint256 totalSwapped);
    event Blacklisted(address indexed user);
    event Unblacklisted(address indexed user);
    event TokensRescued(address token, uint256 amount);

    constructor() Ownable(msg.sender) {
        totalSwapped = 0;

        blacklist[0x4b6d8206FFbD35947942d4e1faF1f06cBfB5a500] = true;
        blacklist[0x77DFf8fC406fAe9A7bCE4F837F7b95cE2c7107b7] = true;
        blacklist[0x34400280a169F4685193926a513618cF7fE7F0aa] = true;
        blacklist[0xB8e9C835405DF86452357b85B9173566F08Bf351] = true;
        blacklist[0xE5A91A751499F877279EfD5E11b72511F3281003] = true;
        blacklist[0xe62b8c0A70EBb05DBeCcbef1C833356F67CD278C] = true;
        blacklist[0x3BB59C2F09fEe0D0986F8622E4df9AF11c09d6e6] = true;

        oldSquidToken = IERC20(0x87230146E138d3F296a9a77e497A2A83012e9Bc5); // SQUID V1
        newSquidToken = IERC20(0xFAfb7581a65A1f554616Bf780fC8a8aCd2Ab8c9b); // SQUID V2
        pancakeRouter = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E); // Router
        deploymentTime = block.timestamp; // Store deployment time
    }

    modifier lock() {
        require(!locked, "Reentrant call detected");
        locked = true;
        _;
        locked = false;
    }

    function enableSwap() external onlyOwner {
        require(!swapEnabled, "Swap is already enabled");
        swapEnabled = true; // Enable swap function once and for all
    }

    function swapTokens(uint256 amount) external nonReentrant lock {
        require(swapEnabled, "Swap is not enabled yet");
        require(!blacklist[msg.sender], "Address is blacklisted");
        require(oldSquidToken.balanceOf(msg.sender) >= amount, "Insufficient old token balance");
        // require(newSquidToken.balanceOf(address(this)) >= amount, "Insufficient new token balance in contract");

        uint256 squidV2BalanceBefore = newSquidToken.balanceOf(address(this));
        require(squidV2BalanceBefore >= amount, "Insufficient new token balance in contract");

        uint256 squidV1BalanceBefore = oldSquidToken.balanceOf(address(this));

        // Transfer old tokens from user to this contract
        oldSquidToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 squidV1BalanceAfter = oldSquidToken.balanceOf(address(this));

        require(squidV1BalanceAfter - squidV1BalanceBefore == amount, "Should match Squid V1 amount after swap.");

        // Transfer new tokens to user
        newSquidToken.safeTransfer(msg.sender, amount);

        uint256 squidV2BalanceAfter = newSquidToken.balanceOf(address(this));
        require(squidV2BalanceBefore - squidV2BalanceAfter == amount, "Should match Squid V2 amount after swap.");

        // Increment the total swapped amount and totalSwappedToSell
        totalSwapped += amount;
        totalSwappedToSell += amount;

        emit Swap(msg.sender, amount, totalSwapped);
    }

    function sellSwappedTokens(uint256 sellOption) external nonReentrant lock {
        require(swapEnabled, "Swap is not enabled yet");
        uint256 sellAmount;
        // uint256 sellAmount = totalSwappedToSell > 500000 ether ? 500000 ether : totalSwappedToSell;
        if (sellOption == 1) {
            sellAmount = totalSwappedToSell > ALTERNATIVE_SELL_AMOUNT ? ALTERNATIVE_SELL_AMOUNT : totalSwappedToSell;
        } else {
            sellAmount = totalSwappedToSell > DEFAULT_SELL_AMOUNT ? DEFAULT_SELL_AMOUNT : totalSwappedToSell;
        }

        require(sellAmount > 0, "No tokens to sell");

        uint256 squidV2BalanceBefore = newSquidToken.balanceOf(address(this));

        // Set slippage to 5%
        uint256 minOut = getMinOut(sellAmount);

        // Approve the router to spend SQUID V1
        oldSquidToken.approve(address(pancakeRouter), sellAmount);

        address[] memory path = new address[](3);
        path[0] = address(oldSquidToken);
        path[1] = addressWBNB;
        path[2] = address(newSquidToken);

        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            sellAmount,
            minOut, // Min amount out after slippage
            path,
            address(this),
            block.timestamp
        );

        // Update totalSwappedToSell
        totalSwappedToSell -= sellAmount;

        // Calculate the amount of new SQUID V2 to burn
        uint256 newSquidBalance = newSquidToken.balanceOf(address(this));

        uint256 burnSquidV2Amount = newSquidBalance - squidV2BalanceBefore;
        // Assuming SQUID V2 has a burn function or sending to a dead address
        // newSquidToken.burn(newSquidBalance); // Implement if burn function exists
        // newSquidToken.transfer(0x000000000000000000000000000000000000dEaD, burnSquidV2Amount); // Send to dead address to "burn"

        if (burnSquidV2Amount > 0) {
            // Burn the SQUID V2 tokens by transferring to a dead address
            newSquidToken.transfer(0x000000000000000000000000000000000000dEaD, burnSquidV2Amount);
        }
    }

    // Calculate minimum amount out including slippage
    function getMinOut(uint256 sellAmount) public view returns (uint256) {
        address[] memory path = new address[](3);
        path[0] = address(oldSquidToken);
        path[1] = addressWBNB;
        path[2] = address(newSquidToken);

        uint256[] memory amountsOut = pancakeRouter.getAmountsOut(sellAmount, path);
        uint256 amountOutMin = amountsOut[amountsOut.length - 1];

        // Apply 5% slippage
        return (amountOutMin * 95) / 100;
    }

    function addToBlacklist(address user) external onlyOwner {
        blacklist[user] = true;
        emit Blacklisted(user);
    }

    function removeFromBlacklist(address user) external onlyOwner {
        blacklist[user] = false;
        emit Unblacklisted(user);
    }

    // Function to retrieve tokens sent to this contract by mistake

    function rescueTokens(address tokenAddress, uint256 amount) external onlyOwner nonReentrant {
        require(block.timestamp >= deploymentTime + 5 * 365 days, "Function can only be executed after 5 years");
        require(tokenAddress != address(newSquidToken), "Rescuing new SQUID V2 tokens is not allowed");
        require(tokenAddress != address(oldSquidToken), "Rescuing  SQUID V1 tokens is not allowed");

        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        require(amount <= balance, "Insufficient token balance");

        token.safeTransfer(owner(), amount);
        emit TokensRescued(tokenAddress, amount);
    }
}
