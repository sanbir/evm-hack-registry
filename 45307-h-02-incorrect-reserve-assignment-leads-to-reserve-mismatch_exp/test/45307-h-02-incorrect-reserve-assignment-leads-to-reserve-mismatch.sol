// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  g8keep — swapped reserves after a failed migration (Pashov H-02, December 2024)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _handleMigrationFailed writes tokenAmount into reserve0 (the ETH
    reserve) and ethAmount into reserve1 (the token reserve). A later buy uses
    those slots, so 1 ETH buys dust instead of about 83 tokens. The ETH stays
    in the curve. */

contract Erc20 {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory symbol_) {
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BondingCurve {
    event WroteReserve0(uint112 value);
    event WroteReserve1(uint112 value);
    uint112 public reserve0;
    uint112 public reserve1;
    uint256 public curveStatus;
    Erc20 public ethToken;
    Erc20 public bond;

    constructor(Erc20 ethToken_, Erc20 bond_) {
        ethToken = ethToken_;
        bond = bond_;
    }

    function _handleMigrationFailed(uint256 ethAmount, uint112 tokenAmount) internal {
        curveStatus = curveStatus | 1;
        reserve0 = tokenAmount;
        // @> VULN: token amount written into the ETH reserve
        emit WroteReserve0(reserve0);
        // FIX: reserve0 = uint112(ethAmount); reserve1 = tokenAmount;
        reserve1 = uint112(ethAmount);
        emit WroteReserve1(reserve1);
    }

    function handleMigrationFailed(uint256 ethAmount, uint112 tokenAmount) external {
        _handleMigrationFailed(ethAmount, tokenAmount);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return amountInWithFee * reserveOut / (reserveIn * 1000 + amountInWithFee);
    }

    function buy(uint256 ethIn) external returns (uint256 tokenOut) {
        tokenOut = getAmountOut(ethIn, uint256(reserve0), uint256(reserve1));
        ethToken.transferFrom(msg.sender, address(this), ethIn);
        bond.transfer(msg.sender, tokenOut);
    }
}

contract Exploit {
    Erc20 public ethToken; // CREATE nonce 1
    Erc20 public bond; // CREATE nonce 2
    BondingCurve public curve; // CREATE nonce 3
    uint256 public tokenOut;
    uint256 public fairOut;

    constructor() {
        ethToken = new Erc20("WETH");
        bond = new Erc20("G8");
        curve = new BondingCurve(ethToken, bond);
        ethToken.mint(address(curve), 5 ether);
        bond.mint(address(curve), 500 ether);
        ethToken.mint(address(this), 1 ether);
    }

    function run() external {
        curve.handleMigrationFailed(5 ether, uint112(500 ether));
        ethToken.approve(address(curve), 1 ether);
        tokenOut = curve.buy(1 ether);
        fairOut = curve.getAmountOut(1 ether, 5 ether, 500 ether);
        require(fairOut > 80 ether, "fair buy");
        require(tokenOut * 1000 < fairOut, "buyer was not robbed");
        require(ethToken.balanceOf(address(curve)) == 6 ether, "eth not kept");
        require(bond.balanceOf(address(this)) == tokenOut, "dust received");
    }
}
