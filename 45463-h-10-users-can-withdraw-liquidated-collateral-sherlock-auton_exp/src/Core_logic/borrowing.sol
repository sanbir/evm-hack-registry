// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interface/CDSInterface.sol";
import "../interface/IBorrowing.sol";
import "../interface/IUSDa.sol";
import "../interface/IBorrowLiquidation.sol";
import {IABONDToken} from "../interface/IAbond.sol";
import {BorrowLib} from "../lib/BorrowLib.sol";
import "../interface/ITreasury.sol";
import "../interface/IOptions.sol";
import "../interface/IMultiSign.sol";
import "../interface/IGlobalVariables.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "../oracles/BasePriceOracle.sol";

/**
 * @title Borrowing contract
 * @author Autonomint
 * @notice One of the main point of interaction with an Autonomint protocol's market
 * - Users can:
 *   # Deposit Collateral
 *   # Withdraw Collateral
 *   # Borrow USDa
 *   # Liquidate positions
 *   # Redeem ABOND
 *   # Pay options fees premium for renewal
 * @dev All admin functions are callable by the admin address only
 */

contract Borrowing is
    IBorrowing,
    Initializable,
    EIP712Upgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable
{
    IUSDa public usda; // our stablecoin
    CDSInterface private cds; // Cds instance
    IABONDToken private abond; // abond stablecoin
    ITreasury private treasury; // Treasury instance
    IOptions private options; // options contract interface
    IMultiSign private multiSign; // Multisign instance
    IBorrowLiquidation private borrowLiquidation; // Borrow liquidation instance
    address private treasuryAddress; // treasury contract address
    address public admin; // admin address
    uint8 private LTV; // LTV is a percentage eg LTV = 60 is 60%, must be divided by 100 in calculations
    uint8 private APR; // APR
    uint256 private totalNormalizedAmount; // total normalized amount in protocol
    uint128 private lastEthprice; // previous eth price
    uint256 public lastCumulativeRate; // previous cumulative rate
    uint128 private lastEventTime; // Timestamp of last event occured in borrowing
    uint128 private noOfLiquidations; // total number of liquidation happened till now
    uint128 public ratePerSec; // interest rate per second
    uint64 private bondRatio; // ABOND : USDA ratio
    bytes32 private DOMAIN_SEPARATOR;
    uint256 private collateralRemainingInWithdraw; // Collateral left during withdraw
    uint256 private collateralValueRemainingInWithdraw; // Collateral value left during withdraw
    using OptionsBuilder for bytes; // For using options in lz transactions
    IGlobalVariables private globalVariables; // Global variable instance
    mapping(AssetName => address assetAddress) public assetAddress; // Mapping to address of the collateral
    //  from AssetName enum Note: For native token ETH, the address is 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
    //  Mapping of token address to price feed address
    BasePriceOracle private oracle; // master price oracle interface

    /**
     * @dev initialize function to initialize the contract
     * @param usdaAddress USDa token address
     * @param cdsAddress CDS contract address
     * @param abondTokenAddress ABOND token address
     * @param multiSignAddress Multi Sign contract address
     * @param mpoAddress Master Price Oracle address
     * @param tokenAddresses Collateral token addresses
     * @param chainId Chain ID of the network
     * @param globalVariablesAddress Global variables contract addresses
     */
    function initialize(
        address usdaAddress,
        address cdsAddress,
        address abondTokenAddress,
        address multiSignAddress,
        address mpoAddress,
        address[] memory collateralAddresses,
        address[] memory tokenAddresses,
        uint64 chainId,
        address globalVariablesAddress
    ) public initializer {
        // Get the total number of collateral addresses
        uint16 noOfCollaterals = uint16(collateralAddresses.length);

        // Initialize the owner of the contract
        __Ownable_init(msg.sender);
        // Initialize the proxy
        __UUPSUpgradeable_init();
        __EIP712_init(BorrowLib.name, BorrowLib.version);
        usda = IUSDa(usdaAddress);
        cds = CDSInterface(cdsAddress);
        abond = IABONDToken(abondTokenAddress);
        multiSign = IMultiSign(multiSignAddress);
        globalVariables = IGlobalVariables(globalVariablesAddress);
        oracle = BasePriceOracle(mpoAddress);

        // Get the DOMAIN SEPARATOR
        DOMAIN_SEPARATOR = keccak256(abi.encode(BorrowLib.PERMIT_TYPEHASH, BorrowLib.name, BorrowLib.version, chainId, address(this)));

        // Loop through the number of collateral address
        for (uint256 i = 0; i < noOfCollaterals; i++) {
            // Assign the value(collateral address) for a key(collateral name ENUM)
            assetAddress[AssetName(i + 1)] = collateralAddresses[i];
        }
        // Loop through the number of collateral address plus token addresses,starting with collateral address length + 1
        // SInce collateral addresses are allready assigned
        for ( uint256 i = (noOfCollaterals + 1); i <= (noOfCollaterals + tokenAddresses.length); i++ ) {
            // Assign the value(token address) for a key(collateral(token) name ENUM)
            assetAddress[AssetName(i)] = tokenAddresses[i - (noOfCollaterals + 1)];
        }
        (, lastEthprice) = getUSDValue(assetAddress[AssetName.ETH]);
        lastEventTime = uint128(block.timestamp);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev modifier to check whether the caller is an admin or not
     */
    modifier onlyAdmin() {
        if (msg.sender != admin) revert Borrow_CallerIsNotAnAdmin();
        _;
    }

    /**
     * @dev modifier to check whether the fucntion is paused or not
     */
    modifier whenNotPaused(IMultiSign.Functions _function) {
        if (multiSign.functionState(_function)) revert Borrow_Paused();
        _;
    }

    /**
     * @dev modifier to check whether the caller is one of the core contract or not
     */
    modifier onlyCoreContracts() {
        if (msg.sender != address(cds) && msg.sender != address(borrowLiquidation)) revert Borrow_OnlyCoreContractsCancall();
        _;
    }

    /**
     * @dev Function to check if an address is a contract
     * @param addr address to check whether the address is an contract address or EOA
     */
    function isContract(address addr) internal view returns (bool) {
        uint size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    /**
     * @dev sets the treasury contract address and instance, can only be called by owner
     * @param _treasury Treasury contract address
     */

    function setTreasury(address _treasury) external onlyAdmin {
        // Check whether the input address is not a zero address and EOA
        if (_treasury == address(0) || !isContract(_treasury)) revert Borrow_CantBeEOAOrZeroAddress(_treasury);

        // Check whether, the function have required approvals from owners to set
        if (!multiSign.executeSetterFunction(IMultiSign.SetterFunctions(5))) revert Borrow_RequiredApprovalsNotMetToSet();

        treasury = ITreasury(_treasury);
        treasuryAddress = _treasury;
    }

    /**
     * @dev sets the options contract address and instance, can only be called by owner
     * @param _options Options contract address
     */
    function setOptions(address _options) external onlyAdmin {
        // Check whether the input address is not a zero address and EOA
        if (_options == address(0) || !isContract(_options)) revert Borrow_CantBeEOAOrZeroAddress(_options);

        options = IOptions(_options);
    }

    /**
     * @dev sets the borrowLiquidation contract address and instance, can only be called by owner
     * @param _borrowLiquidation borrowLiquidation contract address
     */

    function setBorrowLiquidation(address _borrowLiquidation) external onlyAdmin {
        if (_borrowLiquidation == address(0) || !isContract(_borrowLiquidation)) revert Borrow_CantBeEOAOrZeroAddress(_borrowLiquidation);
        borrowLiquidation = IBorrowLiquidation(_borrowLiquidation);
    }

    /**
     * @dev set admin address
     * @param _admin  admin address
     */
    function setAdmin(address _admin) external onlyOwner {
        // Check whether the input address is not a zero address and Contract Address
        if (_admin == address(0) || isContract(_admin)) revert Borrow_CantBeContractOrZeroAddress(_admin);

        // Check whether, the function have required approvals from owners to set
        if (!multiSign.executeSetterFunction(IMultiSign.SetterFunctions(3))) revert Borrow_RequiredApprovalsNotMetToSet();

        admin = _admin;
    }

    /**
     * @dev Deposit collateral into the protocol and mint them back the USDa tokens.
     * The user will get LTV of the deposited collateral value with options fees deducted for a month.
     * If the user is depositing native asset, 50% is deposited to ionic.
     * @param depositParam Struct, which contains other params
     **/

    function depositTokens(
        BorrowDepositParams memory depositParam
    ) external payable nonReentrant whenNotPaused(IMultiSign.Functions(0)) {
        // Assign options for lz contract, here the gas is hardcoded as 400000, we got this through testing by iteration
        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(400000, 0);
        // calculting fee
        MessagingFee memory fee = globalVariables.quote(
            IGlobalVariables.FunctionToDo(1),
            depositParam.assetName,
            _options,
            false
        );
        // Get the exchange rate for a collateral and eth price
        (uint128 exchangeRate, uint128 ethPrice) = getUSDValue(assetAddress[depositParam.assetName]);

        totalNormalizedAmount = BorrowLib.deposit(
            BorrowLibDeposit_Params(
                LTV,
                APR,
                lastCumulativeRate,
                totalNormalizedAmount,
                exchangeRate,
                ethPrice,
                lastEthprice
            ),
            depositParam,
            Interfaces(treasury, globalVariables, usda, abond, cds, options),
            assetAddress
        );

        //Call calculateCumulativeRate() to get currentCumulativeRate
        calculateCumulativeRate();
        lastEventTime = uint128(block.timestamp);

        // Calling Omnichain send function
        globalVariables.send{value: fee.nativeFee}(
            IGlobalVariables.FunctionToDo(1),
            depositParam.assetName,
            fee,
            _options,
            msg.sender
        );
    }

    /**
    @dev Withdraw Collateral from the protocol and burn usda.
    If the deposited collateral is ETH, the user will get 50% of the deposited amount, for the
    remaining, ABOND token is minted and transfer to user which is fungible. The strike price chosen by user also
    deducted from the withdraw amount.
    @param toAddress The address to whom to transfer collateral.
    @param index Index of the withdraw collateral position
    @param odosAssembledData odos assembled data got from odos api
    @param signature odos assembled data signed by backend from admin two address
    **/

    function withDraw(
        address toAddress,
        uint64 index,
        bytes memory odosAssembledData,
        bytes memory signature
    ) external payable nonReentrant whenNotPaused(IMultiSign.Functions(1)) {
        // check is _toAddress in not a zero address and isContract address
        if (toAddress == address(0) || isContract(toAddress)) revert Borrow_CantBeContractOrZeroAddress(toAddress);

        if (!cds.verify(odosAssembledData, signature)) revert Borrow_NotSignedByEIP712Signer();
        // Get the depositor details
        ITreasury.GetBorrowingResult memory getBorrowingResult = treasury.getBorrowing(msg.sender, index);
        // Get the exchange rate for a collateral and eth price
        (uint128 exchangeRate, uint128 ethPrice) = getUSDValue(assetAddress[getBorrowingResult.depositDetails.assetName]);

        // check if borrowerIndex in BorrowerDetails of the msg.sender is greater than or equal to Index
        if (getBorrowingResult.totalIndex >= index) {
            _withdraw(
                toAddress,
                index,
                odosAssembledData,
                uint64(ethPrice),
                exchangeRate,
                uint64(block.timestamp)
            );
        } else {
            // revert if user doens't have the perticular index
            revert Borrow_InvalidIndex();
        }
    }

    /**
     * @dev redeem eth yields from ext protocol by returning abond
     * @param user Address of the abond holder
     * @param aBondAmount ABOND amount to use for redeem
     *
     */
    function redeemYields(
        address user,
        uint128 aBondAmount
    ) public returns (uint256) {
        // Call redeemYields function in Borrow Library
        return (
            BorrowLib.redeemYields(
                user,
                aBondAmount,
                address(usda),
                address(abond),
                address(treasury),
                address(this)
            )
        );
    }

    /**
     * @dev Get the yields from ext protocol
     * @param user Address of the abond holder
     * @param aBondAmount ABOND amount to use for redeem
     */
    function getAbondYields(
        address user,
        uint128 aBondAmount
    ) public view returns (uint128, uint256, uint256) {
        // Call getAbondYields function in Borrow Library
        return (
            BorrowLib.getAbondYields(
                user,
                aBondAmount,
                address(abond),
                address(treasury)
            )
        );
    }

    /**
     * @dev This function liquidate positions which are below downside protection.
     * liquidation is done on two types, which is decided from backend.
     * @param user The address to whom to liquidate ETH.
     * @param index Index of the borrow
     * @param liquidationType Liquidation type to execute
     */

    function liquidate(
        address user,
        uint64 index,
        IBorrowing.LiquidationType liquidationType
    ) external payable whenNotPaused(IMultiSign.Functions(2)) onlyAdmin {
        // Check whether the user address is non zero address
        if (user == address(0)) revert Borrow_MustBeNonZeroAddress(user);
        // Check whether the user address is admin address
        if (msg.sender == user) revert Borrow_CantLiquidateOwnAssets();

        // Call calculate cumulative rate fucntion to get interest
        calculateCumulativeRate();
        // Assign options for lz contract, here the gas is hardcoded as 400000, we got this through testing by iteration
        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(400000, 0);
        // Get the deposit details
        ITreasury.GetBorrowingResult memory getBorrowingResult = treasury.getBorrowing(user, index);
        // Calculating fee for lz transaction
        MessagingFee memory fee = globalVariables.quote(
            IGlobalVariables.FunctionToDo(2),
            getBorrowingResult.depositDetails.assetName,
            _options,
            false
        );
        // Increment number of liquidations
        ++noOfLiquidations;
        (, uint128 ethPrice) = getUSDValue(assetAddress[AssetName.ETH]);
        // Call the liquidateBorrowPosition function in borrowLiquidation contract
        CDSInterface.LiquidationInfo memory liquidationInfo = borrowLiquidation
            .liquidateBorrowPosition{value: msg.value - fee.nativeFee}(
            user,
            index,
            uint64(ethPrice),
            liquidationType,
            lastCumulativeRate
        );

        // Calling Omnichain send function
        globalVariables.sendForLiquidation{value: fee.nativeFee}(
            IGlobalVariables.FunctionToDo(2),
            noOfLiquidations,
            liquidationInfo,
            getBorrowingResult.depositDetails.assetName,
            fee,
            _options,
            msg.sender
        );
    }

    /**
     * @dev Submit the order in Synthetix for closing position, can only be called by Borrowing contract
     */
    function closeThePositionInSynthetix() external onlyAdmin {
        // call closeThePositionInSynthetix in borrowLiquidation contract
        borrowLiquidation.closeThePositionInSynthetix();
    }

    /**
     * @dev Execute the submitted order in Synthetix
     * @param priceUpdateData Bytes[] data to update price
     */
    function executeOrdersInSynthetix(
        bytes[] calldata priceUpdateData
    ) external onlyAdmin {
        // call executeOrdersInSynthetix in borrowLiquidation contract
        borrowLiquidation.executeOrdersInSynthetix(priceUpdateData);
    }

    /**
     * @dev get the usd value of ETH and exchange rate for collaterals
     * @param token Collateral token address
     */
    function getUSDValue(address token) public view returns (uint128, uint128) {
        return oracle.price(token);
    }

    /**
     * @dev Set the protocolo ltv
     * @param ltv loan to value ratio of the protocol
     */
    function setLTV(uint8 ltv) external onlyAdmin {
        // Check ltv is non zero
        if (ltv == 0) revert Borrow_NeedsMoreThanZero();
        // Check whether, the function have required approvals from owners to set
        if (!multiSign.executeSetterFunction(IMultiSign.SetterFunctions(0))) revert Borrow_RequiredApprovalsNotMetToSet();
        LTV = ltv;
    }

    /**
     * @dev set the abond and usda ratio
     * @param _bondRatio ABOND USDa ratio
     */
    function setBondRatio(uint64 _bondRatio) external onlyAdmin {
        // Check bond ratio is non zero
        if (_bondRatio == 0) revert Borrow_NeedsMoreThanZero();
        // Check whether, the function have required approvals from owners to set
        if (!multiSign.executeSetterFunction(IMultiSign.SetterFunctions(7))) revert Borrow_RequiredApprovalsNotMetToSet();
        bondRatio = _bondRatio;
    }

    /**
     * @dev return the LTV of the protocol
     */
    function getLTV() public view returns (uint8) {
        return LTV;
    }

    /**
     * @dev calculate the ratio of CDS Pool/Eth Vault, only called by cds and borrow liq
     * @param amount amount to be depositing
     * @param currentEthPrice current eth price in usd
     */
    function calculateRatio(
        uint256 amount,
        uint128 currentEthPrice
    ) public onlyCoreContracts returns (uint64) {
        return _calculateRatio(amount, currentEthPrice);
    }

    /**
     * @dev calculate the ratio of CDS Pool/Eth Vault
     * @param amount amount to be depositing
     * @param currentEthPrice current eth price in usd
     */
    function _calculateRatio(
        uint256 amount,
        uint128 currentEthPrice
    ) private returns (uint64 ratio) {
        if (currentEthPrice == 0) revert Borrow_GettingETHPriceFailed();

        // Get the omnichain data
        IGlobalVariables.OmniChainData memory omniChainData = globalVariables.getOmniChainData();
        // Get the return values from calculateRatio in library to store
        (ratio, omniChainData) = BorrowLib.calculateRatio(
            amount,
            currentEthPrice,
            lastEthprice,
            omniChainData.totalNoOfDepositIndices,
            omniChainData.totalVolumeOfBorrowersAmountinWei,
            omniChainData.totalCdsDepositedAmount -
                omniChainData.downsideProtected,
            omniChainData // using global data instead of individual chain data
        );

        // updating global data
        globalVariables.setOmniChainData(omniChainData);
    }

    /**
     * @dev set APR of the deposits
     * @param _APR apr of the protocol
     * @param _ratePerSec Interest rate per second
     */
    function setAPR(
        uint8 _APR,
        uint128 _ratePerSec
    ) external whenNotPaused(IMultiSign.Functions(3)) onlyAdmin {
        // Check the input params are non zero
        if (_ratePerSec == 0 || _APR == 0) revert Borrow_NeedsMoreThanZero();
        // Check whether, the function have required approvals from owners to set
        if (!multiSign.executeSetterFunction(IMultiSign.SetterFunctions(1))) revert Borrow_RequiredApprovalsNotMetToSet();
        APR = _APR;
        ratePerSec = _ratePerSec;
    }

    /**
     * @dev calculate cumulative rate
     */
    function calculateCumulativeRate() public returns (uint256) {
        // Get the noOfBorrowers
        uint128 noOfBorrowers = treasury.noOfBorrowers();
        // Call calculateCumulativeRate in borrow library
        uint256 currentCumulativeRate = BorrowLib.calculateCumulativeRate(
            noOfBorrowers,
            ratePerSec,
            lastEventTime,
            lastCumulativeRate
        );
        lastCumulativeRate = currentCumulativeRate;
        return currentCumulativeRate;
    }

    /**
     * @dev updates the APR based on usda price
     * @param usdaPrice USDa price
     */
    function updateRatePerSecByUSDaPrice(uint32 usdaPrice) public onlyAdmin {
        // Check the usda price is non zero
        if (usdaPrice <= 0) revert Borrow_NeedsMoreThanZero();
        // Get the new apr and rate per sec to update from library
        (ratePerSec, APR) = BorrowLib.calculateNewAPRToUpdate(usdaPrice);
    }

    /**
     * @dev renew the position by 30 days by paying usda.
     * The user will have 80% downside protection
     * @param index index of the position to renew
     */
    function renewOptions(uint64 index) external payable {
        if (
            !BorrowLib.renewOptions(
                Interfaces(
                    treasury,
                    globalVariables,
                    usda,
                    abond,
                    cds,
                    options
                ),
                index
            )
        ) revert Borrow_RenewFailed();

        // Get the deposit details
        ITreasury.GetBorrowingResult memory getBorrowingResult = treasury.getBorrowing(msg.sender, index);
        ITreasury.DepositDetails memory depositDetail = getBorrowingResult.depositDetails;
        depositDetail.optionsRenewedTimeStamp = block.timestamp;
        treasury.updateDepositDetails(msg.sender, index, depositDetail);

        // define options for lz send transaction with 400000 gas(found by testing)
        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(400000, 0);

        // calculting fee for lz send transaction
        MessagingFee memory fee = globalVariables.quote(
            IGlobalVariables.FunctionToDo(1),
            depositDetail.assetName,
            _options,
            false
        );

        // Calling Omnichain send function
        globalVariables.send{value: fee.nativeFee}(
            IGlobalVariables.FunctionToDo(1),
            depositDetail.assetName,
            fee,
            _options,
            msg.sender
        );

        emit Renewed(msg.sender, index, block.timestamp);
    }

    /**
     * @dev gets the options fees, the borrower needs to pay to renew
     * @param index the index of the position
     */
    function getOptionFeesToPay(uint64 index) public view returns (uint256) {
        return BorrowLib.getOptionFeesToPay(treasury, index);
    }

    /**
     * @dev get the deposit detail of the particular index
     * @param borrower address of the borrower
     * @param index index of the position
     */
    function getDepositDetails(
        address borrower,
        uint64 index
    ) public view returns (ITreasury.DepositDetails memory depositDetail) {
        // Get the deposit details
        ITreasury.GetBorrowingResult memory getBorrowingResult = treasury.getBorrowing(borrower, index);
        depositDetail = getBorrowingResult.depositDetails;
    }

    /**
    @dev Withdraw Collateral from the protocol and burn usda.
    @param toAddress The address to whom to transfer collateral.
    @param index Index of the withdraw collateral position
    @param odosAssembledData odos assembled data got from odos api
    @param ethPrice Current collateral Price.
    @param withdrawTime Current timestamp
    **/

    function _withdraw(
        address toAddress,
        uint64 index,
        bytes memory odosAssembledData,
        uint64 ethPrice,
        uint128 exchangeRate,
        uint64 withdrawTime
    ) internal {
        // Get the deposit details
        ITreasury.DepositDetails memory depositDetail = getDepositDetails(msg.sender, index);

        // call Caluculate ratio function to update tha changes in cds and eth vaults
        _calculateRatio(0, ethPrice);

        BorrowWithdraw_Result memory result = BorrowLib.withdraw(
            depositDetail,
            BorrowWithdraw_Params(
                toAddress,
                index,
                ethPrice,
                exchangeRate,
                withdrawTime,
                lastCumulativeRate,
                totalNormalizedAmount,
                bondRatio,
                collateralRemainingInWithdraw,
                collateralValueRemainingInWithdraw
            ),
            Interfaces(treasury, globalVariables, usda, abond, cds, options)
        );
        // calculated upside collateral to swap
        uint256 amountToSwap = result.collateralRemainingInWithdraw -
            collateralRemainingInWithdraw;
        if (amountToSwap > 0) {
            // found the exact amount of collateral
            amountToSwap = (amountToSwap * 1 ether) / exchangeRate;
            // call the swapCollateralForUSDT in treasury
            treasury.swapCollateralForUSDT(depositDetail.assetName, amountToSwap, odosAssembledData);
        }

        // Assign options for lz contract, here the gas is hardcoded as 400000, we got this through testing by iteration
        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(350000, 0);

        // calculting fee
        MessagingFee memory fee = globalVariables.quote(
            IGlobalVariables.FunctionToDo(1),
            depositDetail.assetName,
            _options,
            false
        );

        // if there is a downside, get it from cds
        {if (result.downsideProtected > 0) {
            _getDownsideFromCDS(result.downsideProtected, msg.value - fee.nativeFee);
        } else {
            // Send the remaining ETH to Borrower
            (bool sent, ) = payable(toAddress).call{value: msg.value - fee.nativeFee}("");
            if (!sent) revert Borrow_TransferFailed();
        }

        // update the state variables
        totalNormalizedAmount = result.totalNormalizedAmount;
        collateralRemainingInWithdraw = result.collateralRemainingInWithdraw;
        collateralValueRemainingInWithdraw = result.collateralValueRemainingInWithdraw;

        lastEthprice = uint128(ethPrice);
        lastEventTime = uint128(block.timestamp);}

        // Call calculateCumulativeRate function to get the interest
        calculateCumulativeRate();

        // Calling Omnichain send function
        globalVariables.send{value: fee.nativeFee}(
            IGlobalVariables.FunctionToDo(1),
            depositDetail.assetName,
            fee,
            _options,
            msg.sender
        );
    }

    /**
     * @dev getting downside from CDS
     * @param downsideProtected downside protected amount needed
     * @param feeForOFT fee for OFT transfer
     */
    function _getDownsideFromCDS(
        uint128 downsideProtected,
        uint256 feeForOFT
    ) internal {
        if (cds.getTotalCdsDepositedAmount() < downsideProtected) {
            // Call the oftOrCollateralReceiveFromOtherChains function in global variables
            globalVariables.oftOrCollateralReceiveFromOtherChains{value: feeForOFT}(
                IGlobalVariables.FunctionToDo(3),
                IGlobalVariables.USDaOftTransferData(address(treasury),downsideProtected - cds.getTotalCdsDepositedAmount()),
                // Since we don't need ETH, we have passed zero params
                IGlobalVariables.CollateralTokenTransferData(address(0),0,0,0),
                IGlobalVariables.CallingFunction.BORROW_WITHDRAW,
                msg.sender
            );
        } else {
            // updating downside protected from this chain in CDS
            cds.updateDownsideProtected(downsideProtected);
        }
        // Burn the borrow amount
        treasury.approveTokens(IBorrowing.AssetName.USDa, address(this), downsideProtected);
        bool success = usda.contractBurnFrom(address(treasury), downsideProtected);
        if (!success) revert Borrow_BurnFailed();
    }

    // /**
    //  * @dev verifies whether the signer is admin
    //  * @param deadline
    //  */
    function verify(
        uint256 deadline,
        bytes memory signature
    ) public view returns (bool) {
        // define digest
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(keccak256("Permit(uint256 deadline)"), deadline))
        );

        // get the signer
        address signer = ECDSA.recover(digest, signature);

        if (signer == admin && deadline < block.timestamp) {
            return true;
        } else {
            return false;
        }
    }
}
