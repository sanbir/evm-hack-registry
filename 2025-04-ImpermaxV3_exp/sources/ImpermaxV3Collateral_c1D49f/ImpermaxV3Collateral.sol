// File: contracts\CStorage.sol

pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

contract CStorage {
	address public underlying;
	address public factory;
	address public borrowable0;
	address public borrowable1;
	uint public safetyMarginSqrt = 1.58113883e18; //safetyMargin: 250%
	uint public liquidationIncentive = 1.02e18; //2%
	uint public liquidationFee = 0.02e18; //2%
	mapping(uint => uint) public blockOfLastRestructureOrLiquidation;	
	
	function liquidationPenalty() public view returns (uint) {
		return liquidationIncentive + liquidationFee;
	}
}

// File: contracts\libraries\SafeMath.sol

pragma solidity =0.5.16;

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

// File: contracts\interfaces\IFactory.sol

pragma solidity >=0.5.0;

interface IFactory {
	event LendingPoolInitialized(address indexed nftlp, address indexed token0, address indexed token1,
		address collateral, address borrowable0, address borrowable1, uint lendingPoolId);
	event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);
	event NewAdmin(address oldAdmin, address newAdmin);
	event NewReservesPendingAdmin(address oldReservesPendingAdmin, address newReservesPendingAdmin);
	event NewReservesAdmin(address oldReservesAdmin, address newReservesAdmin);
	event NewReservesManager(address oldReservesManager, address newReservesManager);
	
	function admin() external view returns (address);
	function pendingAdmin() external view returns (address);
	function reservesAdmin() external view returns (address);
	function reservesPendingAdmin() external view returns (address);
	function reservesManager() external view returns (address);

	function getLendingPool(address nftlp) external view returns (
		bool initialized, 
		uint24 lendingPoolId, 
		address collateral, 
		address borrowable0, 
		address borrowable1
	);
	function allLendingPools(uint) external view returns (address nftlp);
	function allLendingPoolsLength() external view returns (uint);
	
	function bDeployer() external view returns (address);
	function cDeployer() external view returns (address);

	function createCollateral(address nftlp) external returns (address collateral);
	function createBorrowable0(address nftlp) external returns (address borrowable0);
	function createBorrowable1(address nftlp) external returns (address borrowable1);
	function initializeLendingPool(address nftlp) external;

	function _setPendingAdmin(address newPendingAdmin) external;
	function _acceptAdmin() external;
	function _setReservesPendingAdmin(address newPendingAdmin) external;
	function _acceptReservesAdmin() external;
	function _setReservesManager(address newReservesManager) external;
}

// File: contracts\CSetter.sol

pragma solidity =0.5.16;



