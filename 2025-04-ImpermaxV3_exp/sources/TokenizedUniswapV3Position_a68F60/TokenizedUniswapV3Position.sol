// File: contracts\libraries\SafeMath.sol

pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

// From https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/math/Math.sol
// Subject to the MIT license.

/**
 * @dev Wrappers over Solidity's arithmetic operations with added overflow
 * checks.
 *
 * Arithmetic operations in Solidity wrap on overflow. This can easily result
 * in bugs, because programmers usually assume that an overflow raises an
 * error, which is the standard behavior in high level programming languages.
 * `SafeMath` restores this intuition by reverting the transaction when an
 * operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 */
library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, reverting on overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     * - Addition cannot overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

    /**
     * @dev Returns the addition of two unsigned integers, reverting with custom message on overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     * - Addition cannot overflow.
     */
    function add(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, errorMessage);

        return c;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting on underflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     * - Subtraction cannot underflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction underflow");
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on underflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     * - Subtraction cannot underflow.
     */
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, errorMessage);

        return c;
    }

    /**
     * @dev Returns the integer division of two unsigned integers.
     * Reverts on division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    /**
     * @dev Returns the integer division of two unsigned integers.
     * Reverts with custom message on division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        // Solidity only automatically asserts when dividing by 0
        require(b > 0, errorMessage);
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * Reverts when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * Reverts with custom message when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }
}

// File: contracts\interfaces\IERC721.sol

pragma solidity >=0.5.0;

interface IERC721 {
	event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
	event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
	event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
	
	function name() external view returns (string memory);
	function symbol() external view returns (string memory);
	function balanceOf(address owner) external view returns (uint256 balance);
	function ownerOf(uint256 tokenId) external view returns (address owner);
	function getApproved(uint256 tokenId) external view returns (address operator);
	function isApprovedForAll(address owner, address operator) external view returns (bool);
	
	function DOMAIN_SEPARATOR() external view returns (bytes32);
	function nonces(uint256 tokenId) external view returns (uint256);
	
	function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
	function safeTransferFrom(address from, address to, uint256 tokenId) external;
	function transferFrom(address from, address to, uint256 tokenId) external;
	function approve(address to, uint256 tokenId) external;
	function setApprovalForAll(address operator, bool approved) external;
	function permit(address spender, uint tokenId, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
}

// File: contracts\interfaces\IERC721Receiver.sol

pragma solidity >=0.5.0;

interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

// File: contracts\ImpermaxERC721.sol

pragma solidity =0.5.16;
contract ImpermaxERC721 is IERC721 {
	using SafeMath for uint;
	
	string public name;
	string public symbol;
	
	mapping(address => uint) public balanceOf;
	mapping(uint256 => address) internal _ownerOf;
	mapping(uint256 => address) public getApproved;
	mapping(address => mapping(address => bool)) public isApprovedForAll;
	
	bytes32 public DOMAIN_SEPARATOR;
	mapping(uint256 => uint) public nonces;

	constructor() public {}
	
	function _setName(string memory _name, string memory _symbol) internal {
		name = _name;
		symbol = _symbol;
		
		uint chainId;
		assembly {
			chainId := chainid
		}
		DOMAIN_SEPARATOR = keccak256(
			abi.encode(
				keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
				keccak256(bytes(_name)),
				keccak256(bytes("1")),
				chainId,
				address(this)
			)
		);
	}
	
	function _isAuthorized(address owner, address operator, uint256 tokenId) internal view returns (bool) {
		return operator != address(0) && (owner == operator || isApprovedForAll[owner][operator] || getApproved[tokenId] == operator);
	}

	function _checkAuthorized(address owner, address operator, uint256 tokenId) internal view {
		require(_isAuthorized(owner, operator, tokenId), "ImpermaxERC721: UNAUTHORIZED");
	}

	function _update(address to, uint256 tokenId, address auth) internal returns (address from) {
		from = _ownerOf[tokenId];
		if (auth != address(0)) _checkAuthorized(from, auth, tokenId);

		if (from != address(0)) {
			_approve(address(0), tokenId, address(0));
			balanceOf[from] -= 1;
		}

		if (to != address(0)) {
			balanceOf[to] += 1;
		}

		_ownerOf[tokenId] = to;
		emit Transfer(from, to, tokenId);
	}
	
	function _mint(address to, uint256 tokenId) internal {
		require(to != address(0), "ImpermaxERC721: INVALID_RECEIVER");
		address previousOwner = _update(to, tokenId, address(0));
		require(previousOwner == address(0), "ImpermaxERC721: INVALID_SENDER");
	}
	function _safeMint(address to, uint256 tokenId) internal {
		_safeMint(to, tokenId, "");
	}
	function _safeMint(address to, uint256 tokenId, bytes memory data) internal {
		_mint(to, tokenId);
		_checkOnERC721Received(address(0), to, tokenId, data);
	}
	
	function _burn(uint256 tokenId) internal {
		address previousOwner = _update(address(0), tokenId, address(0));
		require(previousOwner != address(0), "ImpermaxERC721: NONEXISTENT_TOKEN");
	}
	
	function _transfer(address from, address to, uint256 tokenId, address auth) internal {
		require(to != address(0), "ImpermaxERC721: INVALID_RECEIVER");
		address previousOwner = _update(to, tokenId, auth);
		require(previousOwner != address(0), "ImpermaxERC721: NONEXISTENT_TOKEN");
		require(previousOwner == from, "ImpermaxERC721: INCORRECT_OWNER");
	}
	
	function _safeTransfer(address from, address to, uint256 tokenId, address auth) internal {
		_safeTransfer(from, to, tokenId, "", auth);
	}
	function _safeTransfer(address from, address to, uint256 tokenId, bytes memory data, address auth) internal {
		_transfer(from, to, tokenId, auth);
		_checkOnERC721Received(from, to, tokenId, data);
	}

	function _approve(address to, uint256 tokenId, address auth) internal {
		address owner = _requireOwned(tokenId);
		require(auth == address(0) || auth == owner || isApprovedForAll[owner][auth], "ImpermaxERC721: INVALID_APPROVER");
		getApproved[tokenId] = to;
		emit Approval(owner, to, tokenId);
	}

	function _setApprovalForAll(address owner, address operator, bool approved) internal {
		require(operator != address(0), "ImpermaxERC721: INVALID_OPERATOR");
		isApprovedForAll[owner][operator] = approved;
		emit ApprovalForAll(owner, operator, approved);
	}
	
	function _requireOwned(uint256 tokenId) internal view returns (address) {
		address owner = _ownerOf[tokenId];
		require(owner != address(0), "ImpermaxERC721: NONEXISTENT_TOKEN");
		return owner;
	}
	
	function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data) internal {
		if (isContract(to)) {
			bytes4 retval = IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data);
			require(retval == bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")), "ImpermaxERC721: INVALID_RECEIVER");
		}
	}
	
	function ownerOf(uint256 tokenId) external view returns (address) {
		return _requireOwned(tokenId);
	}
	
	function approve(address to, uint256 tokenId) external {
		_approve(to, tokenId, msg.sender);
	}
	
	function setApprovalForAll(address operator, bool approved) external {
		_setApprovalForAll(msg.sender, operator, approved);
	}
	
	function transferFrom(address from, address to, uint256 tokenId) external {
		_transfer(from, to, tokenId, msg.sender);
	}

	function safeTransferFrom(address from, address to, uint256 tokenId) external {
		_safeTransfer(from, to, tokenId, msg.sender);
	}
	
	function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external {
		_safeTransfer(from, to, tokenId, data, msg.sender);
	}
	
	function _checkSignature(address spender, uint tokenId, uint deadline, uint8 v, bytes32 r, bytes32 s, bytes32 typehash) internal {
		require(deadline >= block.timestamp, "ImpermaxERC721: EXPIRED");
		bytes32 digest = keccak256(
			abi.encodePacked(
				'\x19\x01',
				DOMAIN_SEPARATOR,
				keccak256(abi.encode(typehash, spender, tokenId, nonces[tokenId]++, deadline))
			)
		);
		address owner = _requireOwned(tokenId);
		address recoveredAddress = ecrecover(digest, v, r, s);
		require(recoveredAddress == owner, "ImpermaxERC721: INVALID_SIGNATURE");	
	}

	// keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");
	bytes32 public constant PERMIT_TYPEHASH = 0x49ecf333e5b8c95c40fdafc95c1ad136e8914a8fb55e9dc8bb01eaa83a2df9ad;
	function permit(address spender, uint tokenId, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
		_checkSignature(spender, tokenId, deadline, v, r, s, PERMIT_TYPEHASH);
		_approve(spender, tokenId, address(0));
	}
	
	/* Utilities */
	function isContract(address _addr) private view returns (bool){
		uint32 size;
		assembly {
			size := extcodesize(_addr)
		}
		return (size > 0);
	}
}

