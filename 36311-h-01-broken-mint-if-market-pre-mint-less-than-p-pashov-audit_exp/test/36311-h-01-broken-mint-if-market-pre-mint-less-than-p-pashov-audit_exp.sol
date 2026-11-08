// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    FreePrefixCurve,
    IPSeed
} from "./36311-h-01-broken-mint-if-market-pre-mint-less-than-p-pashov-audit.sol";

/// Report's fix: the free-prefix check uses p from the curve, not the stored premint.
contract IPSeedFixed is IPSeed {
    constructor(FreePrefixCurve curve) IPSeed(curve) {}

    function mint(uint256 tokenId, uint256 amount) external payable override returns (uint256 gross, uint256 net) {
        MarketParameters memory _marketParams = marketParams[tokenId];
        (gross, net) = getBuyPrice(tokenId, amount);
        require(msg.value >= gross, "underpaid");
        uint256 p = _marketParams.priceCurve.decodeP(_marketParams.curveParameters);
        if (totalSupply[tokenId] + amount > p && (amount < MINIMUM_TRADE_SIZE || net == 0)) {
            revert TradeSizeOutOfRange();
        }
        balanceOf[tokenId][msg.sender] += amount;
        totalSupply[tokenId] += amount;
    }
}

contract Finding36311Test is Test {
    function test_exploit_free_premint_above_stored_premint_reverts() public {
        Exploit e = new Exploit();
        e.run();
        assertFalse(e.mintOk(), "mint reverted");
        assertEq(e.minted(), 0, "buyer received nothing");
        assertEq(e.market().totalSupply(1), 0, "no tokens issued");
        assertEq(e.WANT(), 50 ether, "50 tokens were requested");
    }

    function test_control_comparing_p_mints_the_free_tokens() public {
        FreePrefixCurve curve = new FreePrefixCurve();
        IPSeedFixed fixedMarket = new IPSeedFixed(curve);
        bytes32 params = bytes32(uint256(100 ether));
        fixedMarket.spawn(1, 10 ether, params);

        (uint256 gross, uint256 net) = fixedMarket.mint(1, 50 ether);
        assertEq(gross, 0, "still inside the free prefix");
        assertEq(net, 0, "price is 0");
        assertEq(fixedMarket.balanceOf(1, address(this)), 50 ether, "buyer received 50");
        assertEq(fixedMarket.totalSupply(1), 50 ether, "supply is 50");
    }
}
