// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MockERC20,
    MockCToken,
    CompoundProvider,
    Controller,
    DerbyVault,
    IController,
    IProvider,
    IERC20
} from "./12293-h-11-vaults-withdrawfromprotocol-incorrectly-scales-amount-t.sol";

/// Same withdrawal as DerbyVault, but the scale uses underlying USDC decimals
/// (the fix: extend ProtocolInfoS with underlying decimals) instead of cUSDC's.
contract DerbyVaultFixed {
    IController public controller;
    uint256 public uScale;
    uint256 public underlyingScale;
    uint256 public vaultNumber;
    uint256 public lastScaled;
    uint256 public lastShares;
    uint256 public lastReceived;

    constructor(address _controller, uint256 _uScale, uint256 _underlyingScale) {
        controller = IController(_controller);
        uScale = _uScale;
        underlyingScale = _underlyingScale;
    }

    function withdrawFromProtocol(uint256 _protocolNum, uint256 _amount) public {
        if (_amount <= 0) return;
        IController.ProtocolInfoS memory protocol = controller.getProtocolInfo(vaultNumber, _protocolNum);
        // FIX: underlyingScale is 10**USDC decimals, not protocol.uScale (10**cUSDC decimals).
        _amount = (_amount * underlyingScale) / uScale;
        uint256 shares = IProvider(protocol.provider).calcShares(_amount, protocol.LPToken);
        uint256 balance = IProvider(protocol.provider).balance(address(this), protocol.LPToken);
        if (shares == 0) return;
        if (balance < shares) shares = balance;
        IERC20(protocol.LPToken).approve(protocol.provider, shares);
        uint256 amountReceived =
            IProvider(protocol.provider).withdraw(shares, protocol.LPToken, protocol.underlying);
        lastShares = shares;
        lastScaled = _amount;
        lastReceived = amountReceived;
    }
}

contract Finding12293Test is Test {
    function test_withdraw_pulls_one_hundred_times_the_request() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("requested USDC raw", e.REQUEST());
        emit log_named_uint("buggy USDC received", e.pulled());
        emit log_named_uint("fair USDC", e.REQUEST());
        emit log_named_uint("cUSDC left raw", e.left());
        emit log_named_uint("position short raw", e.POSITION() - e.REQUEST() - e.left());

        assertEq(e.vault().lastScaled(), 100_000_000 * 1e6, "scaled 1e12 into 1e14");
        assertEq(e.vault().lastShares(), 100_000_000 * 1e6, "100x shares");
        assertEq(e.pulled(), 100_000_000 * 1e6, "vault receives 100000000 USDC");
        assertEq(e.left(), 100_000_000 * 1e6, "100000000 USDC left in Compound");
        // Fair remainder is 199_000_000 USDC. The position is short 99_000_000.
        assertEq((200_000_000 * 1e6 - 1_000_000 * 1e6) - e.left(), 99_000_000 * 1e6, "short 99000000 USDC");

        uint256 fairShares = e.provider().calcShares(1_000_000 * 1e6, address(e.cusdc()));
        assertEq(fairShares, 1_000_000 * 1e6, "unscaled calcShares matches the request");
        assertEq(e.vault().lastShares(), fairShares * 100, "bug is exactly 100x");
    }

    function test_control_underlying_scale_withdraws_one_million() public {
        uint256 position = 200_000_000 * 1e6;
        uint256 request = 1_000_000 * 1e6;

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockCToken cusdc = new MockCToken(address(usdc), 10 ** 16);
        CompoundProvider provider = new CompoundProvider();
        Controller controller = new Controller(address(cusdc), address(provider), address(usdc), 10 ** 8);
        DerbyVaultFixed vault = new DerbyVaultFixed(address(controller), 10 ** 6, 10 ** 6);
        usdc.mint(address(cusdc), position);
        cusdc.mintShares(address(vault), position);

        vault.withdrawFromProtocol(0, request);

        emit log_named_uint("control USDC received", vault.lastReceived());
        emit log_named_uint("control cUSDC left", cusdc.balanceOf(address(vault)));

        assertEq(vault.lastScaled(), request, "underlying scale leaves 1e12");
        assertEq(vault.lastShares(), request, "fair shares");
        assertEq(vault.lastReceived(), request, "vault receives 1000000 USDC");
        assertEq(usdc.balanceOf(address(vault)), request, "idle USDC is the request");
        assertEq(cusdc.balanceOf(address(vault)), position - request, "199000000 USDC stays in Compound");
    }
}
