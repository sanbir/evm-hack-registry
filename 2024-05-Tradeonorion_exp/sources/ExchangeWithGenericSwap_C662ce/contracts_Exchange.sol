// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libs/LibUnitConverter.sol";
import "./libs/LibValidator.sol";
import "./libs/LibExchange.sol";
import "./libs/MarginalFunctionality.sol";
import "./libs/SafeTransferHelper.sol";
import "./OrionVault.sol";

/**
 * @title Exchange
 * @dev Exchange contract for the Orion Protocol
 * @author @wafflemakr
 */

/*

  Overflow safety:
  We do not use SafeMath and control overflows by
  not accepting large ints on input.

  Balances inside contract are stored as int192.

  Allowed input amounts are int112 or uint112: it is enough for all
  practically used tokens: for instance if decimal unit is 1e18, int112
  allow to encode up to 2.5e15 decimal units.
  That way adding/subtracting any amount from balances won't overflow, since
  minimum number of operations to reach max int is practically infinite: ~1e24.

  Allowed prices are uint64. Note, that price is represented as
  price per 1e8 tokens. That means that amount*price always fit uint256,
  while amount*price/1e8 not only fit int192, but also can be added, subtracted
  without overflow checks: number of malicious operations to overflow ~1e13.
*/

contract Exchange is OrionVault {
	using LibValidator for LibValidator.Order;
	using SafeERC20 for IERC20;

	struct UpdateOrderBalanceData {
		uint buyType;
		uint sellType;
		int buyIn;
		int sellIn;
	}

	//  Flags for updateOrders
	//  All flags are explicit
	uint8 constant kSell = 0;
	uint8 constant kBuy = 1; //  if 0 - then sell
	uint8 constant kCorrectMatcherFeeByOrderAmount = 2;

	// EVENTS
	event NewAssetTransaction(
		address indexed beneficiary,
		address indexed recipient,
		address indexed assetAddress,
		bool isDeposit,
		uint112 amount,
		uint64 timestamp
	);

	event Trade(
		address indexed buyer,
		address indexed seller,
		address baseAsset,
		address quoteAsset,
		uint64 filledPrice,
		uint192 filledAmount,
		uint192 amountQuote,
		bytes32 tradeId
	);

	error IncorrectPosition();
	error OnlyMatcher();
	error AlreadyFilled();
	error Fallback();
	error Overflow();
	error EthDepositRejected();
	error NotCollateralAsset();

	modifier onlyMatcher() {
		if (msg.sender != _allowedMatcher) revert OnlyMatcher();
		_;
	}

	// MAIN FUNCTIONS

	/**
	 * @dev Since Exchange will work behind the Proxy contract it can not have constructor
	 */
	function initialize() public payable initializer {
		OwnableUpgradeable.__Ownable_init();
	}

	/**
	 * @dev set marginal settings
	 * @param _collateralAssets - list of addresses of assets which may be used as collateral
	 * @param _stakeRisk - risk coefficient for staked orion as uint8 (0=0, 255=1)
	 * @param _liquidationPremium - premium for liquidator as uint8 (0=0, 255=1)
	 * @param _priceOverdue - time after that price became outdated
	 * @param _positionOverdue - time after that liabilities became overdue and may be liquidated
	 */

	function updateMarginalSettings(
		address[] calldata _collateralAssets,
		uint8 _stakeRisk,
		uint8 _liquidationPremium,
		uint64 _priceOverdue,
		uint64 _positionOverdue
	) public onlyOwner {
		collateralAssets = _collateralAssets;
		stakeRisk = _stakeRisk;
		liquidationPremium = _liquidationPremium;
		priceOverdue = _priceOverdue;
		positionOverdue = _positionOverdue;
	}

	/**
	 * @dev set risk coefficients for collateral assets
	 * @param assets - list of assets
	 * @param risks - list of risks as uint8 (0=0, 255=1)
	 */
	function updateAssetRisks(address[] calldata assets, uint8[] calldata risks) public onlyOwner {
		for (uint256 i; i < assets.length; i++) assetRisks[assets[i]] = risks[i];
	}

	function setAssetBalance(address assetAddress, address account, int192 amount) public onlyOwner {
		assetBalances[account][assetAddress] = amount;
		emit NewAssetTransaction(account, account, assetAddress, true, 0, uint64(block.timestamp));
	}

	/**
	 * @dev Deposit ERC20 tokens to the exchange contract. Beneficiary is msg.sender
	 * @dev User needs to approve token contract first
	 * @param amount asset amount to deposit in its base unit
	 */
	function depositAsset(address assetAddress, uint112 amount) external {
		depositAssetTo(assetAddress, amount, msg.sender);
	}

	/**
	 * @dev Deposit ERC20 tokens to the exchange contract. Beneficiary is account
	 * @dev User needs to approve token contract first
	 * @param amount asset amount to deposit in its base unit
	 */
	function depositAssetTo(address assetAddress, uint112 amount, address account) public nonReentrant {
		uint256 actualAmount = IERC20(assetAddress).balanceOf(address(this));
		IERC20(assetAddress).safeTransferFrom(msg.sender, address(this), uint256(amount));
		actualAmount = IERC20(assetAddress).balanceOf(address(this)) - actualAmount;
		if (actualAmount < amount) revert NotEnoughBalance();
		generalDeposit(assetAddress, uint112(actualAmount), account);
	}

	/**
	 * @notice Deposit ETH to the exchange contract. Beneficiary is msg.sender
	 * @dev deposit event will be emitted with the amount in decimal format (10^8)
	 * @dev balance will be stored in decimal format too
	 */
	function deposit() external payable {
		depositTo(msg.sender);
	}

	/**
	 * @notice Deposit ETH to the exchange contract. Beneficiary is account
	 * @dev deposit event will be emitted with the amount in decimal format (10^8)
	 * @dev balance will be stored in decimal format too
	 */
	function depositTo(address account) public payable nonReentrant {
		generalDeposit(address(0), uint112(msg.value), account);
	}

	/**
	 * @dev internal implementation of deposits
	 */
	function generalDeposit(address assetAddress, uint112 amount, address account) internal {
		bool wasLiability = assetBalances[account][assetAddress] < 0;
		uint112 safeAmountDecimal = LibUnitConverter.baseUnitToDecimal(assetAddress, amount);
		assetBalances[account][assetAddress] += int192(uint192(safeAmountDecimal));
		emit LibExchange.BalanceChange(account, assetAddress, int192(uint192(safeAmountDecimal)));

		if (amount > 0)
			emit NewAssetTransaction(msg.sender, account, assetAddress, true, safeAmountDecimal, uint64(block.timestamp));
		if (wasLiability)
			MarginalFunctionality.updateLiability(
				account,
				assetAddress,
				liabilities,
				uint112(safeAmountDecimal),
				assetBalances[account][assetAddress]
			);
	}

	/**
	 * @dev Withdrawal of funds from the contract to provided address
	 * @param assetAddress address of the asset to withdraw
	 * @param amount asset amount to withdraw in its base unit
	 * @param to recipient address
	 */
	function withdrawTo(address assetAddress, uint112 amount, address to) public nonReentrant {
		uint112 safeAmountDecimal = LibUnitConverter.baseUnitToDecimal(assetAddress, amount);

		assetBalances[msg.sender][assetAddress] -= int192(uint192(safeAmountDecimal));
		emit LibExchange.BalanceChange(msg.sender, assetAddress, -int192(uint192(safeAmountDecimal)));

		if (assetBalances[msg.sender][assetAddress] < 0) revert NotEnoughBalance();
		if (!checkPosition(msg.sender)) revert IncorrectPosition();

		if (assetAddress == address(0)) {
			(bool success, ) = to.call{value: amount}("");
			if (!success) revert NotEnoughBalance();
		} else {
			IERC20(assetAddress).safeTransfer(to, amount);
		}

		emit NewAssetTransaction(msg.sender, to, assetAddress, false, safeAmountDecimal, uint64(block.timestamp));
	}
	/**
	 * @dev Withdrawal of remaining funds from the contract to the address
	 * @param assetAddress address of the asset to withdraw
	 * @param amount asset amount to withdraw in its base unit
	 */
	function withdraw(address assetAddress, uint112 amount) external {
		withdrawTo(assetAddress, amount, msg.sender);
	}

	/**
	 * @dev Get asset balance for a specific address
	 * @param assetAddress address of the asset to query
	 * @param user user address to query
	 */
	function getBalance(address assetAddress, address user) public view returns (int192) {
		return assetBalances[user][assetAddress];
	}

	/**
	 * @dev Batch query of asset balances for a user
	 * @param assetsAddresses array of addresses of the assets to query
	 * @param user user address to query
	 */
	function getBalances(
		address[] memory assetsAddresses,
		address user
	) public view returns (int192[] memory balances) {
		balances = new int192[](assetsAddresses.length);
		for (uint256 i; i < assetsAddresses.length; i++) {
			balances[i] = assetBalances[user][assetsAddresses[i]];
		}
	}

	/**
	 * @dev Batch query of asset liabilities for a user
	 * @param user user address to query
	 */
	function getLiabilities(
		address user
	) public view returns (MarginalFunctionality.Liability[] memory liabilitiesArray) {
		return liabilities[user];
	}

	/**
	 * @dev Return list of assets which can be used for collateral
	 */
	function getCollateralAssets() public view returns (address[] memory) {
		return collateralAssets;
	}

	/**
	 * @dev get filled amounts for a specific order
	 */
	function getFilledAmounts(
		bytes32 orderHash,
		LibValidator.Order memory order
	) public view returns (int192 totalFilled, int192 totalFeesPaid) {
		totalFilled = int192(filledAmounts[orderHash]); //It is safe to convert here: filledAmounts is result of ui112 additions
		totalFeesPaid = int192(
			uint192((uint256(order.matcherFee) * uint256(uint192(totalFilled))) / uint256(order.amount))
		); //matcherFee is u64; safe multiplication here
	}

	function updateFilledAmount(bytes32 orderHash, uint192 amount, uint112 filledBase) internal {
		uint192 total_amount = filledAmounts[orderHash];
		total_amount += filledBase; //it is safe to add ui112 to each other to get i192
		if (total_amount > amount) revert AlreadyFilled();
		filledAmounts[orderHash] = total_amount;
	}

	/**
     * @notice Settle a trade with two orders, filled price and amount
     * @dev 2 orders are submitted, it is necessary to match them:
        check conditions in orders for compliance filledPrice, filledAmount
        change balances on the contract respectively with buyer, seller, matcher
     * @param buyOrder structure of buy side order
     * @param sellOrder structure of sell side order
     * @param filledPrice price at which the order was settled
     * @param filledAmount amount settled between orders
     */
	function fillOrders(
		LibValidator.Order memory buyOrder,
		LibValidator.Order memory sellOrder,
		uint64 filledPrice,
		uint112 filledAmount
	) public nonReentrant {
		// --- VARIABLES --- //
		// Amount of quote asset
		uint256 _amountQuote = (uint256(filledAmount) * filledPrice) / (10 ** 8);
		if (_amountQuote >= type(uint112).max) revert Overflow();
		uint112 amountQuote = uint112(_amountQuote);

		// --- VALIDATIONS --- //

		// Validate signatures using eth typed sign V1
		(bytes32 buyOrderHash, bytes32 sellOrderHash) = LibValidator.checkOrdersInfo(
			buyOrder,
			sellOrder,
			msg.sender,
			filledAmount,
			filledPrice,
			block.timestamp,
			_allowedMatcher
		);

		// --- UPDATES --- //

		//updateFilledAmount
		updateFilledAmount(buyOrderHash, buyOrder.amount, filledAmount);
		updateFilledAmount(sellOrderHash, sellOrder.amount, filledAmount);

		// Update User's balances
		UpdateOrderBalanceData memory data;
		(data.buyType, data.buyIn) = LibExchange.updateOrderBalanceDebit(
			buyOrder,
			filledAmount,
			amountQuote,
			kBuy | kCorrectMatcherFeeByOrderAmount,
			assetBalances,
			liabilities
		);
		(data.sellType, data.sellIn) = LibExchange.updateOrderBalanceDebit(
			sellOrder,
			filledAmount,
			amountQuote,
			kSell | kCorrectMatcherFeeByOrderAmount,
			assetBalances,
			liabilities
		);

		LibExchange.creditUserAssets(
			data.buyType,
			buyOrder.senderAddress,
			data.buyIn,
			buyOrder.baseAsset,
			assetBalances,
			liabilities
		);
		LibExchange.creditUserAssets(
			data.sellType,
			sellOrder.senderAddress,
			data.sellIn,
			sellOrder.quoteAsset,
			assetBalances,
			liabilities
		);

		if (!checkPosition(buyOrder.senderAddress)) revert IncorrectPosition();
		if (!checkPosition(sellOrder.senderAddress)) revert IncorrectPosition();

		emit Trade(
			buyOrder.senderAddress,
			sellOrder.senderAddress,
			buyOrder.baseAsset,
			buyOrder.quoteAsset,
			filledPrice,
			filledAmount,
			amountQuote,
			keccak256(abi.encode(buyOrderHash, sellOrderHash))
		);
	}

	/**
	 * @dev wrapper for LibValidator methods, may be deleted.
	 */
	function validateOrder(LibValidator.Order memory order) public pure returns (bool isValid) {
		(isValid, ) = LibValidator.validateV3(order);
	}

	/**
	 * @dev check user marginal position (compare assets and liabilities)
	 * @return isPositive - boolean whether liabilities are covered by collateral or not
	 */
	function checkPosition(address user) public view returns (bool) {
		if (liabilities[user].length == 0) return true;
		return calcPosition(user).state == MarginalFunctionality.PositionState.POSITIVE;
	}

	/**
	 * @dev internal methods which collect all variables used by MarginalFunctionality to one structure
	 * @param user user address to query
	 * @return UsedConstants - MarginalFunctionality.UsedConstants structure
	 */
	function getConstants(address user) internal view returns (MarginalFunctionality.UsedConstants memory) {
		return
			MarginalFunctionality.UsedConstants(
				user,
				_oracleAddress,
				address(_orionToken),
				positionOverdue,
				priceOverdue,
				stakeRisk,
				liquidationPremium
			);
	}

	/**
	 * @dev calc user marginal position (compare assets and liabilities)
	 * @param user user address to query
	 * @return position - MarginalFunctionality.Position structure
	 */
	function calcPosition(address user) public view returns (MarginalFunctionality.Position memory) {
		MarginalFunctionality.UsedConstants memory constants = getConstants(user);

		return MarginalFunctionality.calcPosition(collateralAssets, liabilities, assetBalances, assetRisks, constants);
	}

	/**
     * @dev method to cover some of overdue broker liabilities and get ORN in exchange
            same as liquidation or margin call
     * @param broker - broker which will be liquidated
     * @param redeemedAsset - asset, liability of which will be covered
	 * @param collateralAsset - asset, with which liability will be covered
     * @param amount - amount of covered asset
     */
	function partiallyLiquidate(address broker, address redeemedAsset, address collateralAsset, uint112 amount) public {
		bool isCollateralAsset = false;
		for (uint i = 0; i < collateralAssets.length; ++i) {
			if (collateralAssets[i] == collateralAsset) {
				isCollateralAsset = true;
				break;
			}
		}
		if (!isCollateralAsset) revert NotCollateralAsset();
		MarginalFunctionality.UsedConstants memory constants = getConstants(broker);
		MarginalFunctionality.partiallyLiquidate(
			collateralAssets,
			liabilities,
			assetBalances,
			assetRisks,
			constants,
			redeemedAsset,
			collateralAsset,
			amount
		);
	}

	receive() external payable {
		if (msg.sender == tx.origin) revert EthDepositRejected();
	}

	/**
	 *  @dev  revert on fallback function
	 */
	fallback() external {
		revert Fallback();
	}

	/* Error Codes
        E1: Insufficient Balance, flavor S - stake, L - liabilities, P - Position, B,S - buyer, seller
        E2: Invalid Signature, flavor B,S - buyer, seller
        E3: Invalid Order Info, flavor G - general, M - wrong matcher, M2 unauthorized matcher, As - asset mismatch,
            AmB/AmS - amount mismatch (buyer,seller), PrB/PrS - price mismatch(buyer,seller), D - direction mismatch,
            U - Unit Converter Error, C - caller mismatch
        E4: Order expired, flavor B,S - buyer,seller
        E5: Contract not active,
        E6: Transfer error
        E7: Incorrect state prior to liquidation
        E8: Liquidator doesn't satisfy requirements
        E9: Data for liquidation handling is outdated
        E10: Incorrect state after liquidation
        E11: Amount overflow
        E12: Incorrect filled amount, flavor G,B,S: general(overflow), buyer order overflow, seller order overflow
        E14: Authorization error, sfs - seizeFromStake
        E15: Wrong passed params
        E16: Underlying protection mechanism error, flavor: R, I, O: Reentrancy, Initialization, Ownable
    */
}
