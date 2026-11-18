// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Nexus DepositUSD — C-01 (Pashov, 2024-11-29)
    executeWithdrawal pays the user with ETH via call{value: amount} even though
    the queued balance is a USD token (DAI / sDAI). The contract holds no ETH, so
    the call fails and the USD stays locked. The blamed call is preserved verbatim.
*/

contract MockToken {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract Receiver {
    // No receive() and no fallback. A value-bearing call returns false.
}

contract DepositUSD {
    struct Withdrawal {
        uint256 amount;
        uint256 withdrawalExecutionTime;
    }

    MockToken public usd;
    address public strategyExecutor;
    mapping(address => mapping(bytes32 => Withdrawal)) public withdrawals;

    error IncorrectStrategyExecutor(address sender);
    error CallFailed();
    event WithdrawalCompleted(address indexed receiver, bytes32 hash);

    constructor(MockToken _usd, address _executor) {
        usd = _usd;
        strategyExecutor = _executor;
    }

    function queueWithdrawal(address receiver, bytes32 hash, uint256 amount) external {
        usd.transferFrom(msg.sender, address(this), amount);
        withdrawals[receiver][hash].amount = amount;
    }

    function executeWithdrawal(address _receiver, bytes32 _hash) external {
        if (msg.sender != strategyExecutor) revert IncorrectStrategyExecutor(msg.sender); // @beat:guard
        (bool success, bytes memory returndata) = _receiver.call{value: withdrawals[_receiver][_hash].amount, gas: 10000}(""); // @> VULN: sends ETH instead of the deposited USD token
        // FIX: usd.transfer(_receiver, withdrawals[_receiver][_hash].amount);
        if (!success) {
            if (returndata.length == 0) revert CallFailed(); // @beat:revert
            assembly {
                revert(add(32, returndata), mload(returndata))
            }
        }
        withdrawals[_receiver][_hash].withdrawalExecutionTime = block.timestamp;
        emit WithdrawalCompleted(_receiver, _hash);
    }

    function executeWithdrawalFixed(address _receiver, bytes32 _hash) external {
        if (msg.sender != strategyExecutor) revert IncorrectStrategyExecutor(msg.sender);
        uint256 amount = withdrawals[_receiver][_hash].amount;
        withdrawals[_receiver][_hash].amount = 0;
        usd.transfer(_receiver, amount);
        withdrawals[_receiver][_hash].withdrawalExecutionTime = block.timestamp;
    }
}

contract Exploit {
    MockToken public dai;
    DepositUSD public vault;
    Receiver public user;
    bytes32 public constant HASH = keccak256("nexus-withdrawal");
    uint256 public constant AMOUNT = 1000 ether;
    bool public withdrawalReverted;
    uint256 public daiLocked;
    uint256 public userDai;

    constructor() {
        dai = new MockToken("DAI"); // nonce 1
        user = new Receiver(); // nonce 2
        vault = new DepositUSD(dai, address(this)); // nonce 3
    }

    function run() external {
        dai.mint(address(this), AMOUNT);
        dai.approve(address(vault), AMOUNT);
        vault.queueWithdrawal(address(user), HASH, AMOUNT); // @beat:queue
        (bool ok,) = address(vault).call(abi.encodeWithSelector(vault.executeWithdrawal.selector, address(user), HASH)); // @beat:call
        withdrawalReverted = !ok;
        daiLocked = dai.balanceOf(address(vault)); // @beat:locked
        userDai = dai.balanceOf(address(user));
        require(withdrawalReverted, "withdrawal should revert");
        require(daiLocked == AMOUNT, "DAI not locked");
        require(userDai == 0, "user received DAI");
        require(address(vault).balance == 0, "vault holds ETH");
        require(address(user).balance == 0, "user received ETH");
    }
}
