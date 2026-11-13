// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  STBL ESS NFT vault mergeLot (Cyfrin 2026-06, finding 66735)
    _Vault_mergeLot delegates to SplitMerge.merge, which burns both NFTs
    (isDisabled = true) before disableYield snapshots stakingData.earned.
    claim(burnedId) then reverts STBL_YLDDisabled. The reward tokens stay
    in the YieldDistributor. The merged NFT starts at earned = 0.

    CREATE order inside Exploit:
      nonce 1 Reward, 2 YLD, 3 YieldDistributor, 4 Issuer, 5 SplitMerge, 6 Vault
*/

contract Reward {
    string public symbol = "YLD-R";
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
        bool isDisabled;
    }

    mapping(uint256 => Meta) public meta;
    uint256 public nextId = 1;

    function disabled(uint256 id) external view returns (bool) {
        return meta[id].isDisabled;
    }

    function burn(address, uint256 id) external {
        meta[id].isDisabled = true;
    }

    function mint(address) external returns (uint256 id) {
        id = nextId++;
    }
}

contract YieldDistributor {
    Reward public reward;
    YLD public yld;
    mapping(uint256 => uint256) public earned;
    mapping(uint256 => uint256) public stakingBalance;
    error STBL_YLDDisabled(uint256 id);

    constructor(Reward _reward, YLD _yld) {
        reward = _reward;
        yld = _yld;
    }

    function distribute(uint256 id, uint256 amount) external {
        reward.transferFrom(msg.sender, address(this), amount);
        earned[id] += amount;
        stakingBalance[id] += amount;
    }

    function disableStaking(uint256 id) external {
        uint256 pending = earned[id];
        earned[id] = pending;
        stakingBalance[id] = 0;
    }

    function enableYield(uint256 id) external {
        earned[id] = 0;
        stakingBalance[id] = 0;
    }

    function claim(uint256 id) external {
        if (yld.disabled(id)) revert STBL_YLDDisabled(id);
        uint256 amount = earned[id];
        earned[id] = 0;
        reward.transfer(msg.sender, amount);
    }
}

contract Issuer {
    YieldDistributor public dist;

    constructor(YieldDistributor _dist) {
        dist = _dist;
    }

    function disableYield(uint256 id) external {
        dist.disableStaking(id);
    }

    function enableYield(uint256 id) external {
        dist.enableYield(id);
    }
}

contract SplitMerge {
    YLD public yld;
    Issuer public issuer;

    constructor(YLD _yld, Issuer _issuer) {
        yld = _yld;
        issuer = _issuer;
    }

    function merge(address caller, uint256 tokenIdA, uint256 tokenIdB) external returns (uint256 newTokenId) {
        yld.burn(caller, tokenIdA);
        yld.burn(caller, tokenIdB);
        newTokenId = yld.mint(caller);
        issuer.disableYield(tokenIdA);
        issuer.disableYield(tokenIdB);
        issuer.enableYield(newTokenId);
    }
}

contract Vault {
    SplitMerge public splitMerge;
    uint256 public lastMerged;

    constructor(SplitMerge _split) {
        splitMerge = _split;
    }

    function mergeLot(uint256 lotA, uint256 lotB) external returns (uint256 merged) {
        // @> VULN: merge burns both NFTs before any yield claim, stranding earned rewards
        merged = splitMerge.merge(msg.sender, lotA, lotB);
        lastMerged = merged;
    }
}

contract VaultFixed {
    SplitMerge public splitMerge;
    YieldDistributor public dist;

    constructor(SplitMerge _split, YieldDistributor _dist) {
        splitMerge = _split;
        dist = _dist;
    }

    function mergeLot(uint256 lotA, uint256 lotB) external returns (uint256 merged) {
        dist.claim(lotA);
        dist.claim(lotB);
        merged = splitMerge.merge(msg.sender, lotA, lotB);
    }
}

contract Exploit {
    Reward public reward;
    YLD public yld;
    YieldDistributor public dist;
    Issuer public issuer;
    SplitMerge public splitMerge;
    Vault public vault;
    uint256 public stranded;
    uint256 public mergedId;
    uint256 public constant NFT_A = 11;
    uint256 public constant NFT_B = 12;
    uint256 public constant YIELD = 40 ether;

    constructor() {
        reward = new Reward();
        yld = new YLD();
        dist = new YieldDistributor(reward, yld);
        issuer = new Issuer(dist);
        splitMerge = new SplitMerge(yld, issuer);
        vault = new Vault(splitMerge);
        reward.mint(address(this), YIELD);
    }

    function run() external {
        reward.approve(address(dist), YIELD);
        dist.distribute(NFT_A, YIELD);
        require(dist.earned(NFT_A) == YIELD, "accrued");
        mergedId = vault.mergeLot(NFT_A, NFT_B);
        require(yld.disabled(NFT_A), "burned");
        stranded = dist.earned(NFT_A);
        require(stranded == YIELD, "still earned");
        require(dist.earned(mergedId) == 0, "not forwarded");
        (bool claimed,) = address(dist).call(abi.encodeWithSelector(dist.claim.selector, NFT_A));
        require(!claimed, "claimed");
        require(reward.balanceOf(address(dist)) == YIELD, "locked");
        require(reward.balanceOf(address(this)) == 0, "user got nothing");
    }
}
