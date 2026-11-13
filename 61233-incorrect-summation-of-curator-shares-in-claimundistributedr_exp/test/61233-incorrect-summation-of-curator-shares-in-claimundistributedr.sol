// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Suzaku Rewards.claimUndistributedRewards (Cyfrin, 2025-07).
    curatorShares[epoch][curator] is already that curator's total, but the
    loop adds it once per vault the curator owns. Two vaults turn 1000 bp
    into 2000 bp. Of 10,000 reward tokens, the distributor is paid 2,000
    instead of 3,000, and 1,000 tokens stay in the contract with no claimant.
    The control counts each curator once and leaves a zero balance.
*/

contract Token {
    string public symbol = "REWARD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract VaultTokenized {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }
}

contract Rewards {
    uint256 public constant BASIS = 10_000;
    Token public token;
    address public distributor;
    address public operator;
    address public curator;
    VaultTokenized public vault1;
    VaultTokenized public vault2;
    mapping(uint256 => mapping(address => uint256)) public operatorShares;
    mapping(uint256 => mapping(address => uint256)) public vaultShares;
    mapping(uint256 => mapping(address => uint256)) public curatorShares;
    mapping(uint256 => uint256) public rewardsForEpoch;
    uint256 public lastTotalShares;

    constructor(Token _token, address _distributor, address _operator, address _curator, VaultTokenized _vault1, VaultTokenized _vault2) {
        token = _token;
        distributor = _distributor;
        operator = _operator;
        curator = _curator;
        vault1 = _vault1;
        vault2 = _vault2;
    }

    function seed(uint256 epoch) external {
        operatorShares[epoch][operator] = 2000;
        vaultShares[epoch][address(vault1)] = 2000;
        vaultShares[epoch][address(vault2)] = 2000;
        curatorShares[epoch][curator] = 1000;
        rewardsForEpoch[epoch] = 10_000 ether;
    }

    function getAllOperators() public view returns (address[] memory operators) {
        operators = new address[](1);
        operators[0] = operator;
    }

    function getVaults() public view returns (address[] memory vaults) {
        vaults = new address[](2);
        vaults[0] = address(vault1);
        vaults[1] = address(vault2);
    }

    function claimUndistributedRewards(uint256 epoch) external {
        require(msg.sender == distributor, "role");
        uint256 totalDistributedShares = 0;
        address[] memory operators = getAllOperators();
        for (uint256 i = 0; i < operators.length; i++) {
            totalDistributedShares += operatorShares[epoch][operators[i]];
        }
        address[] memory vaults = getVaults();
        for (uint256 i = 0; i < vaults.length; i++) {
            totalDistributedShares += vaultShares[epoch][vaults[i]];
        }
        // @> VULN: curatorShares already stores the curator's total, but it is added again for every vault they own
        for (uint256 i = 0; i < vaults.length; i++) {
            address curatorOwner = VaultTokenized(vaults[i]).owner();
            totalDistributedShares += curatorShares[epoch][curatorOwner];
        }
        lastTotalShares = totalDistributedShares;
        uint256 totalRewardsForEpoch = rewardsForEpoch[epoch];
        uint256 undistributedRewards = totalRewardsForEpoch - ((totalRewardsForEpoch * totalDistributedShares) / BASIS);
        token.transfer(distributor, undistributedRewards);
    }

    function claimShare(uint256 epoch, uint8 kind, address who) external returns (uint256 amt) {
        uint256 share;
        if (kind == 0) {
            share = operatorShares[epoch][who];
            operatorShares[epoch][who] = 0;
        } else if (kind == 1) {
            share = vaultShares[epoch][who];
            vaultShares[epoch][who] = 0;
        } else {
            share = curatorShares[epoch][who];
            curatorShares[epoch][who] = 0;
        }
        amt = (rewardsForEpoch[epoch] * share) / BASIS;
        if (amt > 0) {
            token.transfer(who, amt);
        }
    }
}