// File: contracts\interfaces\INFTLP.sol

pragma solidity >=0.5.0;

interface INFTLP {
	struct RealXY {
		uint256 realX;
		uint256 realY;
	}
	
	struct RealXYs {
		RealXY lowestPrice;
		RealXY currentPrice;
		RealXY highestPrice;
	}
	
	// ERC-721
	function ownerOf(uint256 _tokenId) external view returns (address);
	function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
	function safeTransferFrom(address from, address to, uint256 tokenId) external;
	function transferFrom(address from, address to, uint256 tokenId) external;
	
	// Global state
	function token0() external view returns (address);
	function token1() external view returns (address);
	
	// Position state
	function getPositionData(uint256 _tokenId, uint256 _safetyMarginSqrt) external returns (
		uint256 priceSqrtX96,
		RealXYs memory realXYs
	);
	
	// Interactions
	
	function split(uint256 tokenId, uint256 percentage) external returns (uint256 newTokenId);
	function join(uint256 tokenId, uint256 tokenToJoin) external;
}

// File: contracts\extensions\interfaces\IUniswapV3Factory.sol

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title The interface for the Uniswap V3 Factory
/// @notice The Uniswap V3 Factory facilitates creation of Uniswap V3 pools and control over the protocol fees
interface IUniswapV3Factory {
    /// @notice Emitted when the owner of the factory is changed
    /// @param oldOwner The owner before the owner was changed
    /// @param newOwner The owner after the owner was changed
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    /// @notice Emitted when a pool is created
    /// @param token0 The first token of the pool by address sort order
    /// @param token1 The second token of the pool by address sort order
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @param tickSpacing The minimum number of ticks between initialized ticks
    /// @param pool The address of the created pool
    event PoolCreated(
        address indexed token0,
        address indexed token1,
        uint24 indexed fee,
        int24 tickSpacing,
        address pool
    );

    /// @notice Emitted when a new fee amount is enabled for pool creation via the factory
    /// @param fee The enabled fee, denominated in hundredths of a bip
    /// @param tickSpacing The minimum number of ticks between initialized ticks for pools created with the given fee
    event FeeAmountEnabled(uint24 indexed fee, int24 indexed tickSpacing);

    /// @notice Returns the current owner of the factory
    /// @dev Can be changed by the current owner via setOwner
    /// @return The address of the factory owner
    function owner() external view returns (address);

