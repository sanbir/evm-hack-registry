// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "hardhat/console.sol";
import "./TensorpricerInterface.sol";
import "./LevTokenInterfaces.sol";
import "./ErrorReporter.sol";
import "./EIP20Interface.sol";
import "./ExponentialNoError.sol";
import "./DepositWithdraw.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title LevToken Contract
 * @notice Abstract base for LevTokens
 * @author Vortex
 */
abstract contract LevToken is LevTokenInterface, DepositWithdraw, CurveSwap, ExponentialNoError, TokenErrorReporter, Initializable {

    /**
     * @notice set the depErc20 token
     * @param depErc20_ The address of the associated depErc20
     */
    function setDepErc20(DepErc20Interface depErc20_) public virtual{
        require(msg.sender == admin, "only admin may set depErc20");
        depErc20 = depErc20_;
    }

    /**
     * @notice Initialize the money market
     * @param tensorpricer_ The address of the Tensorpricer
     * @param name_ EIP-20 name of this token
     * @param symbol_ EIP-20 symbol of this token
     * @param decimals_ EIP-20 decimal precision of this token
     */
    function initialize(address underlying_,
                        address borrowUnderlying_,
                        TensorpricerInterface tensorpricer_,
                        string memory name_,
                        string memory symbol_,
                        uint8 decimals_) public virtual onlyInitializing {
        require(msg.sender == admin, "only admin may initialize the market");
        
        // Set the tensorpricer
        uint err = _setTensorpricer(tensorpricer_);
        require(err == NO_ERROR, "setting tensorpricer failed");

        name = name_;
        symbol = symbol_;
        decimals = decimals_;

        // The counter starts true to prevent changing it from zero to non-zero (i.e. smaller cost/refund)
        _notEntered = true;
    }

    /**
     * @notice Initialize the compound portion
     * @param compoundV2cUSDCAddress_ The address of the cUSDC
     * @param compoundV2cUSDTAddress_ The address of the cUSDT
     * @param USDCAddress_ The address of USDC
     * @param USDTAddress_ The address of USDT
    */
    function setAddressesForCompound(address compoundV2cUSDCAddress_, address compoundV2cUSDTAddress_, address USDCAddress_, address USDTAddress_) public {
        require(msg.sender==admin, "only admin can set addresses in general");
        setAddresses(compoundV2cUSDCAddress_, compoundV2cUSDTAddress_, USDCAddress_, USDTAddress_);
    }

    /**
     * @notice Initialize the curve portion
     * @param TriPool_ The address of the Tripool
     * @param ADDRESSPROVIDER_ The address of the curve provider
     * @param USDC_ADDRESS_ The address of USDC
     * @param USDT_ADDRESS_ The address of USDT
    */
    function setAddressesForCurve(address TriPool_, address ADDRESSPROVIDER_, address USDC_ADDRESS_, address USDT_ADDRESS_) public {
        require(msg.sender==admin, "only admin can set addresses in general");
        setAddressesCurve(TriPool_, ADDRESSPROVIDER_, USDC_ADDRESS_, USDT_ADDRESS_);
    }

    /**
     * @notice Transfer `tokens` tokens from `src` to `dst` by `spender`
     * @dev Called by both `transfer` and `transferFrom` internally
     * @param spender The address of the account performing the transfer
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param tokens The number of tokens to transfer
     * @return 0 if the transfer succeeded, else revert
     */
    function transferTokens(address spender, address src, address dst, uint tokens) internal returns (uint) {
        /* Fail if transfer not allowed */
        uint allowed = tensorpricer.transferAllowed(address(this), src, dst, tokens);
        if (allowed != 0) {
            revert TransferTensorpricerRejection(allowed);   // change the name
        }

        /* Do not allow self-transfers */
        if (src == dst) {
            revert TransferNotAllowed();
        }

        /* Get the allowance, infinite for the account owner */
        uint startingAllowance = 0;
        if (spender == src) {
            startingAllowance = type(uint).max;
        } else {
            startingAllowance = transferAllowances[src][spender];
            if(startingAllowance < tokens){
                revert TransferNotEnoughAllowance();
            }
        }

        /* Do the calculations, checking for {under,over}flow */
        uint allowanceNew = startingAllowance - tokens;
        uint srLevTokensNew = accountTokens[src] - tokens;
        uint dstTokensNew = accountTokens[dst] + tokens;

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        accountTokens[src] = srLevTokensNew;
        accountTokens[dst] = dstTokensNew;

        /* Eat some of the allowance (if necessary) */
        if (startingAllowance != type(uint).max) {
            transferAllowances[src][spender] = allowanceNew;
        }

        /* We emit a Transfer event */
        emit Transfer(src, dst, tokens);

        return NO_ERROR;
    }

    /**
     * @notice Transfer `amount` tokens from `msg.sender` to `dst`
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transfer(address dst, uint256 amount) override external nonReentrant returns (bool) {
        return transferTokens(msg.sender, msg.sender, dst, amount) == NO_ERROR;
    }

    /**
     * @notice Transfer `amount` tokens from `src` to `dst`
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transferFrom(address src, address dst, uint256 amount) override external nonReentrant returns (bool) {
        return transferTokens(msg.sender, src, dst, amount) == NO_ERROR;
    }

    /**
     * @notice Approve `spender` to transfer up to `amount` from `src`
     * @dev This will overwrite the approval amount for `spender`
     *  and is subject to issues noted [here](https://eips.ethereum.org/EIPS/eip-20#approve)
     * @param spender The address of the account which may transfer tokens
     * @param amount The number of tokens that are approved (uint256.max means infinite)
     * @return Whether or not the approval succeeded
     */
    function approve(address spender, uint256 amount) override external returns (bool) {
        address src = msg.sender;
        transferAllowances[src][spender] = amount;
        emit Approval(src, spender, amount);
        return true;
    }

    /**
     * @notice Get the current allowance from `owner` for `spender`
     * @param owner The address of the account which owns the tokens to be spent
     * @param spender The address of the account which may transfer tokens
     * @return The number of tokens allowed to be spent (-1 means infinite)
     */
    function allowance(address owner, address spender) override external view returns (uint256) {
        return transferAllowances[owner][spender];
    }

    /**
     * @notice Get the token balance of the `owner`
     * @param owner The address of the account to query
     * @return The number of tokens owned by `owner`
     */
    function balanceOf(address owner) override external view returns (uint256) {
        return accountTokens[owner];
    }

    /**
     * @notice Get the nav of the `owner`
     * @dev
     * @param owner The address of the account to query
     * @return The amount of nav owned by `owner`
     */
    function getNAV(address owner) override external view returns (uint) {
        Exp memory nav = Exp({mantissa: netAssetValue});
        return mul_ScalarTruncate(nav, accountTokens[owner]);
    }

    /**
     * @notice Get a snapshot of the account's balances, and the cached exchange rate
     * @dev This is used by tensorpricer to more efficiently perform liquidity checks.
     * @param account Address of the account to snapshot
     * @return (possible error, token balance, borrow balance, exchange rate mantissa)
     */
    function getAccountSnapshot(address account) override external view returns (uint, uint) {
        return (
            NO_ERROR,
            accountTokens[account]
        );
    }

    /**
     * @notice Get cash balance of this LevToken in USDC
     * @return The quantity of USDC owned by this contract (deposits + amt obtained from sale of USDT)
     */
    function getCash() override external view returns (uint) {
        return getCashPrior();
    }

    /**
     * @notice Get cash balance deposited at compound
     * @return The quantity of underlying asset owned by this contract
     */
    function getCompoundBalance() override external view returns (uint) {
        return getCmpBalanceInternal();
    }

    function getCmpBalanceInternal() internal view returns (uint) {
        Exp memory exchangeRate = Exp({mantissa: getCmpUSDCExchRate()});
        return mul_ScalarTruncate(exchangeRate, getCUSDCNumber());
    }

    function getLevReserve() override external view returns (uint) {
        return levReserve;
    }

    function getHisHighNav() override external view returns (uint) {
        return hisHighNav;
    }

    // rebalance specific:

    /**
     * @notice Calculates the net asset value of the levToken
     * @dev
     * @return calculated net asset value scaled by 1e18
     */
    function updateNetAssetValue(uint latestBorrowBalanceUSDC, uint offset) internal {//nonReentrant {
        netAssetValue = calcNetAssetValue(latestBorrowBalanceUSDC, offset);
    }

    /**
     * @notice Calculates the net asset value of the levToken
     * @dev
     * @return calculated net asset value scaled by 1e18
     */
    function calcNetAssetValue(uint latestBorrowBalanceUSDC, uint offset) internal view returns (uint){//nonReentrant {
        uint _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            /*
             * If there are no tokens minted:
             *  NAV = initialNAV
             */
            return initialNetAssetValueMantissa;
        } else {
            /*
             * Otherwise:
             *  NAV = (USDC_Balance - borrowed_USDT_Balance * fx_USDTUSDC) / totalSupply
             */
            uint balanceUSDCExReserves = getCashExReserves() + getCmpBalanceInternal();
            if(balanceUSDCExReserves > latestBorrowBalanceUSDC + offset){
                return (balanceUSDCExReserves - latestBorrowBalanceUSDC - offset) * expScale / _totalSupply;
            }else{
                return 0;
            }
        }
    }

    function updateStats(bool recalc, uint tmpTotalAssetValue, uint tmpLevRatio, uint redeemTokensIn) internal {
        if(recalc){
            uint availCash = getCashExReserves() + getCmpBalanceInternal();
            if(redeemTokensIn > 0){
                uint currTotalAssetValue;
                uint amtToSubtract;
                if(availCash > borrowBalanceUSDC){
                    currTotalAssetValue = availCash - borrowBalanceUSDC;
                    uint currNav = currTotalAssetValue * expScale / totalSupply;
                    redeemAmountInUSDC = currNav * redeemTokensIn / expScale;
                    //console.log("calc redeemAmountInUSDC=",redeemAmountInUSDC);
                    amtToSubtract = borrowBalanceUSDC + redeemAmountInUSDC;
                }else{
                    currTotalAssetValue = 0;
                    amtToSubtract = borrowBalanceUSDC;
                }
                if(availCash > amtToSubtract){
                    totalAssetValue = availCash - amtToSubtract;
                    levRatio = borrowBalanceUSDC*expScale / totalAssetValue;
                }else{
                    totalAssetValue = 0;
                    levRatio = 0;
                }
            }else{
                uint amtToSubtract = borrowBalanceUSDC;
                if(availCash > amtToSubtract){
                    totalAssetValue = availCash - amtToSubtract;
                    levRatio = borrowBalanceUSDC*expScale / totalAssetValue;
                }else{
                    totalAssetValue = 0;
                    levRatio = 0;
                }
            }
        }else{
            if(redeemTokensIn > 0){
                uint availCash = getCashExReserves() + getCmpBalanceInternal();
                //uint currNav = tmpTotalAssetValue * expScale / totalSupply; // wrong
                uint currNav = tmpTotalAssetValue * expScale / (totalSupply - redeemTokensIn);
                //console.log("tmpTotalAssetValue=",tmpTotalAssetValue);
                redeemAmountInUSDC = currNav * redeemTokensIn / expScale;
                //console.log("non calc redeemAmountInUSDC=",redeemAmountInUSDC);
                //console.log("currNav=",currNav);
                uint amtToSubtract = borrowBalanceUSDC + redeemAmountInUSDC;
                if(availCash > amtToSubtract){
                    totalAssetValue = availCash - amtToSubtract;
                    levRatio = borrowBalanceUSDC*expScale / totalAssetValue;
                }else{
                    totalAssetValue = 0;
                    levRatio = 0;
                }
            }else{  
                totalAssetValue = tmpTotalAssetValue;
                levRatio = tmpLevRatio; 
            }
        }
    }

    function refreshTargetLevRatio(uint fx_USDTUSDC_Mantissa) public pure returns (uint, uint, uint) {
        // targetLevRatio, releverageTrigger, deleverageTrigger
        if(fx_USDTUSDC_Mantissa < 6e17 || fx_USDTUSDC_Mantissa > 14e17){
            return (1e18, 0, 2e18);
        }else if(fx_USDTUSDC_Mantissa < 9e17 || fx_USDTUSDC_Mantissa > 11e17){
            return (3e18, 2e18, 4e18);
        }else{
            return (5e18, 4e18, 6e18);
        }
    }

    function updateExtraBorrow(Exp memory fx_USDTUSDC, uint tmpTotalAssetValue, uint targetLevRatio) internal {
        uint targetBorrowUSDT = div_(targetLevRatio*tmpTotalAssetValue/expScale, fx_USDTUSDC);
//        console.log("tmpTotalAssetValue,targetLevRatio=%d,%d",tmpTotalAssetValue,targetLevRatio);
//        console.log("targetBorrowUSDT,borrowBalanceUSDT=%d,%d",targetBorrowUSDT,borrowBalanceUSDT);
        if(targetBorrowUSDT > borrowBalanceUSDT){
            extraBorrowDemand = targetBorrowUSDT - borrowBalanceUSDT;
            extraBorrowSupply = 0;
        }else{
            extraBorrowDemand = 0;
            extraBorrowSupply = borrowBalanceUSDT - targetBorrowUSDT;
        }
    }

    function updateBorrowBalances(uint fxToUse, uint newBorrowBalanceUSDT) internal {
        borrowBalanceUSDT = newBorrowBalanceUSDT;
        borrowBalanceUSDC = newBorrowBalanceUSDT * fxToUse / expScale;
    }

    function releverage(uint newBorrowDemand) internal {
        // depToken goes to curve to sell its own USDT to USDC pushing USDC to leverager directly. simple
        uint transFx = depErc20.borrow(newBorrowDemand);
        updateBorrowBalances(transFx, depErc20.getTotalBorrows());  // only 1 borrower, no need to parse in address
    }

    function deleverage(Exp memory fx_USDTUSDC, uint newBorrowSupply, bool isRedeemAll) internal returns (bool) {
        uint amtUSDC = mul_(newBorrowSupply, fx_USDTUSDC);
        if(isRedeemAll){
            amtUSDC = amtUSDC * 105 / 100;  // add 5% buffer
            withdrawUSDCfromCmp(getCmpBalanceInternal());  // taking out all we have
        }else{
            uint cashOnBook = getCashExReserves();
            if(amtUSDC > cashOnBook){   // we still have cash in wallet, may not need to go to compound
                uint amtUSDCmissing = amtUSDC - cashOnBook;
                // need to go to compound to get the USDC
                uint compoundBalance = getCmpBalanceInternal();
                if(compoundBalance > (amtUSDCmissing + extraUSDC)){
                    withdrawUSDCfromCmp(amtUSDCmissing + extraUSDC);
                }else{
                    withdrawUSDCfromCmp(compoundBalance);  // taking out all we have, but may not be enough still!
                }
            }
        }
        // levToken goes to curve to sell its USDC to USDT pushing USDT to depositor directly
        uint latestCashOnBook = getCashExReserves();
        uint finalRepayAmount;
        if(latestCashOnBook >= amtUSDC){ // normal case
            finalRepayAmount = changeUSDC2USDT(amtUSDC, 0, address(depErc20));
//            console.log("changed %d usdc into %d usdt",amtUSDC,finalRepayAmount);
            uint transFx = amtUSDC * expScale / finalRepayAmount;
            // we accrueInterest & update the ledgers in depErc20 after the transfer!
            depErc20.repayBorrow(finalRepayAmount, false);
            updateBorrowBalances(transFx, depErc20.getTotalBorrows());  // only 1 borrower, no need to parse in address
        }else{
            finalRepayAmount = changeUSDC2USDT(latestCashOnBook, 0, address(depErc20)); // best efforts
//            console.log("(insufficient) changed %d usdc into %d usdt",latestCashOnBook,finalRepayAmount);
            uint transFx = latestCashOnBook * expScale / finalRepayAmount;
            if(isRedeemAll){
//                console.log("liquidation during deleverage, nav -> 0");
                uint depTotalBorrows = depErc20.getTotalBorrows();
                if(depTotalBorrows > finalRepayAmount){ // insufficient, record how much owed
                    updateBorrowBalances(transFx, depTotalBorrows - finalRepayAmount);
                }else{
                    updateBorrowBalances(transFx, 0); // repaid too much, deptoken will push back extra, and zero its totalBorrows
                }
                depErc20.repayBorrow(finalRepayAmount, true);
                return true;    // liquidation triggered
            }else{
                // we accrueInterest & update the ledgers in depErc20 after the transfer!
                depErc20.repayBorrow(finalRepayAmount, false);
                updateBorrowBalances(transFx, depErc20.getTotalBorrows());  // only 1 borrower, no need to parse in address
            }
        }
        return false;
    }

    function deleverageAll() internal returns (bool) {
//        console.log("deleverageAll triggered!");
        uint cashOnBook = getCashExReserves();
        // need to go to compound to get the USDC
        uint compoundBalance = getCmpBalanceInternal();
//        console.log("cashOnBook,compoundBalance=%d,%d", cashOnBook, compoundBalance);
        if(compoundBalance > 0) {
            withdrawUSDCfromCmp(compoundBalance);  // taking out all we have
        }
        cashOnBook = getCashExReserves();   // query again, since withdrawal from cmp costs gas. this now includes true amt withdrawn from cmp
        // levToken goes to curve to sell all its USDC to USDT pushing USDT to depositor directly
        if(cashOnBook > 0){
            uint finalRepayAmount = changeUSDC2USDT(cashOnBook, 0, address(depErc20));
//            console.log("changed %d usdc into %d usdt",cashOnBook,finalRepayAmount);
            uint transFx = cashOnBook * expScale / finalRepayAmount;
            // we accrueInterest & update the ledgers in depErc20 after the transfer!
            uint origBorrowBalanceUSDT = depErc20.getTotalBorrowsAfterAccrueInterest();    // hasnt taken into account the repayment above yet
            extraBorrowDemand = 0;
            extraBorrowSupply = 0;
//            console.log("finalRepayAmount,origBorrowBalanceUSDT=%d,%d", finalRepayAmount, origBorrowBalanceUSDT);
            if(origBorrowBalanceUSDT > finalRepayAmount){
                updateBorrowBalances(transFx, origBorrowBalanceUSDT - finalRepayAmount);  // record in borrowBalanceUSDT the bad debt
                depErc20.repayBorrow(finalRepayAmount, true);
                updateStats(false, 0, 0, 0);
                tensorpricer._setMintPausedLev(address(this), true);
                tensorpricer._setRedeemPausedLev(address(this), true);
            }else{  // enough to pay
                updateBorrowBalances(transFx, 0);
                depErc20.repayBorrow(finalRepayAmount, false);
                updateStats(true, 0, 0, 0);
                return false;
            }
        }
        return true;
    }

    function checkRebalanceExt() external view returns (checkRebalanceRes memory) {
        return checkRebalance(2, 0);
    }

    function checkRebalance(uint callingSrc, uint tmpRedeemAmountInUSDC) internal view returns (checkRebalanceRes memory) {
        uint fx_USDTUSDC_Mantissa = tensorpricer.getFx('USDTUSDC');
        (uint targetLevRatio, uint releverageTrigger, uint deleverageTrigger) = refreshTargetLevRatio(fx_USDTUSDC_Mantissa);
        Exp memory fx_USDTUSDC = Exp({mantissa: fx_USDTUSDC_Mantissa});
        
        //uint fxmantissa = fx_USDTUSDC.mantissa;
        //console.log("fx,",fxmantissa);
        //console.log("checkrebalance,%d,%d,%d",targetLevRatio,releverageTrigger,deleverageTrigger);
        if(callingSrc==0){   // mint. new USDC already in
            uint tmpBorrowBalanceUSDC = mul_(borrowBalanceUSDT, fx_USDTUSDC);
            uint tmpBalanceUSDC = getCashExReserves() + getCmpBalanceInternal();
            if(tmpBalanceUSDC > tmpBorrowBalanceUSDC){
                uint tmpTotalAssetValue = tmpBalanceUSDC - tmpBorrowBalanceUSDC;
                uint tmpLevRatio = tmpBorrowBalanceUSDC*expScale / tmpTotalAssetValue;
                
                if(tmpLevRatio < releverageTrigger){    // need to leverage up
                    return checkRebalanceRes({res:1, targetLevRatio:targetLevRatio, tmpBorrowBalanceUSDC:tmpBorrowBalanceUSDC, tmpTotalAssetValue:tmpTotalAssetValue, tmpLevRatio:tmpLevRatio});
                }else if(tmpLevRatio > deleverageTrigger){
                    return checkRebalanceRes({res:2, targetLevRatio:targetLevRatio, tmpBorrowBalanceUSDC:tmpBorrowBalanceUSDC, tmpTotalAssetValue:tmpTotalAssetValue, tmpLevRatio:tmpLevRatio});
                }else{  //no changes
                    return checkRebalanceRes({res:0, targetLevRatio:targetLevRatio, tmpBorrowBalanceUSDC:tmpBorrowBalanceUSDC, tmpTotalAssetValue:tmpTotalAssetValue, tmpLevRatio:tmpLevRatio});
                }
            }else{
                return checkRebalanceRes({res:3, targetLevRatio:targetLevRatio, tmpBorrowBalanceUSDC:tmpBorrowBalanceUSDC, tmpTotalAssetValue:0, tmpLevRatio:0});
            }
        }else if (callingSrc==1){  // redeem. USDC NOT transferred out yet
            if(totalSupply > 0){
                //console.log("getCashExReserves=",getCashExReserves());
                //console.log("getCmpBalanceInternal=",getCmpBalanceInternal());
                //console.log("tmpRedeemAmountInUSDC=",tmpRedeemAmountInUSDC);
                uint tmpBalanceUSDC = getCashExReserves() + getCmpBalanceInternal() - tmpRedeemAmountInUSDC;
                //console.log("tmpBalanceUSDC=",tmpBalanceUSDC);

                //console.log("borrowBalanceUSDT=",borrowBalanceUSDT);
                //console.log("fx_USDTUSDC=",fx_USDTUSDC_Mantissa);
                uint tmpBorrowBalanceUSDC = mul_(borrowBalanceUSDT, fx_USDTUSDC);
                //console.log("tmpBorrowBalanceUSDC=",tmpBorrowBalanceUSDC);
                
                if(tmpBalanceUSDC > tmpBorrowBalanceUSDC){
                    uint tmpTotalAssetValue = tmpBalanceUSDC - tmpBorrowBalanceUSDC;
                    uint tmpLevRatio = tmpBorrowBalanceUSDC*expScale / tmpTotalAssetValue;
//                    console.log("tmpBalanceUSDC,tmpBorrowBalanceUSDC=%d,%d",tmpBalanceUSDC,tmpBorrowBalanceUSDC);
                    if(tmpLevRatio > deleverageTrigger){ // need to work out a new nav
                        return checkRebalanceRes({res:2, targetLevRatio:targetLevRatio, tmpBorrowBalanceUSDC:tmpBorrowBalanceUSDC, tmpTotalAssetValue:tmpTotalAssetValue, tmpLevRatio:tmpLevRatio});
                    }else if(tmpLevRatio < releverageTrigger){
                        return checkRebalanceRes({res:1, targetLevRatio:targetLevRatio, tmpBorrowBalanceUSDC:tmpBorrowBalanceUSDC, tmpTotalAssetValue:tmpTotalAssetValue, tmpLevRatio:tmpLevRatio});
                    }else{  // no changes, only redeemAmount*nav USDC will be transferred out
                        return checkRebalanceRes({res:0, targetLevRatio:targetLevRatio, tmpBorrowBalanceUSDC:tmpBorrowBalanceUSDC, tmpTotalAssetValue:tmpTotalAssetValue, tmpLevRatio:tmpLevRatio});
                    }
                }else{
                    return checkRebalanceRes({res:3, targetLevRatio:targetLevRatio, tmpBorrowBalanceUSDC:tmpBorrowBalanceUSDC, tmpTotalAssetValue:0, tmpLevRatio:0});
                }
            }else{
                return checkRebalanceRes({res:0, targetLevRatio:0, tmpBorrowBalanceUSDC:0, tmpTotalAssetValue:0, tmpLevRatio:0});
            }
        }else{  // regular check due to fx
            if(totalSupply > 0){
                uint tmpBorrowBalanceUSDC = mul_(borrowBalanceUSDT, fx_USDTUSDC);
                uint tmpBalanceUSDC = getCashExReserves() + getCmpBalanceInternal();
                if(tmpBalanceUSDC > tmpBorrowBalanceUSDC){
                    uint tmpTotalAssetValue = tmpBalanceUSDC - tmpBorrowBalanceUSDC;
                    uint tmpLevRatio = tmpBorrowBalanceUSDC*expScale / tmpTotalAssetValue;

                    if(tmpLevRatio < releverageTrigger){    // need to leverage up
                        return checkRebalanceRes({res:1, targetLevRatio:targetLevRatio, tmpBorrowBalanceUSDC:tmpBorrowBalanceUSDC, tmpTotalAssetValue:tmpTotalAssetValue, tmpLevRatio:tmpLevRatio});
                    }else if(tmpLevRatio > deleverageTrigger){ // need to work out a new nav
                        return checkRebalanceRes({res:2, targetLevRatio:targetLevRatio, tmpBorrowBalanceUSDC:tmpBorrowBalanceUSDC, tmpTotalAssetValue:tmpTotalAssetValue, tmpLevRatio:tmpLevRatio});
                    }else{
                        return checkRebalanceRes({res:0, targetLevRatio:targetLevRatio, tmpBorrowBalanceUSDC:tmpBorrowBalanceUSDC, tmpTotalAssetValue:tmpTotalAssetValue, tmpLevRatio:tmpLevRatio});
                    }
                }else{
                    return checkRebalanceRes({res:3, targetLevRatio:targetLevRatio, tmpBorrowBalanceUSDC:tmpBorrowBalanceUSDC, tmpTotalAssetValue:0, tmpLevRatio:0});
                }
            }else{
                return checkRebalanceRes({res:0, targetLevRatio:0, tmpBorrowBalanceUSDC:0, tmpTotalAssetValue:0, tmpLevRatio:0});
            }
        }
    }

    function doRebalanceExt() public {//nonReentrant {
        checkRebalanceRes memory myRes = checkRebalance(2, 0);
        doRebalance(2, myRes, 0);
    }

    function doRebalance(uint callingSrc, checkRebalanceRes memory myRes, uint redeemTokensIn) internal {//nonReentrant {
        uint fx_USDTUSDC_Mantissa = tensorpricer.getFx('USDTUSDC');
        Exp memory fx_USDTUSDC = Exp({mantissa: fx_USDTUSDC_Mantissa});
        targetLevRatio = myRes.targetLevRatio;  // if we go to do reBalance, update it, else needs to pay gas
        if(myRes.res == 3){ // need to clear all positions
            if(deleverageAll()){
                netAssetValue = 0;
            }else{
                updateNetAssetValue(borrowBalanceUSDC, 0);
            }
        }else{
            if(callingSrc==0){   // mint. new USDC already in
                if(myRes.res==1){    // need to leverage up
                    updateExtraBorrow(fx_USDTUSDC, myRes.tmpTotalAssetValue, myRes.targetLevRatio);
                    // releverage
                    if(extraBorrowDemand > 0) {
                        releverage(extraBorrowDemand);
                    }else{
                        borrowBalanceUSDC = myRes.tmpBorrowBalanceUSDC;
                    }
                    updateStats(true, 0, 0, 0);
                }else if(myRes.res==2){
                    updateExtraBorrow(fx_USDTUSDC, myRes.tmpTotalAssetValue, myRes.targetLevRatio);
                    // deleverage
                    if(extraBorrowSupply > 0){
                        deleverage(fx_USDTUSDC, extraBorrowSupply, false);
                    }else{
                        borrowBalanceUSDC = myRes.tmpBorrowBalanceUSDC;
                    }
                    updateStats(true, 0, 0, 0);
                }else if(myRes.res==0){  //no changes. do NOT expect deleverage here
                    borrowBalanceUSDC = myRes.tmpBorrowBalanceUSDC;
                    updateStats(false, myRes.tmpTotalAssetValue, myRes.tmpLevRatio, 0);
                    extraBorrowDemand = 0;
                    extraBorrowSupply = 0;
                }
            }else if (callingSrc==1){  // redeem. USDC NOT transferred out yet
                if(myRes.res==2){ // need to work out a new nav
                    updateExtraBorrow(fx_USDTUSDC, myRes.tmpTotalAssetValue, myRes.targetLevRatio);
                    // deleverage
                    if(extraBorrowSupply > 0){
                        deleverage(fx_USDTUSDC, extraBorrowSupply, false);
                    }else{
                        borrowBalanceUSDC = myRes.tmpBorrowBalanceUSDC;
                    }
                    updateStats(true, 0, 0, redeemTokensIn);
                }else if(myRes.res==1){
                    updateExtraBorrow(fx_USDTUSDC, myRes.tmpTotalAssetValue, myRes.targetLevRatio);
                    // releverage
                    if(extraBorrowDemand > 0) {
                        releverage(extraBorrowDemand);
                    }else{
                        borrowBalanceUSDC = myRes.tmpBorrowBalanceUSDC;
                    }
                    updateStats(true, 0, 0, redeemTokensIn);
                }else if(myRes.res==0){  // no changes, only redeemAmount*nav USDC will be transferred out
                    borrowBalanceUSDC = myRes.tmpBorrowBalanceUSDC;
                    updateStats(false, myRes.tmpTotalAssetValue, myRes.tmpLevRatio, redeemTokensIn);
                    extraBorrowDemand = 0;
                    extraBorrowSupply = 0;
                }
            }else{  // this is for Keeper. dont come to this function at all if res==0
                if(myRes.res==1){    // need to leverage up
                    updateExtraBorrow(fx_USDTUSDC, myRes.tmpTotalAssetValue, myRes.targetLevRatio);
                    // releverage
                    if(extraBorrowDemand > 0) {
                        releverage(extraBorrowDemand);
                    }else{
                        borrowBalanceUSDC = myRes.tmpBorrowBalanceUSDC;
                    }
                    // only need to do supplyUSDC for callingSrc 2, but not callingSrc 0, 
                    // because callingSrc 0 calls it separately
                    uint currUSDCBalance = getCashExReserves();
                    if(checkCompound(currUSDCBalance)){
                        supplyUSDC(currUSDCBalance - thresholdUSDC);
                    }
                    updateStats(true, 0, 0, 0);
                    updateNetAssetValue(borrowBalanceUSDC, 0);  // again only for callingSrc!=0, coz callingSrc 0 calls it after totalSupply update
                }else if(myRes.res==2){ // need to work out a new nav
                    updateExtraBorrow(fx_USDTUSDC, myRes.tmpTotalAssetValue, myRes.targetLevRatio);
                    // deleverage
                    if(extraBorrowSupply > 0){
                        deleverage(fx_USDTUSDC, extraBorrowSupply, false);
                    }else{
                        borrowBalanceUSDC = myRes.tmpBorrowBalanceUSDC;
                    }
                    updateStats(true, 0, 0, 0);
                    updateNetAssetValue(borrowBalanceUSDC, 0);
                }
            }
        }
    }

    function redeemAllRebalance() internal returns (uint){
        uint fx_USDTUSDC_Mantissa = tensorpricer.getFx('USDTUSDC');
        Exp memory fx_USDTUSDC = Exp({mantissa: fx_USDTUSDC_Mantissa});
        extraBorrowDemand = 0;
        extraBorrowSupply = borrowBalanceUSDT;
        bool isLiquidate = deleverage(fx_USDTUSDC, extraBorrowSupply, true);    // this takes out everything we have in cmp
        if(isLiquidate){
            updateStats(false, 0, 0, 0);
            netAssetValue = 0;
            tensorpricer._setMintPausedLev(address(this), true);
            tensorpricer._setRedeemPausedLev(address(this), true);
//            console.log("redeemAllRebalance liquidate triggered");
            return 0;
        }else{
            uint currUSDCBalance = getCashExReserves(); // all available cash on the book now
            uint redeemFeeBeforeLevRatio = (redeemFeePC * currUSDCBalance) / expScale;
            uint redeemFee = (targetLevRatio * redeemFeeBeforeLevRatio) / expScale;
            
//            console.log("redeemFee =",redeemFee);
            if(currUSDCBalance <= redeemFee){
                redeemFee = currUSDCBalance;
//                console.log("currUSDCBalance not enough. redeemFee reduced to =",redeemFee);
                currUSDCBalance = 0;
            }else{
                currUSDCBalance = currUSDCBalance - redeemFee;
            }

            levReserve = levReserve + redeemFee;
            updateStats(false, 0, 0, 0);
            netAssetValue = initialNetAssetValueMantissa;

            return currUSDCBalance;
        }
    }

    /**
     * @notice check if sufficient USDC to push to compound
     * @dev
     * @return if true, then transfer
     */
    function checkCompound(uint currUSDCBalance) internal pure returns (bool) {
        if(currUSDCBalance > minTransferAmtUSDC+thresholdUSDC){
            return true;
        }else{
            return false;
        }
    }

    function checkLeveragibility(Exp memory fx_USDTUSDC, uint mintAmount) internal view returns (bool) {
        uint tmpBorrowBalanceUSDC = mul_(borrowBalanceUSDT, fx_USDTUSDC);
        uint availCash = getCashExReserves() + getCmpBalanceInternal();
        uint tmpLevRatio = 0;
//        console.log("tmpBorrowBalanceUSDC",tmpBorrowBalanceUSDC);
//        console.log("availCash",availCash);
        if(availCash > tmpBorrowBalanceUSDC){   // minting may still be possible, depending on unborrowedCashAtDep > loanNeeded
            uint tmpTotalAssetValue = availCash - tmpBorrowBalanceUSDC;
            tmpLevRatio = tmpBorrowBalanceUSDC*expScale / tmpTotalAssetValue;
//            console.log("tmpLevRatio",tmpLevRatio);
        }else{  // both availCash & tmpBorrowBalanceUSDC are zero
            (uint initLevRatio,,) = refreshTargetLevRatio(fx_USDTUSDC.mantissa);
            tmpLevRatio = initLevRatio;
        }
        uint loanNeeded = tmpLevRatio * div_(mintAmount, fx_USDTUSDC) / expScale;
        uint unborrowedCashAtDep = depErc20.getUnborrowedUSDTBalance();
        
//        console.log("loanNeeded",loanNeeded);
//        console.log("unborrowedCashAtDep",unborrowedCashAtDep);
        return unborrowedCashAtDep > loanNeeded;
    }

    function payback(address minter, uint _totalAssetValue) internal {
        if(_totalAssetValue > 0){
            // this is another undesirable scenario. dont issue new tokens, return as much to minter as possible. stop further mint/redeem
            uint compoundBalance = getCmpBalanceInternal();
            if(compoundBalance > 0){
                withdrawUSDCfromCmp(compoundBalance);  // taking out all we have
            }
            doTransferOut(payable(minter), _totalAssetValue);
//            console.log("return as much as possible,",_totalAssetValue);
            emit Transfer(minter, address(this), 0);
        }
        updateStats(false, 0, 0, 0);
        extraBorrowDemand = 0;
        extraBorrowSupply = 0;
        netAssetValue = 0;
        tensorpricer._setMintPausedLev(address(this), true);
        tensorpricer._setRedeemPausedLev(address(this), true);
    }

    /**
     * @notice User supplies USDC into the market and receives levErc20s in exchange
     * @param mintAmount The amount of USDC to supply
     */
    function mintInternal(uint mintAmount) internal nonReentrant {
        address minter = msg.sender;   //The address of the account which is supplying USDC
        /* Fail if mint not allowed */
        uint allowed = tensorpricer.mintAllowed(address(this), minter);
        if (allowed != 0) {
            revert MintTensorpricerRejection(allowed);
        }

        uint fx_USDTUSDC_Mantissa = tensorpricer.getFx('USDTUSDC');
        Exp memory fx_USDTUSDC = Exp({mantissa: fx_USDTUSDC_Mantissa});
//        console.log("mint fx=",fx_USDTUSDC_Mantissa);

        //require(checkLeveragibility(fx_USDTUSDC, mintAmount), "not enough deposit to create");
        if(!checkLeveragibility(fx_USDTUSDC, mintAmount)){
//            console.log("not enough deposit to create");
            return;
        }
        // require(checkLeveragibility(fx_USDTUSDC, mintAmount), "not enough deposit to create");
        // start executing transfers according to the completed calculations

        /*
         *  We call `doTransferIn` for the minter and the mintAmount.
         *  Note: The levErc20 can only handle USDC!
         *  `doTransferIn` reverts if anything goes wrong, since we can't be sure if side-effects occurred. 
         *  The function returns the amount actually transferred, in case of a fee. 
         *  On success, the levErc20 holds an additional `actualMintAmount` of cash.
         *  getCash() will reflect this transfer
         */
        uint actualMintAmount = doTransferIn(minter, mintAmount);

        uint mintTokens;
        uint navAfterTradeMantissa;
        // update a tmp new nav
        Exp memory tmpNav;
        uint tmpBorrowBalanceUSDC = mul_(borrowBalanceUSDT, fx_USDTUSDC);
        uint tmpNavMantissa = calcNetAssetValue(tmpBorrowBalanceUSDC, actualMintAmount);
        bool skipRebalance = false;
        if(tmpNavMantissa == 0){
            if(deleverageAll()){
                return;
            }
            skipRebalance = true;
        }
        
        tmpNav = Exp({mantissa: takePerfFee(tmpNavMantissa)});

        /*
        *  calculate the number of levErc20s to be minted:
        *  mintTokens = actualMintAmount / netassetvalue
        */
        
        checkRebalanceRes memory myRes;
        if(!skipRebalance){
            myRes = checkRebalance(0, 0);
//            console.log("checkRebalance res:",myRes.res);
//            console.log("checkRebalance targetLevRatio:",myRes.targetLevRatio);
            doRebalance(0, myRes, 0);    // rebalance will have been done if needed
        }
        
        if(!skipRebalance && myRes.res==0){   // no rebalances
            mintTokens = div_(actualMintAmount, tmpNav);
        }else{  // use rebalance fx
            // totalassetvalue already updated by now
            uint _totalSupply = totalSupply;
            if(_totalSupply == 0){
                navAfterTradeMantissa = initialNetAssetValueMantissa;
                mintTokens = div_(actualMintAmount, Exp({mantissa: navAfterTradeMantissa}));
            }else{
                uint _totalAssetValue = totalAssetValue;
                if(_totalAssetValue > actualMintAmount){
                    navAfterTradeMantissa = (_totalAssetValue - actualMintAmount) * expScale / _totalSupply;
                    mintTokens = div_(actualMintAmount, Exp({mantissa: navAfterTradeMantissa}));
                }else{
                    payback(minter, _totalAssetValue);
                    return;
                }
            }
        }

        uint currUSDCBalance = getCashExReserves();
        if(checkCompound(currUSDCBalance)){
            supplyUSDC(currUSDCBalance - thresholdUSDC);
        }
        
        /*
         * We calculate the new total supply of levErc20s and minter token balance, checking for overflow:
         *  totalSupplyNew = totalSupply + mintTokens
         *  accountTokensNew = accountTokens[minter] + mintTokens
         * And write them into storage
         */
        totalSupply = totalSupply + mintTokens;
        accountTokens[minter] = accountTokens[minter] + mintTokens;
        // once totalSupply updated, we update nav
        updateNetAssetValue(borrowBalanceUSDC, 0);
        /* We emit a Mint event, and a Transfer event */
        emit Mint(minter, actualMintAmount, mintTokens, netAssetValue);
        emit Transfer(address(this), minter, mintTokens);
    }

    /**
     * @notice Sender redeems levErc20s in exchange for the underlying asset
     * @dev
     * @param redeemTokens The number of levErc20s to redeem into underlying
     */
    function redeemInternal(uint redeemTokensIn) internal nonReentrant {
        address payable redeemer = payable(msg.sender);

        /* Fail if redeem not allowed */
        uint allowed = tensorpricer.redeemAllowed(address(this), redeemer, redeemTokensIn);
        if (allowed != 0) {
            revert RedeemTensorpricerRejection(allowed);
        }

        uint fx_USDTUSDC_Mantissa = tensorpricer.getFx('USDTUSDC');
        //console.log("redeem fx=",fx_USDTUSDC_Mantissa);

        // work out a tmpNetAssetValue here
        uint tmpBorrowBalanceUSDC = mul_(borrowBalanceUSDT, Exp({mantissa: fx_USDTUSDC_Mantissa}));
        //console.log("tmpBorrowBalanceUSDC=%d",tmpBorrowBalanceUSDC);
        uint tmpNetAssetValue = calcNetAssetValue(tmpBorrowBalanceUSDC, 0);
        (uint targetLevRatio,,) = refreshTargetLevRatio(fx_USDTUSDC_Mantissa);

        /*
        *  We calculate the nav and the amount of underlying to be redeemed:
        *  redeemTokens = redeemTokensIn
        *  redeemAmount = redeemTokensIn x nav
        */
        
        uint updatedTmpNavMantissa = takePerfFee(tmpNetAssetValue);  // take fees first before calculating the latest redeemable nav
        uint tmpRedeemAmount = mul_ScalarTruncate(Exp({mantissa: updatedTmpNavMantissa}), redeemTokensIn);

        uint trueRedeemAmount;
        if(totalSupply == redeemTokensIn){  // redeem all, special logic
            trueRedeemAmount = redeemAllRebalance();
            totalSupply = 0;
        }else{
            redeemAmountInUSDC = 0; // let do rebalance update it
            if(tmpNetAssetValue > 0){
                doRebalance(1, checkRebalance(1, tmpRedeemAmount), redeemTokensIn);    // rebalance will have been done if needed
            }else{
                if(deleverageAll()){
                    emit Redeem(redeemer, 0, redeemTokensIn, netAssetValue);
                    return;
                }
            }
        
            // then we use the new latest (but not final) nav (updated in doRebalance) to work out how much to pay client
            // we dont subtract redeemAmount, nor reduce totalSupply when computing this new latest nav
            uint redeemFeeBeforeLevRatio = (redeemFeePC * redeemAmountInUSDC) / expScale;
            uint redeemFee = (targetLevRatio * redeemFeeBeforeLevRatio) / expScale;
            
//            console.log("redeemFee =",redeemFee);

            trueRedeemAmount = redeemAmountInUSDC - redeemFee;
            levReserve = levReserve + redeemFee;

            uint currUSDCBalance = getCashExReserves();
            if (redeemAmountInUSDC > currUSDCBalance) { // need to get some funds from Compound
                uint amtNeeded = redeemAmountInUSDC - currUSDCBalance;
                uint compoundBalance = getCmpBalanceInternal();
                if(compoundBalance > (amtNeeded + extraUSDC)){
                    withdrawUSDCfromCmp(amtNeeded + extraUSDC);
                }else{
                    withdrawUSDCfromCmp(compoundBalance);  // taking out all we have
                }
            }
            totalSupply = totalSupply - redeemTokensIn;
            updateNetAssetValue(borrowBalanceUSDC, trueRedeemAmount); // transferOut NOT done yet!
        }
        /*
        * We write the previously calculated values into storage.
        *  Note: Avoid token reentrancy attacks by writing reduced supply before external transfer.
        */
        accountTokens[redeemer] = accountTokens[redeemer] - redeemTokensIn;
        /*
        * We invoke doTransferOut for the redeemer and the redeemAmount.
        *  On success, the depErc20 has redeemAmount less of cash.
        *  doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
        */
        if(trueRedeemAmount > 0){
            doTransferOut(redeemer, trueRedeemAmount);
            /* We emit a Transfer event, and a Redeem event */
            emit Transfer(redeemer, address(this), redeemTokensIn);
            emit Redeem(redeemer, trueRedeemAmount, redeemTokensIn, netAssetValue);
        }else{
            emit Redeem(redeemer, 0, redeemTokensIn, netAssetValue);
        }
    }

    /**
     * @notice depErc20 user forces levToken to repay. User sells USDC to get USDT
     * @param repayAmountInUSDT The amt of USDT needed
     * @return net proceeds. it goes directly to the depToken
     */
    function forceRepayInternal(uint repayAmountInUSDT) internal nonReentrant returns (uint) {
        // need to determine how much USDC is needed. do as the oracle says
        Exp memory fx_USDTUSDC = Exp({mantissa: tensorpricer.getFx('USDTUSDC')});
        uint amtUSDC = mul_(repayAmountInUSDT, fx_USDTUSDC);
        amtUSDC = (amtUSDC * 105) / 100;    // we add 5% as buffer
        uint availCash = getCashExReserves();
        if(amtUSDC > availCash){
            uint amtUSDCmissing = amtUSDC - availCash; // we still have cash in wallet
            // need to go to compound to get the USDC
            uint compoundBalance = getCmpBalanceInternal();
            if(compoundBalance > (amtUSDCmissing + extraUSDC)){
                withdrawUSDCfromCmp(amtUSDCmissing + extraUSDC);
            }else{
                withdrawUSDCfromCmp(compoundBalance);  // taking out all we have
            }
        }
        uint netForceRepayAmount = changeUSDC2USDT(amtUSDC, 0, address(depErc20));
//        console.log("changed %d usdc into %d usdt",amtUSDC,netForceRepayAmount);
        return netForceRepayAmount;
    }

    function updateLedgerInternal() internal {
        updateBorrowBalances(tensorpricer.getFx('USDTUSDC'), depErc20.getTotalBorrows());   // no need to use transFx even tho traded, becoz no lev mint/redeem
        updateStats(true, 0, 0, 0);
        updateNetAssetValue(borrowBalanceUSDC, 0);
    }

    /**
     * @notice push a portion of profit to reserves 
     */
    function takePerfFee(uint navMantissa) internal returns (uint) {
        uint perfFee = 0;
        if(navMantissa > hisHighNav && totalSupply > 0){
//            console.log("netnav,hishighnav = %d,%d",navMantissa,hisHighNav);
            uint gain = (navMantissa-hisHighNav) * totalSupply / expScale;    // gain same unit as totalSupply, 1e6
            hisHighNav = navMantissa;
            perfFee = gain * perfPC / expScale;
            uint tmpTotalAssetValue = navMantissa * totalSupply / expScale;
            console.log("tmpTotalAssetValue,perffee,gain = %d,%d,%d",tmpTotalAssetValue,perfFee,gain);
            // by definition, tmpTotalAssetValue >= perfFee
            levReserve = levReserve + perfFee;
            uint updatedNavMantissa = (tmpTotalAssetValue - perfFee)*expScale / totalSupply;  // no need to minus redeemFee here. it's taken away in the final transfer out amt
            console.log("updatedNavMantissa = ",updatedNavMantissa);
            return updatedNavMantissa;  // only used in minting to determine how many new deptokens to issue
        }else{
            return navMantissa;
        }
    }

    /*** Admin Functions ***/

    /**
      * @notice Begins transfer of admin rights. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
      * @dev Admin function to begin change of admin. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
      * @param newPendingAdmin New pending admin.
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setPendingAdmin(address payable newPendingAdmin) override external returns (uint) {
        // Check caller = admin
        if (msg.sender != admin) {
            revert SetPendingAdminOwnerCheck();
        }

        // Save current value, if any, for inclusion in log
        address oldPendingAdmin = pendingAdmin;

        // Store pendingAdmin with value newPendingAdmin
        pendingAdmin = newPendingAdmin;

        // Emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin)
        emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);

        return NO_ERROR;
    }

    /**
      * @notice Accepts transfer of admin rights. msg.sender must be pendingAdmin
      * @dev Admin function for pending admin to accept role and update admin
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _acceptAdmin() override external returns (uint) {
        // Check caller is pendingAdmin and pendingAdmin ≠ address(0)
        if (msg.sender != pendingAdmin || msg.sender == address(0)) {
            revert AcceptAdminPendingAdminCheck();
        }

        // Save current values for inclusion in log
        address oldAdmin = admin;
        address oldPendingAdmin = pendingAdmin;

        // Store admin with value pendingAdmin
        admin = pendingAdmin;

        // Clear the pending value
        pendingAdmin = payable(address(0));

        emit NewAdmin(oldAdmin, admin);
        emit NewPendingAdmin(oldPendingAdmin, pendingAdmin);

        return NO_ERROR;
    }

    /**
     * @notice Accrues interest and reduces reserves by transferring to admin
     * @param reduceAmount Amount of reduction to reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _reduceReserves(uint reduceAmount) override external nonReentrant returns (uint) {
        // _reduceReservesFresh emits reserve-reduction-specific logs on errors, so we don't need to.
        return _reduceReservesFresh(reduceAmount);
    }

    /**
     * @notice Reduces reserves by transferring to admin
     * @dev Requires fresh interest accrual
     * @param reduceAmount Amount of reduction to reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _reduceReservesFresh(uint reduceAmount) internal returns (uint) {
        // totalReserves - reduceAmount
        uint levReserveNew;

        // Check caller is admin
        if (msg.sender != admin) {
            revert ReduceReservesAdminCheck();
        }

        // Fail gracefully if protocol has insufficient underlying cash
        if (getCashPrior() < reduceAmount) {
            revert ReduceReservesCashNotAvailable();
        }

        // Check reduceAmount ≤ reserves[n] (totalReserves)
        if (reduceAmount > levReserve) {
            revert ReduceReservesCashValidation();
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        levReserveNew = levReserve - reduceAmount;

        // Store reserves[n+1] = reserves[n] - reduceAmount
        levReserve = levReserveNew;

        // doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
        doTransferOut(admin, reduceAmount);

        emit ReservesReduced(admin, reduceAmount, levReserveNew);

        return NO_ERROR;
    }

    /**
      * @notice Sets a new tensorpricer for the market
      * @dev Admin function to set a new tensorpricer
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setTensorpricer(TensorpricerInterface newTensorpricer) override public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            revert SetTensorpricerOwnerCheck();
        }

        TensorpricerInterface oldTensorpricer = tensorpricer;
        // Ensure invoke tensorpricer.isTensorpricer() returns true
        require(newTensorpricer.isTensorpricer(), "marker method returned false");

        // Set market's tensorpricer to newTensorpricer
        tensorpricer = newTensorpricer;

        // Emit NewTensorpricer(oldTensorpricer, newTensorpricer)
        emit NewTensorpricer(oldTensorpricer, newTensorpricer);

        return NO_ERROR;
    }

    function getCashExReserves() internal view returns (uint) {
        uint allCash = getCashPrior();
        if(allCash > levReserve){
            return allCash - levReserve;
        }else{
            return 0;
        }
    }
    /*** Safe Token ***/

    /**
     * @notice Gets balance of this contract in terms of the underlying
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying owned by this contract
     */
    function getCashPrior() virtual internal view returns (uint);

    /**
     * @dev Performs a transfer in, reverting upon failure. Returns the amount actually transferred to the protocol, in case of a fee.
     *  This may revert due to insufficient balance or insufficient allowance.
     */
    function doTransferIn(address from, uint amount) virtual internal returns (uint);

    /**
     * @dev Performs a transfer out, ideally returning an explanatory error code upon failure rather than reverting.
     *  If caller has not called checked protocol's balance, may revert due to insufficient cash held in the contract.
     *  If caller has checked protocol's balance, and verified it is >= amount, this should not revert in normal conditions.
     */
    function doTransferOut(address payable to, uint amount) virtual internal;

    /*** Reentrancy Guard ***/

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true; // get a gas-refund post-Istanbul
    }
}