contract CSetter is ImpermaxERC721, CStorage {

	uint public constant SAFETY_MARGIN_SQRT_MIN = 1.00e18; //safetyMargin: 100%
	uint public constant SAFETY_MARGIN_SQRT_MAX = 1.58113884e18; //safetyMargin: 250%
	uint public constant LIQUIDATION_INCENTIVE_MIN = 1.00e18; //100%
	uint public constant LIQUIDATION_INCENTIVE_MAX = 1.05e18; //105%
	uint public constant LIQUIDATION_FEE_MAX = 0.08e18; //8%
	
	event NewSafetyMargin(uint newSafetyMarginSqrt);
	event NewLiquidationIncentive(uint newLiquidationIncentive);
	event NewLiquidationFee(uint newLiquidationFee);

	// called once by the factory
	function _setFactory() external {
		require(factory == address(0), "ImpermaxV3Collateral: FACTORY_ALREADY_SET");
		factory = msg.sender;
	}
	
	function _initialize (
		string calldata _name,
		string calldata _symbol,
		address _underlying, 
		address _borrowable0, 
		address _borrowable1
	) external {
		require(msg.sender == factory, "ImpermaxV3Collateral: UNAUTHORIZED"); // sufficient check
		_setName(_name, _symbol);
		underlying = _underlying;
		borrowable0 = _borrowable0;
		borrowable1 = _borrowable1;
	}

	function _setSafetyMarginSqrt(uint newSafetyMarginSqrt) external nonReentrant {
		_checkSetting(newSafetyMarginSqrt, SAFETY_MARGIN_SQRT_MIN, SAFETY_MARGIN_SQRT_MAX);
		safetyMarginSqrt = newSafetyMarginSqrt;
		emit NewSafetyMargin(newSafetyMarginSqrt);
	}

	function _setLiquidationIncentive(uint newLiquidationIncentive) external nonReentrant {
		_checkSetting(newLiquidationIncentive, LIQUIDATION_INCENTIVE_MIN, LIQUIDATION_INCENTIVE_MAX);
		liquidationIncentive = newLiquidationIncentive;
		emit NewLiquidationIncentive(newLiquidationIncentive);
	}

	function _setLiquidationFee(uint newLiquidationFee) external nonReentrant {
		_checkSetting(newLiquidationFee, 0, LIQUIDATION_FEE_MAX);
		liquidationFee = newLiquidationFee;
		emit NewLiquidationFee(newLiquidationFee);
	}
	
	function _checkSetting(uint parameter, uint min, uint max) internal view {
		_checkAdmin();
		require(parameter >= min, "ImpermaxV3Collateral: INVALID_SETTING");
		require(parameter <= max, "ImpermaxV3Collateral: INVALID_SETTING");
	}
	
	function _checkAdmin() internal view {
		require(msg.sender == IFactory(factory).admin(), "ImpermaxV3Collateral: UNAUTHORIZED");
	}
	
	/*** Utilities ***/
	
	// prevents a contract from calling itself, directly or indirectly.
	bool internal _notEntered = true;
	modifier nonReentrant() {
		require(_notEntered, "ImpermaxV3Collateral: REENTERED");
		_notEntered = false;
		_;
		_notEntered = true;
	}
}

// File: contracts\interfaces\IBorrowable.sol

pragma solidity >=0.5.0;

interface IBorrowable {

	/*** Impermax ERC20 ***/
	
	event Transfer(address indexed from, address indexed to, uint value);
	event Approval(address indexed owner, address indexed spender, uint value);
	
	function name() external view returns (string memory);
	function symbol() external view returns (string memory);
	function decimals() external view returns (uint8);
	function totalSupply() external view returns (uint);
	function balanceOf(address owner) external view returns (uint);
	function allowance(address owner, address spender) external view returns (uint);
	function approve(address spender, uint value) external returns (bool);
	function transfer(address to, uint value) external returns (bool);
	function transferFrom(address from, address to, uint value) external returns (bool);
	
	function DOMAIN_SEPARATOR() external view returns (bytes32);
	function PERMIT_TYPEHASH() external pure returns (bytes32);
	function nonces(address owner) external view returns (uint);
	function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
	
	/*** Pool Token ***/
	
	event Mint(address indexed sender, address indexed minter, uint mintAmount, uint mintTokens);
	event Redeem(address indexed sender, address indexed redeemer, uint redeemAmount, uint redeemTokens);
	event Sync(uint totalBalance);
	
	function underlying() external view returns (address);
	function factory() external view returns (address);
	function totalBalance() external view returns (uint);
	function MINIMUM_LIQUIDITY() external pure returns (uint);

	function exchangeRate() external returns (uint);
	function mint(address minter) external returns (uint mintTokens);
	function redeem(address redeemer) external returns (uint redeemAmount);
	function skim(address to) external;
	function sync() external;
	
	function _setFactory() external;
	
	/*** Borrowable ***/

	event BorrowApproval(address indexed owner, address indexed spender, uint value);
	event Borrow(address indexed sender, uint256 indexed tokenId, address indexed receiver, uint borrowAmount, uint repayAmount, uint accountBorrowsPrior, uint accountBorrows, uint totalBorrows);
	event Liquidate(address indexed sender, uint256 indexed tokenId, address indexed liquidator, uint seizeTokenId, uint repayAmount, uint accountBorrowsPrior, uint accountBorrows, uint totalBorrows);
	event RestructureDebt(uint256 indexed tokenId, uint reduceToRatio, uint repayAmount, uint accountBorrowsPrior, uint accountBorrows, uint totalBorrows);
	