    /// @notice Returns the tick spacing for a given fee amount, if enabled, or 0 if not enabled
    /// @dev A fee amount can never be removed, so this value should be hard coded or cached in the calling context
    /// @param fee The enabled fee, denominated in hundredths of a bip. Returns 0 in case of unenabled fee
    /// @return The tick spacing
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);

    /// @notice Returns the pool address for a given pair of tokens and a fee, or address 0 if it does not exist
    /// @dev tokenA and tokenB may be passed in either token0/token1 or token1/token0 order
    /// @param tokenA The contract address of either token0 or token1
    /// @param tokenB The contract address of the other token
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @return pool The pool address
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address pool);

    /// @notice Creates a pool for the given two tokens and fee
    /// @param tokenA One of the two tokens in the desired pool
    /// @param tokenB The other of the two tokens in the desired pool
    /// @param fee The desired fee for the pool
    /// @dev tokenA and tokenB may be passed in either order: token0/token1 or token1/token0. tickSpacing is retrieved
    /// from the fee. The call will revert if the pool already exists, the fee is invalid, or the token arguments
    /// are invalid.
    /// @return pool The address of the newly created pool
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external returns (address pool);

    /// @notice Updates the owner of the factory
    /// @dev Must be called by the current owner
    /// @param _owner The new owner of the factory
    function setOwner(address _owner) external;

    /// @notice Enables a fee amount with the given tickSpacing
    /// @dev Fee amounts may never be removed once enabled
    /// @param fee The fee amount to enable, denominated in hundredths of a bip (i.e. 1e-6)
    /// @param tickSpacing The spacing between ticks to be enforced for all pools created with the given fee amount
    function enableFeeAmount(uint24 fee, int24 tickSpacing) external;
}

// File: contracts\extensions\interfaces\IUniswapV3Pool.sol

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface IUniswapV3Pool {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function maxLiquidityPerTick() external view returns (uint128);
	
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function protocolFees() external view returns (uint128, uint128);
    function liquidity() external view returns (uint128);

    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    function tickBitmap(int16 wordPosition) external view returns (uint256);

    function positions(bytes32 key)
        external
        view
        returns (
            uint128 _liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function observations(uint256 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        );
		
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
        external
        view
        returns (
            int56 tickCumulativeInside,
            uint160 secondsPerLiquidityInsideX128,
            uint32 secondsInside
        );
		
    function initialize(uint160 sqrtPriceX96) external;

    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);

    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);

    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external returns (uint256 amount0, uint256 amount1);

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
	
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;

    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

// File: contracts\extensions\interfaces\ITokenizedUniswapV3Position.sol

pragma solidity >=0.5.0;

interface ITokenizedUniswapV3Position {
	
	// ERC-721
	
	function name() external view returns (string memory);
	function symbol() external view returns (string memory);
	function balanceOf(address owner) external view returns (uint256 balance);
	function ownerOf(uint256 tokenId) external view returns (address owner);
	function getApproved(uint256 tokenId) external view returns (address operator);
	function isApprovedForAll(address owner, address operator) external view returns (bool);
	
	function DOMAIN_SEPARATOR() external view returns (bytes32);
	function nonces(uint256 tokenId) external view returns (uint256);
	
	function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
	function safeTransferFrom(address from, address to, uint256 tokenId) external;
	function transferFrom(address from, address to, uint256 tokenId) external;
	function approve(address to, uint256 tokenId) external;
	function setApprovalForAll(address operator, bool approved) external;
	function permit(address spender, uint tokenId, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
	
	// INFTLP
	
	function token0() external view returns (address);
	function token1() external view returns (address);
	function getPositionData(uint256 _tokenId, uint256 _safetyMarginSqrt) external returns (
		uint256 priceSqrtX96,
		INFTLP.RealXYs memory realXYs
	);
	
	function join(uint256 tokenId, uint256 tokenToJoin) external;
	function split(uint256 tokenId, uint256 percentage) external returns (uint256 newTokenId);
	
	// ITokenizedUniswapV3Position
	
	struct Position {
		uint24 fee;
		int24 tickLower;
		int24 tickUpper;
		uint128 liquidity;
		uint256 feeGrowthInside0LastX128;
		uint256 feeGrowthInside1LastX128;
		uint256 unclaimedFees0;	
		uint256 unclaimedFees1;	
	}
	
	function factory() external view returns (address);
	function uniswapV3Factory() external view returns (address);
	
	function totalBalance(uint24 fee, int24 tickLower, int24 tickUpper) external view returns (uint256);
	
	function positions(uint256 tokenId) external view returns (
		uint24 fee,
		int24 tickLower,
		int24 tickUpper,
		uint128 liquidity,
		uint256 feeGrowthInside0LastX128,
		uint256 feeGrowthInside1LastX128,
		uint256 unclaimedFees0,
		uint256 unclaimedFees1
	);
	function positionsLength() external view returns (uint256);
	
	function getPool(uint24 fee) external view returns (address pool);
	
	function oraclePriceSqrtX96() external returns (uint256);
	
	event MintPosition(uint256 indexed tokenId, uint24 fee, int24 tickLower, int24 tickUpper);
	event UpdatePositionLiquidity(uint256 indexed tokenId, uint256 liquidity);
	event UpdatePositionFeeGrowthInside(uint256 indexed tokenId, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128);
	event UpdatePositionUnclaimedFees(uint256 indexed tokenId, uint256 unclaimedFees0, uint256 unclaimedFees1);

	function _initialize (
		address _uniswapV3Factory, 
		address _oracle, 
		address _token0, 
		address _token1
	) external;
	
	function mint(address to, uint24 fee, int24 tickLower, int24 tickUpper) external  returns (uint256 newTokenId);
	function redeem(address to, uint256 tokenId) external  returns (uint256 amount0, uint256 amount1);

}

// File: contracts\extensions\interfaces\IUniswapV3AC.sol

pragma solidity >=0.5.0;

interface IUniswapV3AC {
	function getToCollect(
		ITokenizedUniswapV3Position.Position calldata position, 
		uint256 tokenId, 
		uint256 feeCollected0, 
		uint256 feeCollected1
	) external returns (uint256 collect0, uint256 collect1, bytes memory data);
	
