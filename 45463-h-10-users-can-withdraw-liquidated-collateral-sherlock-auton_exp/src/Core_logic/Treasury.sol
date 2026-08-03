// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "../interface/IUSDa.sol";
import {State, IABONDToken} from "../interface/IAbond.sol";
import "../interface/IBorrowing.sol";
import "../interface/ITreasury.sol";
import "../interface/IGlobalVariables.sol";
import "../interface/IonicInterface.sol";
import "../interface/IWETH9.sol";
import "../interface/IWrsETH.sol";

/**
 * @title Treasury contract
 * @author Autonomint
 * @notice There is no user interaction function in this contract except view functions
 * All the borrow deposit details and all the funds in cds,borrow are stored in this contract
 * - In this contract
 *   # The collateral is deposited to external protocols
 *   # Withdrew from external protocol
 *   # Approve functions to transfer funds
 * @dev All the functions have modifier.
 */

contract Treasury is
    ITreasury,
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable
{
    IBorrowing private borrow; // Borrowing instance
    IUSDa public usda; // USDa instance
    IABONDToken private abond; // ABOND instance
    IERC20 private usdt; // USDT instance
    IWETH9 private WETH; // WETH instance
    address private cdsContract; // cds contract address
    address private borrowLiquidation; // borrow liquiation contract address
    // Get depositor details by address
    mapping(address depositor => BorrowerDetails) public borrowing; // borrower details mapping
    //Get external protocol deposit details by protocol name (enum)
    mapping(Protocol => ProtocolDeposit) private protocolDeposit; // external protocol details mapping
    uint256 public totalVolumeOfBorrowersAmountinWei; // Total collateral depsoited in ETH
    //eth vault value
    uint256 public totalVolumeOfBorrowersAmountinUSD; // Total collateral deposited in USD
    uint128 public noOfBorrowers; // No of borrowers in this chain
    uint256 private totalInterest; // total interest gained from lending
    uint256 private totalInterestFromLiquidation;
    uint256 public abondUSDaPool; // usda abond pool value
    uint256 private interestFromExternalProtocolDuringLiquidation; // interest from ext protocol till liquidation
    uint128 private PRECISION;
    uint256 private CUMULATIVE_PRECISION;
    uint256 public usdaGainedFromLiquidation; // USDa gained during liquidation
    uint256 private usdaCollectedFromCdsWithdraw; // 10% deducted usda from cds users during withdraw
    uint256 private liquidatedCollateralCollectedFromCdsWithdraw;
    IGlobalVariables private globalVariables; // Global variables instance
    uint256 private yieldsFromLrts; // Yields from LRTs during withdraw
    uint256 private yieldsFromLiquidatedLrts; // Yields from LRTs which are liquidated
    mapping(IBorrowing.AssetName => uint256 collateralAmountDeposited) public depositedCollateralAmountInWei; // Collaterals deposited in this chain
    mapping(IBorrowing.AssetName => uint256 collateralAmountDepositedInUsd) private depositedCollateralAmountInUsd; // Collaterals deposited in this chain in usd
    uint256 public totalVolumeOfBorrowersAmountLiquidatedInWei; // Total collateral liquidated in ETH value
    mapping(IBorrowing.AssetName => uint256 collateralAmountLiquidated) public liquidatedCollateralAmountInWei; // Collaterals deposited in this chain
    address odosRouterV2;
    IonicInterface ionic;

    /**
     * @dev initialize function to initialize the contract
     * @param borrowingAddress borrowingAddress
     * @param usdaAddress usdaAddress
     * @param abondAddress abondAddress
     * @param cdsContractAddress cdsContractAddress
     * @param borrowLiquidationAddress borrowLiquidationAddress
     * @param usdtAddress usdtAddress
     * @param globalVariablesAddress globalVariablesAddress
     */
    function initialize(
        address borrowingAddress,
        address usdaAddress,
        address abondAddress,
        address cdsContractAddress,
        address borrowLiquidationAddress,
        address usdtAddress,
        address globalVariablesAddress
    ) public initializer {
        address[7] memory addresses = [
            borrowingAddress,
            usdaAddress,
            abondAddress,
            cdsContractAddress,
            borrowLiquidationAddress,
            usdtAddress,
            globalVariablesAddress
        ];

        for (uint8 i = 0; i < 5; i++) {
            if (addresses[i] == address(0) || !isContract(addresses[i])) revert Treasury_CantBeEOAOrZeroAddress(addresses[i]);
        }

        // intialize the owner of the contract
        __Ownable_init(msg.sender);
        // Initialize the uups proxy contract
        __UUPSUpgradeable_init();
        cdsContract = cdsContractAddress;
        borrow = IBorrowing(borrowingAddress);
        usda = IUSDa(usdaAddress);
        abond = IABONDToken(abondAddress);
        usdt = IERC20(usdtAddress);
        globalVariables = IGlobalVariables(globalVariablesAddress);
        borrowLiquidation = borrowLiquidationAddress;
        PRECISION = 1e18;
        CUMULATIVE_PRECISION = 1e27;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    /**
     * @dev modifier to check whether the caller is one of the core contract or not
     */
    modifier onlyCoreContracts() {
        require(
            msg.sender == address(borrow) ||
            msg.sender == cdsContract ||
            msg.sender == borrowLiquidation ||
            msg.sender == address(globalVariables),
            "This function can only called by Core contracts"
        );
        _;
    }

    /**
     * @dev Function to check if an address is a contract
     * @param account address to check whether the address is an contract address or EOA
     */
    function isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    /**
     * @dev This function takes ethPrice, depositTime parameters to deposit eth into the contract and mint them back the USDa tokens.
     * @param ethPrice get current eth price
     * @param depositTime get unixtime stamp at the time of deposit
     * @param user Borrower address
     * @param assetName Collateral type
     * @param depositingAmount Depositing collateral amount
     **/

    function deposit(
        address user,
        uint128 ethPrice,
        uint64 depositTime,
        IBorrowing.AssetName assetName,
        uint256 depositingAmount
    ) external payable onlyCoreContracts returns (DepositResult memory) {
        uint64 borrowerIndex;
        //check if borrower is depositing for the first time or not
        if (!borrowing[user].hasDeposited) {
            //change borrowerindex to 1
            borrowerIndex = borrowing[user].borrowerIndex = 1;

            //change hasDeposited bool to true after first deposit
            borrowing[user].hasDeposited = true;
            ++noOfBorrowers;
        } else {
            //increment the borrowerIndex for each deposit
            borrowerIndex = ++borrowing[user].borrowerIndex;
        }

        // update total deposited amount of the user
        borrowing[user].depositedAmountInETH += depositingAmount;

        // update deposited amount of the user
        borrowing[user].depositDetails[borrowerIndex].depositedAmountInETH = uint128(depositingAmount);

        depositedCollateralAmountInWei[assetName] += depositingAmount;

        depositedCollateralAmountInUsd[assetName] += (ethPrice * depositingAmount);

        //Total volume of borrowers in USD
        totalVolumeOfBorrowersAmountinUSD += (ethPrice * depositingAmount);

        //Total volume of borrowers in Wei
        totalVolumeOfBorrowersAmountinWei += depositingAmount;

        //Adding depositTime to borrowing struct
        borrowing[user].depositDetails[borrowerIndex].depositedTime = depositTime;

        // Storing current time as renewed time
        borrowing[user].depositDetails[borrowerIndex].optionsRenewedTimeStamp = depositTime;

        //Adding ethprice to struct
        borrowing[user].depositDetails[borrowerIndex].ethPriceAtDeposit = ethPrice;

        // update deposited amount of the deposit in usd
        borrowing[user].depositDetails[borrowerIndex].depositedAmountUsdValue = uint128(depositingAmount) * ethPrice;

        borrowing[user].depositDetails[borrowerIndex].assetName = assetName;

        // If the collateral type is other than ETH, dont deposit to ext protocol
        if (assetName == IBorrowing.AssetName.ETH) {
            uint256 externalProtocolDepositCollateral = ((depositingAmount * 50) / 100);
            // Deposit ETH to ionic
            depositToIonicByUser(externalProtocolDepositCollateral);

            borrowing[user].depositDetails[borrowerIndex].aBondCr = getCumulativeRate(Protocol.Ionic);
        }
        // emit deposit event
        emit Deposit(user, depositingAmount);
        return DepositResult(borrowing[user].hasDeposited, borrowerIndex);
    }

    /**
     * @dev withdraw the deposited collateral
     * @param borrower borrower address
     * @param toAddress adrress to return collateral
     * @param amount amount of collateral to return
     * @param exchangeRate current exchanga rate of the deposited collateral
     * @param index deposit index
     */
    function withdraw(
        address borrower,
        address toAddress,
        uint256 amount,
        uint128 exchangeRate,
        uint64 index
    ) external payable onlyCoreContracts returns (bool) {
        // Check the _amount is non zero
        require(amount > 0, "Cannot withdraw zero collateral");
        if (toAddress == address(0)) revert Treasury_ZeroAddress();
        // Get the borrower deposit details
        DepositDetails memory depositDetails = borrowing[borrower].depositDetails[index];
        // check the deposit alredy withdrew or not
        require(depositDetails.withdrawed, "Already withdrawn");

        // Update the collateral data
        depositedCollateralAmountInUsd[depositDetails.assetName] -= depositDetails.depositedAmountUsdValue;
        depositedCollateralAmountInWei[depositDetails.assetName] -= depositDetails.depositedAmountInETH;
        // Updating total volumes
        totalVolumeOfBorrowersAmountinUSD -= depositDetails.depositedAmountUsdValue;
        totalVolumeOfBorrowersAmountinWei -= depositDetails.depositedAmountInETH;
        // Deduct tototalBorrowedAmountt
        borrowing[borrower].totalBorrowedAmount -= depositDetails.borrowedAmount;
        borrowing[borrower].depositedAmountInETH -= depositDetails.depositedAmountInETH;

        depositDetails.withdrawAmount += uint128(amount);
        // Based on collaterla type transfer the amounts
        if (depositDetails.assetName == IBorrowing.AssetName.ETH) {
            // Send the ETH to Borrower
            (bool sent, ) = payable(toAddress).call{value: amount}("");
            require(sent, "Failed to send Collateral");
        } else {
            uint256 upside = ((depositDetails.depositedAmountInETH * 50) / 100) - amount;
            uint256 upsideToDeduct = (upside * 1 ether) / exchangeRate;
            // Transfer collateral to user
            bool sent = IERC20(borrow.assetAddress(depositDetails.assetName)).transfer(toAddress, depositDetails.depositedAmount - upsideToDeduct);
            // check the transfer is successfull or not
            require(sent, "Failed to send Collateral");
        }
        depositDetails.depositedAmount = 0;
        depositDetails.depositedAmountInETH = 0;

        // if user has no deposited collaterals then decrement number of borrowers
        if (borrowing[borrower].depositedAmountInETH == 0) {
            --noOfBorrowers;
        }
        borrowing[borrower].depositDetails[index] = depositDetails;
        // emit withdraw event
        emit Withdraw(toAddress, amount);
        return true;
    }

    /**
     * @dev Withdraws ETH from external protocol
     * @param user ABOND holder address
     * @param aBondAmount ABOND amount, the user is redeeming
     */
    function withdrawFromExternalProtocol(
        address user,
        uint128 aBondAmount
    ) external onlyCoreContracts returns (uint256) {
        if (user == address(0)) revert Treasury_ZeroAddress();

        // Withdraw from external protocols
        uint256 redeemAmount = withdrawFromIonicByUser(user, aBondAmount);
        // Send the ETH to user
        (bool sent, ) = payable(user).call{value: redeemAmount}("");
        // check the transfer is successfull or not
        require(sent, "Failed to send Ether");
        return redeemAmount;
    }

    /**
     * @dev Withdraws ETH from external protocol during liquidation
     * @param user ABOND holder address
     * @param index index of the deposit
     */
    function withdrawFromExternalProtocolDuringLiq(
        address user,
        uint64 index
    ) external onlyCoreContracts returns (uint256) {
        // Calculate the current cumulative rate

        uint256 balanceBeforeWithdraw = address(this).balance;

        // Withdraw from external protocols
        uint256 redeemAmount = withdrawFromIonicDuringLiq(user, index);

        if (address(this).balance < redeemAmount + balanceBeforeWithdraw) revert Treasury_WithdrawExternalProtocolDuringLiqFailed();
        return (redeemAmount - (borrowing[user].depositDetails[index].depositedAmount * 50) / 100);
    }

    /**
     * @dev Calculates the yields from external protocol
     * @param user Address of the abond holder
     * @param aBondAmount ABOND amount
     */
    function calculateYieldsForExternalProtocol(
        address user,
        uint128 aBondAmount
    ) public view onlyCoreContracts returns (uint256) {
        // Get the ABOND state of the user
        State memory userState = abond.userStates(user);
        // Calculate deposited amount
        uint128 depositedAmount = (aBondAmount * userState.ethBacked) / PRECISION;
        // Calculate normalized amount
        uint256 normalizedAmount = (depositedAmount * CUMULATIVE_PRECISION) / userState.cumulativeRate;

        //get the current cumulative rates of the external protocols
        uint256 currentCumulativeRate = getCurrentCumulativeRate(ionic.exchangeRateCurrent(), Protocol.Ionic);

        //withdraw amount
        uint256 amount = (currentCumulativeRate * normalizedAmount) / CUMULATIVE_PRECISION;

        return amount;
    }

    // UPDATE FUNcTIONS

    /**
     * @dev updates the user deposit details
     * @param depositor Address of the user
     * @param depositDetail updated deposit details to store
     */
    function updateDepositDetails(
        address depositor,
        uint64 index,
        DepositDetails memory depositDetail
    ) external onlyCoreContracts {
        borrowing[depositor].depositDetails[index] = depositDetail;
    }

    /**
     * @dev update whether the user has borrowed or not
     * @param borrower address of the user
     * @param borrowed boolean to store
     */
    function updateHasBorrowed(
        address borrower,
        bool borrowed
    ) external onlyCoreContracts {
        borrowing[borrower].hasBorrowed = borrowed;
    }

    /**
     * @dev update the user total borrowed amount
     * @param borrower address of the user
     * @param amount borrowed amount
     */
    function updateTotalBorrowedAmount(
        address borrower,
        uint256 amount
    ) external onlyCoreContracts {
        borrowing[borrower].totalBorrowedAmount += amount;
    }

    /**
     * @dev update the total interest gained for the protocol
     * @param amount interest amount
     */
    function updateTotalInterest(uint256 amount) external onlyCoreContracts {
        totalInterest += amount;
    }

    /**
     * @dev update the total interest gained from liquidation for the protocol
     * @param amount interest amount
     */
    function updateTotalInterestFromLiquidation(
        uint256 amount
    ) external onlyCoreContracts {
        totalInterestFromLiquidation += amount;
    }

    /**
     * @dev update abond usda pool
     * @param amount usda amount
     * @param operation whether to add or subtract
     */
    function updateAbondUSDaPool(
        uint256 amount,
        bool operation
    ) external onlyCoreContracts {
        require(amount != 0, "Treasury:Amount should not be zero");
        if (operation) {
            abondUSDaPool += amount;
        } else {
            abondUSDaPool -= amount;
        }
    }

    /**
     * @dev update usdaGainedFromLiquidation
     * @param amount usda amount
     * @param operation whether to add or subtract
     */
    function updateUSDaGainedFromLiquidation(
        uint256 amount,
        bool operation
    ) external onlyCoreContracts {
        if (operation) {
            usdaGainedFromLiquidation += amount;
        } else {
            usdaGainedFromLiquidation -= amount;
        }
    }

    /**
     * @dev updates totalVolumeOfBorrowersAmountinWei and totalVolumeOfBorrowersAmountLiquidatedInWei
     * @param amount collateral amount in eth value
     */
    function updateTotalVolumeOfBorrowersAmountinWei(
        uint256 amount
    ) external onlyCoreContracts {
        totalVolumeOfBorrowersAmountinWei -= amount;
        totalVolumeOfBorrowersAmountLiquidatedInWei += amount;
    }

    /**
     * @dev updates the totalVolumeOfBorrowersAmountinUSD
     * @param amountInUSD collateral amount in usd value
     */
    function updateTotalVolumeOfBorrowersAmountinUSD(
        uint256 amountInUSD
    ) external onlyCoreContracts {
        totalVolumeOfBorrowersAmountinUSD -= amountInUSD;
    }

    /**
     * @dev updates depositedCollateralAmountInWei
     * @param asset asset name
     * @param amount amount in wei
     */
    function updateDepositedCollateralAmountInWei(
        IBorrowing.AssetName asset,
        uint256 amount
    ) external onlyCoreContracts {
        depositedCollateralAmountInWei[asset] -= amount;
        liquidatedCollateralAmountInWei[asset] += amount;
    }

    /**
     * @dev Updates depositedCollateralAmountInUsd
     * @param asset asset name
     * @param amountInUSD amount in usd
     */
    function updateDepositedCollateralAmountInUsd(
        IBorrowing.AssetName asset,
        uint256 amountInUSD
    ) external onlyCoreContracts {
        depositedCollateralAmountInUsd[asset] -= amountInUSD;
    }

    /**
     * @dev updatse the interestFromExternalProtocolDuringLiquidation
     * @param amount interest
     */
    function updateInterestFromExternalProtocol(
        uint256 amount
    ) external onlyCoreContracts {
        interestFromExternalProtocolDuringLiquidation += amount;
    }

    /**
     * @dev updates usdaCollectedFromCdsWithdraw
     * @param amount usda amount
     */
    function updateUsdaCollectedFromCdsWithdraw(
        uint256 amount
    ) external onlyCoreContracts {
        usdaCollectedFromCdsWithdraw += amount;
    }

    /**
     * @dev updates liquidatedCollateralCollectedFromCdsWithdraw
     * @param amount liquidated collateral amount deducted from cds user during withdraw
     */
    function updateLiquidatedETHCollectedFromCdsWithdraw(
        uint256 amount
    ) external onlyCoreContracts {
        liquidatedCollateralCollectedFromCdsWithdraw += amount;
    }

    /**
     * @dev updates yieldsFromLiquidatedLrts
     * @param yields yields accured from liquidated till cds withdraw
     */
    function updateYieldsFromLiquidatedLrts(
        uint256 yields
    ) external onlyCoreContracts {
        yieldsFromLiquidatedLrts += yields;
    }

    // GETTERS FUNCTIONS

    /**
     * @dev get the borrower details, but will revert
     * @param depositor address of the borrower
     * @param index index of the deposit
     */
    function getBorrowing(
        address depositor,
        uint64 index
    ) external view returns (GetBorrowingResult memory) {
        require(borrowing[depositor].borrowerIndex > 0,"The user dont have any debts");
        return GetBorrowingResult(borrowing[depositor].borrowerIndex, borrowing[depositor].depositDetails[index]);
    }

    /**
     * @dev get the total deposited amount
     * @param borrower address of the borrower
     */
    function getTotalDeposited(
        address borrower
    ) external view returns (uint256) {
        return borrowing[borrower].depositedAmountInETH;
    }

    /**
     * @dev get the cumulative rate
     */
    function getCumulativeRate(
        Protocol protocol
    ) public view returns (uint128) {
        return uint128(protocolDeposit[protocol].cumulativeRate);
    }

    /**
     * @dev get the current cumulative rate
     * @param _currentExchangeRate current ionic exchange rate
     * @param _protocol Which protocol
     */
    function getCurrentCumulativeRate(
        uint256 _currentExchangeRate,
        Protocol _protocol
    ) internal view returns (uint256) {
        uint256 currentCumulativeRate;
        // If it's the first deposit, set the cumulative rate to precision (i.e., 1 in fixed-point representation).
        if (protocolDeposit[_protocol].totalCreditedTokens == 0) {
            currentCumulativeRate = CUMULATIVE_PRECISION;
        } else {
            // Calculate the change in the credited amount relative to the total credited tokens so far.
            uint256 change = ((_currentExchangeRate - protocolDeposit[_protocol].exchangeRate) * CUMULATIVE_PRECISION) / protocolDeposit[_protocol].exchangeRate;
            // Update the cumulative rate using the calculated change.
            currentCumulativeRate = ((CUMULATIVE_PRECISION + change) * protocolDeposit[_protocol].cumulativeRate) / CUMULATIVE_PRECISION;
        }
        return currentCumulativeRate;
    }

    /**
     * @dev get the total eth in treasury contract
     */
    function getBalanceInTreasury() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * usda approval
     * @param assetName Token Name
     * @param spender address to spend
     * @param amount usda amount
     */
    function approveTokens(
        IBorrowing.AssetName assetName,
        address spender,
        uint amount
    ) external onlyCoreContracts {
        require(
            assetName != IBorrowing.AssetName.DUMMY &&
            spender != address(0) &&
            amount != 0,
            "Invalid param"
        );

        bool state;
        if (assetName == IBorrowing.AssetName.USDa) {
            state = usda.contractApprove(spender, amount);
        } else {
            state = IERC20(borrow.assetAddress(assetName)).approve(spender,amount);
        }

        require(state, "Approve failed");
    }

    /**
     * @dev This function withdraw interest.
     * @param toAddress The address to whom to transfer StableCoins.
     * @param amount The amount of stablecoins to withdraw.
     */

    function withdrawInterest(
        address toAddress,
        uint256 amount
    ) external onlyOwner {
        require(toAddress != address(0) && amount != 0,"Input address or amount is invalid");
        require(amount <= (totalInterest + totalInterestFromLiquidation),"Treasury don't have enough interest");
        totalInterest -= amount;
        bool sent = usda.transfer(toAddress, amount);
        require(sent, "Failed to send Ether");
    }

    /**
     * @dev transfer eth from treasury
     * @param user address of the recepient
     * @param amount amount to transfer
     */
    function transferEthToCdsLiquidators(
        address user,
        uint128 amount
    ) external onlyCoreContracts {
        require(user != address(0) && amount != 0,"Input address or amount is invalid");
        // Get the omnichain data
        IGlobalVariables.OmniChainData memory omniChainData = globalVariables.getOmniChainData();
        // Check whether treasury has enough collateral to transfer
        require(amount <= omniChainData.collateralProfitsOfLiquidators,"Treasury don't have enough ETH amount");
        omniChainData.collateralProfitsOfLiquidators -= amount;
        globalVariables.setOmniChainData(omniChainData);

        // Transfer ETH to user
        (bool sent, ) = payable(user).call{value: amount}("");
        if (!sent) revert Treasury_EthTransferToCdsLiquidatorFailed();
    }

    /**
     * @dev calculates the current cumulative rate
     * @param _currentExchangeRate Current Ionic Exchange
     * @param _protocol External protocol name
     */
    function _calculateCumulativeRate(
        uint256 _currentExchangeRate,
        Protocol _protocol
    ) internal returns (uint256) {
        uint256 currentCumulativeRate;
        // If it's the first deposit, set the cumulative rate to precision (i.e., 1 in fixed-point representation).
        if (protocolDeposit[_protocol].totalCreditedTokens == 0) {
            currentCumulativeRate = CUMULATIVE_PRECISION;
        } else {
            // Calculate the change in the credited amount relative to the total credited tokens so far.
            uint256 change = ((_currentExchangeRate - protocolDeposit[_protocol].exchangeRate) * CUMULATIVE_PRECISION) / protocolDeposit[_protocol].exchangeRate;
            // Update the cumulative rate using the calculated change.
            currentCumulativeRate = ((CUMULATIVE_PRECISION + change) * protocolDeposit[_protocol].cumulativeRate) / CUMULATIVE_PRECISION;
        }
        protocolDeposit[_protocol].cumulativeRate = currentCumulativeRate;
        return currentCumulativeRate;
    }

    /**
     * @dev Deposit ETH to Ionic
     * @param depositAmount Deposit ETH amount
     */
    function depositToIonicByUser(uint256 depositAmount) internal nonReentrant {
        uint256 currentExchangeRate = ionic.exchangeRateCurrent();
        // calculate the current cumulative rate
        _calculateCumulativeRate(currentExchangeRate, Protocol.Ionic);

        // Changing ETH into WETH
        WETH.deposit{value: depositAmount}();

        // Approve WETH to Ionic
        bool approved = WETH.approve(address(ionic), depositAmount);

        if (!approved) revert Treasury_ApproveFailed();

        // Call the mint function in Ionic to deposit eth.
        ionic.mint(depositAmount);

        uint256 creditedAmount = ionic.balanceOf(address(this));

        protocolDeposit[Protocol.Ionic].totalCreditedTokens = creditedAmount;
        protocolDeposit[Protocol.Ionic].exchangeRate = currentExchangeRate;
    }

    /**
     * @dev Withdraw ETH from Ionic
     * @param user User address
     * @param aBondAmount ABOND amount to redeem
     */
    function withdrawFromIonicByUser(
        address user,
        uint128 aBondAmount
    ) internal nonReentrant returns (uint256) {
        uint256 currentExchangeRate = ionic.exchangeRateCurrent();
        uint256 currentCumulativeRate = _calculateCumulativeRate(currentExchangeRate, Protocol.Ionic);

        State memory userState = abond.userStates(user);
        uint128 depositedAmount = (aBondAmount * userState.ethBacked) / PRECISION;
        uint256 normalizedAmount = (depositedAmount * CUMULATIVE_PRECISION) / userState.cumulativeRate;

        //withdraw amount
        uint256 amount = (currentCumulativeRate * normalizedAmount) / CUMULATIVE_PRECISION;
        // withdraw from ionic
        ionic.redeemUnderlying(amount);

        protocolDeposit[Protocol.Ionic].totalCreditedTokens = ionic.balanceOf(address(this));
        protocolDeposit[Protocol.Ionic].exchangeRate = currentExchangeRate;
        // convert weth to eth
        WETH.withdraw(amount);
        return amount;
    }

    function withdrawFromIonicDuringLiq(
        address user,
        uint64 index
    ) internal nonReentrant returns (uint256) {
        uint256 currentExchangeRate = ionic.exchangeRateCurrent();
        uint256 currentCumulativeRate = _calculateCumulativeRate(currentExchangeRate,Protocol.Ionic);

        DepositDetails memory depositDetail = borrowing[user].depositDetails[index];
        State memory userState = abond.userStatesAtDeposits(user, index);
        uint256 normalizedAmount = (depositDetail.depositedAmount * CUMULATIVE_PRECISION * 50) / (userState.cumulativeRate * 100);

        //withdraw amount
        uint256 amount = (currentCumulativeRate * normalizedAmount) / CUMULATIVE_PRECISION;
        // withdraw from ionic
        ionic.redeemUnderlying(amount);
        protocolDeposit[Protocol.Ionic].totalCreditedTokens = ionic.balanceOf(address(this));
        protocolDeposit[Protocol.Ionic].exchangeRate = currentExchangeRate;
        // convert weth to eth
        WETH.withdraw(amount);
        return amount;
    }

    /**
     * @dev sets the external protocol contract addresses
     * @param ionicWETHAddress ionicWETH contract Address
     * @param wethAddress wethAddress
     */
    function setExternalProtocolAddresses(
        address ionicWETHAddress,
        address wethAddress,
        address odosRouterV2Address
    ) external onlyOwner {
        address[2] memory addresses = [ionicWETHAddress, wethAddress];

        for (uint8 i = 0; i < 2; i++) {
            if (addresses[i] == address(0) || !isContract(addresses[i])) revert Treasury_CantBeEOAOrZeroAddress(addresses[i]);
        }
        WETH = IWETH9(wethAddress);
        ionic = IonicInterface(ionicWETHAddress);
        odosRouterV2 = odosRouterV2Address;
    }

    /**
     * @dev Transfer the tokens and ETH to Global variables contract
     * @param transferAmounts amount tokens and ETH to transfer
     */
    function transferFundsToGlobal(
        uint256[4] memory transferAmounts
    ) external onlyCoreContracts {
        // Loop through the array to transfer all amounts
        for (uint8 i = 0; i < 4; i++) {
            // Transfer only if the amount is greater than zero
            if (transferAmounts[i] > 0) {
                address assetAddress = borrow.assetAddress(IBorrowing.AssetName((i == 3 ? 4 : i) + 1));
                // Transfer tokens if the index not equal to 0, since index 0 is ETH
                if (i != 0) {
                    if (i == 2) {
                        if (!IWrsETH(assetAddress).approve(assetAddress, transferAmounts[1])) revert Treasury_ApproveFailed();
                        IWrsETH(assetAddress).withdraw(borrow.assetAddress(IBorrowing.AssetName.rsETH), transferAmounts[2]);
                        assetAddress = borrow.assetAddress(IBorrowing.AssetName.rsETH);
                    }
                    bool success = IERC20(assetAddress).transfer(msg.sender, transferAmounts[i]); 
                    if (!success) revert Treasury_TransferFailed();
                } else {
                    // Transfer ETH to global variable contract
                    (bool sent, ) = payable(msg.sender).call{value: transferAmounts[i]}(""); 
                    require(sent, "Failed to send Ether");
                }
            }
        }
    }

    /**
     * @dev swap collateral in odos
     * @param asset collateral type to return
     * @param swapAmount amount to swap to usdt from odos
     * @param odosAssembledData assembled data, got from odos api
     */
    function swapCollateralForUSDT(
        IBorrowing.AssetName asset,
        uint256 swapAmount,
        bytes memory odosAssembledData
    ) external onlyCoreContracts returns (uint256) {
        //? Differs from actual value used in backend, so changing the final digit to 0,
        //? in both backend and here.
        swapAmount = (swapAmount / 10) * 10;
        // check the asset is eligible asset
        if (
            asset != IBorrowing.AssetName.ETH &&
            asset != IBorrowing.AssetName.WeETH &&
            asset != IBorrowing.AssetName.WrsETH
        ) revert Treasury_InvalidAsset(asset);
        // if the asset is other than native asset, approve it.
        if (
            asset == IBorrowing.AssetName.WeETH ||
            asset == IBorrowing.AssetName.WrsETH
        ) {
            bool approved = IERC20(borrow.assetAddress(asset)).approve(odosRouterV2, swapAmount);
            // check whether the approve is successfull or not
            if (!approved) revert Treasury_ApproveFailed();
        }

        // paas the odos assembled data as msg.data to routerV2 contract of odos
        // if the asset is native, pass as msg.value
        (bool success, bytes memory result) = odosRouterV2.call{value: asset == IBorrowing.AssetName.ETH ? swapAmount : 0}(odosAssembledData);

        // check the swap is successfull or not.
        if (!success) revert Treasury_SwapFailed();

        // return the usdt amount
        return abi.decode(result, (uint256));
    }

    /**
     * @dev wraps rsETH to wrsETH
     * @param amount amount of rsETH to wrap.
     */
    function wrapRsETH(uint256 amount) external onlyCoreContracts {
        // Check whether the amount is non zero
        if (amount == 0) revert("Zero rsETH amount to wrap");
        // Approve the wrsETH contract to wrap rsETH
        bool approved = IERC20(borrow.assetAddress(IBorrowing.AssetName.rsETH)).approve(borrow.assetAddress(IBorrowing.AssetName.WrsETH), amount);
        //Check whether the approve is successfull
        if (!approved) revert Treasury_ApproveFailed();
        // Call deposit function in wrsETH contract to wrap rsETH
        IWrsETH(borrow.assetAddress(IBorrowing.AssetName.WrsETH)).deposit(borrow.assetAddress(IBorrowing.AssetName.rsETH),amount);
    }

    receive() external payable {}
}