	function collateral() external view returns (address);
	function reserveFactor() external view returns (uint);
	function exchangeRateLast() external view returns (uint);
	function borrowIndex() external view returns (uint);
	function totalBorrows() external view returns (uint);
	function borrowAllowance(address owner, address spender) external view returns (uint);
	function borrowBalance(uint tokenId) external view returns (uint);	
	function currentBorrowBalance(uint tokenId) external returns (uint);	
	
	function BORROW_PERMIT_TYPEHASH() external pure returns (bytes32);
	function borrowApprove(address spender, uint256 value) external returns (bool);
	function borrowPermit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
	function borrow(uint256 tokenId, address receiver, uint borrowAmount, bytes calldata data) external;
	function liquidate(uint256 tokenId, uint repayAmount, address liquidator, bytes calldata data) external returns (uint seizeTokenId);
	function restructureDebt(uint256 tokenId, uint256 reduceToRatio) external;
	
	/*** Borrowable Interest Rate Model ***/

	event AccrueInterest(uint interestAccumulated, uint borrowIndex, uint totalBorrows);
	event CalculateKink(uint kinkRate);
	event CalculateBorrowRate(uint borrowRate);
	
	function KINK_BORROW_RATE_MAX() external pure returns (uint);
	function KINK_BORROW_RATE_MIN() external pure returns (uint);
	function KINK_MULTIPLIER() external pure returns (uint);
	function borrowRate() external view returns (uint);
	function kinkBorrowRate() external view returns (uint);
	function kinkUtilizationRate() external view returns (uint);
	function adjustSpeed() external view returns (uint);
	function rateUpdateTimestamp() external view returns (uint32);
	function accrualTimestamp() external view returns (uint32);
	
	function accrueInterest() external;
	
	/*** Borrowable Setter ***/

	event NewReserveFactor(uint newReserveFactor);
	event NewKinkUtilizationRate(uint newKinkUtilizationRate);
	event NewAdjustSpeed(uint newAdjustSpeed);
	event NewDebtCeiling(uint newDebtCeiling);

	function RESERVE_FACTOR_MAX() external pure returns (uint);
	function KINK_UR_MIN() external pure returns (uint);
	function KINK_UR_MAX() external pure returns (uint);
	function ADJUST_SPEED_MIN() external pure returns (uint);
	function ADJUST_SPEED_MAX() external pure returns (uint);
	
	function _initialize (
		string calldata _name, 
		string calldata _symbol,
		address _underlying, 
		address _collateral
	) external;
	function _setReserveFactor(uint newReserveFactor) external;
	function _setKinkUtilizationRate(uint newKinkUtilizationRate) external;
	function _setAdjustSpeed(uint newAdjustSpeed) external;
}

// File: contracts\interfaces\ICollateral.sol

pragma solidity >=0.5.0;

interface ICollateral {
	
	/* ImpermaxERC721 */

	event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
	event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
	event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
	
	function name() external view returns (string memory);
	function symbol() external view returns (string memory);
	function balanceOf(address owner) external view returns (uint256 balance);
	function ownerOf(uint256 tokenId) external view returns (address owner);
	function getApproved(uint256 tokenId) external view returns (address operator);
	function isApprovedForAll(address owner, address operator) external view returns (bool);
	
