// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DaosLive finalize — the swap recipient is address(this) and there
    is no withdraw (Shieldify, H-01, finding 57868).
    SYNTHETIC, cheatcode-free. One transaction, no warp.

    exactInputSingle mints the 1000 sniped tokens to recipient.
    The audited call sets recipient to address(this). DaosLive has
    no sweep. The 1000 tokens stay on the contract. A call to a
    withdraw selector does not exist, so it cannot move them.
    The fixed call sets recipient to the DAO treasury, which then
    holds the 1000 and the contract holds 0. */

contract SnipeToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

struct ExactInputSingleParams {
    address tokenIn;
    address tokenOut;
    uint24 fee;
    address recipient;
    uint256 amountIn;
    uint256 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
    uint256 deadline;
}

contract SwapRouter {
    SnipeToken public token;

    constructor(SnipeToken token_) {
        token = token_;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        require(block.timestamp <= params.deadline, "Transaction too old");
        amountOut = params.amountIn;
        token.mint(params.recipient, amountOut);
    }
}

contract Treasury {
    function balance(SnipeToken token) external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}

contract DaosLive {
    SwapRouter public router;
    SnipeToken public token;
    Treasury public treasury;
    uint256 public snipeAmount;
    bool public toTreasury;

    constructor(SwapRouter router_, SnipeToken token_, Treasury treasury_, uint256 snipeAmount_, bool toTreasury_) {
        router = router_;
        token = token_;
        treasury = treasury_;
        snipeAmount = snipeAmount_;
        toTreasury = toTreasury_;
    }

    function finalize() external returns (uint256 amountOut) {
        address recipient = toTreasury ? address(treasury) : address(this);
        // @> VULN: recipient is address(this). Nothing in this contract can withdraw the tokens.
        amountOut = router.exactInputSingle(
            ExactInputSingleParams({
                tokenIn: address(0),
                tokenOut: address(token),
                fee: 3000,
                recipient: recipient,
                amountIn: snipeAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                deadline: block.timestamp
            })
        );
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    SnipeToken public token; // nonce 1
    SwapRouter public router; // nonce 2
    Treasury public treasury; // nonce 3
    DaosLive public dao; // nonce 4

    uint256 public stuck;
    bool public sweepMissing;

    constructor() {
        token = new SnipeToken();
        router = new SwapRouter(token);
        treasury = new Treasury();
        dao = new DaosLive(router, token, treasury, N, false);
    }

    function run() external {
        uint256 out = dao.finalize();
        require(out == N, "swap returned N");
        stuck = token.balanceOf(address(dao));
        require(stuck == N, "N tokens sit on DaosLive");
        (bool ok,) = address(dao).call(abi.encodeWithSignature("sweep(address)", address(token)));
        sweepMissing = !ok;
        require(sweepMissing, "no withdraw");
        require(token.balanceOf(address(dao)) == N, "still stuck");
        require(token.balanceOf(address(treasury)) == 0, "treasury got nothing");
    }
}
