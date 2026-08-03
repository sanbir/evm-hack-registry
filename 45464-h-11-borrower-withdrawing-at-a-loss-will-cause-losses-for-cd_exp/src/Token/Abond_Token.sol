// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {State} from "../interface/IAbond.sol";
import "../lib/Colors.sol";

/**
 * @title ABONDToken contract
 * @author Autonomint
 * @notice The ABOND token contract
 * - has all ERC20 functions
 */

contract ABONDToken is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    UUPSUpgradeable,
    OwnableUpgradeable
{
    mapping(address user => State) public userStates; // ABOND state of this user
    mapping(address user => mapping(uint64 index => State)) public userStatesAtDeposits; // ABOND state at each deposits
    uint128 PRECISION;
    address private borrowingContract; // borrowing contract address

    /**
     * @dev initialize function to initialize the contract
     */
    function initialize() public initializer {
        // Initialize the ERC20 token
        __ERC20_init("ABOND Token", "ABOND");
        // Initialize the token as burnable
        __ERC20Burnable_init();
        // Initialize the token as pausable
        __ERC20Pausable_init();
        // Initialize the owner of the contract
        __Ownable_init(msg.sender);
        // Initialize the proxy
        __UUPSUpgradeable_init();
        PRECISION = 1e18;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    /**
     * @dev modifier to check whether the msg.sender is borrowing contract
     */
    modifier onlyBorrowingContract() {
        require(msg.sender == borrowingContract,"This function can only called by borrowing contract");
        _;
    }

    /**
     * @dev Function to check if an address is a contract
     * @param account address to check whether the address is an contract address or EOA
     */
    function isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    /**
     * @dev mints ABOND token to the user
     * @param to Address to mint
     * @param index Withdraw positions index in borrowing
     * @param amount amount of ABOND to mint
     */
    function mint(
        address to,
        uint64 index,
        uint256 amount
    ) public onlyBorrowingContract returns (bool) {
        // check the to address is non zero address
        require(to != address(0), "Invalid User");

        // get the initial(deposit) state and current state
        State memory fromState = userStatesAtDeposits[to][index];
        State memory toState = userStates[to];

        // update the from state
        fromState.ethBacked = (fromState.ethBacked * PRECISION) / uint128(amount);
        // update the to state
        toState = Colors._credit(fromState, toState, uint128(amount));

        userStatesAtDeposits[to][index] = fromState;
        userStates[to] = toState;

        // mint abond
        _mint(to, amount);
        return true;
    }

    /**
     * transfer abond from msg.sender to, to address
     * @param to address of the recepient
     * @param value abond amount to transfer
     */
    function transfer(
        address to,
        uint256 value
    ) public override returns (bool) {
        // check the input params are non zero
        require(msg.sender != address(0) && to != address(0), "Invalid User");

        // get the sender and receiver state
        State memory fromState = userStates[msg.sender];
        State memory toState = userStates[to];

        // check sender has enough abond to transfer
        require(fromState.aBondBalance >= value, "Insufficient aBond balance");

        // update receiver state
        toState = Colors._credit(fromState, toState, uint128(value));
        userStates[to] = toState;

        // update sender state
        fromState = Colors._debit(fromState, uint128(value));
        userStates[msg.sender] = fromState;

        // transfer abond
        super.transfer(to, value);
        return true;
    }

    /**
     * transfer abond from spender to, to address
     * @param from address of the abond owner
     * @param to address of the recepient
     * @param value abond amount to transfer
     */
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        // check the input params are non zero
        require(from != address(0) && to != address(0), "Invalid User");

        // get the sender and receiver state
        State memory fromState = userStates[from];
        State memory toState = userStates[to];

        // update receiver state
        toState = Colors._credit(fromState, toState, uint128(value));
        userStates[to] = toState;

        // update sender state
        fromState = Colors._debit(fromState, uint128(value));
        userStates[msg.sender] = fromState;

        // transfer abond
        super.transferFrom(from, to, value);
        return true;
    }

    function burnFromUser(
        address to,
        uint256 amount
    ) public onlyBorrowingContract returns (bool) {
        //get the state
        State memory state = userStates[to];
        // update the state
        state = Colors._debit(state, uint128(amount));
        userStates[to] = state;
        // burn abond
        burnFrom(to, amount);
        return true;
    }

    function burn(uint256 value) public override onlyBorrowingContract {
        super.burn(value);
    }

    function burnFrom(
        address account,
        uint256 value
    ) public override onlyBorrowingContract {
        super.burnFrom(account, value);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20Upgradeable, ERC20PausableUpgradeable) {
        super._update(from, to, value);
    }

    /**
     * @dev set the borrowing contract
     * @param _address Borrowing contract address
     */
    function setBorrowingContract(address _address) external onlyOwner {
        require(_address != address(0) && isContract(_address),"Input address is invalid");
        borrowingContract = _address;
    }

    /**
     * @dev sets the abond data for the borrower during deposit
     * @param user address of the borrower
     * @param index index
     * @param ethBacked eth backed for abond
     * @param cumulativeRate ext protocol cumulative rate
     */
    function setAbondData(
        address user,
        uint64 index,
        uint128 ethBacked,
        uint128 cumulativeRate
    ) external onlyBorrowingContract {
        // get the state
        State memory state = userStatesAtDeposits[user][index];

        // assign cr and eth backed, since we dont know abond amount during deposit
        state.cumulativeRate = cumulativeRate;
        state.ethBacked = ethBacked;

        // update the state
        userStatesAtDeposits[user][index] = state;
    }
}
