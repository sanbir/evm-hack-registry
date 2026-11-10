// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Goat Tech — earningReinvest reduces maxEarning, then withdraw overwrites it
    (Cantina / cccz, AuditVault 40666).
    SYNTHETIC, cheatcode-free reduction. Report figures:
    maxEarning 1000, sharedA 1000, balance 1100, sPercent 10%,
    reinvest 1000 at maxDuration. The reduction to 0 is replaced by
    shareCommission's write of 1090. The fix reduces after withdraw,
    leaving the cap at 90. Credited earning 1090 is above that cap. */

contract CapToken {
    mapping(address => uint256) public balanceOf;
    address public immutable admin;

    constructor() {
        admin = msg.sender;
    }

    function set(address account, uint256 value) external {
        require(msg.sender == admin, "admin");
        balanceOf[account] = value;
    }
}

contract Earning {
    mapping(address => uint256) public maxEarningOf;
    mapping(address => uint256) public sharedA;
    mapping(address => uint256) public balanceOfEarning;
    CapToken public cap;
    address public admin;
    uint256 public sPercent = 10;

    modifier onlyAdmin() {
        require(msg.sender == admin, "admin");
        _;
    }

    constructor(address admin_) {
        admin = admin_;
        cap = new CapToken();
    }

    function seed(address account, uint256 balance, uint256 shared, uint256 maxEarning) external onlyAdmin {
        balanceOfEarning[account] = balance;
        sharedA[account] = shared;
        updateMaxEarning(account, maxEarning);
    }

    function shareCommission(address account_) public {
        uint256 pending = balanceOfEarning[account_] - sharedA[account_];
        uint256 commissioned = pending * (100 - sPercent) / 100;
        sharedA[account_] += commissioned;
    }

    function withdraw(address account_, uint256, address) external onlyAdmin {
        shareCommission(account_);
        if (sharedA[account_] > maxEarningOf[account_]) {
            updateMaxEarning(account_, sharedA[account_]);
        }
    }

    function updateMaxEarning(address account, uint256 maxEarning) public onlyAdmin {
        maxEarningOf[account] = maxEarning;
        cap.set(account, maxEarning);
    }
}

contract Goat {
    uint256 public maxDuration = 100;
    Earning public earning;

    constructor() {
        earning = new Earning(address(this));
    }

    function seed(address account) external {
        earning.seed(account, 1100, 1000, 1000);
    }

    function earningWithdraw(bool isEth_, uint256 amount_, address payable, uint256) public {
        address account = msg.sender;
        Earning book = isEth_ ? earning : earning;
        book.withdraw(account, amount_, address(this));
    }

    function earningReinvest(
        bool isEth_,
        address payable,
        uint256 duration_,
        uint256 amount_,
        uint256,
        uint256
    ) external {
        address account = msg.sender;
        if (isEth_) {
            uint256 realDuration = duration_;
            if (realDuration > maxDuration) {
                realDuration = maxDuration;
            }
            uint256 maxEarning = earning.maxEarningOf(account);
            maxEarning -= amount_ * realDuration / maxDuration;
            earning.updateMaxEarning(account, maxEarning);
        }
        // @> VULN: withdraw runs after the reduction, and shareCommission writes maxEarning back up.
        earningWithdraw(isEth_, amount_, payable(address(this)), 0);
        _stake();
    }

    /// Control: withdraw first, then the same reduction. Cap becomes 1090 - 1000 = 90.
    function earningReinvestFixed(
        bool isEth_,
        address payable,
        uint256 duration_,
        uint256 amount_,
        uint256,
        uint256
    ) external {
        address account = msg.sender;
        earningWithdraw(isEth_, amount_, payable(address(this)), 0);
        if (isEth_) {
            uint256 realDuration = duration_;
            if (realDuration > maxDuration) {
                realDuration = maxDuration;
            }
            uint256 maxEarning = earning.maxEarningOf(account);
            maxEarning -= amount_ * realDuration / maxDuration;
            earning.updateMaxEarning(account, maxEarning);
        }
        _stake();
    }

    function _stake() internal {}
}

contract Exploit {
    uint256 public constant AMOUNT = 1000;
    uint256 public constant DURATION = 100;

    Goat public goat;
    Earning public earning;
    CapToken public cap;
    uint256 public credited;
    uint256 public brokenCap;
    uint256 public fairCap;

    constructor() {
        goat = new Goat();
        earning = goat.earning();
        cap = earning.cap();
    }

    function run() external {
        goat.seed(address(this));
        goat.earningReinvest(true, payable(address(0xB0B)), DURATION, AMOUNT, 0, 0);
        credited = earning.sharedA(address(this));
        brokenCap = earning.maxEarningOf(address(this));
        fairCap = credited - AMOUNT * DURATION / goat.maxDuration();
        require(credited == 1090, "credited earning");
        require(brokenCap == 1090, "reduction did not stick");
        require(fairCap == 90, "reduced cap");
        require(brokenCap > fairCap, "user is not above the cap");
        require(cap.balanceOf(address(this)) == brokenCap, "cap token");
    }
}