	function mintLiquidity(
		address bountyTo, 
		bytes calldata data
	) external returns (uint256 bounty0, uint256 bounty1);
}

// File: contracts\extensions\interfaces\IV3Oracle.sol

pragma solidity >=0.5.0;

interface IV3Oracle {
	function oraclePriceSqrtX96(address token0, address token1) external returns (uint256);
}

// File: contracts\extensions\interfaces\ITokenizedUniswapV3Factory.sol

pragma solidity >=0.5.0;

interface ITokenizedUniswapV3Factory {
	event NFTLPCreated(address indexed token0, address indexed token1, address NFTLP, uint);
	event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);
	event NewAdmin(address oldAdmin, address newAdmin);
	event NewAcModule(address oldAcModule, address newAcModule);
	
	function admin() external view returns (address);
	function pendingAdmin() external view returns (address);
	
	function uniswapV3Factory() external view returns (address);
	function deployer() external view returns (address);
	function oracle() external view returns (address);
	function acModule() external view returns (address);
	
	function getNFTLP(address tokenA, address tokenB) external view returns (address);
	function allNFTLP(uint) external view returns (address);
	function allNFTLPLength() external view returns (uint);
	
	function createNFTLP(address tokenA, address tokenB) external returns (address NFTLP);
	
	function _setPendingAdmin(address newPendingAdmin) external;
	function _acceptAdmin() external;
	function _setAcModule(address newAcModule) external;
}

// File: contracts\libraries\FullMath.sol

// SPDX-License-Identifier: MIT
pragma solidity >=0.4.0 <0.8.0;

/// @title Contains 512-bit math functions
/// @notice Facilitates multiplication and division that can have overflow of an intermediate value without any loss of precision
/// @dev Handles "phantom overflow" i.e., allows multiplication and division where an intermediate value overflows 256 bits
library FullMath {
    /// @notice Calculates floor(a×b÷denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result
    /// @dev Credit to Remco Bloemen under MIT license https://xn--2-umb.com/21/muldiv
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        // 512-bit multiply [prod1 prod0] = a * b
        // Compute the product mod 2**256 and mod 2**256 - 1
        // then use the Chinese Remainder Theorem to reconstruct
        // the 512 bit result. The result is stored in two 256
        // variables such that product = prod1 * 2**256 + prod0
        uint256 prod0; // Least significant 256 bits of the product
        uint256 prod1; // Most significant 256 bits of the product
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        // Handle non-overflow cases, 256 by 256 division
        if (prod1 == 0) {
            require(denominator > 0);
            assembly {
                result := div(prod0, denominator)
            }
            return result;
        }

        // Make sure the result is less than 2**256.
        // Also prevents denominator == 0
        require(denominator > prod1);

        ///////////////////////////////////////////////
        // 512 by 256 division.
        ///////////////////////////////////////////////

        // Make division exact by subtracting the remainder from [prod1 prod0]
        // Compute remainder using mulmod
        uint256 remainder;
        assembly {
            remainder := mulmod(a, b, denominator)
        }
        // Subtract 256 bit number from 512 bit number
        assembly {
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }

        // Factor powers of two out of denominator
        // Compute largest power of two divisor of denominator.
        // Always >= 1.
        uint256 twos = -denominator & denominator;
        // Divide denominator by power of two
        assembly {
            denominator := div(denominator, twos)
        }

        // Divide [prod1 prod0] by the factors of two
        assembly {
            prod0 := div(prod0, twos)
        }
        // Shift in bits from prod1 into prod0. For this we need
        // to flip `twos` such that it is 2**256 / twos.
        // If twos is zero, then it becomes one
        assembly {
            twos := add(div(sub(0, twos), twos), 1)
        }
        prod0 |= prod1 * twos;

        // Invert denominator mod 2**256
        // Now that denominator is an odd number, it has an inverse
        // modulo 2**256 such that denominator * inv = 1 mod 2**256.
        // Compute the inverse by starting with a seed that is correct
        // correct for four bits. That is, denominator * inv = 1 mod 2**4
        uint256 inv = (3 * denominator) ^ 2;
        // Now use Newton-Raphson iteration to improve the precision.
        // Thanks to Hensel's lifting lemma, this also works in modular
        // arithmetic, doubling the correct bits in each step.
        inv *= 2 - denominator * inv; // inverse mod 2**8
        inv *= 2 - denominator * inv; // inverse mod 2**16
        inv *= 2 - denominator * inv; // inverse mod 2**32
        inv *= 2 - denominator * inv; // inverse mod 2**64
        inv *= 2 - denominator * inv; // inverse mod 2**128
        inv *= 2 - denominator * inv; // inverse mod 2**256

        // Because the division is now exact we can divide by multiplying
        // with the modular inverse of denominator. This will give us the
        // correct result modulo 2**256. Since the precoditions guarantee
        // that the outcome is less than 2**256, this is the final result.
        // We don't need to compute the high bits of the result and prod1
        // is no longer required.
        result = prod0 * inv;
        return result;
    }

    /// @notice Calculates ceil(a×b÷denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result
    function mulDivRoundingUp(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) > 0) {
            require(result < uint256(-1));
            result++;
        }
    }
}

