// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Nexus — DSRStrategy.deposit calls sDAI.deposit without approving DAI
    (Pashov, 2024-11-29). sDAI pulls DAI with transferFrom. The 1_000 DAI a
    user already sent into the strategy never becomes sDAI, and the quoted
    strategy has no idle-DAI withdraw, so the 1_000 DAI stays there. The
    fixed strategy approves and receives 1_000 sDAI. */

contract Dai {
    string public symbol = "DAI";
    uint8 public constant decimals = 18;
    address public minter;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
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

contract SDai {
    string public symbol = "sDAI";
    uint8 public constant decimals = 18;
    Dai public dai;
    mapping(address => uint256) public balanceOf;

    constructor(Dai _dai) {
        dai = _dai;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(dai.transferFrom(msg.sender, address(this), assets), "pull");
        shares = assets;
        balanceOf[receiver] += shares;
    }
}

contract DSRStrategy {
    Dai public dai;
    SDai public sdai;

    constructor(Dai _dai, SDai _sdai) {
        dai = _dai;
        sdai = _sdai;
    }

    function fund(uint256 amount) external {
        dai.transferFrom(msg.sender, address(this), amount);
    }

    function deposit(uint256 _value) public returns (uint256) {
        sdai.deposit(_value, address(this)); // @> VULN: no DAI.approve(sDAI) before deposit, so the pull reverts
        return 100;
    }
}

contract DSRStrategyFixed {
    Dai public dai;
    SDai public sdai;

    constructor(Dai _dai, SDai _sdai) {
        dai = _dai;
        sdai = _sdai;
    }

    function fund(uint256 amount) external {
        dai.transferFrom(msg.sender, address(this), amount);
    }

    function deposit(uint256 _value) public returns (uint256) {
        dai.approve(address(sdai), _value);
        sdai.deposit(_value, address(this));
        return 100;
    }
}

contract Exploit {
    Dai public dai; // nonce 1
    SDai public sdai; // nonce 2
    DSRStrategy public strategy; // nonce 3
    bool public depositReverted;

    constructor() {
        dai = new Dai();
        sdai = new SDai(dai);
        strategy = new DSRStrategy(dai, sdai);
    }

    function run() external {
        dai.mint(address(this), 1000 ether);
        dai.approve(address(strategy), 1000 ether);
        strategy.fund(1000 ether);
        require(dai.balanceOf(address(strategy)) == 1000 ether, "funded");
        try strategy.deposit(1000 ether) returns (uint256) {
            depositReverted = false;
        } catch {
            depositReverted = true;
        }
        require(depositReverted, "deposit must revert");
        require(dai.balanceOf(address(strategy)) == 1000 ether, "DAI stuck");
        require(sdai.balanceOf(address(strategy)) == 0, "no sDAI");
        require(dai.allowance(address(strategy), address(sdai)) == 0, "no approval");
    }
}
