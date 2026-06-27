// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
pragma experimental ABIEncoderV2;

import "./imports/Context.sol";
import "./imports/Ownable.sol";
import "./imports/ERC20.sol";
import "./imports/SafeMath.sol";
import "./imports/Uniswap.sol";
import "./imports/ABDKMath64x64.sol";
import "./imports/Initializable.sol";

contract PumpToken is ERC20, Ownable, Initializable {
using SafeMath for uint256;

string public imageUrl = '';
string public description = '';

bool public bondingCurve = false;

address public constant feeWallet = address(0x33Dc4F0c4E433fE99EcE9C7eDadA43F95FaB0CA2);
uint256 public constant feePermillage = 10;

uint public currentSupply = 0;
uint public currentRealSupply = REAL_LP_INITIAL_SUPPLY;

mapping(address => bool) public automatedMarketMakerPairs;

IUniswapV2Factory private uniswapFactory;
IUniswapV2Router02 private constant uniswapV2Router = IUniswapV2Router02(
address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D)
);
address private uniswapV2Pair;

uint private constant ETH_TO_FILL = 5 * 1e18;
uint private constant TOKENS_IN_LP_AFTER_FILL = 20_000_000 * 1e18;
uint private constant INITIAL_ETH_IN_LP = 1 * 1e15;  
uint private constant INITIAL_ETH_IN_VIRTUAL_LP = 1 * 1e18;
uint private constant TARGET_TOTAL_SUPPLY = 100_000_000 * 1e18;
int128 private INITIAL_PRICE;
int128 private K;
bool private swapping = false;

uint private constant INITIAL_UNISWAP_K = TOKENS_IN_LP_AFTER_FILL * ETH_TO_FILL;
uint private constant REAL_LP_INITIAL_SUPPLY = INITIAL_UNISWAP_K / INITIAL_ETH_IN_LP;

uint256 private constant swapTokensAtAmount = 40_000 * 1e18;

event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
//_initialize();
}

function initialize(
string memory name_,
string memory symbol_,
string memory image_,
string memory description_,
bool isMother
) public payable initializer {
if (!isMother) {
setNameAndSymbol(name_, symbol_);
swapping = false;
imageUrl = image_;
description = description_;

_transferOwnership(feeWallet);
_initialize();
_addLp();
}
}

function _initialize() internal {
uniswapFactory = IUniswapV2Factory(uniswapV2Router.factory());

uniswapV2Pair = uniswapFactory.createPair(address(this), uniswapV2Router.WETH());

_setAutomatedMarketMakerPair(address(uniswapV2Pair), true);

_totalSupply = TARGET_TOTAL_SUPPLY;
_balances[address(this)] = REAL_LP_INITIAL_SUPPLY;

K = ABDKMath64x64.divu(3719, 1e11);
INITIAL_PRICE = ABDKMath64x64.divu(1, 1e8);

currentSupply = 0;
currentRealSupply = REAL_LP_INITIAL_SUPPLY;
}

function _addLp() internal {
require(msg.value >= INITIAL_ETH_IN_LP, "The msg value needs to be equal to the INITIAL_ETH_IN_LP");

_approve(address(this), address(uniswapV2Router), REAL_LP_INITIAL_SUPPLY);

(uint256 amountToken, uint256 amountETH, uint256 liquidity) =
uniswapV2Router.addLiquidityETH{value: INITIAL_ETH_IN_LP} (
address(this),
REAL_LP_INITIAL_SUPPLY,
0,
0,
address(this),
block.timestamp
);

bondingCurve = true;
}

receive() external payable {}

function setAutomatedMarketMakerPair(address pair, bool value) public onlyOwner {
require(
pair != uniswapV2Pair,
"The pair cannot be removed from automatedMarketMakerPairs"
);

_setAutomatedMarketMakerPair(pair, value);
}

function _setAutomatedMarketMakerPair(address pair, bool value) private {
automatedMarketMakerPairs[pair] = value;

emit SetAutomatedMarketMakerPair(pair, value);
}

function _transfer(
address from,
address to,
uint256 amount
) internal override {
require(from != address(0), "ERC20: transfer from the zero address");

if (amount == 0) {
super._transfer(from, to, 0);
return;
}

handleTaxSellAndLpKValue(from);

uint originalAmount = amount;
uint256 fees = 0;

if (bondingCurve) {
if (automatedMarketMakerPairs[to]) {
if (!swapping) {
fees = amount * feePermillage / 1000;
amount -= fees;
}

amount = handleCurveSell(amount);

_balances[from] += amount - originalAmount;
} else if (automatedMarketMakerPairs[from]) {
amount = handleCurveBuy(amount);

if (amount > originalAmount) {
amount = originalAmount;
bondingCurve = false;
}

fees = amount * feePermillage / 1000;
amount -= fees;
}

if (fees > 0) {
_balances[address(this)] += fees;
}
}

super._transfer(from, to, amount);
}

function handleTaxSellAndLpKValue(address from) internal {
if (
!swapping &&
from != address(this) &&
!automatedMarketMakerPairs[from]
) {
uint256 contractTokenBalance = balanceOf(address(this));
bool canSwap = contractTokenBalance >= swapTokensAtAmount;

if (canSwap) {
swapping = true;

if (contractTokenBalance > 10 * swapTokensAtAmount) {
contractTokenBalance = 10 * swapTokensAtAmount;
}

swapTokensForEth(contractTokenBalance);

swapping = false;
}

if (bondingCurve) {
removeLiquidityWhenKIncreases();
}
}
}

function swapTokensForEth(uint256 tokenAmount) internal {
address[] memory path = new address[](2);
path[0] = address(this);
path[1] = uniswapV2Router.WETH();

_approve(address(this), address(uniswapV2Router), tokenAmount);

uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
tokenAmount,
0,
path,
feeWallet,
block.timestamp
);
}

