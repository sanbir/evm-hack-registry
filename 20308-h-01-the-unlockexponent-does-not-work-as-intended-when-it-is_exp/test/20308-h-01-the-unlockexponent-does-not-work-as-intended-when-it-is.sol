// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Zerem — unlockExponent (Pashov, finding 20308)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: factor = deltaTimeNormalized ** unlockExponent. Exponent 0
    yields factor 1, so totalUnlockedAmount = totalAmount / 1e8 forever.
    The README says exponent 0 unlocks the full balance after unlockDelaySec.
    Vulnerable math preserved below (@> VULN). */

contract Token {
    string public symbol = "LOCK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract ZeremVault {
    uint256 public constant precision = 1e8;
    uint256 public unlockExponent;
    uint256 public unlockDelaySec;
    uint256 public unlockPeriodSec;
    uint256 public totalAmount;
    uint256 public unlockStart;
    uint256 public claimed;
    Token public token;

    constructor(Token t, uint256 exponent) {
        token = t;
        unlockExponent = exponent;
        unlockDelaySec = 0;
        unlockPeriodSec = 100_000;
    }

    function lock(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        totalAmount = amount;
        unlockStart = block.timestamp;
        claimed = 0;
    }

    function _getWithdrawableAmount() public view returns (uint256 totalUnlockedAmount) {
        if (block.timestamp < unlockStart + unlockDelaySec) return 0;
        uint256 deltaTime = block.timestamp - unlockStart;
        uint256 deltaTimeDelayed = deltaTime > unlockDelaySec ? deltaTime - unlockDelaySec : 0;
        uint256 deltaTimeNormalized = (deltaTimeDelayed * precision) / unlockPeriodSec;
        uint256 factor = deltaTimeNormalized ** unlockExponent;
        if (factor > precision) { // @> VULN: exponent 0 leaves factor at 1, so this cap never restores a full unlock
            factor = precision;
        }
        totalUnlockedAmount = (totalAmount * factor) / precision;
    }

    function claim() external returns (uint256 paid) {
        uint256 unlocked = _getWithdrawableAmount();
        paid = unlocked - claimed;
        claimed = unlocked;
        token.transfer(msg.sender, paid);
    }
}

contract Exploit {
    Token public token; // CREATE nonce 1
    ZeremVault public vault; // CREATE nonce 2
    uint256 public constant TOTAL = 1e18;

    constructor() {
        token = new Token();
        vault = new ZeremVault(token, 0);
    }

    function run() external {
        token.mint(address(this), TOTAL);
        token.approve(address(vault), TOTAL);
        vault.lock(TOTAL);
        uint256 paid = vault.claim();
        uint256 stuck = token.balanceOf(address(vault));
        require(paid == TOTAL / vault.precision(), "only total/1e8");
        require(stuck == TOTAL - paid, "rest stuck");
        require(vault.claimed() == paid, "claimed");
        require(stuck > paid * 1000, "dust is not the harm");
    }
}
