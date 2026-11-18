// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Nexus — H-03 (Pashov, 2024-11-29)
    DepositETH.executeStrategies delegatecalls LidoStrategy. The strategy can
    stake ETH into stETH and has no withdraw. The redemption delegatecall
    reverts with CallFailed, and the 10 stETH stays in the vault. */

contract Token {
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

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
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

contract LidoStrategy {
    function stake(address ethToken, address steth) external {
        uint256 bal = Token(ethToken).balanceOf(address(this)); // [S3]
        Token(ethToken).burn(address(this), bal);
        Token(steth).mint(address(this), bal);
    }
}

contract LidoStrategyFixed {
    function stake(address ethToken, address steth) external {
        uint256 bal = Token(ethToken).balanceOf(address(this));
        Token(ethToken).burn(address(this), bal);
        Token(steth).mint(address(this), bal);
    }

    function withdraw(address ethToken, address steth, uint256 amount) external {
        Token(steth).burn(address(this), amount);
        Token(ethToken).mint(address(this), amount);
    }
}

contract DepositETH {
    error IncorrectStrategyExecutor(address caller);
    error IncorrectStrategy(address strategy);
    error CallFailed();

    struct StrategyExecution {
        address strategy;
        bytes executionData;
    }

    address public strategyExecutor;
    address public lido;
    Token public ethToken;
    Token public steth;
    mapping(address => bool) public strategyExists;
    mapping(address => uint256) public shares;

    constructor(address executor, Token _eth, Token _st, address strategy) {
        strategyExecutor = executor;
        ethToken = _eth;
        steth = _st;
        lido = strategy;
        strategyExists[strategy] = true;
    }

    function deposit(uint256 amount) external {
        require(ethToken.transferFrom(msg.sender, address(this), amount), "pull"); // [S1]
        shares[msg.sender] += amount;
    }

    function executeStrategies(StrategyExecution[] memory _executionData) external {
        if (msg.sender != strategyExecutor) revert IncorrectStrategyExecutor(msg.sender);
        unchecked {
            for (uint256 i = 0; i < _executionData.length; i++) {
                if (!strategyExists[_executionData[i].strategy]) revert IncorrectStrategy(_executionData[i].strategy);
                (bool success, bytes memory returndata) =
                    _executionData[i].strategy.delegatecall(_executionData[i].executionData); // @> VULN: [S2] LidoStrategy has stake and no withdraw, so redeem cannot pull stETH back.
                // FIX: implement LidoStrategy.withdraw and delegatecall it from redeem.
                if (!success) {
                    if (returndata.length == 0) revert CallFailed(); // [S4]
                    assembly {
                        revert(add(32, returndata), mload(returndata))
                    }
                }
            }
        }
    }
}

contract Exploit {
    Token public ethToken; // nonce 1
    Token public steth; // nonce 2
    LidoStrategy public lido; // nonce 3
    DepositETH public vault; // nonce 4
    uint256 public constant AMOUNT = 10 ether;
    bool public redeemReverted;

    constructor() {
        ethToken = new Token("ETH");
        steth = new Token("stETH");
        lido = new LidoStrategy();
        vault = new DepositETH(address(this), ethToken, steth, address(lido));
        ethToken.mint(address(this), AMOUNT);
        ethToken.approve(address(vault), AMOUNT);
    }

    function _stake() internal {
        DepositETH.StrategyExecution[] memory data = new DepositETH.StrategyExecution[](1);
        data[0] = DepositETH.StrategyExecution({
            strategy: address(lido),
            executionData: abi.encodeWithSignature("stake(address,address)", address(ethToken), address(steth))
        });
        vault.executeStrategies(data); // [S5]
    }

    function run() external {
        vault.deposit(AMOUNT);
        _stake();
        DepositETH.StrategyExecution[] memory data = new DepositETH.StrategyExecution[](1);
        data[0] = DepositETH.StrategyExecution({
            strategy: address(lido),
            executionData: abi.encodeWithSignature(
                "withdraw(address,address,uint256)", address(ethToken), address(steth), AMOUNT
            )
        });
        (bool ok,) = address(vault).call(abi.encodeCall(DepositETH.executeStrategies, (data))); // [S6]
        redeemReverted = !ok;
        require(redeemReverted, "withdraw delegatecall should revert");
        require(steth.balanceOf(address(vault)) == AMOUNT, "10 stETH stuck");
        require(ethToken.balanceOf(address(this)) == 0, "depositor got no ETH back");
    }
}
