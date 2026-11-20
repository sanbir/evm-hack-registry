// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  OmoVault.totalAssets (Pashov, 2025-01).
    The vault holds 100. The agent reports 100 of positions, of which
    60 were borrowed from another vault. totalAssets returns 200.
    The control adds only this vault's 40 and returns 140.
*/

contract Agent {
    function getPositionValue(address) external pure returns (uint256) {
        return 100 ether;
    }

    function valueFor(uint256 vaultId) external pure returns (uint256) {
        if (vaultId == 1) return 40 ether;
        return 60 ether;
    }
}

contract Vault {
    uint256 public holdings = 100 ether;
    Agent public agent;
    uint256 public calls;
    uint256 public lastHoldings;
    uint256 public lastAccount;
    uint256 public lastAssets;
    uint256 public reported;

    constructor(Agent _agent) {
        agent = _agent;
    }

    function totalAssets() public returns (uint256) {
        calls += 1;
        uint256 vaultHoldings = holdings;
        lastHoldings = vaultHoldings;
        uint256 accountHoldings = agent.getPositionValue(address(this));
        lastAccount = accountHoldings;
        uint256 sum = vaultHoldings + accountHoldings; // @> VULN: every position on the agent is counted, including the other vault's 60
        lastAssets = sum;
        reported = sum;
        return sum;
    }
}

contract VaultFixed {
    Agent public agent;
    uint256 public holdings = 100 ether;

    constructor(Agent _agent) {
        agent = _agent;
    }

    function totalAssets() public view returns (uint256) {
        return holdings + agent.valueFor(1);
    }
}

contract OverMarker {
    string public symbol = "OVER-VALUE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Agent public agent;
    Vault public vault;
    OverMarker public marker;

    function run() external {
        agent = new Agent();
        vault = new Vault(agent);
        marker = new OverMarker();
        uint256 quoted = vault.totalAssets();
        require(quoted == 200 ether, "reports 200");
        marker.mint(SINK, 60 ether);
        require(marker.balanceOf(SINK) == 60 ether, "60 too much");
    }
}
