// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Omo — funds get locked in the vault (Pashov Audit Group, C-04)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: topOff resolves the Dynamic Account with record.receiver.
    The receiver has no account, so the agent cannot finish the redeem and
    the deposited assets stay in the vault. The quoted lines are verbatim.
    The fix keys the lookup on record.owner, who did register the agent. */

contract MiniToken {
    string public symbol;
    uint8 public constant decimals = 0;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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

contract OmoAgent {
    address public agent0;

    constructor(address a) {
        agent0 = a;
    }

    function agents(uint256) external view returns (address) {
        return agent0;
    }
}

struct Record {
    address owner;
    address receiver;
    uint256 assets;
}

contract OmoVault {
    MiniToken public asset;
    mapping(address => address) public userToAccount;
    Record public pending;
    uint256 public paid;

    constructor(address token) {
        asset = MiniToken(token);
    }

    function register(address user, address account) external {
        userToAccount[user] = account;
    }

    function deposit(uint256 assets) external {
        asset.transferFrom(msg.sender, address(this), assets);
    }

    function requestRedeem(address receiver, uint256 assets) external {
        pending = Record(msg.sender, receiver, assets);
    }

    function topOff() external {
        Record storage record = pending;
        // @> VULN: userToAccount is keyed by record.receiver, who never registered an agent
        address userAccount = userToAccount[record.receiver];
        require(userAccount != address(0), "NO_REGISTERED_ACCOUNT");

        OmoAgent agent = OmoAgent(payable(userAccount));
        require(agent.agents(0) == msg.sender, "UNAUTHORIZED_AGENT");

        asset.transfer(record.receiver, record.assets);
        paid = record.assets;
        pending.assets = 0;
    }

    function withdraw() external view returns (uint256) {
        return paid;
    }
}

contract OmoVaultFixed {
    MiniToken public asset;
    mapping(address => address) public userToAccount;
    Record public pending;
    uint256 public paid;

    constructor(address token) {
        asset = MiniToken(token);
    }

    function register(address user, address account) external {
        userToAccount[user] = account;
    }

    function deposit(uint256 assets) external {
        asset.transferFrom(msg.sender, address(this), assets);
    }

    function requestRedeem(address receiver, uint256 assets) external {
        pending = Record(msg.sender, receiver, assets);
    }

    function topOff() external {
        Record storage record = pending;
        // FIX: the owner is the account that registered the agent
        address userAccount = userToAccount[record.owner];
        require(userAccount != address(0), "NO_REGISTERED_ACCOUNT");

        OmoAgent agent = OmoAgent(payable(userAccount));
        require(agent.agents(0) == msg.sender, "UNAUTHORIZED_AGENT");

        asset.transfer(record.receiver, record.assets);
        paid = record.assets;
        pending.assets = 0;
    }
}

interface IRedeem {
    function deposit(uint256 assets) external;
    function requestRedeem(address receiver, uint256 assets) external;
}

contract Owner {
    MiniToken public asset;

    constructor(address token) {
        asset = MiniToken(token);
    }

    function fund(IRedeem vault, address receiver, uint256 amount) external {
        asset.approve(address(vault), amount);
        vault.deposit(amount);
        vault.requestRedeem(receiver, amount);
    }
}

contract Receiver {}

contract Exploit {
    uint256 public constant LOCKED = 1000;

    MiniToken public asset; // CREATE nonce 1
    OmoAgent public account; // CREATE nonce 2
    OmoVault public vault; // CREATE nonce 3
    Owner public owner; // CREATE nonce 4
    Receiver public receiver; // CREATE nonce 5

    bool public topOffReverted;
    uint256 public stuck;
    uint256 public paidOut;

    constructor() {
        asset = new MiniToken("OUSD");
        account = new OmoAgent(address(this));
        vault = new OmoVault(address(asset));
        owner = new Owner(address(asset));
        receiver = new Receiver();
        vault.register(address(owner), address(account));
    }

    function run() external {
        asset.mint(address(owner), LOCKED);
        owner.fund(IRedeem(address(vault)), address(receiver), LOCKED);

        (bool ok,) = address(vault).call(abi.encodeWithSelector(vault.topOff.selector));
        topOffReverted = !ok;

        paidOut = vault.withdraw();
        stuck = asset.balanceOf(address(vault));
        uint256 receiverBal = asset.balanceOf(address(receiver));

        require(topOffReverted, "topOff did not revert");
        require(paidOut == 0, "withdraw paid");
        require(receiverBal == 0, "receiver was paid");
        require(stuck == LOCKED, "assets not stuck");
        require(vault.userToAccount(address(owner)) == address(account), "owner account missing");
        require(vault.userToAccount(address(receiver)) == address(0), "receiver has an account");
    }
}
