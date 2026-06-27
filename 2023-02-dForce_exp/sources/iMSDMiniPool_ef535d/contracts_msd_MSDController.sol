// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts-upgradeable/utils/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";

import "./MSD.sol";

/**
 * @dev Interface for Minters, minters now can be iMSD and MSDS
 */
interface IMinter {
    function updateInterest() external returns (bool);
}

/**
 * @title dForce's Multi-currency Stable Debt Token Controller
 * @author dForce
 */

contract MSDController is Initializable, Ownable {
    using SafeMathUpgradeable for uint256;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    /// @dev EnumerableSet of all msdTokens
    EnumerableSetUpgradeable.AddressSet internal msdTokens;

    // @notice Mapping of msd tokens to corresponding minters
    mapping(address => EnumerableSetUpgradeable.AddressSet) internal msdMinters;

    struct TokenData {
        // System earning from borrow interest
        uint256 earning;
        // System debt from saving interest
        uint256 debt;
    }

    // @notice Mapping of msd tokens to corresponding TokenData
    mapping(address => TokenData) public msdTokenData;

    /**
     * @dev Emitted when `token` is added into msdTokens.
     */
    event MSDAdded(address token);

    /**
     * @dev Emitted when `minter` is added into `tokens`'s minters.
     */
    event MinterAdded(address token, address minter);

    /**
     * @dev Emitted when `minter` is removed from `tokens`'s minters.
     */
    event MinterRemoved(address token, address minter);

    /**
     * @dev Emitted when `token`'s earning is added by `minter`.
     */
    event MSDEarningAdded(
        address token,
        address minter,
        uint256 earning,
        uint256 totalEarning
    );

    /**
     * @dev Emitted when `token`'s debt is added by `minter`.
     */
    event MSDDebtAdded(
        address token,
        address minter,
        uint256 debt,
        uint256 totalDebt
    );

    /**
     * @dev Emitted when reserve is withdrawn from `token`.
     */
    event ReservesWithdrawn(
        address owner,
        address token,
        uint256 amount,
        uint256 oldTotalReserves,
        uint256 newTotalReserves
    );

    /**
     * @notice Expects to call only once to initialize the MSD controller.
     */
    function initialize() external initializer {
        __Ownable_init();
    }

    /**
     * @notice Ensure this is a MSD Controller contract.
     */
    function isMSDController() external pure returns (bool) {
        return true;
    }

    /**
     * @dev Throws if token is not in msdTokens
     */
    function _checkMSD(address _token) internal view {
        require(hasMSD(_token), "token is not a valid MSD token");
    }

    /**
     * @dev Throws if token is not a valid MSD token.
     */
    modifier onlyMSD(address _token) {
        _checkMSD(_token);
        _;
    }

    /**
     * @dev Throws if called by any account other than the _token's minters.
     */
    modifier onlyMSDMinter(address _token, address caller) {
        _checkMSD(_token);

        require(
            msdMinters[_token].contains(caller),
            "onlyMinter: caller is not the token's minter"
        );

        _;
    }

    /**
     * @notice Add `_token` into msdTokens.
     * If `_token` have not been in msdTokens, emits a `MSDTokenAdded` event.
     *
     * @param _token The token to add
     * @param _minters The addresses to add as token's minters
     *
     * Requirements:
     * - the caller must be `owner`.
     */
    function _addMSD(address _token, address[] calldata _minters)
        external
        onlyOwner
    {
        require(_token != address(0), "MSD token cannot be a zero address");
        if (msdTokens.add(_token)) {
            emit MSDAdded(_token);
        }

        _addMinters(_token, _minters);
    }

    /**
     * @notice Add `_minters` into minters.
     * If `_minters` have not been in minters, emits a `MinterAdded` event.
     *
     * @param _minters The addresses to add as minters
     *
     * Requirements:
     * - the caller must be `owner`.
     */
    function _addMinters(address _token, address[] memory _minters)
        public
        onlyOwner
        onlyMSD(_token)
    {
        uint256 _len = _minters.length;

        for (uint256 i = 0; i < _len; i++) {
            require(
                _minters[i] != address(0),
                "minter cannot be a zero address"
            );

            if (msdMinters[_token].add(_minters[i])) {
                emit MinterAdded(_token, _minters[i]);
            }
        }
    }

    /**
     * @notice Remove `minter` from minters.
     * If `minter` is a minter, emits a `MinterRemoved` event.
     *
     * @param _minter The minter to remove
     *
     * Requirements:
     * - the caller must be `owner`, `_token` must be a MSD Token.
     */
    function _removeMinter(address _token, address _minter)
        external
        onlyOwner
        onlyMSD(_token)
    {
        require(_minter != address(0), "_minter cannot be a zero address");

        if (msdMinters[_token].remove(_minter)) {
            emit MinterRemoved(_token, _minter);
        }
    }

    /**
     * @notice Withdraw the reserve of `_token`.
     * @param _token The MSD token to withdraw
     * @param _amount The amount of token to withdraw
     *
     * Requirements:
     * - the caller must be `owner`, `_token` must be a MSD Token.
     */
    function _withdrawReserves(address _token, uint256 _amount)
        external
        onlyOwner
        onlyMSD(_token)
    {
        (uint256 _equity, ) = calcEquity(_token);

        require(_equity >= _amount, "Token do not have enough reserve");

        // Increase the token debt
        msdTokenData[_token].debt = msdTokenData[_token].debt.add(_amount);

        // Directly mint the token to owner
        MSD(_token).mint(owner, _amount);

        emit ReservesWithdrawn(
            owner,
            _token,
            _amount,
            _equity,
            _equity.sub(_amount)
        );
    }

    /**
     * @notice Mint `amount` of `_token` to `_to`.
     * @param _token The MSD token to mint
     * @param _to The account to mint to
     * @param _amount The amount of token to mint
     *
     * Requirements:
     * - the caller must be `minter` of `_token`.
     */
    function mintMSD(
        address _token,
        address _to,
        uint256 _amount
    ) external onlyMSDMinter(_token, msg.sender) {
        MSD(_token).mint(_to, _amount);
    }

    /*********************************/
    /******** MSD Token Equity *******/
    /*********************************/

    /**
     * @notice Add `amount` of debt to `_token`.
     * @param _token The MSD token to add debt
     * @param _debt The amount of debt to add
     *
     * Requirements:
     * - the caller must be `minter` of `_token`.
     */
    function addDebt(address _token, uint256 _debt)
        external
        onlyMSDMinter(_token, msg.sender)
    {
        msdTokenData[_token].debt = msdTokenData[_token].debt.add(_debt);

        emit MSDDebtAdded(_token, msg.sender, _debt, msdTokenData[_token].debt);
    }

    /**
     * @notice Add `amount` of earning to `_token`.
     * @param _token The MSD token to add earning
     * @param _earning The amount of earning to add
     *
     * Requirements:
     * - the caller must be `minter` of `_token`.
     */
    function addEarning(address _token, uint256 _earning)
        external
        onlyMSDMinter(_token, msg.sender)
    {
        msdTokenData[_token].earning = msdTokenData[_token].earning.add(
            _earning
        );

        emit MSDEarningAdded(
            _token,
            msg.sender,
            _earning,
            msdTokenData[_token].earning
        );
    }

    /**
     * @notice Get the MSD token equity
     * @param _token The MSD token to query
     * @return token equity, token debt, will call `updateInterest()` on its minters
     *
     * Requirements:
     * - `_token` must be a MSD Token.
     *
     */
    function calcEquity(address _token)
        public
        onlyMSD(_token)
        returns (uint256, uint256)
    {
        // Call `updateInterest()` on all minters to get the latest token data
        EnumerableSetUpgradeable.AddressSet storage _msdMinters =
            msdMinters[_token];

        uint256 _len = _msdMinters.length();
        for (uint256 i = 0; i < _len; i++) {
            IMinter(_msdMinters.at(i)).updateInterest();
        }

        TokenData storage _tokenData = msdTokenData[_token];

        return
            _tokenData.earning > _tokenData.debt
                ? (_tokenData.earning.sub(_tokenData.debt), uint256(0))
                : (uint256(0), _tokenData.debt.sub(_tokenData.earning));
    }

    /*********************************/
    /****** General Information ******/
    /*********************************/

    /**
     * @notice Return all of the MSD tokens
     * @return _allMSDs The list of MSD token addresses
     */
    function getAllMSDs() public view returns (address[] memory _allMSDs) {
        EnumerableSetUpgradeable.AddressSet storage _msdTokens = msdTokens;

        uint256 _len = _msdTokens.length();
        _allMSDs = new address[](_len);
        for (uint256 i = 0; i < _len; i++) {
            _allMSDs[i] = _msdTokens.at(i);
        }
    }

    /**
     * @notice Check whether a address is a valid MSD
     * @param _token The token address to check for
     * @return true if the _token is a valid MSD otherwise false
     */
    function hasMSD(address _token) public view returns (bool) {
        return msdTokens.contains(_token);
    }

    /**
     * @notice Return all minter of a MSD token
     * @param _token The MSD token address to get minters for
     * @return _minters The list of MSD token minter addresses
     * Will retuen empty if `_token` is not a valid MSD token
     */
    function getMSDMinters(address _token)
        public
        view
        returns (address[] memory _minters)
    {
        EnumerableSetUpgradeable.AddressSet storage _msdMinters =
            msdMinters[_token];

        uint256 _len = _msdMinters.length();
        _minters = new address[](_len);
        for (uint256 i = 0; i < _len; i++) {
            _minters[i] = _msdMinters.at(i);
        }
    }
}
