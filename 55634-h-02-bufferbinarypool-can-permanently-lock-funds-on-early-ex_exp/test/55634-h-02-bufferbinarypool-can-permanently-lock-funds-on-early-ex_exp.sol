// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/core/BufferBinaryPool.sol";
import "../src/core/BufferBinaryOptions.sol";
import "../src/core/OptionsConfig.sol";
import "../src/interfaces/Interfaces.sol";

/*//////////////////////////////////////////////////////////////
       Opaque out-of-scope boundary doubles (NOT the finding)
//////////////////////////////////////////////////////////////*/

// Minimal real ERC20 payment token (USDC-like, 6 decimals). The finding is not
// about the token; a real minimal ERC20 stands in for the opaque payment asset.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract BoosterDouble is IBooster {
    function getUserBoostData(address, address) external pure override returns (UserBoostTrades memory) {
        return UserBoostTrades(0, 0);
    }
    function updateUserBoost(address, address) external override {}
    function getBoostPercentage(address, address) external pure override returns (uint256) { return 0; }
}

contract OptionStorageDouble is IOptionStorage {
    function save(uint256, address, address) external override {}
}

contract PoolOIStorageDouble is IPoolOIStorage {
    function updatePoolOI(bool, uint256) external override {}
    function totalPoolOI() external pure override returns (uint256) { return 0; }
}

contract ReferralDouble is IReferralStorage {
    function codeOwner(string memory) external pure override returns (address) { return address(0); }
    function traderReferralCodes(address) external pure override returns (string memory) { return ""; }
    function getTraderReferralInfo(address) external pure override returns (string memory, address) { return ("", address(0)); }
    function setTraderReferralCode(address, string memory) external override {}
    function setReferrerTier(address, uint8) external override {}
    function referrerTierStep(uint8) external pure override returns (uint8) { return 0; }
    function referrerTierDiscount(uint8) external pure override returns (uint32) { return 0; }
    function referrerTier(address) external pure override returns (uint8) { return 0; }
}

/*//////////////////////////////////////////////////////////////
                              PoC
//////////////////////////////////////////////////////////////*/

