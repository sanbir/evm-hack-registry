// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, MoveToken, RestorationDesk} from "./40983-malicious-restoration-servers-can-replay-restoredata-message.sol";

contract RestorationDeskFixed {
    MoveToken public immutable token;
    mapping(address => uint256) public credit;
    mapping(address => uint256) public used;

    constructor(MoveToken token_) {
        token = token_;
    }

    function creditAccount(address account, uint256 amount) external {
        credit[account] = amount;
    }

    function restore(address account, uint256 amount, bytes calldata sig) external {
        bytes32 hash = keccak256(abi.encode(account, amount));
        require(_recover(hash, sig) == account, "signer");
        require(used[account] == 0, "replay");
        used[account] = 1;
        credit[account] -= amount;
        token.transfer(msg.sender, amount);
    }

    function _recover(bytes32 hash, bytes calldata sig) internal pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        return ecrecover(hash, v, r, s);
    }
}

contract Finding40983Test is Test {
    function test_second_restore_moves_100() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.firstMoved(), 100, "first");
        assertEq(e.secondMoved(), 100, "second");
        assertEq(e.token().balanceOf(address(e)), 200, "server");
        assertEq(e.desk().credit(e.USER()), 0, "drained");
        console2.log("first moved", e.firstMoved());
        console2.log("second moved", e.secondMoved());
        console2.log("server balance", e.token().balanceOf(address(e)));
    }

    function test_control_nonce_stops_the_second_restore() public {
        MoveToken token = new MoveToken();
        RestorationDeskFixed desk = new RestorationDeskFixed(token);
        token.mint(address(desk), 200);
        address user = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        desk.creditAccount(user, 200);
        bytes memory sig = abi.encodePacked(
            bytes32(0x6d664fe8c1b2a589b2a342cf747fe9c374116ecf5011466b9467bd68d432901e),
            bytes32(0x76110b80b3e36b3b24d005da2b44d41210b51cc1b9f0bac39ff35a5e19bc0732),
            uint8(27)
        );
        desk.restore(user, 100, sig);
        (bool ok,) = address(desk).call(abi.encodeWithSelector(desk.restore.selector, user, 100, sig));
        assertFalse(ok, "second restore reverts");
        assertEq(desk.credit(user), 100, "100 remains");
        assertEq(token.balanceOf(address(this)), 100, "only the first 100 moved");
        console2.log("control credit left", desk.credit(user));
        console2.log("control moved", token.balanceOf(address(this)));
    }
}
