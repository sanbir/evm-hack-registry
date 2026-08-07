// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/core/BufferRouter.sol";
import "../src/core/BufferBinaryOptions.sol";
import "../src/core/BufferBinaryPool.sol";
import "../src/core/OptionsConfig.sol";
import "../src/core/Validator.sol";
import "../src/interfaces/Interfaces.sol";

/*//////////////////////////////////////////////////////////////
       Opaque out-of-scope boundary doubles (NOT the finding)
//////////////////////////////////////////////////////////////*/

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
// AccountRegistrar boundary: account registration (an open-time concern) is not the
// subject. Returns a preset 1CT signer for a user.
contract AccountRegistrarDouble is IAccountRegistrar {
    mapping(address => AccountMapping) public override accountMapping;
    function setOneCT(address user, address oneCT) external { accountMapping[user] = AccountMapping(oneCT, 0); }
    function registerAccount(address, address, bytes memory) external override {}
}

/// ERC-1271 smart-account signer that the controller (the trader's 1CT wallet, or
/// the price publisher) can make attest to specific message digests. The Buffer
/// findings are SCHEMA gaps (missing timestamp/direction binding), NOT signature
/// forgeability — so a controlled smart account that genuinely attests exactly the
/// messages its owner authorizes is a faithful model of the real 1CT / oracle key.
contract Wallet1271 {
    mapping(bytes32 => bool) public approved;
    function approve(bytes32 digest) external { approved[digest] = true; }
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return approved[hash] ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/*//////////////////////////////////////////////////////////////
     RouterHarness — REAL BufferRouter + open-time seed helpers
//////////////////////////////////////////////////////////////*/

/// Inherits the REAL BufferRouter (so closeAnytime / verifyMarketDirection /
/// verifyPublisher / verifyCloseAnytime and the unlock path all run the audited
/// code). Adds ONLY: (a) a seed helper writing the exact state that _openTrade
/// produces (open-time is not the subject — the real createFromRouter still runs
/// and locks REAL pool liquidity), and (b) view helpers exposing the exact signed
/// digests so the controlled 1CT / publisher wallets can attest to them.
contract RouterHarness is BufferRouter {
    constructor(address _publisher, address _sfPublisher, address _admin, address _accountRegistrar)
        BufferRouter(_publisher, _sfPublisher, _admin, _accountRegistrar) {}

    function seedOption(
        address optionsContract,
        address user,
        address signer,
        uint256 queueId,
        uint256 strike,
        uint256 amount,
        uint256 totalFee,
        uint256 queuedTime,
        uint256 period
    ) external returns (uint256 optionId) {
        IBufferBinaryOptions.OptionParams memory p = IBufferBinaryOptions.OptionParams({
            strike: strike,
            amount: amount,
            period: period,
            allowPartialFill: false,
            totalFee: totalFee,
            user: user,
            referralCode: "",
            baseSettlementFeePercentage: 0
        });
        optionId = IBufferBinaryOptions(optionsContract).createFromRouter(p, queuedTime);
        queuedTrades[queueId] = QueuedTrade({
            user: user,
            totalFee: totalFee,
            period: period,
            targetContract: optionsContract,
            strike: strike,
            slippage: 0,
            allowPartialFill: false,
            referralCode: "",
            traderNFTId: 0,
            settlementFee: 0,
            isLimitOrder: false,
            isTradeResolved: true,
            optionId: optionId,
            isEarlyCloseAllowed: true
        });
        optionIdMapping[optionsContract][optionId] = OptionInfo({ queueId: queueId, signer: signer, nonce: 0 });
    }

    function _domainSep() internal view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("Validator")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }

    // Digest verifyCloseAnytime checks (signer = the user's 1CT).
    function closeAnytimeDigest(string memory assetPair, uint256 timestamp, uint256 optionId)
        external view returns (bytes32)
    {
        bytes32 hashData = keccak256(abi.encode(
            keccak256("CloseAnytimeSignature(string assetPair,uint256 timestamp,uint256 optionId)"),
            keccak256(bytes(assetPair)), timestamp, optionId));
        return keccak256(abi.encodePacked("\x19\x01", _domainSep(), hashData));
    }

    // Digest verifyPublisher checks (signer = the price publisher).
    function publisherDigest(string memory assetPair, uint256 timestamp, uint256 price)
        external pure returns (bytes32)
    {
        bytes32 hashData = keccak256(abi.encodePacked(assetPair, timestamp, price));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hashData));
    }

    // Digest verifyMarketDirection checks (signer = the user's 1CT). Non-limit order.
    function marketDirectionDigest(IBufferRouter.CloseTradeParams memory params, uint256 queueId)
        external view returns (bytes32)
    {
        QueuedTrade memory qt = queuedTrades[queueId];
        bytes32 hashData = Validator.getMarketDirectionHashWithSF(params, qt, params.marketDirectionSignInfo);
        return keccak256(abi.encodePacked("\x19\x01", _domainSep(), hashData));
    }
}

