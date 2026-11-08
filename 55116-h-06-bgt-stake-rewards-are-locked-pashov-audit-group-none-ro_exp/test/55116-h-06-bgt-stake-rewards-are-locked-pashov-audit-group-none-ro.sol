// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Roots Staker — BGT stake rewards (HONEY) are locked
    (Pashov Audit Group, H-06, finding 55116, review 2025-02-09).

    SYNTHETIC, cheatcode-free. Boosting stakes the Staker contract's BGT
    into BGTStaker. HONEY is booked to that contract. BGTStaker.getReward
    pays only msg.sender, and Roots Staker has no function that calls it,
    so the HONEY cannot be claimed. The control adds that call and pays N.

    No timestamp jump: blockDelta is stored and already greater than 8191. */

interface IBGTStaker {
    function stake(address user, uint256 amount) external;
    function getReward() external returns (uint256);
}

contract Honey {
    string public constant name = "HONEY";
    string public constant symbol = "HONEY";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract BGTStaker {
    Honey public immutable honey;
    mapping(address => uint256) public staked;
    mapping(address => uint256) public earned;

    constructor(Honey _honey) {
        honey = _honey;
    }

    function stake(address user, uint256 amount) external {
        staked[user] += amount;
    }

    function fundReward(address user, uint256 amount) external {
        honey.transferFrom(msg.sender, address(this), amount);
        earned[user] += amount;
    }

    function getReward() external returns (uint256) {
        // @> VULN: HONEY is paid only to msg.sender, and Roots Staker never calls this, so its rewards stay locked
        return _getReward(msg.sender, msg.sender);
    }

    function _getReward(address account, address recipient) internal returns (uint256 reward) {
        reward = earned[account];
        if (reward != 0) {
            earned[account] = 0;
            honey.transfer(recipient, reward);
        }
    }
}

contract BGT {
    address public staker;
    uint256 public amount;

    constructor(address _staker) {
        staker = _staker;
    }

    function setAmount(uint256 _amount) external {
        amount = _amount;
    }

    function activateBoost(address user, bytes calldata pubkey) external returns (bool) {
        pubkey;
        IBGTStaker(staker).stake(user, amount);
        return true;
    }
}

contract RootsStaker {
    BGT public rewardCache;
    uint256 public queued;
    uint256 public blockDelta;
    bytes public pubkey;

    constructor(BGT _bgt) {
        rewardCache = _bgt;
    }

    function queueBoost(uint256 bgtAmount, bytes memory _pubkey) external {
        queued = bgtAmount;
        blockDelta = 8192;
        pubkey = _pubkey;
        rewardCache.setAmount(bgtAmount);
    }

    function pokeBoost() external {
        _tryToBoost();
    }

    function _tryToBoost() internal {
        if (queued > 0 && blockDelta > 8191) {
            rewardCache.activateBoost(address(this), pubkey);
        }
    }
}

contract RootsStakerFixed {
    BGT public rewardCache;
    uint256 public queued;
    uint256 public blockDelta;
    bytes public pubkey;

    constructor(BGT _bgt) {
        rewardCache = _bgt;
    }

    function queueBoost(uint256 bgtAmount, bytes memory _pubkey) external {
        queued = bgtAmount;
        blockDelta = 8192;
        pubkey = _pubkey;
        rewardCache.setAmount(bgtAmount);
    }

    function pokeBoost() external {
        _tryToBoost();
    }

    function _tryToBoost() internal {
        if (queued > 0 && blockDelta > 8191) {
            rewardCache.activateBoost(address(this), pubkey);
        }
    }

    function claimBoostRewards(address to) external returns (uint256 paid) {
        BGTStaker vault = BGTStaker(rewardCache.staker());
        paid = vault.getReward();
        vault.honey().transfer(to, paid);
    }
}

contract User {
    uint256 public paid;

    function claim(BGTStaker vault) external {
        paid = vault.getReward();
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;
    uint256 public constant BGT_AMOUNT = 1 ether;

    Honey public honey;
    BGTStaker public vault;
    BGT public bgt;
    RootsStaker public staker;
    User public user;

    uint256 public paidToUser;
    uint256 public stuck;

    constructor() {
        honey = new Honey();
        vault = new BGTStaker(honey);
        bgt = new BGT(address(vault));
        staker = new RootsStaker(bgt);
        user = new User();
    }

    function run() external {
        this.queue();
        this.boost();
        this.fundRewards();
        this.userClaims();
        this.readStuck();
        this.assertHarm();
    }

    function queue() external {
        staker.queueBoost(BGT_AMOUNT, hex"01");
    }

    function boost() external {
        staker.pokeBoost();
    }

    function fundRewards() external {
        honey.mint(address(this), N);
        honey.approve(address(vault), N);
        vault.fundReward(address(staker), N);
    }

    function userClaims() external {
        user.claim(vault);
        paidToUser = user.paid();
    }

    function readStuck() external {
        stuck = honey.balanceOf(address(vault));
    }

    function assertHarm() external {
        require(vault.staked(address(staker)) == BGT_AMOUNT, "not staked");
        require(paidToUser == 0, "user was paid");
        require(stuck == N, "rewards not stuck");
        require(honey.balanceOf(address(user)) == 0, "user received honey");
        require(vault.earned(address(staker)) == N, "earned not on staker");
    }
}
