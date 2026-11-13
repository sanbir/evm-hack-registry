// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  SKALE TokenState — purchased tokens stay locked after the unlock window
    (ConsenSys Diligence, SKALE token, Jan 2020). TokenState.sol L258-L264.
    SYNTHETIC, cheatcode-free reduction.
    Unlock runs only inside the delegation callback, and only when
    totalDelegated >= purchased. A holder who has delegated 600 of 1000
    for longer than 90 days never takes that branch, so N stays unclaimable.
    The control unlocks once 90 days have passed and at least half is delegated. */

contract Cash {
    string public symbol = "SKL";
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

contract BuggyState {
    Cash public cash;
    mapping(address => uint256) public purchased;
    mapping(address => uint256) public totalDelegated;
    mapping(address => uint256) public unlocked;
    event Checked(uint256 delegated, uint256 purchasedAmount);

    constructor(address _cash) {
        cash = Cash(_cash);
    }

    function buy(address holder, uint256 amount) external {
        purchased[holder] = amount;
        cash.mint(address(this), amount);
    }

    function delegatePurchased(address holder, uint256 amount) external {
        totalDelegated[holder] += amount;
        // @> VULN: no 90-day check; unlock only if delegated >= every purchased token, so 600 of 1000 stays locked
        emit Checked(totalDelegated[holder], purchased[holder]);
        if (totalDelegated[holder] >= purchased[holder]) {
            unlocked[holder] = purchased[holder];
        }
    }

    function claim(address holder) external returns (uint256 amount) {
        amount = unlocked[holder];
        require(amount > 0, "locked");
        unlocked[holder] = 0;
        cash.transfer(holder, amount);
    }
}

contract FixedState {
    Cash public cash;
    mapping(address => uint256) public purchased;
    mapping(address => uint256) public totalDelegated;
    mapping(address => uint256) public unlocked;

    constructor(address _cash) {
        cash = Cash(_cash);
    }

    function buy(address holder, uint256 amount) external {
        purchased[holder] = amount;
        cash.mint(address(this), amount);
    }

    function delegatePurchased(address holder, uint256 amount) external {
        totalDelegated[holder] += amount;
    }

    function unlockIfDue(address holder) external {
        require(block.timestamp >= 90 days, "early");
        require(totalDelegated[holder] * 2 >= purchased[holder], "under half");
        unlocked[holder] = purchased[holder];
    }

    function claim(address holder) external returns (uint256 amount) {
        amount = unlocked[holder];
        require(amount > 0, "locked");
        unlocked[holder] = 0;
        cash.transfer(holder, amount);
    }
}

contract Holder {}

contract Exploit {
    uint256 public constant N = 1000 ether;
    uint256 public constant DELEGATED = 600 ether;

    Cash public cash;
    BuggyState public buggy;
    FixedState public fixedState;
    Holder public holder;

    bool public buggyClaimed;
    uint256 public controlClaimed;

    constructor() {
        cash = new Cash();
        buggy = new BuggyState(address(cash));
        fixedState = new FixedState(address(cash));
        holder = new Holder();
    }

    function run() external {
        buggy.buy(address(holder), N);
        buggy.delegatePurchased(address(holder), DELEGATED);
        fixedState.buy(address(holder), N);
        fixedState.delegatePurchased(address(holder), DELEGATED);
        require(buggy.unlocked(address(holder)) == 0, "buggy unlocked early");
        try buggy.claim(address(holder)) returns (uint256) {
            buggyClaimed = true;
        } catch {
            buggyClaimed = false;
        }
        require(!buggyClaimed, "buggy claim");
        require(cash.balanceOf(address(holder)) == 0, "holder still empty");
        fixedState.unlockIfDue(address(holder));
        controlClaimed = fixedState.claim(address(holder));
        require(controlClaimed == N, "control");
        require(cash.balanceOf(address(holder)) == N, "paid");
    }
}
