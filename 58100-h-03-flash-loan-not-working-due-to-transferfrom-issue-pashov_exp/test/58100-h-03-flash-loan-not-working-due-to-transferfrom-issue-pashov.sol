// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Astrolab As4626 — flashLoanSimple uses safeTransferFrom on its own USDC
    (Pashov Audit Group, H-03, January 2024).
    SYNTHETIC, cheatcode-free reduction. The blamed pull is verbatim.
    Root cause: safeTransferFrom(address(this), receiver, amount) asks USDC
    for allowance[vault][vault]. That allowance is 0, so a legitimate borrow
    reverts and the cash cannot be used. The control uses safeTransfer and
    collects a real repayment of amount + fee. */

interface IFlashLoanReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 fee,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

library AsMaths {
    uint256 internal constant BP_BASIS = 10_000;

    function bp(uint256 amount, uint256 basisPoints) internal pure returns (uint256) {
        return (amount * basisPoints) / BP_BASIS;
    }
}

contract Asset {
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) internal allowed;

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowed[owner][spender];
    }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowedAmt = allowed[from][msg.sender];
        require(value <= allowedAmt, "ERC20: transfer amount exceeds allowance");
        _balances[from] -= value;
        _balances[to] += value;
        if (allowedAmt != type(uint256).max) {
            allowed[from][msg.sender] = allowedAmt - value;
        }
        return true;
    }
}

library SafeERC20 {
    function safeTransferFrom(Asset token, address from, address to, uint256 value) internal {
        // @> VULN: inlined body of asset.safeTransferFrom(address(this), receiver, amount). allowance[vault][vault] is 0.
        bool ok = token.transferFrom(from, to, value);
        require(ok, "SafeERC20: transferFrom failed");
    }

    function safeTransfer(Asset token, address to, uint256 value) internal {
        bool ok = token.transfer(to, value);
        require(ok, "SafeERC20: transfer failed");
    }
}

contract FlashLender {
    using AsMaths for uint256;
    using SafeERC20 for Asset;

    struct Fees {
        uint256 flash;
    }

    Asset public asset;
    Fees public fees;
    uint256 public maxLoan;
    uint256 public totalLent;
    mapping(address => bool) public exemptionList;

    error AmountTooHigh(uint256 amount);
    error FlashLoanDefault(address borrower, uint256 amount);

    event FlashLoan(address indexed borrower, uint256 amount, uint256 fee);

    uint256 private locked = 1;

    modifier nonReentrant() {
        require(locked == 1, "reentrancy");
        locked = 2;
        _;
        locked = 1;
    }

    constructor(Asset _asset) {
        asset = _asset;
        maxLoan = type(uint256).max;
        fees.flash = 100;
    }

    function availableBorrowable() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function flashLoanSimple(IFlashLoanReceiver receiver, uint256 amount, bytes calldata params) external nonReentrant {
        uint256 available = availableBorrowable();
        if (amount > available || amount > maxLoan) revert AmountTooHigh(amount);

        uint256 fee = exemptionList[msg.sender] ? 0 : amount.bp(fees.flash);
        uint256 toRepay = amount + fee;

        uint256 balanceBefore = asset.balanceOf(address(this));
        totalLent += amount;

        // viaIR inlines the line below into SafeERC20.safeTransferFrom; the executing transferFrom is marked @> VULN
        asset.safeTransferFrom(address(this), address(receiver), amount);
        // FIX: asset.safeTransfer(address(receiver), amount);
        receiver.executeOperation(address(asset), amount, fee, msg.sender, params);

        if ((asset.balanceOf(address(this)) - balanceBefore) < toRepay) revert FlashLoanDefault(msg.sender, amount);

        emit FlashLoan(msg.sender, amount, fee);
    }
}

