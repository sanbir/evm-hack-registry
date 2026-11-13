// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  OmoVault.topOff — only agent id 0 may redeem (Pashov, 53316)
    SYNTHETIC, cheatcode-free reduction.
    Root cause: topOff requires agents(0) == msg.sender. Id 0 is never registered,
    so the real agent cannot redeem and the vault balance stays put.
    The control passes the registered agent id and pays N. */

contract MockERC20 {
    string public name = "Asset";
    string public symbol = "AST";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract OmoAgent {
    address public manager;
    mapping(uint256 => address) public agents;

    function setAgent(uint256 id, address who) external {
        agents[id] = who;
    }
}

contract OmoVault {
    MockERC20 public asset;
    bool public immutable useRealId;

    constructor(MockERC20 a, bool realId) {
        asset = a;
        useRealId = realId;
    }

    function topOff(address userAccount, uint256 agentId) external {
        OmoAgent agent = OmoAgent(payable(userAccount));
        uint256 id = useRealId ? agentId : 0;
        if (!useRealId) {
            // @> VULN: only agent id 0 is checked, and that id was never registered
            require(agent.agents(0) == msg.sender, "UNAUTHORIZED_AGENT");
        } else {
            require(agent.agents(id) == msg.sender, "UNAUTHORIZED_AGENT");
        }
        uint256 n = asset.balanceOf(address(this));
        asset.transfer(msg.sender, n);
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    MockERC20 public asset; // nonce 1
    OmoAgent public account; // nonce 2
    OmoVault public vault; // nonce 3
    OmoVault public controlVault; // nonce 4

    uint256 public stuck;
    bool public redeemReverted;
    uint256 public controlPaid;

    constructor() {
        asset = new MockERC20();
        account = new OmoAgent();
        vault = new OmoVault(asset, false);
        controlVault = new OmoVault(asset, true);
        account.setAgent(1, address(this));
        asset.mint(address(this), N * 2);
    }

    function run() external {
        require(account.agents(0) == address(0), "id 0 empty");
        require(account.agents(1) == address(this), "real agent");
        asset.transfer(address(vault), N);
        try vault.topOff(address(account), 1) {
            revert("redeemed");
        } catch {
            redeemReverted = true;
        }
        stuck = asset.balanceOf(address(vault));
        require(redeemReverted, "not reverted");
        require(stuck == N, "N did not stay");

        asset.transfer(address(controlVault), N);
        controlVault.topOff(address(account), 1);
        controlPaid = asset.balanceOf(address(this));
        require(controlPaid == N, "control did not pay N");
        require(asset.balanceOf(address(controlVault)) == 0, "control vault empty");
    }
}