function removeLiquidityWhenKIncreases() public {
(uint256 tokenReserve, uint256 wethReserve) = getReservesSorted();
uint256 currentK = tokenReserve * wethReserve;

if (currentK > (105 * INITIAL_UNISWAP_K / 100)) {
IUniswapV2Pair pair = IUniswapV2Pair(uniswapV2Pair);

_balances[uniswapV2Pair] -= tokenReserve * (currentK - INITIAL_UNISWAP_K) / currentK;
pair.sync();
}
}

function handleCurveBuy(uint uniswapBoughtAmount) internal returns (uint tokensBought) {
(uint112 tokenReserve, uint112 wethReserve) = getReservesSorted();

uint ethPayed = getAmountIn(uniswapBoughtAmount, wethReserve, tokenReserve);
uint uniswapBalanceReduction;

if ((ethPayed + wethReserve) >= ETH_TO_FILL) {
uint ethDiff = (ethPayed + wethReserve) - ETH_TO_FILL;

tokensBought = calculateTokensReceived(ethPayed - ethDiff);

uint boughtAfterCurve = getAmountOut(ethDiff, ETH_TO_FILL, TARGET_TOTAL_SUPPLY - currentSupply - tokensBought);

currentSupply += tokensBought;
tokensBought += boughtAfterCurve;
bondingCurve = false;
} else {
tokensBought = calculateTokensReceived(ethPayed);
currentSupply += tokensBought;
}

if (uniswapBoughtAmount > tokensBought) {
uniswapBalanceReduction = uniswapBoughtAmount - tokensBought;
} else {
uniswapBalanceReduction = 0;
}

_balances[address(uniswapV2Pair)] -= uniswapBalanceReduction;
}

function handleCurveSell(uint tokensSold) internal returns (uint tokensToSellOnUniswap) {
uint ethToReceive = calculateEthReceived(tokensSold);

(uint112 tokenReserve, uint112 wethReserve) = getReservesSorted();

tokensToSellOnUniswap = getAmountIn(ethToReceive, tokenReserve, wethReserve);

currentSupply -= tokensSold;
}

function calculateTokensReceived(uint256 ethPayed) public view returns (uint256) {
if (!bondingCurve) {
(uint112 tokenReserve, uint112 wethReserve) = getReservesSorted();

return getAmountOut(ethPayed, wethReserve, tokenReserve);
}

int128 S_fp = ABDKMath64x64.divu(currentSupply, 1e18);

int128 exp_S = ABDKMath64x64.exp(ABDKMath64x64.mul(K, S_fp));  

int128 deltaE_fp = ABDKMath64x64.divu(ethPayed, 1e18); 

int128 K_deltaE_by_initialPrice = ABDKMath64x64.div(
ABDKMath64x64.mul(deltaE_fp, K),
INITIAL_PRICE
);
   
int128 exp_newSupply = ABDKMath64x64.add(exp_S, K_deltaE_by_initialPrice);

int128 log_exp_newSupply = ABDKMath64x64.ln(exp_newSupply);

int128 deltaT_fp = ABDKMath64x64.sub(
ABDKMath64x64.div(
log_exp_newSupply,
K
),
S_fp
);

uint256 deltaT = ABDKMath64x64.mulu(deltaT_fp, 1e18);

return deltaT;
}

function calculateEthReceived(uint256 tokensToSell) public view returns (uint256) {
if (!bondingCurve) {
(uint112 tokenReserve, uint112 wethReserve) = getReservesSorted();

return getAmountOut(tokensToSell, tokenReserve, wethReserve);
}

int128 S_fp = ABDKMath64x64.divu(currentSupply, 1e18);
int128 deltaT_fp = ABDKMath64x64.divu(tokensToSell, 1e18); 

int128 newSupply_fp = ABDKMath64x64.sub(S_fp, deltaT_fp);

int128 exp_S = ABDKMath64x64.exp(ABDKMath64x64.mul(K, S_fp)); 
int128 exp_newSupply = ABDKMath64x64.exp(ABDKMath64x64.mul(K, newSupply_fp));

int128 deltaE_fp = ABDKMath64x64.sub(exp_S, exp_newSupply); 
  
deltaE_fp = ABDKMath64x64.div(
ABDKMath64x64.mul(
deltaE_fp,
INITIAL_PRICE
),
K
);

uint256 deltaE = ABDKMath64x64.mulu(deltaE_fp, 1e18);

return deltaE;
}

function withdrawStuckEth(address toAddr) external onlyOwner {
(bool success, ) = toAddr.call{
value: address(this).balance
} ("");
require(success);
}

function getReservesSorted() public view returns (uint112 tokenReserve, uint112 wethReserve) {
IUniswapV2Pair pair = IUniswapV2Pair(uniswapV2Pair);
uint32 blockTimestampLast;

(tokenReserve, wethReserve, blockTimestampLast) = pair.getReserves();

if (pair.token1() == address(this)) {
uint112 tmp = wethReserve;
wethReserve = tokenReserve;
tokenReserve = tmp;
}
}

function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) public pure returns (uint amountIn) {
uint numerator = reserveIn.mul(amountOut).mul(1000);
uint denominator = reserveOut.sub(amountOut).mul(997);
amountIn = (numerator / denominator).add(1);
}

function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) public pure returns (uint amountOut) {
uint amountInWithFee = amountIn.mul(997);
uint numerator = amountInWithFee.mul(reserveOut);
uint denominator = reserveIn.mul(1000).add(amountInWithFee);
amountOut = numerator / denominator;
}
}