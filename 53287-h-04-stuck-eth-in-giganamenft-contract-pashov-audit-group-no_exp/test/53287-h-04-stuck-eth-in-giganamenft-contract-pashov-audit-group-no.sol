// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  GigaNameNFT.mintUsername is payable and neither GigaNameNFT nor GameNFT
    has a withdraw (Pashov Audit Group, Gigaverse, 2025-01-18, H-04).
    SYNTHETIC, cheatcode-free, one transaction.
    1 ETH is paid to mint. The buggy contract balance stays 1 ETH.
    The control contract has withdraw and the manager receives that 1 ETH. */

contract Harm {
    string public symbol = "STUCK-ETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract GigaNameNFT {
    uint256 public nextId;

    function mintUsername() external payable {
        require(msg.value == 1 ether, "fee");
        // @> VULN: the mint fee stays here; this contract has no withdraw
        nextId += 1;
    }
}

contract FixedGameNFT {
    uint256 public nextId;

    function mintUsername() external payable {
        require(msg.value == 1 ether, "fee");
        nextId += 1;
    }

    function withdraw(address payable to) external {
        to.transfer(address(this).balance);
    }
}

contract Manager {
    receive() external payable {}
}

contract Exploit {
    uint256 public constant FEE = 1 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Harm public harm;
    GigaNameNFT public buggy;
    FixedGameNFT public fixedNft;
    Manager public manager;

    uint256 public mintedId;
    uint256 public stuck;
    uint256 public rescued;
    uint256 public fixedLeft;

    constructor() {
        harm = new Harm();
        buggy = new GigaNameNFT();
        fixedNft = new FixedGameNFT();
        manager = new Manager();
    }

    function run() external payable {
        require(msg.value == 2 ether, "value");
        require(address(buggy).balance == 0, "start");
        buggy.mintUsername{value: FEE}();
        mintedId = buggy.nextId();
        require(mintedId == 1, "minted");
        stuck = address(buggy).balance;
        require(stuck == FEE, "stuck");
        fixedNft.mintUsername{value: FEE}();
        require(address(fixedNft).balance == FEE, "control held");
        fixedNft.withdraw(payable(address(manager)));
        rescued = address(manager).balance;
        require(rescued == FEE, "rescued");
        fixedLeft = address(fixedNft).balance;
        require(fixedLeft == 0, "cleared");
        harm.mint(SINK, stuck);
        require(harm.balanceOf(SINK) == FEE, "marked");
    }
}
