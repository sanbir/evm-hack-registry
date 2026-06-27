// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./LevToken.sol";

/**
 * @title LevErc20 Contract
 * @notice LevTokens which wrap an EIP-20 underlying
 * @author Vortex
 */
contract LevErc20 is LevToken, LevErc20Interface {

    string public prologue;

    /**
     * @notice set depErc20 
     * @param depErc20_ The address of the associated depErc20
     */
    function setDepErc20(DepErc20Interface depErc20_) public override{
        super.setDepErc20(depErc20_);
    }

    /**
     * @notice Initialize the new money market
     * @param underlying_ The address of the underlying asset
     * @param borrowUnderlying_ The address of the borrow underlying asset
     * @param tensorpricer_ The address of the Tensorpricer
     * @param name_ ERC-20 name of this token
     * @param symbol_ ERC-20 symbol of this token
     * @param decimals_ ERC-20 decimal precision of this token
     */
    function initialize(address underlying_,
                        address borrowUnderlying_,
                        TensorpricerInterface tensorpricer_,
                        string memory name_,
                        string memory symbol_,
                        uint8 decimals_) public override initializer {
        // LevToken initialize does the bulk of the work
        admin = payable(msg.sender);
        super.initialize(underlying_, borrowUnderlying_, tensorpricer_, name_, symbol_, decimals_);

        // Set underlying and sanity check it
        underlying = underlying_;
        EIP20Interface(underlying).totalSupply();

        // Set borrow underlying and sanity check it
        borrowUnderlying = borrowUnderlying_;
        EIP20Interface(borrowUnderlying).totalSupply();

        netAssetValue = initialNetAssetValueMantissa;
        hisHighNav = initialNetAssetValueMantissa;
        targetLevRatio = initialTargetLevRatio;
    }

    function setPrologue() public {
        require(msg.sender == admin, "only admin may set prologue");
        prologue = 'leverc20 success';
    }

    /*** User Interface ***/

    function getAdmin() override external view returns (address payable) {
        return admin;
    }

    /*
     * @notice Sender supplies assets into the market and receives depErc20s in exchange
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param mintAmount The amount of the underlying asset to supply
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function mint(uint mintAmount) override external returns (uint) {
        require(mintAmount > 0, "cannot mint <= 0");
        mintInternal(mintAmount);
        return NO_ERROR;
    }

    /*
     * @notice Sender redeems levErc20s in exchange for the underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemTokens The number of levErc20s to redeem into USDC
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeem(uint redeemTokens) override external returns (uint) {
        redeemInternal(redeemTokens);
        return NO_ERROR;
    }

    /**
     * @notice A public function to sweep accidental ERC-20 transfers to this contract. Tokens are sent to admin (timelock)
     * @param token The address of the ERC-20 token to sweep
     */
    function sweepToken(EIP20NonStandardInterface token) override external {
        require(msg.sender == admin, "DepErc20::sweepToken: only admin can sweep tokens");
        require(address(token) != underlying, "DepErc20::sweepToken: can not sweep underlying token");
        uint256 balance = token.balanceOf(address(this));
        token.transfer(admin, balance);
    }

    /**
     * @notice Get extra borrow demand of this levToken
     * @return The borrowDemand denominated in borrowUnderlying
     */
    function getExtraBorrowDemand() override external view returns (uint256){
        return extraBorrowDemand;
    }

    /**
     * @notice Get extra borrow supply of this levToken
     * @return The borrowSupply denominated in borrowUnderlying
     */
    function getExtraBorrowSupply() override external view returns (uint256){
        return extraBorrowSupply;
    }

    /**
     * @notice depErc20 user (not the contract itself) calls forceRepay
     * @param repayAmountInUSDT The amount of underlying to force repay
     * @return uint actual amount liquidated
     */
    function forceRepay(uint256 repayAmountInUSDT) override virtual external returns (uint) {
        require(msg.sender==address(depErc20), "only depToken can call forceRepay");
//        console.log("forcerepay triggered,repayAmountInUSDT=",repayAmountInUSDT);
        return forceRepayInternal(repayAmountInUSDT);
    }

    function updateLedger() override virtual external {
        require(msg.sender==address(depErc20), "only depToken can call updateLedger");
        return updateLedgerInternal();
    }

    /*** Safe Token ***/

    /**
     * @notice Gets balance of this contract in terms of the underlying
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying tokens owned by this contract
     */
    function getCashPrior() virtual override internal view returns (uint) {
        EIP20Interface token = EIP20Interface(underlying);
//        console.log("leverc20 cash prior=", token.balanceOf(address(this)));
        return token.balanceOf(address(this));
    }

    /**
     * @dev Similar to EIP20 transfer, except it handles a False result from `transferFrom` and reverts in that case.
     *      This will revert due to insufficient balance or insufficient allowance.
     *      This function returns the actual amount received,
     *      which may be less than `amount` if there is a fee attached to the transfer.
     *
     *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
     *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doTransferIn(address from, uint amount) virtual override internal returns (uint) {
        // Read from storage once
        address underlying_ = underlying;
        EIP20NonStandardInterface token = EIP20NonStandardInterface(underlying_);
        uint balanceBefore = EIP20Interface(underlying_).balanceOf(address(this));
        token.transferFrom(from, address(this), amount);

        bool success;
        assembly {
            switch returndatasize()
                case 0 {                       // This is a non-standard ERC-20
                    success := not(0)          // set success to true
                }
                case 32 {                      // This is a compliant ERC-20
                    returndatacopy(0, 0, 32)
                    success := mload(0)        // Set `success = returndata` of override external call
                }
                default {                      // This is an excessively non-compliant ERC-20, revert.
                    revert(0, 0)
                }
        }
        require(success, "TOKEN_TRANSFER_IN_FAILED");

        // Calculate the amount that was *actually* transferred
        uint balanceAfter = EIP20Interface(underlying_).balanceOf(address(this));
        return balanceAfter - balanceBefore;   // underflow already checked above, just subtract
    }

    /**
     * @dev Similar to EIP20 transfer, except it handles a False success from `transfer` and returns an explanatory
     *      error code rather than reverting. If caller has not called checked protocol's balance, this may revert due to
     *      insufficient cash held in this contract. If caller has checked protocol's balance prior to this call, and verified
     *      it is >= amount, this should not revert in normal conditions.
     *
     *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
     *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doTransferOut(address payable to, uint amount) virtual override internal {
        EIP20NonStandardInterface token = EIP20NonStandardInterface(underlying);
        token.transfer(to, amount);

        bool success;
        assembly {
            switch returndatasize()
                case 0 {                      // This is a non-standard ERC-20
                    success := not(0)          // set success to true
                }
                case 32 {                     // This is a compliant ERC-20
                    returndatacopy(0, 0, 32)
                    success := mload(0)        // Set `success = returndata` of override external call
                }
                default {                     // This is an excessively non-compliant ERC-20, revert.
                    revert(0, 0)
                }
        }
        require(success, "TOKEN_TRANSFER_OUT_FAILED");
    }
}