// File: contracts\extensions\libraries\LiquidityAmounts.sol

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title Liquidity amount functions
/// @notice Provides functions for computing liquidity amounts from token amounts and prices
library LiquidityAmounts {
    uint constant Q96 = 2**96;
	
    /// @notice Downcasts uint256 to uint128
    /// @param x The uint258 to be downcasted
    /// @return y The passed value, downcasted to uint128
    function toUint128(uint256 x) private pure returns (uint128 y) {
        require((y = uint128(x)) == x);
    }

    /// @notice Computes the amount of liquidity received for a given amount of token0 and price range
    /// @dev Calculates amount0 * (sqrt(upper) * sqrt(lower)) / (sqrt(upper) - sqrt(lower))
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param amount0 The amount0 being sent in
    /// @return liquidity The amount of returned liquidity
    function getLiquidityForAmount0(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = FullMath.mulDiv(sqrtRatioAX96, sqrtRatioBX96, Q96);
        return toUint128(FullMath.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96));
    }

    /// @notice Computes the amount of liquidity received for a given amount of token1 and price range
    /// @dev Calculates amount1 / (sqrt(upper) - sqrt(lower)).
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param amount1 The amount1 being sent in
    /// @return liquidity The amount of returned liquidity
    function getLiquidityForAmount1(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return toUint128(FullMath.mulDiv(amount1, Q96, sqrtRatioBX96 - sqrtRatioAX96));
    }

    /// @notice Computes the maximum amount of liquidity received for a given amount of token0, token1, the current
    /// pool prices and the prices at the tick boundaries
    /// @param sqrtRatioX96 A sqrt price representing the current pool prices
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param amount0 The amount of token0 being sent in
    /// @param amount1 The amount of token1 being sent in
    /// @return liquidity The maximum amount of liquidity received
    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            liquidity = getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtRatioX96, sqrtRatioBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioX96, amount1);

            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
        }
    }

    /// @notice Computes the amount of token0 for a given amount of liquidity and a price range
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount0 The amount of token0
    function getAmount0ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return
            FullMath.mulDiv(
                uint256(liquidity) << 96,
                sqrtRatioBX96 - sqrtRatioAX96,
                sqrtRatioBX96
            ) / sqrtRatioAX96;
    }

    /// @notice Computes the amount of token1 for a given amount of liquidity and a price range
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount1 The amount of token1
    function getAmount1ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96);
    }

    /// @notice Computes the token0 and token1 value for a given amount of liquidity, the current
    /// pool prices and the prices at the tick boundaries
    /// @param sqrtRatioX96 A sqrt price representing the current pool prices
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount0 The amount of token0
    /// @return amount1 The amount of token1
    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
        } else {
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
    }
}

// File: contracts\extensions\libraries\UniswapV3Position.sol

// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

/// @title Position
/// @notice Positions represent an owner address' liquidity between a lower and upper tick boundary
/// @dev Positions store additional state for tracking fees owed to the position
library UniswapV3Position {
    // info stored for each user's position
    struct Info {
        // the amount of liquidity owned by this position
        uint128 liquidity;
        // fee growth per unit of liquidity as of the last update to liquidity or fees owed
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // the fees owed to the position owner in token0/token1
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /// @notice Returns the Info struct of a position, given an owner and position boundaries
    /// @param owner The address of the position owner
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @return hash of the position
    function getHash(
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper));
    }
}

// File: contracts\extensions\libraries\TickMath.sol

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0 <0.8.0;