/// AuditVault #55634 [H-02] — BufferBinaryPool.send() decrements `lockedAmount`
/// by the AMOUNT SENT, not by the full option size it unlocks. On an early
/// exercise the option pays out only a partial `profit < lockedAmount`, so the
/// `lockedAmount - profit` remainder stays counted as "locked" forever even
/// though the option is fully closed — permanently subtracting it from the
/// pool's availableBalance() and locking LP funds.
contract PoC_55634 is Test {
    MockUSDC internal usdc;
    BufferBinaryPool internal pool;
    BufferBinaryOptions internal options;
    OptionsConfig internal config;

    address internal constant LP = address(0x11);
    address internal constant TRADER = address(0x22);
    address internal constant SF_SINK = address(0x5E77);

    uint256 internal constant LP_LIQUIDITY = 1_000e6; // 1,000 USDC

    function _deployStack() internal {
        usdc = new MockUSDC();
        pool = new BufferBinaryPool(ERC20(address(usdc)), 0 /*lockupPeriod*/);
        config = new OptionsConfig(pool);
        options = new BufferBinaryOptions();

        options.initialize(
            ERC20(address(usdc)),
            ILiquidityPool(address(pool)),
            IOptionsConfig(address(config)),
            IReferralStorage(address(new ReferralDouble())),
            IBufferBinaryOptions.AssetCategory.Crypto,
            "ETH",
            "USD"
        );

        // Wire config's opaque sidecars.
        config.setIV(10_000); // 100% annualised vol (factor 1e4)
        config.setSettlementFeeDisbursalContract(SF_SINK);
        config.setOptionStorageContract(address(new OptionStorageDouble()));
        config.setPoolOIStorageContract(address(new PoolOIStorageDouble()));
        config.setBoosterContract(address(new BoosterDouble()));

        // Roles: options may lock/send in the pool; this test drives the router path.
        pool.grantRole(pool.OPTION_ISSUER_ROLE(), address(options));
        options.grantRole(options.ROUTER_ROLE(), address(this));
        options.approvePoolToTransferTokenX();

        // LP seeds the pool.
        usdc.mint(LP, LP_LIQUIDITY);
        vm.startPrank(LP);
        usdc.approve(address(pool), type(uint256).max);
        pool.provide(LP_LIQUIDITY, 0);
        vm.stopPrank();
    }

    /// Create one real option locking `amount` of pool liquidity.
    function _openOption(uint256 amount, uint256 totalFee, uint256 queuedTime, uint256 period)
        internal
        returns (uint256 optionId)
    {
        // Fund the options contract with the full fee it must disburse + lock.
        usdc.mint(address(options), totalFee);
        IBufferBinaryOptions.OptionParams memory p = IBufferBinaryOptions.OptionParams({
            strike: 1_000e8,
            amount: amount,
            period: period,
            allowPartialFill: false,
            totalFee: totalFee,
            user: TRADER,
            referralCode: "",
            baseSettlementFeePercentage: 0
        });
        optionId = options.createFromRouter(p, queuedTime);
    }

    function test_H02_partialExerciseLocksLpFundsForever() public {
        _deployStack();

        uint256 amount = 100e6;   // lockedAmount = 100 USDC
        uint256 totalFee = 60e6;  // premium = 50 (amount/2), settlementFee = 10
        uint256 queuedTime = 1_000;
        uint256 period = 3_600;
        uint256 optionId = _openOption(amount, totalFee, queuedTime, period);

        // sanity: pool locked the full option size
        assertEq(pool.lockedAmount(), amount, "pre: full amount locked");
        (, , , uint256 lockedAmount, , uint256 expiration, , ) = options.options(optionId);
        assertEq(lockedAmount, amount, "option locked = amount");

        // EARLY exercise: closingTime strictly before expiration => partial BSM profit.
        uint256 closingTime = queuedTime + 1_800; // 1,800s in, 1,800s before expiry
        assertLt(closingTime, expiration, "must be an early close");

        uint256 traderBefore = usdc.balanceOf(TRADER);
        // ATM-ish price so the binary pays a genuine PARTIAL (not full, not zero).
        options.unlock(optionId, 1_000e8, closingTime, true);
        uint256 profit = usdc.balanceOf(TRADER) - traderBefore;

        // The option paid a partial profit and is now fully closed (burned).
        assertGt(profit, 0, "profit must be > 0");
        assertLt(profit, amount, "early exercise must be a PARTIAL payout");
        (IBufferBinaryOptions.State state, , , , , , , ) = options.options(optionId);
        assertEq(uint256(state), uint256(IBufferBinaryOptions.State.Exercised), "option closed");

        // === HARM: the (amount - profit) remainder is still counted as locked ===
        uint256 stuck = pool.lockedAmount();
        assertEq(stuck, amount - profit, "lockedAmount stuck at (amount - profit)");
        assertGt(stuck, 0, "funds permanently locked");
        emit log_named_uint("permanently locked (USDC 1e6)", stuck);
        emit log_named_uint("partial profit paid (USDC 1e6)", profit);

        // The pool physically holds these tokens (they belong to LPs now the option
        // is closed) but availableBalance() hides `stuck` of them forever.
        uint256 freeTokens = pool.totalTokenXBalance(); // balance - lockedPremium
        uint256 available = pool.availableBalance();     // freeTokens - lockedAmount
        assertEq(freeTokens - available, stuck, "availableBalance short by `stuck`");

        // The LP owns 100% of the pool but can never pull the last `stuck` tokens.
        uint256 lpShare = pool.shareOf(LP); // == freeTokens (sole LP)
        assertEq(lpShare, freeTokens, "LP owns the whole pool");
        assertGt(lpShare, available, "LP's share exceeds what is withdrawable");

        // Withdrawing the LP's full rightful share reverts: funds are locked.
        vm.prank(LP);
        vm.expectRevert(bytes("Pool: Not enough funds on the pool contract. Please lower the amount."));
        pool.withdraw(lpShare);

        // The LP can only ever get `available`; `stuck` is lost.
        vm.prank(LP);
        pool.withdraw(available);
        assertEq(usdc.balanceOf(address(pool)) - pool.lockedPremium(), stuck, "exactly `stuck` trapped in pool");
    }

    /// Negative control: a FULL exercise (closingTime >= expiration => profit ==
    /// lockedAmount) unlocks the entire amount and traps nothing. This proves the
    /// lock is caused specifically by the partial-payout branch of send().
    function test_H02_fullExerciseLocksNothing() public {
        _deployStack();

        uint256 amount = 100e6;
        uint256 totalFee = 60e6;
        uint256 queuedTime = 1_000;
        uint256 period = 3_600;
        uint256 optionId = _openOption(amount, totalFee, queuedTime, period);

        (, , , , , uint256 expiration, , ) = options.options(optionId);

        // FULL exercise: closingTime at/after expiration => profit == lockedAmount.
        uint256 traderBefore = usdc.balanceOf(TRADER);
        options.unlock(optionId, 1_500e8, expiration, true); // ITM call, full payout
        uint256 profit = usdc.balanceOf(TRADER) - traderBefore;

        assertEq(profit, amount, "full exercise pays the whole locked amount");
        assertEq(pool.lockedAmount(), 0, "nothing left locked when payout is full");
    }
}
