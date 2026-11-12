// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Underlying,
    UsdxlAToken,
    DeployUsdxlUtils
} from "./55467-h-03-incorrect-proxy-address-tracking-misconfigures-usdxl-po.sol";

contract DeployUsdxlUtilsFixed is DeployUsdxlUtils {
    constructor(UsdxlAToken impl, UsdxlAToken proxy, Underlying asset) DeployUsdxlUtils(impl, proxy, asset) {}

    function _getUsdxlATokenProxy() public override returns (address) {
        trackedProxy = address(usdxlATokenProxy);
        return trackedProxy;
    }
}

contract Finding55467Test is Test {
    function test_exploit_mints_on_the_implementation() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.underlying().balanceOf(address(e.impl())), 1000, "1000 underlying on the implementation");
        assertEq(e.underlying().balanceOf(address(e.proxy())), 0, "proxy holds 0");
        assertEq(e.impl().balanceOf(address(e)), 1000, "1000 aToken mis-minted");
    }

    function test_control_stores_the_proxy() public {
        Underlying underlying = new Underlying();
        UsdxlAToken impl = new UsdxlAToken();
        UsdxlAToken proxy = new UsdxlAToken();
        DeployUsdxlUtilsFixed utils = new DeployUsdxlUtilsFixed(impl, proxy, underlying);
        underlying.mint(address(utils), 1000);
        address hit = utils._getUsdxlATokenProxy();
        utils.supply(address(this), 1000);
        assertEq(hit, address(proxy), "control hits the proxy");
        assertEq(underlying.balanceOf(address(proxy)), 1000, "proxy holds 1000");
        assertEq(underlying.balanceOf(address(impl)), 0, "implementation holds 0");
        assertEq(proxy.balanceOf(address(this)), 1000, "aToken minted on the proxy");
        assertEq(impl.balanceOf(address(this)), 0, "implementation minted 0");
    }
}