/// @title Math library for computing sqrt prices from ticks and vice versa
/// @notice Computes sqrt price for ticks of size 1.0001, i.e. sqrt(1.0001^tick) as fixed point Q64.96 numbers. Supports
/// prices between 2**-128 and 2**128
library TickMath {
    /// @dev The minimum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**-128
    int24 internal constant MIN_TICK = -887272;
    /// @dev The maximum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**128
    int24 internal constant MAX_TICK = -MIN_TICK;

    /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// @notice Calculates sqrt(1.0001^tick) * 2^96
    /// @dev Throws if |tick| > max tick
    /// @param tick The input tick for the above formula
    /// @return sqrtPriceX96 A Fixed point Q64.96 number representing the sqrt of the ratio of the two assets (token1/token0)
    /// at the given tick
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(MAX_TICK), 'TickMath: T');

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = uint256(-1) / ratio;

        // this divides by 1<<32 rounding up to go from a Q128.128 to a Q128.96.
        // we then downcast because we know the result always fits within 160 bits due to our tick input constraint
        // we round up in the division so getTickAtSqrtRatio of the output price is always consistent
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    /// @notice Calculates the greatest tick value such that getRatioAtTick(tick) <= ratio
    /// @dev Throws in case sqrtPriceX96 < MIN_SQRT_RATIO, as MIN_SQRT_RATIO is the lowest value getRatioAtTick may
    /// ever return.
    /// @param sqrtPriceX96 The sqrt ratio for which to compute the tick as a Q64.96
    /// @return tick The greatest tick for which the ratio is less than or equal to the input ratio
    function getTickAtSqrtRatio(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        // second inequality must be < because the price can never reach the price at the max tick
        require(sqrtPriceX96 >= MIN_SQRT_RATIO && sqrtPriceX96 < MAX_SQRT_RATIO, 'TickMath: R');
        uint256 ratio = uint256(sqrtPriceX96) << 32;

        uint256 r = ratio;
        uint256 msb = 0;

        assembly {
            let f := shl(7, gt(r, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(6, gt(r, 0xFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(5, gt(r, 0xFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(4, gt(r, 0xFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(3, gt(r, 0xFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(2, gt(r, 0xF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(1, gt(r, 0x3))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := gt(r, 0x1)
            msb := or(msb, f)
        }

        if (msb >= 128) r = ratio >> (msb - 127);
        else r = ratio << (127 - msb);

        int256 log_2 = (int256(msb) - 128) << 64;

        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(63, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(62, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(61, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(60, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(59, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(58, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(57, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(56, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(55, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(54, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(53, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(52, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(51, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(50, f))
        }

        int256 log_sqrt10001 = log_2 * 255738958999603826347141; // 128.128 number

        int24 tickLow = int24((log_sqrt10001 - 3402992956809132418596140100660247210) >> 128);
        int24 tickHi = int24((log_sqrt10001 + 291339464771989622907027621153398088495) >> 128);

        tick = tickLow == tickHi ? tickLow : getSqrtRatioAtTick(tickHi) <= sqrtPriceX96 ? tickHi : tickLow;
    }
}

// File: contracts\extensions\TokenizedUniswapV3Position.sol

pragma solidity =0.5.16;
contract TokenizedUniswapV3Position is ITokenizedUniswapV3Position, INFTLP, ImpermaxERC721 {
	using TickMath for int24;
	
    uint constant Q128 = 2**128;

	uint256 public constant FEE_COLLECTED_WEIGHT = 0.95e18; // 95%
	
	address public factory;
	address public uniswapV3Factory;
	address public oracle;
	address public token0;
	address public token1;
	
	mapping(uint24 => 
		mapping(int24 => 
			mapping(int24 => uint256)
		)
	) public totalBalance;
	
	mapping(uint256 => Position) public positions;
	uint256 public positionsLength;
		
	/*** Global state ***/
	
	// called once by the factory at the time of deployment
	function _initialize (
		address _uniswapV3Factory, 
		address _oracle, 
		address _token0, 
		address _token1
	) external {
		require(factory == address(0), "Impermax: FACTORY_ALREADY_SET"); // sufficient check
		factory = msg.sender;
		_setName("Tokenized Uniswap V3", "NFT-UNI-V3");
		uniswapV3Factory = _uniswapV3Factory;
		oracle = _oracle;
		token0 = _token0;
		token1 = _token1;
		
		// quickly check if the oracle support this tokens pair
		oraclePriceSqrtX96();
	}
	
	function getPool(uint24 fee) public view returns (address pool) {
		pool = IUniswapV3Factory(uniswapV3Factory).getPool(token0, token1, fee);
		require(pool != address(0), "TokenizedUniswapV3Position: UNSUPPORTED_FEE");
	}
	
	function _updateBalance(uint24 fee, int24 tickLower, int24 tickUpper) internal {
		address pool = getPool(fee);
		bytes32 hash = UniswapV3Position.getHash(address(this), tickLower, tickUpper);
		(uint balance,,,,) = IUniswapV3Pool(pool).positions(hash);
		totalBalance[fee][tickLower][tickUpper] = balance;
	}
	
	function oraclePriceSqrtX96() public returns (uint256) {
		return IV3Oracle(oracle).oraclePriceSqrtX96(token0, token1);
	}
 
	/*** Position state ***/
	
	// this assumes that the position fee growth snapshot has already been updated through burn()
	function _getfeeCollectedAndGrowth(Position memory position, address pool) internal view returns (uint256 fg0, uint256 fg1, uint256 feeCollected0, uint256 feeCollected1) {
		bytes32 hash = UniswapV3Position.getHash(address(this), position.tickLower, position.tickUpper);
		(,fg0, fg1,,) = IUniswapV3Pool(pool).positions(hash);
		
		uint256 delta0 = fg0 - position.feeGrowthInside0LastX128;
		uint256 delta1 = fg1 - position.feeGrowthInside1LastX128;
		
		feeCollected0 = delta0.mul(position.liquidity).div(Q128).add(position.unclaimedFees0);
		feeCollected1 = delta1.mul(position.liquidity).div(Q128).add(position.unclaimedFees1);
	}
	function _getFeeCollected(Position memory position, address pool) internal view returns (uint256 feeCollected0, uint256 feeCollected1) {
		(,,feeCollected0, feeCollected1) = _getfeeCollectedAndGrowth(position, pool);
	}
	
	function getPositionData(uint256 tokenId, uint256 safetyMarginSqrt) external returns (
		uint256 priceSqrtX96,
		INFTLP.RealXYs memory realXYs
	) {
		Position memory position = positions[tokenId];
		
		// trigger update of fee growth
		address pool = getPool(position.fee);
		IUniswapV3Pool(pool).burn(position.tickLower, position.tickUpper, 0);
		(uint256 feeCollectedX, uint256 feeCollectedY) = _getFeeCollected(position, pool);
	
		require(safetyMarginSqrt >= 1e18, "TokenizedUniswapV3Position: INVALID_SAFETY_MARGIN");
		_requireOwned(tokenId);
		
		uint160 pa = position.tickLower.getSqrtRatioAtTick();
		uint160 pb = position.tickUpper.getSqrtRatioAtTick();
		
		priceSqrtX96 = oraclePriceSqrtX96();
		uint160 currentPrice = safe160(priceSqrtX96);
		uint160 lowestPrice = safe160(priceSqrtX96.mul(1e18).div(safetyMarginSqrt));
		uint160 highestPrice = safe160(priceSqrtX96.mul(safetyMarginSqrt).div(1e18));
		
		(realXYs.lowestPrice.realX, realXYs.lowestPrice.realY) = LiquidityAmounts.getAmountsForLiquidity(lowestPrice, pa, pb, position.liquidity);
		(realXYs.currentPrice.realX, realXYs.currentPrice.realY) = LiquidityAmounts.getAmountsForLiquidity(currentPrice, pa, pb, position.liquidity);
		(realXYs.highestPrice.realX, realXYs.highestPrice.realY) = LiquidityAmounts.getAmountsForLiquidity(highestPrice, pa, pb, position.liquidity);
		
		uint256 feeCollectedWeightedX = feeCollectedX.mul(FEE_COLLECTED_WEIGHT).div(1e18);
		uint256 feeCollectedWeightedY = feeCollectedY.mul(FEE_COLLECTED_WEIGHT).div(1e18);
		
		realXYs.lowestPrice.realX += feeCollectedWeightedX;
		realXYs.lowestPrice.realY += feeCollectedWeightedY; 
		realXYs.currentPrice.realX += feeCollectedX;
		realXYs.currentPrice.realY += feeCollectedY;
		realXYs.highestPrice.realX += feeCollectedWeightedX;
		realXYs.highestPrice.realY += feeCollectedWeightedY;
	}
 
	/*** Interactions ***/
	
	// this low-level function should be called from another contract
	function mint(address to, uint24 fee, int24 tickLower, int24 tickUpper) external nonReentrant returns (uint256 newTokenId) {
		address pool = getPool(fee);		
		bytes32 hash = UniswapV3Position.getHash(address(this), tickLower, tickUpper);
		(uint balance, uint256 fg0, uint256 fg1,,) = IUniswapV3Pool(pool).positions(hash);
		uint liquidity = balance.sub(totalBalance[fee][tickLower][tickUpper]);
		
		newTokenId = positionsLength++;
		_mint(to, newTokenId);		
		positions[newTokenId] = Position({
			fee: fee,
			tickLower: tickLower,
			tickUpper: tickUpper,
			liquidity: safe128(liquidity),
			feeGrowthInside0LastX128: fg0,
			feeGrowthInside1LastX128: fg1,
			unclaimedFees0: 0,
			unclaimedFees1: 0
		});
		
		_updateBalance(fee, tickLower, tickUpper);
		
		emit MintPosition(newTokenId, fee, tickLower, tickUpper);
		emit UpdatePositionLiquidity(newTokenId, liquidity);
		emit UpdatePositionFeeGrowthInside(newTokenId, fg0, fg1);
		emit UpdatePositionUnclaimedFees(newTokenId, 0, 0);
	}

	// this low-level function should be called from another contract
	function redeem(address to, uint256 tokenId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
		_checkAuthorized(_requireOwned(tokenId), msg.sender, tokenId);
		
		Position memory position = positions[tokenId];
		delete positions[tokenId];
		_burn(tokenId);
		
		address pool = getPool(position.fee);		
		(amount0, amount1) = IUniswapV3Pool(pool).burn(position.tickLower, position.tickUpper, position.liquidity);
		_updateBalance(position.fee, position.tickLower, position.tickUpper);
		
		(uint256 feeCollected0, uint256 feeCollected1) = _getFeeCollected(position, pool);
		amount0 = amount0.add(feeCollected0);
		amount1 = amount1.add(feeCollected1);

		(amount0, amount1) = IUniswapV3Pool(pool).collect(to, position.tickLower, position.tickUpper, safe128(amount0), safe128(amount1));
		
		emit UpdatePositionLiquidity(tokenId, 0);
		emit UpdatePositionUnclaimedFees(tokenId, 0, 0);
	}
	
	function _splitUint(uint256 n, uint256 percentage) internal pure returns (uint256 a, uint256 b) {
		a = n.mul(percentage).div(1e18);
		b = n.sub(a);
	}
	function split(uint256 tokenId, uint256 percentage) external nonReentrant returns (uint256 newTokenId) {
		require(percentage <= 1e18, "TokenizedUniswapV3Position: ABOVE_100_PERCENT");
		address owner = _requireOwned(tokenId);
		_checkAuthorized(owner, msg.sender, tokenId);
		_approve(address(0), tokenId, address(0)); // reset approval
		
		Position memory oldPosition = positions[tokenId];
		(uint256 newLiquidity, uint256 oldLiquidity) = _splitUint(oldPosition.liquidity, percentage);
		(uint256 newUnclaimedFees0, uint256 oldUnclaimedFees0) = _splitUint(oldPosition.unclaimedFees0, percentage);
		(uint256 newUnclaimedFees1, uint256 oldUnclaimedFees1) = _splitUint(oldPosition.unclaimedFees1, percentage);
		positions[tokenId].liquidity = safe128(oldLiquidity);
		positions[tokenId].unclaimedFees0 = oldUnclaimedFees0;
		positions[tokenId].unclaimedFees1 = oldUnclaimedFees1;
		newTokenId = positionsLength++;
		_mint(owner, newTokenId);
		positions[newTokenId] = Position({
			fee: oldPosition.fee,
			tickLower: oldPosition.tickLower,
			tickUpper: oldPosition.tickUpper,
			liquidity: safe128(newLiquidity),
			feeGrowthInside0LastX128: oldPosition.feeGrowthInside0LastX128,
			feeGrowthInside1LastX128: oldPosition.feeGrowthInside1LastX128,
			unclaimedFees0: newUnclaimedFees0,
			unclaimedFees1: newUnclaimedFees1
		});
		
		emit UpdatePositionLiquidity(tokenId, oldLiquidity);
		emit UpdatePositionUnclaimedFees(tokenId, oldUnclaimedFees0, oldUnclaimedFees1);
		emit MintPosition(newTokenId, oldPosition.fee, oldPosition.tickLower, oldPosition.tickUpper);
		emit UpdatePositionLiquidity(newTokenId, newLiquidity);
		emit UpdatePositionUnclaimedFees(newTokenId, newUnclaimedFees0, newUnclaimedFees1);
		emit UpdatePositionFeeGrowthInside(newTokenId, oldPosition.feeGrowthInside0LastX128, oldPosition.feeGrowthInside1LastX128);
	}
	
	function join(uint256 tokenId, uint256 tokenToJoin) external nonReentrant {
		_checkAuthorized(_requireOwned(tokenToJoin), msg.sender, tokenToJoin);
		
		Position memory positionA = positions[tokenId];
		Position memory positionB = positions[tokenToJoin];
		
		require(tokenId != tokenToJoin, "TokenizedUniswapV3Position: SAME_ID");
		require(positionA.fee == positionB.fee, "TokenizedUniswapV3Position: INCOMPATIBLE_TOKENS_META");
		require(positionA.tickLower == positionB.tickLower, "TokenizedUniswapV3Position: INCOMPATIBLE_TOKENS_META");
		require(positionA.tickUpper == positionB.tickUpper, "TokenizedUniswapV3Position: INCOMPATIBLE_TOKENS_META");
		
		uint256 newLiquidity = uint256(positionA.liquidity).add(positionB.liquidity);
		
		// update feeGrowthInside and feeCollected based on the latest snapshot
		// it's not necessary to call burn() in order to update the feeGrowthInside of the position
		uint256 newUnclaimedFees0; uint256 newUnclaimedFees1;
		address pool = getPool(positionA.fee);
		(
			uint256 newFeeGrowthInside0LastX128, 
			uint256 newFeeGrowthInside1LastX128, 
			uint256 feeCollectedA0, 
			uint256 feeCollectedA1
		) = _getfeeCollectedAndGrowth(positionA, pool);
		{
		(
			uint256 feeCollectedB0, 
			uint256 feeCollectedB1
		) = _getFeeCollected(positionB, pool);
		newUnclaimedFees0 = feeCollectedA0.add(feeCollectedB0);
		newUnclaimedFees1 = feeCollectedA1.add(feeCollectedB1);
		}
		
		positions[tokenId].liquidity = safe128(newLiquidity);
		positions[tokenId].feeGrowthInside0LastX128 = newFeeGrowthInside0LastX128;
		positions[tokenId].feeGrowthInside1LastX128 = newFeeGrowthInside1LastX128;
		positions[tokenId].unclaimedFees0 = newUnclaimedFees0;
		positions[tokenId].unclaimedFees1 = newUnclaimedFees1;
		delete positions[tokenToJoin];
		_burn(tokenToJoin);
		
		emit UpdatePositionLiquidity(tokenId, newLiquidity);
		emit UpdatePositionFeeGrowthInside(tokenId, newFeeGrowthInside0LastX128, newFeeGrowthInside1LastX128);
		emit UpdatePositionUnclaimedFees(tokenId, newUnclaimedFees0, newUnclaimedFees1);
		emit UpdatePositionLiquidity(tokenToJoin, 0);
		emit UpdatePositionUnclaimedFees(tokenToJoin, 0, 0);
	}
	
	/*** Autocompounding Module ***/
	
	function reinvest(uint256 tokenId, address bountyTo) external nonReentrant returns (uint256 bounty0, uint256 bounty1) {
		// 1. Initialize and read fee collected
		address acModule = ITokenizedUniswapV3Factory(factory).acModule();
		Position memory position = positions[tokenId];
		Position memory newPosition = positions[tokenId];
		uint256 feeCollected0; uint256 feeCollected1;
		address pool = getPool(position.fee);
		IUniswapV3Pool(pool).burn(position.tickLower, position.tickUpper, 0);
		(
			newPosition.feeGrowthInside0LastX128,
			newPosition.feeGrowthInside1LastX128,
			feeCollected0,
			feeCollected1
		) = _getfeeCollectedAndGrowth(position, pool);
		require(feeCollected0 > 0 || feeCollected1 > 0, "TokenizedUniswapV3Position: NO_FEES_COLLECTED");
	
		// 2. Calculate how much to collect and send it to autocompounder (and update unclaimedFees)
		(uint256 collect0, uint256 collect1, bytes memory data) = IUniswapV3AC(acModule).getToCollect(
			position, 
			tokenId, 
			feeCollected0, 
			feeCollected1
		);
		newPosition.unclaimedFees0 = feeCollected0.sub(collect0, "TokenizedUniswapV3Position: COLLECT_0_TOO_HIGH");
		newPosition.unclaimedFees1 = feeCollected1.sub(collect1, "TokenizedUniswapV3Position: COLLECT_1_TOO_HIGH");
		
		IUniswapV3Pool(pool).collect(acModule, position.tickLower, position.tickUpper, safe128(collect0), safe128(collect1));
		
		
		// 3. Let the autocompounder convert the fees to liquidity
		{
		uint256 totalBalanceBefore = totalBalance[position.fee][position.tickLower][position.tickUpper];
		(bounty0, bounty1) = IUniswapV3AC(acModule).mintLiquidity(bountyTo, data);		
		_updateBalance(position.fee, position.tickLower, position.tickUpper);
		uint256 newLiquidity = totalBalance[position.fee][position.tickLower][position.tickUpper].sub(totalBalanceBefore);
		require(newLiquidity > 0, "TokenizedUniswapV3Position: NO_LIQUIDITY_ADDED");
		newPosition.liquidity = safe128(newLiquidity.add(position.liquidity));
		}
		
		// 4. Update the position
		positions[tokenId] = newPosition;
		
		emit UpdatePositionLiquidity(tokenId, newPosition.liquidity);
		emit UpdatePositionFeeGrowthInside(tokenId, newPosition.feeGrowthInside0LastX128, newPosition.feeGrowthInside1LastX128);
		emit UpdatePositionUnclaimedFees(tokenId, newPosition.unclaimedFees0, newPosition.unclaimedFees1);
	}
	
	/*** Utilities ***/

    function safe128(uint n) internal pure returns (uint128) {
        require(n < 2**128, "Impermax: SAFE128");
        return uint128(n);
    }

    function safe160(uint n) internal pure returns (uint160) {
        require(n < 2**160, "Impermax: SAFE160");
        return uint160(n);
    }
	
	// prevents a contract from calling itself, directly or indirectly.
	bool internal _notEntered = true;
	modifier nonReentrant() {
		require(_notEntered, "Impermax: REENTERED");
		_notEntered = false;
		_;
		_notEntered = true;
	}
}

// File: contracts\extensions\interfaces\ITokenizedUniswapV3Deployer.sol

pragma solidity >=0.5.0;

interface ITokenizedUniswapV3Deployer {
	function deployNFTLP(address token0, address token1) external returns (address NFTLP);
}

// File: contracts\extensions\TokenizedUniswapV3Deployer.sol

pragma solidity =0.5.16;
contract TokenizedUniswapV3Deployer is ITokenizedUniswapV3Deployer {
	constructor () public {}
	
	function deployNFTLP(address token0, address token1) external returns (address NFTLP) {
		bytes memory bytecode = type(TokenizedUniswapV3Position).creationCode;
		bytes32 salt = keccak256(abi.encodePacked(msg.sender, token0, token1));
		assembly {
			NFTLP := create2(0, add(bytecode, 32), mload(bytecode), salt)
		}
	}
}