contract FlashLenderFixed {
    using AsMaths for uint256;
    using SafeERC20 for Asset;

    struct Fees {
        uint256 flash;
    }

    Asset public asset;
    Fees public fees;
    uint256 public maxLoan;
    uint256 public totalLent;
    mapping(address => bool) public exemptionList;

    error AmountTooHigh(uint256 amount);
    error FlashLoanDefault(address borrower, uint256 amount);

    event FlashLoan(address indexed borrower, uint256 amount, uint256 fee);

    uint256 private locked = 1;

    modifier nonReentrant() {
        require(locked == 1, "reentrancy");
        locked = 2;
        _;
        locked = 1;
    }

    constructor(Asset _asset) {
        asset = _asset;
        maxLoan = type(uint256).max;
        fees.flash = 100;
    }

    function availableBorrowable() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function flashLoanSimple(IFlashLoanReceiver receiver, uint256 amount, bytes calldata params) external nonReentrant {
        uint256 available = availableBorrowable();
        if (amount > available || amount > maxLoan) revert AmountTooHigh(amount);

        uint256 fee = exemptionList[msg.sender] ? 0 : amount.bp(fees.flash);
        uint256 toRepay = amount + fee;

        uint256 balanceBefore = asset.balanceOf(address(this));
        totalLent += amount;

        asset.safeTransfer(address(receiver), amount);
        receiver.executeOperation(address(asset), amount, fee, msg.sender, params);

        if (asset.balanceOf(address(this)) + amount < balanceBefore + toRepay) {
            revert FlashLoanDefault(msg.sender, amount);
        }

        emit FlashLoan(msg.sender, amount, fee);
    }
}

contract HonestReceiver is IFlashLoanReceiver {
    Asset public asset;
    uint256 public received;
    uint256 public repaid;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function executeOperation(address, uint256 amount, uint256 fee, address, bytes calldata) external returns (bool) {
        received = amount;
        uint256 pay = amount + fee;
        asset.transfer(msg.sender, pay);
        repaid = pay;
        return true;
    }
}

contract Exploit {
    uint256 public constant LOAN = 250_000e6;
    uint256 public constant FEE = 2_500e6;

    Asset public asset; // nonce 1
    FlashLender public lender; // nonce 2
    HonestReceiver public receiver; // nonce 3
    FlashLenderFixed public fixedLender; // nonce 4
    HonestReceiver public controlReceiver; // nonce 5

    bool public vulnReverted;
    uint256 public selfAllowance;
    uint256 public vulnReceived;
    uint256 public vaultBalanceAfter;
    uint256 public controlReceived;
    uint256 public controlRepaid;
    uint256 public controlVaultAfter;

    constructor() {
        asset = new Asset();
        lender = new FlashLender(asset);
        receiver = new HonestReceiver(asset);
        fixedLender = new FlashLenderFixed(asset);
        controlReceiver = new HonestReceiver(asset);
    }

    function run() external {
        asset.mint(address(lender), LOAN);
        selfAllowance = asset.allowance(address(lender), address(lender));

        try lender.flashLoanSimple(receiver, LOAN, "") {
            vulnReverted = false;
        } catch {
            vulnReverted = true;
        }

        vulnReceived = receiver.received();
        vaultBalanceAfter = asset.balanceOf(address(lender));

        asset.mint(address(fixedLender), LOAN);
        asset.mint(address(controlReceiver), FEE);
        fixedLender.flashLoanSimple(controlReceiver, LOAN, "");

        controlReceived = controlReceiver.received();
        controlRepaid = controlReceiver.repaid();
        controlVaultAfter = asset.balanceOf(address(fixedLender));

        require(vulnReverted, "borrow did not revert");
        require(selfAllowance == 0, "self allowance");
        require(vulnReceived == 0, "receiver was paid");
        require(vaultBalanceAfter == LOAN, "loan left the vault");
        require(lender.totalLent() == 0, "reverted lend stuck");
        require(controlReceived == LOAN, "control did not transfer");
        require(controlRepaid == LOAN + FEE, "control did not repay");
        require(controlVaultAfter == LOAN + FEE, "fee not kept");
    }
}
