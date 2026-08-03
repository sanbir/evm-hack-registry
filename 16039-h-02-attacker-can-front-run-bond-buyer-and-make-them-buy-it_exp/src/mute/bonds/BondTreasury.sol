pragma solidity ^0.8.0;
import '../libraries/SafeMath.sol';
import '../libraries/Ownable.sol';
import '../libraries/TransferHelper.sol';
import '../interfaces/IERC20.sol';


contract BondTreasury is Ownable {
    /* ======== DEPENDENCIES ======== */
    using SafeMath for uint;

    /* ======== STATE VARIABLS ======== */

    address public immutable payoutToken;

    mapping(address => bool) public bondContract;

    /* ======== EVENTS ======== */

    event BondContractWhitelisted(address bondContract);
    event BondContractDewhitelisted(address bondContract);
    event Withdraw(address token, address destination, uint amount);

    /* ======== CONSTRUCTOR ======== */

    constructor(address _payoutToken) {
        require( _payoutToken != address(0) );
        payoutToken = _payoutToken;
    }

    /* ======== BOND CONTRACT FUNCTION ======== */

    /**
     *  @notice bond contract recieves payout tokens
     *  @param _amountPayoutToken uint
     */
    function sendPayoutTokens(uint _amountPayoutToken) external {
        require(bondContract[msg.sender], "msg.sender is not a bond contract");
        TransferHelper.safeTransfer(payoutToken, msg.sender, _amountPayoutToken);
    }

    /* ======== VIEW FUNCTION ======== */

    /**
    *   @notice returns payout token valuation of priciple
    *   @param _principalTokenAddress address
    *   @param _amount uint
    *   @return value_ uint
     */
    function valueOfToken( address _principalTokenAddress, uint _amount ) public view returns ( uint value_ ) {
        // convert amount to match payout token decimals
        value_ = _amount.mul( 10 ** IERC20( payoutToken ).decimals() ).div( 10 ** IERC20( _principalTokenAddress ).decimals() );
    }


    /* ======== OWNER FUNCTIONS ======== */

    /**
     *  @notice owner can withdraw ERC20 token to desired address
     *  @param _token uint
     *  @param _destination address
     *  @param _amount uint
     */
    function withdraw(address _token, address _destination, uint _amount) external onlyOwner {
        TransferHelper.safeTransfer(_token, _destination, _amount);
        emit Withdraw(_token, _destination, _amount);
    }

    /**
        @notice whitelist bond contract
        @param _bondContract address
     */
    function whitelistBondContract(address _bondContract) external onlyOwner {
        bondContract[_bondContract] = true;
        emit BondContractWhitelisted(_bondContract);
    }

    /**
        @notice dewhitelist bond contract
        @param _bondContract address
     */
    function dewhitelistBondContract(address _bondContract) external onlyOwner {
        bondContract[_bondContract] = false;
        emit BondContractDewhitelisted(_bondContract);
    }

}