/*//////////////////////////////////////////////////////////////
                Shared deploy + close plumbing
//////////////////////////////////////////////////////////////*/

abstract contract BufferBase is Test {
    MockUSDC internal usdc;
    BufferBinaryPool internal pool;
    BufferBinaryOptions internal options;
    OptionsConfig internal config;
    AccountRegistrarDouble internal registrar;
    RouterHarness internal router;

    address internal constant SF_SINK = address(0x5E77);

    Wallet1271 internal oneCT;      // the trader's 1CT smart account
    Wallet1271 internal publisher;  // the price oracle's smart account

    uint256 internal constant LP_LIQUIDITY = 1_000e6;

    function _deployStack() internal {
        usdc = new MockUSDC();
        pool = new BufferBinaryPool(ERC20(address(usdc)), 0);
        config = new OptionsConfig(pool);
        options = new BufferBinaryOptions();
        registrar = new AccountRegistrarDouble();
        oneCT = new Wallet1271();
        publisher = new Wallet1271();

        // Router: publisher = the oracle wallet; keepers open (private mode off).
        router = new RouterHarness(address(publisher), address(publisher), address(this), address(registrar));

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
        config.setEarlyCloseThreshold(0);
        config.toggleEarlyClose(); // isEarlyCloseAllowed = true

        pool.grantRole(pool.OPTION_ISSUER_ROLE(), address(options));
        options.grantRole(options.ROUTER_ROLE(), address(router));
        options.approvePoolToTransferTokenX();

        // The finding's precondition: private keeper mode is DISABLED.
        router.setInPrivateKeeperMode();
        assertTrue(!router.isInPrivateKeeperMode(), "private keeper mode must be off");

        // LP seeds the pool.
        usdc.mint(address(this), LP_LIQUIDITY);
        usdc.approve(address(pool), type(uint256).max);
        pool.provide(LP_LIQUIDITY, 0);
    }

    /// Open a real option owned by `user`, signed by 1CT `oneCT`.
    function _seed(address user, uint256 queueId, uint256 strike, uint256 amount, uint256 totalFee, uint256 queuedTime, uint256 period)
        internal returns (uint256 optionId)
    {
        registrar.setOneCT(user, address(oneCT));
        usdc.mint(address(options), totalFee);
        optionId = router.seedOption(address(options), user, address(oneCT), queueId, strike, amount, totalFee, queuedTime, period);
    }

    function _closeParams(uint256 optionId, uint256 closingPrice, bool isAbove, uint256 mdTs, uint256 pubTs, uint256 userTs)
        internal view returns (IBufferRouter.CloseAnytimeParams memory cap)
    {
        IBufferRouter.CloseTradeParams memory ctp = IBufferRouter.CloseTradeParams({
            optionId: optionId,
            targetContract: address(options),
            closingPrice: closingPrice,
            isAbove: isAbove,
            marketDirectionSignInfo: IBufferRouter.SignInfo({ signature: hex"01", timestamp: mdTs }),
            publisherSignInfo: IBufferRouter.SignInfo({ signature: hex"01", timestamp: pubTs })
        });
        cap = IBufferRouter.CloseAnytimeParams({
            closeTradeParams: ctp,
            userSignInfo: IBufferRouter.SignInfo({ signature: hex"01", timestamp: userTs })
        });
    }

    // 1CT attests the user close + market direction; publisher attests the price.
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

    function _optionState(uint256 optionId) internal view returns (IBufferBinaryOptions.State s) {
        (s, , , , , , , ) = options.options(optionId);
    }
}
