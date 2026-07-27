// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '../libraries/SafeMath.sol';
import '../libraries/TransferHelper.sol';

contract MuteBond {
    using SafeMath for uint;

    /* ======== EVENTS ======== */

    event BondCreated(uint deposit, uint payout, address depositor, uint time);
    event BondPriceChanged(uint internalPrice, uint debtRatio);
    event MaxPriceChanged(uint _price);
    event MaxPayoutChanged(uint _price);
    event EpochDurationChanged(uint _payout);
    event BondLockTimeChanged(uint _duration);
    event StartPriceChanged(uint _lock);

     /* ======== STATE VARIABLES ======== */

    address immutable private muteToken; // token paid for principal
    address immutable private dMuteToken;
    address immutable private lpToken; // inflow token
    ITreasury immutable private customTreasury; // pays for and receives principal
    uint public bond_time_lock = 7 days; // length of lockup in dMute for bonds

    uint public totalPayoutGiven; // total amount of mute paid
    uint public totalDebt; // total amount of LP collected

    uint public epochDuration = 7 days; // the length of an epoch from getting from startPrice  to maxPrice
    uint public maxPrice; // max limit price for the LP token (LP:mute ratio)
    uint public startPrice; // start price of the LP token (LP:mute ratio)
    uint public maxPayout; // max amount of mute tokens to sell in each epoch
    uint public epochStart; // timestamp of the current epoch start
    uint public epoch; // amount of cycles for bonds so far

    BondTerms[] public terms; // identifies the terms for a bond in a given epoch
    Bonds[] public bonds; // stores individual deposits

    // Info for bond epochs
    struct BondTerms {
        uint bondTotal; // amount of tokens bonded so far
        uint payoutTotal;
        uint lastTimestamp;
    }

    // Info for a single depositors bond info
    struct Bonds {
        uint value; //
        uint payout; //
        address depositor; //
        uint timestamp;
    }



    /* ======== CONSTRUCTOR ======== */

    /**
     *  @notice initializes the bond
     *  @param _customTreasury address
     *  @param _lpToken address
     *  @param _dmuteToken address
     *  @param _maxPrice uint
     *  @param _startPrice uint
     *  @param _maxPayout uint
     */
    constructor(address _customTreasury, address _lpToken, address _dmuteToken,
                uint _maxPrice, uint _startPrice, uint _maxPayout) {
        require( _customTreasury != address(0) && _lpToken != address(0));
        customTreasury = ITreasury( _customTreasury );
        muteToken = ITreasury(_customTreasury).payoutToken();
        dMuteToken = _dmuteToken;

        lpToken = _lpToken;

        // approve lock token to spend payout
        TransferHelper.safeApprove(muteToken, dMuteToken, type(uint256).max);


        require(_maxPrice >= _startPrice, "starting price < min");

        epochStart = block.timestamp;
        maxPrice = _maxPrice;
        startPrice = _startPrice;
        maxPayout = _maxPayout;

        terms.push(BondTerms(0,0,0));
    }


    /* ======== OWNER FUNCTIONS ======== */

    /**
     *  @notice sets the max limit price for the LP token
     *  @param _price uint
     */
    function setMaxPrice(uint _price) external {
        require(msg.sender == customTreasury.owner());
        maxPrice = _price;
        emit MaxPriceChanged(_price);
    }

    /**
     *  @notice sets the start price for the LP token
     *  @param _price uint
     */
    function setStartPrice(uint _price) external {
        require(msg.sender == customTreasury.owner());
        startPrice = _price;
        emit StartPriceChanged(_price);
    }

    /**
     *  @notice sets the max amount of mute tokens to sell in each epoch
     *  @param _payout uint
     */
    function setMaxPayout(uint _payout) external {
        require(msg.sender == customTreasury.owner());
        maxPayout = _payout;
        emit MaxPayoutChanged(_payout);
    }

    /**
     *  @notice sets the length of bond epoch
     *  @param _duration uint
     */
    function setEpochDuration(uint _duration) external {
        require(msg.sender == customTreasury.owner());
        epochDuration = _duration;
        emit EpochDurationChanged(_duration);
    }

    /**
     *  @notice sets the length of lockup for mute purchases in dMute
     *  @param _lock uint
     */
    function setBondTimeLock(uint _lock) external {
        require(msg.sender == customTreasury.owner());
        bond_time_lock = _lock;
        emit BondLockTimeChanged(_lock);
    }

    /* ======== USER FUNCTIONS ======== */

    /**
     *  @notice purchase a bond with LP, bump bond price back by 5% after purchase based on current delta
     *  @param value uint
     *  @param _depositor address
     *  @param max_buy bool
     */
    function deposit(uint value, address _depositor, bool max_buy) external returns (uint) {
        // amount of mute tokens
        uint payout = payoutFor( value );
        if(max_buy == true){
          value = maxPurchaseAmount();
          payout = maxDeposit();
        } else {
          // safety checks for custom purchase
          require( payout >= ((10**18) / 100), "Bond too small" ); // must be > 0.01 payout token ( underflow protection )
          require( payout <= maxPayout, "Bond too large"); // size protection because there is no slippage
          require( payout <= maxDeposit(), "Deposit too large"); // size protection because there is no slippage
        }


        // total debt is increased
        totalDebt = totalDebt.add( value );
        totalPayoutGiven = totalPayoutGiven.add(payout); // total payout increased

        customTreasury.sendPayoutTokens(payout);
        TransferHelper.safeTransferFrom(lpToken, msg.sender, address(customTreasury), value ); // transfer principal bonded to custom treasury

        // indexed events are emitted
        emit BondCreated(value, payout, _depositor, block.timestamp);

        bonds.push(Bonds(value, payout, _depositor, block.timestamp));
        // redeem bond for user, mint dMute tokens for duration of vest period
        IDMute(dMuteToken).LockTo(payout, bond_time_lock, _depositor);

        terms[epoch].payoutTotal = terms[epoch].payoutTotal + payout;
        terms[epoch].bondTotal = terms[epoch].bondTotal + value;
        terms[epoch].lastTimestamp = block.timestamp;

        // adjust price by a ~5% premium of delta
        uint timeElapsed = block.timestamp - epochStart;
        epochStart = epochStart.add(timeElapsed.mul(5).div(100));
        // safety check
        if(epochStart >= block.timestamp)
          epochStart = block.timestamp;

        // exhausted this bond, issue new one
        if(terms[epoch].payoutTotal == maxPayout){
            terms.push(BondTerms(0,0,0));
            epochStart = block.timestamp;
            epoch++;
        }

        return payout;
    }

    /* ======== HELPER FUNCTIONS ======== */


    /**
     *  @notice returns bond info for the current epoch and global values
     */
    function bondInfo() external view returns (uint totDebt, uint totPayout, uint price, uint maxDep, uint maxPurchase, uint maxPay) {
        totDebt = totalDebt;
        totPayout = totalPayoutGiven;
        price = bondPrice();
        maxDep = maxDeposit();
        maxPurchase = maxPurchaseAmount();
        maxPay = maxPayout;
    }

    /**
     *  @notice returns current epoch
     */
    function currentEpoch() public view returns (uint) {
        return epoch;
    }

    /**
     *  @notice returns current bond price
     */
    function bondPrice() public view returns (uint) {
        uint timeElapsed = block.timestamp - epochStart;
        uint priceDelta = maxPrice - startPrice;

        if(timeElapsed > epochDuration)
          timeElapsed = epochDuration;

        return timeElapsed.mul(priceDelta).div(epochDuration).add(startPrice);
    }

    /**
     *  @notice returns bond price for amount
     *  @param _am uint
     */
    function payoutFor(uint _am) public view returns (uint) {
        return bondPrice().mul(_am).div(10**18);
    }

    /**
     *  @notice returns max amount of lp tokens receivable in current bond epoch
     */
    function maxPurchaseAmount() public view returns (uint) {
        return maxDeposit().mul(10**18).div(bondPrice());
    }

    /**
     *  @notice returns remaining mute tokens in current bond epoch
     */
    function maxDeposit() public view returns (uint) {
        return maxPayout.sub(terms[epoch].payoutTotal);
    }

}

interface ITreasury {
    function sendPayoutTokens(uint _amountPayoutToken) external;
    function valueOfToken( address _principalTokenAddress, uint _amount ) external view returns ( uint value_ );
    function payoutToken() external view returns (address);
    function owner() external view returns (address);
}

interface IDMute {
  function LockTo(uint256 _amount, uint256 _lock_time, address to) external;
}