	function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
	function safeTransferFrom(address from, address to, uint256 tokenId) external;
	function transferFrom(address from, address to, uint256 tokenId) external;
	function approve(address to, uint256 tokenId) external;
	function setApprovalForAll(address operator, bool approved) external;
	function permit(address spender, uint tokenId, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
	
	/* Collateral */
	
	event Mint(address indexed to, uint tokenId);
	event Redeem(address indexed to, uint tokenId, uint percentage, uint redeemTokenId);
	event Seize(address indexed to, uint tokenId, uint percentage, uint redeemTokenId);
	event RestructureBadDebt(uint tokenId, uint postLiquidationCollateralRatio);
	
	function underlying() external view returns (address);
	function factory() external view returns (address);
	function borrowable0() external view returns (address);
	function borrowable1() external view returns (address);
	function safetyMarginSqrt() external view returns (uint);
	function liquidationIncentive() external view returns (uint);
	function liquidationFee() external view returns (uint);
	function liquidationPenalty() external view returns (uint);

	function mint(address to, uint256 tokenId) external;
	function redeem(address to, uint256 tokenId, uint256 percentage, bytes calldata data) external returns (uint redeemTokenId);
	function redeem(address to, uint256 tokenId, uint256 percentage) external returns (uint redeemTokenId);
	function isLiquidatable(uint tokenId) external returns (bool);
	function isUnderwater(uint tokenId) external returns (bool);
	function canBorrow(uint tokenId, address borrowable, uint accountBorrows) external returns (bool);
	function restructureBadDebt(uint tokenId) external;
	function seize(uint tokenId, uint repayAmount, address liquidator, bytes calldata data) external returns (uint seizeTokenId);
	
	/* CSetter */
	
	event NewSafetyMargin(uint newSafetyMarginSqrt);
	event NewLiquidationIncentive(uint newLiquidationIncentive);
	event NewLiquidationFee(uint newLiquidationFee);

	function SAFETY_MARGIN_SQRT_MIN() external pure returns (uint);
	function SAFETY_MARGIN_SQRT_MAX() external pure returns (uint);
	function LIQUIDATION_INCENTIVE_MIN() external pure returns (uint);
	function LIQUIDATION_INCENTIVE_MAX() external pure returns (uint);
	function LIQUIDATION_FEE_MAX() external pure returns (uint);
	
	function _setFactory() external;
	function _initialize (
		string calldata _name,
		string calldata _symbol,
		address _underlying, 
		address _borrowable0, 
		address _borrowable1
	) external;
	function _setSafetyMarginSqrt(uint newSafetyMarginSqrt) external;
	function _setLiquidationIncentive(uint newLiquidationIncentive) external;
	function _setLiquidationFee(uint newLiquidationFee) external;
}

// File: contracts\interfaces\IImpermaxCallee.sol

pragma solidity >=0.5.0;

interface IImpermaxCallee {
    function impermaxV3Borrow(address sender, uint256 tokenId, uint borrowAmount, bytes calldata data) external;
    function impermaxV3Redeem(address sender, uint256 tokenId, uint256 redeemTokenId, bytes calldata data) external;
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

// File: contracts\libraries\CollateralMath.sol

pragma solidity =0.5.16;
library CollateralMath {
	using SafeMath for uint;

    uint constant Q64 = 2**64;
    uint constant Q96 = 2**96;
    uint constant Q192 = 2**192;
	
	enum Price {LOWEST, CURRENT, HIGHEST}

	struct PositionObject {
		INFTLP.RealXYs realXYs;
		uint priceSqrtX96;
		uint debtX;
		uint debtY;
		uint liquidationPenalty;
		uint safetyMarginSqrt;
	}
	
	function newPosition(
		INFTLP.RealXYs memory realXYs,
		uint priceSqrtX96,
		uint debtX,
		uint debtY,
		uint liquidationPenalty,
		uint safetyMarginSqrt
	) internal pure returns (PositionObject memory) {
		return PositionObject({
			realXYs: realXYs,
			priceSqrtX96: priceSqrtX96,
			debtX: debtX,
			debtY: debtY,
			liquidationPenalty: liquidationPenalty,
			safetyMarginSqrt: safetyMarginSqrt
		});
	}
	
    function safeInt256(uint256 n) internal pure returns (int256) {
        require(n < 2**255, "Impermax: SAFE_INT");
        return int256(n);
    }
	
	// price
	function getRelativePriceX(uint priceSqrtX96) internal pure returns (uint) {
		return priceSqrtX96;
	}
	// 1 / price
	function getRelativePriceY(uint priceSqrtX96) internal pure returns (uint) {
		return Q192.div(priceSqrtX96);
	}
	
	// amountX * priceX + amountY * priceY
	function getValue(PositionObject memory positionObject, Price price, uint amountX, uint amountY) internal pure returns (uint) {
		uint priceSqrtX96 = positionObject.priceSqrtX96;
		if (price == Price.LOWEST) priceSqrtX96 = priceSqrtX96.mul(1e18).div(positionObject.safetyMarginSqrt);
		if (price == Price.HIGHEST) priceSqrtX96 = priceSqrtX96.mul(positionObject.safetyMarginSqrt).div(1e18);
		uint relativePriceX = getRelativePriceX(priceSqrtX96);
		uint relativePriceY = getRelativePriceY(priceSqrtX96);
		return amountX.mul(relativePriceX).div(Q64).add(amountY.mul(relativePriceY).div(Q64));
	}
	
	// realX * priceX + realY * priceY
	function getCollateralValue(PositionObject memory positionObject, Price price) internal pure returns (uint) {
		INFTLP.RealXY memory realXY = positionObject.realXYs.currentPrice;
		if (price == Price.LOWEST) realXY = positionObject.realXYs.lowestPrice;
		if (price == Price.HIGHEST) realXY = positionObject.realXYs.highestPrice;
		return getValue(positionObject, price, realXY.realX, realXY.realY);
	}

	// debtX * priceX + realY * debtY	
	function getDebtValue(PositionObject memory positionObject, Price price) internal pure returns (uint) {
		return getValue(positionObject, price, positionObject.debtX, positionObject.debtY);
	}
	
	// collateralValue - debtValue * liquidationPenalty
	function getLiquidityPostLiquidation(PositionObject memory positionObject, Price price) internal pure returns (int) {
		uint collateralNeeded = getDebtValue(positionObject, price).mul(positionObject.liquidationPenalty).div(1e18);
		uint collateralValue = getCollateralValue(positionObject, price);
		return safeInt256(collateralValue) - safeInt256(collateralNeeded);
	}
	
	// collateralValue / (debtValue * liquidationPenalty)
	function getPostLiquidationCollateralRatio(PositionObject memory positionObject) internal pure returns (uint) {
		uint collateralNeeded = getDebtValue(positionObject, Price.CURRENT).mul(positionObject.liquidationPenalty).div(1e18);
		uint collateralValue = getCollateralValue(positionObject, Price.CURRENT);
		return collateralValue.mul(1e18).div(collateralNeeded, "ImpermaxV3Collateral: NO_DEBT");
	}
	
	function isLiquidatable(PositionObject memory positionObject) internal pure returns (bool) {
		int a = getLiquidityPostLiquidation(positionObject, Price.LOWEST);
		int b = getLiquidityPostLiquidation(positionObject, Price.HIGHEST);
		return a < 0 || b < 0;
	}
	
	function isUnderwater(PositionObject memory positionObject) internal pure returns (bool) {
		int liquidity = getLiquidityPostLiquidation(positionObject, Price.CURRENT);
		return liquidity < 0;
	}
}

// File: contracts\ImpermaxV3Collateral.sol

pragma solidity =0.5.16;







contract ImpermaxV3Collateral is ICollateral, CSetter {	
	using CollateralMath for CollateralMath.PositionObject;

    uint256 internal constant Q192 = 2**192;

	constructor() public {}
	
	/*** Collateralization Model ***/
	
	function _getPositionObjectAmounts(uint tokenId, uint debtX, uint debtY) internal returns (CollateralMath.PositionObject memory positionObject) {
		if (debtX == uint(-1)) debtX = IBorrowable(borrowable0).currentBorrowBalance(tokenId);
		if (debtY == uint(-1)) debtY = IBorrowable(borrowable1).currentBorrowBalance(tokenId);
		
		(uint priceSqrtX96, INFTLP.RealXYs memory realXYs) = 
			INFTLP(underlying).getPositionData(tokenId, safetyMarginSqrt);
		require(priceSqrtX96 > 100 && priceSqrtX96 < Q192 / 100, "ImpermaxV3Collateral: PRICE_CALCULATION_ERROR");
		
		positionObject = CollateralMath.newPosition(realXYs, priceSqrtX96, debtX, debtY, liquidationPenalty(), safetyMarginSqrt);
	}
	
	function _getPositionObject(uint tokenId) internal returns (CollateralMath.PositionObject memory positionObject) {
		return _getPositionObjectAmounts(tokenId, uint(-1), uint(-1));
	}
	
	/*** ERC721 Wrapper ***/
	
	function mint(address to, uint256 tokenId) external nonReentrant {
		require(_ownerOf[tokenId] == address(0), "ImpermaxV3Collateral: NFT_ALREADY_MINTED");
		require(INFTLP(underlying).ownerOf(tokenId) == address(this), "ImpermaxV3Collateral: NFT_NOT_RECEIVED");
		_mint(to, tokenId);
		emit Mint(to, tokenId);
	}

	function redeem(address to, uint256 tokenId, uint256 percentage, bytes memory data) public nonReentrant returns (uint256 redeemTokenId) {
		require(percentage <= 1e18, "ImpermaxV3Collateral: PERCENTAGE_ABOVE_100");
		_checkAuthorized(_requireOwned(tokenId), msg.sender, tokenId);
		_approve(address(0), tokenId, address(0)); // reset approval
				
		// optimistically redeem
		if (percentage == 1e18) {
			redeemTokenId = tokenId;
			_burn(tokenId);
			INFTLP(underlying).safeTransferFrom(address(this), to, redeemTokenId);
			if (data.length > 0) IImpermaxCallee(to).impermaxV3Redeem(msg.sender, tokenId, redeemTokenId, data);
			
			// finally check that the position is not left underwater
			require(IBorrowable(borrowable0).borrowBalance(tokenId) == 0, "ImpermaxV3Collateral: INSUFFICIENT_LIQUIDITY");
			require(IBorrowable(borrowable1).borrowBalance(tokenId) == 0, "ImpermaxV3Collateral: INSUFFICIENT_LIQUIDITY");
		} else {
			redeemTokenId = INFTLP(underlying).split(tokenId, percentage);
			INFTLP(underlying).safeTransferFrom(address(this), to, redeemTokenId);
			if (data.length > 0) IImpermaxCallee(to).impermaxV3Redeem(msg.sender, tokenId, redeemTokenId, data);
			
			// finally check that the position is not left underwater
			require(!isLiquidatable(tokenId), "ImpermaxV3Collateral: INSUFFICIENT_LIQUIDITY");
		}
		
		emit Redeem(to, tokenId, percentage, redeemTokenId);
	}
	function redeem(address to, uint256 tokenId, uint256 percentage) external returns (uint256 redeemTokenId) {
		return redeem(to, tokenId, percentage, "");
	}
	
	/*** Collateral ***/
	
	function isLiquidatable(uint tokenId) public returns (bool) {
		CollateralMath.PositionObject memory positionObject = _getPositionObject(tokenId);
		return positionObject.isLiquidatable();
	}
	
	function isUnderwater(uint tokenId) public returns (bool) {
		CollateralMath.PositionObject memory positionObject = _getPositionObject(tokenId);
		return positionObject.isUnderwater();
	}
	
	function canBorrow(uint tokenId, address borrowable, uint accountBorrows) public returns (bool) {
		address _borrowable0 = borrowable0;
		address _borrowable1 = borrowable1;
		require(borrowable == _borrowable0 || borrowable == _borrowable1, "ImpermaxV3Collateral: INVALID_BORROWABLE");
		require(INFTLP(underlying).ownerOf(tokenId) == address(this), "ImpermaxV3Collateral: INVALID_NFTLP_ID");
		
		uint debtX = borrowable == _borrowable0 ? accountBorrows : uint(-1);
		uint debtY = borrowable == _borrowable1 ? accountBorrows : uint(-1);
		
		CollateralMath.PositionObject memory positionObject = _getPositionObjectAmounts(tokenId, debtX, debtY);
		return !positionObject.isLiquidatable();
	}
	
	function restructureBadDebt(uint tokenId) external nonReentrant {
		CollateralMath.PositionObject memory positionObject = _getPositionObject(tokenId);
		uint postLiquidationCollateralRatio = positionObject.getPostLiquidationCollateralRatio();
		require(postLiquidationCollateralRatio < 1e18, "ImpermaxV3Collateral: NOT_UNDERWATER");
		IBorrowable(borrowable0).restructureDebt(tokenId, postLiquidationCollateralRatio);
		IBorrowable(borrowable1).restructureDebt(tokenId, postLiquidationCollateralRatio);
		
		blockOfLastRestructureOrLiquidation[tokenId] = block.number;
		
		emit RestructureBadDebt(tokenId, postLiquidationCollateralRatio);
	}
	
	// this function must be called from borrowable0 or borrowable1
	function seize(uint tokenId, uint repayAmount, address liquidator, bytes calldata data) external nonReentrant returns (uint seizeTokenId) {
		require(msg.sender == borrowable0 || msg.sender == borrowable1, "ImpermaxV3Collateral: UNAUTHORIZED");
		
		uint repayToCollateralRatio;
		{
			CollateralMath.PositionObject memory positionObject = _getPositionObject(tokenId);
			
			if (blockOfLastRestructureOrLiquidation[tokenId] != block.number) {
				require(positionObject.isLiquidatable(), "ImpermaxV3Collateral: INSUFFICIENT_SHORTFALL");
				require(!positionObject.isUnderwater(), "ImpermaxV3Collateral: CANNOT_LIQUIDATE_UNDERWATER_POSITION");
				blockOfLastRestructureOrLiquidation[tokenId] = block.number;
			}
			
			uint collateralValue = positionObject.getCollateralValue(CollateralMath.Price.CURRENT);
			uint repayValue = msg.sender == borrowable0
				? positionObject.getValue(CollateralMath.Price.CURRENT, repayAmount, 0)
				: positionObject.getValue(CollateralMath.Price.CURRENT, 0, repayAmount);
			
			repayToCollateralRatio = repayValue.mul(1e18).div(collateralValue);
			require(repayToCollateralRatio.mul(liquidationPenalty()) <= 1e36, "ImpermaxV3Collateral: UNEXPECTED_RATIO");
		}
		
		uint seizePercentage = repayToCollateralRatio.mul(liquidationIncentive).div(1e18);
		seizeTokenId = INFTLP(underlying).split(tokenId, seizePercentage);

		address reservesManager = IFactory(factory).reservesManager();		
		if (liquidationFee > 0) {
			uint feePercentage = repayToCollateralRatio.mul(liquidationFee).div(uint(1e18).sub(seizePercentage));	
			uint feeTokenId = INFTLP(underlying).split(tokenId, feePercentage);
			_mint(reservesManager, feeTokenId); // _safeMint would be unsafe
			emit Seize(reservesManager, tokenId, feePercentage, feeTokenId);
		}
		
		INFTLP(underlying).safeTransferFrom(address(this), liquidator, seizeTokenId, data);
		emit Seize(liquidator, tokenId, seizePercentage, seizeTokenId);
	}
	
	function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external pure returns (bytes4 returnValue) {
		operator; from; tokenId; data;
		return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
	}
}

// File: contracts\interfaces\ICDeployer.sol

pragma solidity >=0.5.0;

interface ICDeployer {
	function deployCollateral(address nftlp) external returns (address collateral);
}

// File: contracts\CDeployer.sol

pragma solidity =0.5.16;
/*
 * This contract is used by the Factory to deploy Collateral(s)
 * The bytecode would be too long to fit in the Factory
 */
 
contract CDeployer is ICDeployer {
	constructor () public {}
	
	function deployCollateral(address nftlp) external returns (address collateral) {
		bytes memory bytecode = type(ImpermaxV3Collateral).creationCode;
		bytes32 salt = keccak256(abi.encodePacked(msg.sender, nftlp));
		assembly {
			collateral := create2(0, add(bytecode, 32), mload(bytecode), salt)
		}
	}
}