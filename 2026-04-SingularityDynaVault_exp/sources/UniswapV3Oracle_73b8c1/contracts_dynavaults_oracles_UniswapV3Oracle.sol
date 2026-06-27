// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import "../interfaces/IReferenceAssetOracle.sol";
import "../utils/Checks.sol";

/**
 * @title Uniswap V3 Reference Asset Oracle
 * @notice This calculates the geometric mean of prices across multiple observation points with a configurable observation period in Uniswap V3 style AMM.
 * This avoids economic exploits using flash loan attacks. The geometric mean smooths out extreme values and minimizes the impact of outliers,
 * making it more resistant to manipulation.
 * @notice you can configure the fee level of the specific Uniswap V3 pool to use as oracle source. (defaults to 0.30% when unspecified)
 */
contract UniswapV3Oracle is IReferenceAssetOracle, AccessControl {
	using Checks for address;

	bytes32 public constant ORACLE_ADMIN = keccak256(abi.encode("ORACLE_ADMIN"));

	address public immutable uniswapV3Factory; // 0x1F98431c8aD98523631AE4a59f267346ea31F984;
	address public immutable WETH; // 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
	address public immutable override referenceAsset;

	uint32 public observationPeriod;
	uint256 public minLiquidityThreshold;

	mapping(address => mapping(address => uint24)) public uniV3fee;

	event UpdatedMinimumLiquidityThreshold(address caller, uint256 newThreshold);

	constructor(address uniswapV3FactoryAddress, uint32 _initialObservationPeriod, address referenceAssetAddress, address wethAddress) {
		uniswapV3FactoryAddress.requireNonZeroAddress();
		referenceAssetAddress.requireNonZeroAddress();
		wethAddress.requireNonZeroAddress();
		uniswapV3Factory = uniswapV3FactoryAddress;
		observationPeriod = _initialObservationPeriod;
		WETH = wethAddress;
		referenceAsset = referenceAssetAddress;
		_grantRole(ORACLE_ADMIN, msg.sender);
		_grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
	}

	function tokenReferenceValue(address tokenIn, uint256 amount) public view override returns (uint256 referenceValue, uint256 oldestObservation) {
		if (tokenIn == referenceAsset) return (amount, block.timestamp);
		return getPrice(tokenIn, referenceAsset, amount);
	}

	function getPrice(address base, address quote) public view override returns (uint256, uint256) {
		uint8 decimals = IERC20Metadata(base).decimals();
		uint256 amount = 10 ** decimals;
		return getPrice(base, quote, amount);
	}

	function getPrice(address base, address quote, uint256 amount) public view returns (uint256, uint256) {
		uint24 baseFee = (uniV3fee[base][quote] > 0) ? uniV3fee[base][quote] : 3000;
		(uint256 directValue, uint256 directTimestamp) = getPrice(base, baseFee, quote, amount);
		if (directTimestamp == 0 && base != WETH && quote != WETH) {
			baseFee = (uniV3fee[base][WETH] > 0) ? uniV3fee[base][WETH] : 3000;
			(uint256 wethValue, uint256 baseTimestamp) = getPrice(base, baseFee, WETH, amount);
			if (baseTimestamp == 0) return (0, 0);
			uint24 wethFee = (uniV3fee[WETH][quote] > 0) ? uniV3fee[WETH][quote] : 3000;
			(uint256 indirectValue, uint256 indirectTimestamp) = getPrice(WETH, wethFee, quote, wethValue);
			uint256 oldestTimestamp = (indirectTimestamp < baseTimestamp) ? indirectTimestamp : baseTimestamp;
			return (indirectValue, oldestTimestamp);
		}
		return (directValue, directTimestamp);
	}

	function getPrice(address base, uint24 fee, address quote, uint256 amount) public view returns (uint256 price, uint256 oldestObservation) {
		uint32 secondsAgo = uint32(observationPeriod);
		uint32[] memory secondsAgos = new uint32[](2);
		secondsAgos[0] = secondsAgo;
		secondsAgos[1] = 0;
		address pool = IUniswapV3Factory(uniswapV3Factory).getPool(base, quote, fee);
		if (pool != address(0)) {
			if (IUniswapV3Pool(pool).liquidity() < minLiquidityThreshold) return (0, 0);
			// use uniswap v3 when pool exists
			(int56[] memory tickCumulatives, ) = IUniswapV3Pool(pool).observe(secondsAgos);
			int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
			// int56 / uint32 = int24
			int24 tick = int24(tickCumulativesDelta / int56(uint56(secondsAgo)));
			uint256 amountOut = OracleLibrary.getQuoteAtTick(tick, uint128(amount), base, quote);
			(, , uint16 observationIndex, , , , ) = IUniswapV3Pool(pool).slot0();
			(uint32 observationTimestamp, , , bool initialized) = IUniswapV3Pool(pool).observations(observationIndex);
			if (initialized) oldestObservation = observationTimestamp;
			return (amountOut, oldestObservation);
		}
	}

	function setUniV3fee(address base, address quote, uint24 fee) external onlyRole(ORACLE_ADMIN) {
		uniV3fee[base][quote] = fee;
		uniV3fee[quote][base] = fee;
	}

	function setMinimumLiquidityThreshold(uint256 newMinLiquidityThreshold) external onlyRole(ORACLE_ADMIN) {
		minLiquidityThreshold = newMinLiquidityThreshold;
		emit UpdatedMinimumLiquidityThreshold(msg.sender, newMinLiquidityThreshold);
	}
}