contract RewardsFixed {
    uint256 public constant BASIS = 10_000;
    Token public token;
    address public distributor;
    address public operator;
    address public curator;
    VaultTokenized public vault1;
    VaultTokenized public vault2;
    mapping(uint256 => mapping(address => uint256)) public operatorShares;
    mapping(uint256 => mapping(address => uint256)) public vaultShares;
    mapping(uint256 => mapping(address => uint256)) public curatorShares;
    mapping(uint256 => uint256) public rewardsForEpoch;

    constructor(Token _token, address _distributor, address _operator, address _curator, VaultTokenized _vault1, VaultTokenized _vault2) {
        token = _token;
        distributor = _distributor;
        operator = _operator;
        curator = _curator;
        vault1 = _vault1;
        vault2 = _vault2;
    }

    function seed(uint256 epoch) external {
        operatorShares[epoch][operator] = 2000;
        vaultShares[epoch][address(vault1)] = 2000;
        vaultShares[epoch][address(vault2)] = 2000;
        curatorShares[epoch][curator] = 1000;
        rewardsForEpoch[epoch] = 10_000 ether;
    }

    function claimUndistributedRewards(uint256 epoch) external returns (uint256 undistributedRewards) {
        uint256 totalDistributedShares = 0;
        totalDistributedShares += operatorShares[epoch][operator];
        totalDistributedShares += vaultShares[epoch][address(vault1)];
        totalDistributedShares += vaultShares[epoch][address(vault2)];
        totalDistributedShares += curatorShares[epoch][curator];
        uint256 totalRewardsForEpoch = rewardsForEpoch[epoch];
        undistributedRewards = totalRewardsForEpoch - ((totalRewardsForEpoch * totalDistributedShares) / BASIS);
        token.transfer(distributor, undistributedRewards);
    }

    function claimShare(uint256 epoch, uint8 kind, address who) external returns (uint256 amt) {
        uint256 share;
        if (kind == 0) {
            share = operatorShares[epoch][who];
            operatorShares[epoch][who] = 0;
        } else if (kind == 1) {
            share = vaultShares[epoch][who];
            vaultShares[epoch][who] = 0;
        } else {
            share = curatorShares[epoch][who];
            curatorShares[epoch][who] = 0;
        }
        amt = (rewardsForEpoch[epoch] * share) / BASIS;
        if (amt > 0) {
            token.transfer(who, amt);
        }
    }
}

contract Exploit {
    address public constant DISTRIBUTOR = address(uint160(0xD157));
    address public constant OPERATOR = address(uint160(0x0A0));
    address public constant CURATOR = address(uint160(0xC0A));
    uint256 public constant EPOCH = 3;

    Token public token;
    VaultTokenized public vault1;
    VaultTokenized public vault2;
    Rewards public rewards;
    uint256 public totalShares;
    uint256 public distributorPaid;
    uint256 public locked;

    constructor() {
        token = new Token();
        vault1 = new VaultTokenized(CURATOR);
        vault2 = new VaultTokenized(CURATOR);
        rewards = new Rewards(token, address(this), OPERATOR, CURATOR, vault1, vault2);
        rewards.seed(EPOCH);
    }

    function run() external {
        token.mint(address(rewards), 10_000 ether);
        uint256 before = token.balanceOf(address(this));
        rewards.claimUndistributedRewards(EPOCH);
        distributorPaid = token.balanceOf(address(this)) - before;
        totalShares = rewards.lastTotalShares();
        rewards.claimShare(EPOCH, 0, OPERATOR);
        rewards.claimShare(EPOCH, 1, address(vault1));
        rewards.claimShare(EPOCH, 1, address(vault2));
        rewards.claimShare(EPOCH, 2, CURATOR);
        locked = token.balanceOf(address(rewards));
        require(totalShares == 8000, "shares");
        require(distributorPaid == 2000 ether, "underpaid");
        require(token.balanceOf(OPERATOR) == 2000 ether, "operator");
        require(token.balanceOf(address(vault1)) == 2000 ether, "v1");
        require(token.balanceOf(address(vault2)) == 2000 ether, "v2");
        require(token.balanceOf(CURATOR) == 1000 ether, "curator");
        require(locked == 1000 ether, "locked");
    }
}
