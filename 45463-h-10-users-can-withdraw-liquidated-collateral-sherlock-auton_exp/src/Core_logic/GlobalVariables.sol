// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interface/IUSDa.sol";
import "../interface/CDSInterface.sol";
import "../interface/IGlobalVariables.sol";
import "../interface/ITreasury.sol";
import "../interface/IBorrowing.sol";
import "../lib/CDSLib.sol";
import {OAppUpgradeable} from "layerzero-v2/oapp/contracts/oapp/OAppUpgradeable.sol";
import {OApp, MessagingFee, Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {MessagingReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppSender.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

/**
 * @title GlobalVariables contract
 * @author Autonomint
 * @notice Main contract for Layer Zero transactions
 * @notice layer zero transactions are done only in this contract
 * @notice global omnichain data are stored in this contract only
 * @dev All functions have modifier, except quote function
 */

contract GlobalVariables is
    IGlobalVariables,
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    OAppUpgradeable
{
    using OptionsBuilder for bytes; // OptionsBuilder library for LayerZero functionalities
    IUSDa private usda; // USDa instance
    CDSInterface private cds; // CDS instance
    ITreasury private treasury; // Treasury instance
    address private borrowing; // Borrowing address
    address private borrowLiq; // borrow liq address
    address private dstGlobalVariablesAddress; // Destination chain global variables address
    uint32 private dstEid; // Destination Endpoint ID
    OmniChainData private omniChainData; // omniChainData contains global data(all chains)
    IBorrowing private borrowInstance; // Borrowing instance
    mapping(IBorrowing.AssetName assetName => CollateralData collateralData) private s_collateralData; // Individual collateral data

    /**
     * @dev Initialize the contract which initializer modifier
     * @param usdaAddress USDa address
     * @param cdsAddress CDS address
     * @param lzEndpoint Endpoint address from Layer Zero
     * @param delegate Delegate Address usually owner address
     */
    function initialize(
        address usdaAddress,
        address cdsAddress,
        address lzEndpoint,
        address delegate
    ) public initializer {
        // Assign usda of IUSDa type with usda address
        usda = IUSDa(usdaAddress);
        // Assign cds of CDSInterface type with cds address
        cds = CDSInterface(cdsAddress);
        // Initialize the owner in the contracts
        __Ownable_init(msg.sender);
        // Initialize the UUPS proxy
        __UUPSUpgradeable_init();
        // Initialize the OAPP contract with endpoint and delegate addresses
        __OApp_init(lzEndpoint, delegate);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    /**
     * @dev Function to check if an address is a contract
     * @param addr address to check whether the address is an contract address or EOA
     */
    function isContract(address addr) internal view returns (bool) {
        uint size;
        // If the address exist in the chain, then it will return the size which is non zero
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    /**
     * @dev Modifier to check whether the msg.sender is any one of the core contracts address
     */
    modifier onlyCoreContracts() {
        require(
            msg.sender == borrowing ||
            msg.sender == address(cds) ||
            msg.sender == borrowLiq ||
            msg.sender == address(treasury),
            "This function can only called by Core contracts"
        );
        _;
    }

    //////////////////////
    /////// GETTERS //////
    //////////////////////

    /**
     * @dev returns the OmniChainData global data
     * @return OmniChainData struct
     */
    function getOmniChainData() public view returns (OmniChainData memory) {
        return omniChainData;
    }

    /**
     * @dev returns the individual collateral data based on the collateral
     * @param assetName Name of the collateral
     * @return CollateralData struct
     */
    function getOmniChainCollateralData(
        IBorrowing.AssetName assetName
    ) external view returns (CollateralData memory) {
        return s_collateralData[assetName];
    }

    //////////////////////
    /////// SETTERS //////
    //////////////////////

    /**
     * @dev sets the omnichain global data to the 'omniChainData' variable,
     * can only be called by core contracts
     * @param _omniChainData Omnichain global data
     */
    function setOmniChainData(
        OmniChainData memory _omniChainData
    ) public onlyCoreContracts {
        omniChainData = _omniChainData;
    }

    /**
     * @dev sets the individual collateral data to the 's_collateralData' mapping,
     * can only be called by core contracts
     * @param collateralData individual collateral data
     */
    function updateCollateralData(
        IBorrowing.AssetName assetName,
        CollateralData memory collateralData
    ) external onlyCoreContracts {
        s_collateralData[assetName] = collateralData;
    }

    /**
     * @dev sets the destination EID, can only be called by owner
     * @param eid Endpoint id to assign
     */
    function setDstEid(uint32 eid) public onlyOwner {
        dstEid = eid;
    }

    /**
     * @dev sets the treasury contract address and instance, can only be called by owner
     * @param _treasury Treasury contract address
     */
    function setTreasury(address _treasury) public onlyOwner {
        // Check whether the input address is not a zero address and EOA
        require(_treasury != address(0) && isContract(_treasury),"Treasury address should not be zero address and must be contract address");
        treasury = ITreasury(_treasury);
    }

    /**
     * @dev Sets the borrowing contract address and instance, can only be called by owner
     * @param _borrow Borrowing contract address
     */
    function setBorrowing(address _borrow) public onlyOwner {
        // Check whether the input address is not a zero address and EOA
        require(_borrow != address(0) && isContract(_borrow),"Borrowing address should not be zero address and must be contract address");
        borrowing = _borrow;
        borrowInstance = IBorrowing(_borrow);
    }

    /**
     * @dev Sets the borrow liquidaton contract address, can only be called by owner
     * @param _borrowLiq Borrow Liquidation contract address
     */
    function setBorrowLiq(address _borrowLiq) public onlyOwner {
        // Check whether the input address is not a zero address and EOA
        require(_borrowLiq != address(0) && isContract(_borrowLiq),"Borrow Liquidation address should not be zero address and must be contract address");
        borrowLiq = _borrowLiq;
    }

    /**
     * @dev Sets the dst global variables contract address, can only be called by owner
     * @param _globalVariables Global variables contract address
     */
    function setDstGlobalVariablesAddress(
        address _globalVariables
    ) public onlyOwner {
        // Check whether the input address is not a zero address
        //? Here we can't able to check whether the address is contract address or not,
        //? since it is present in different chain
        require(_globalVariables != address(0),"Destination address should not be zero address");
        dstGlobalVariablesAddress = _globalVariables;
    }

    /**
     * @dev Sends msg to destination chain, to transfer the OFT and Native tokens to get in this chain,
     * can only be called by cds or borrow liquidation contracts
     * @param functionToDo What function the destination chain contract needs to do,
     * E.g Token Transfer or updating data only like that
     * @param oftTransferData USDa amount to get from dst chain with address to receive in this chain and amount\
     * @param collateralTokenTransferData Collaterals which are oft to get from dst chain
     * @param refundAddress Address to refund the gas fee paid by msg.sender
     */
    function oftOrCollateralReceiveFromOtherChains(
        FunctionToDo functionToDo,
        USDaOftTransferData memory oftTransferData,
        CollateralTokenTransferData memory collateralTokenTransferData,
        CallingFunction callingFunction,
        address refundAddress
    ) external payable onlyCoreContracts returns (MessagingReceipt memory receipt)
    {
        // Define the payload to pass to _lzsend function with same order of data
        bytes memory _payload = abi.encode(
            functionToDo,
            callingFunction,
            callingFunction == CallingFunction.CDS_WITHDRAW ? oftTransferData.tokensToSend : 0,
            callingFunction == CallingFunction.BORROW_WITHDRAW ? oftTransferData.tokensToSend : 0,
            callingFunction == CallingFunction.BORROW_LIQ ? oftTransferData.tokensToSend : 0,
            CDSInterface.LiquidationInfo(0,0,0,0,IBorrowing.AssetName.DUMMY,0),
            0,
            oftTransferData,
            collateralTokenTransferData,
            omniChainData,
            IBorrowing.AssetName.DUMMY,
            s_collateralData[IBorrowing.AssetName.DUMMY]
        );
        // We need to send the gas fee required for transfer of oft and eth from dst to this chain
        // Fee required for this omnichain transaction
        MessagingFee memory _fee;
        // Fee required for USDa transfer, which we need to send to dst chain, so that dst chain don't need to pay gas fees
        MessagingFee memory feeForTokenTransfer;
        // Fee required for ETH,WeETH,RsETH transfer, which we need to send to dst chain, so that dst chain don't need to pay gas fees
        MessagingFee memory feeForCollateralTransfer;
        // Gas needs to send
        bytes memory _options;
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(60000, 0);
        // Define sendParam for OFT transfer
        SendParam memory _sendParam = SendParam(
            dstEid,
            bytes32(uint256(uint160(oftTransferData.recipient))),
            oftTransferData.tokensToSend * 10,
            oftTransferData.tokensToSend,
            options,
            "0x",
            "0x"
        );
        // Calculate the fee needed in dst chain to transfer oft from dst to this chain
        feeForTokenTransfer = usda.quoteSend(_sendParam, false);
        // DEfine options to get ETH from other chain with inbuilt function from layer zero //?addExecutorNativeDropOption
        options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(280000, 0).addExecutorNativeDropOption(
                uint128(collateralTokenTransferData.ethToSend),
                bytes32(uint256(uint160(dstGlobalVariablesAddress)))
            );
        // Calculate the fee needed to transfer ETH from dst to this chain
        feeForCollateralTransfer = quote(
            FunctionToDo(1),
            IBorrowing.AssetName.DUMMY,
            options,
            false
        );
        //? Based on the functionToDo in dst chain, define options
        // If we need to get only the USDa from dst chain
        if (functionToDo == FunctionToDo.TOKEN_TRANSFER) {
            // Define options with native fee required in dst chain
            // to transfer this USDa using 'addExecutorNativeDropOption' with fee amount and this chain address where to get
            _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(500000, 0).addExecutorNativeDropOption(
                    uint128(feeForTokenTransfer.nativeFee),
                    bytes32(uint256(uint160(dstGlobalVariablesAddress)))
                );
            // If we need to get only the Collaterals from dst chain
        } else if (functionToDo == FunctionToDo.COLLATERAL_TRANSFER) {
            // Define options with native fee required in dst chain
            // to transfer this collaterals using 'addExecutorNativeDropOption' with fee amount and this chain address where to get
            _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(300000, 0).addExecutorNativeDropOption(
                    // Since, we have 3 collaterals, we are passing native fee required for 2 OFT transfers
                    // and 1 native transfer,so we are multiplying oft fee with 2.
                    // Since feeForCollateralTransfer includes the fee with native token needed, we are subtracting the native token
                    // needed to get the fee alone
                    uint128(2 * feeForTokenTransfer.nativeFee + (feeForCollateralTransfer.nativeFee - collateralTokenTransferData.ethToSend)),
                    bytes32(uint256(uint160(dstGlobalVariablesAddress)))
                );
            // If we need to get both the Collaterals and USDa from dst chain
        } else if (functionToDo == FunctionToDo.BOTH_TRANSFER) {
            _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(700000, 0).addExecutorNativeDropOption(
                    // Since, we have 3 collaterals, we are passing native fee required for 3 OFT transfers
                    // and 1 native transfer,so we are multiplying oft fee with 3.
                    // Since feeForCollateralTransfer includes the fee with native token needed, we are subtracting the native token
                    // needed to get the fee alone
                    uint128(5 * feeForTokenTransfer.nativeFee + (feeForCollateralTransfer.nativeFee - collateralTokenTransferData.ethToSend)),
                    bytes32(uint256(uint160(dstGlobalVariablesAddress)))
                );
        }
        // Calculate the fee for _lzSend function
        // Since in this function we don't need to store data, we are passing zero params and DUMMY enums.
        _fee = quoteInternal(
            dstEid,
            functionToDo,
            oftTransferData.tokensToSend,
            oftTransferData.tokensToSend,
            oftTransferData.tokensToSend,
            CDSInterface.LiquidationInfo(0,0,0,0,IBorrowing.AssetName.DUMMY,0),
            0,
            oftTransferData,
            collateralTokenTransferData,
            IBorrowing.AssetName.DUMMY,
            _options,
            false
        );

        // Calling layer zero send function to send to dst chain
        receipt = _lzSend(
            dstEid,
            _payload,
            _options,
            _fee,
            payable(refundAddress)
        );
    }

    /**
     * @dev Internal function which calls _lzsend functions
     * @param _dstEid dst eid
     * @param _functionToDo fucntion to do in dst chain
     * @param _optionsFeesToGetFromOtherChain options fees to get from dst chain
     * @param _cdsAmountToGetFromOtherChain cds amount to get from other chain in liquidation
     * @param _liqAmountToGetFromOtherChain liq amount to get from other chain in liquidation
     * @param _liquidationInfo liq info to store in global
     * @param _liqIndex Index of the above liq info to store
     * @param _assetName collateral name to update data
     * @param _fee fee for the transaction
     * @param _options options to define gas limit
     * @param _refundAddress address to resend fee
     */
    function sendInternal(
        uint32 _dstEid,
        FunctionToDo _functionToDo,
        uint256 _optionsFeesToGetFromOtherChain,
        uint256 _cdsAmountToGetFromOtherChain,
        uint256 _liqAmountToGetFromOtherChain,
        CDSInterface.LiquidationInfo memory _liquidationInfo,
        uint128 _liqIndex,
        IBorrowing.AssetName _assetName,
        MessagingFee memory _fee,
        bytes memory _options,
        address _refundAddress
    ) internal returns (MessagingReceipt memory receipt) {
        // encoding the message
        bytes memory _payload = abi.encode(OAppData(
                _functionToDo,
                CallingFunction.DUMMY,
                _optionsFeesToGetFromOtherChain,
                _cdsAmountToGetFromOtherChain,
                _liqAmountToGetFromOtherChain,
                _liquidationInfo,
                _liqIndex,
                USDaOftTransferData(address(0), 0),
                CollateralTokenTransferData(address(0), 0, 0, 0),
                omniChainData,
                _assetName,
                s_collateralData[_assetName]
            )
        );
        // Calling layer zero send function to send to dst chain
        receipt = _lzSend(
            _dstEid,
            _payload,
            _options,
            _fee,
            payable(_refundAddress)
        );
    }

    /**
     * @dev Internal function which calls quote function to get fee
     * @param _dstEid dst eid
     * @param _functionToDo fucntion to do in dst chain
     * @param _optionsFeesToGetFromOtherChain options fees to get from dst chain
     * @param _cdsAmountToGetFromOtherChain cds amount to get from other chain in liquidation
     * @param _liqAmountToGetFromOtherChain liq amount to get from other chain in liquidation
     * @param _liquidationInfo liq info to store in global
     * @param _liqIndex Index of the above liq info to store
     * @param _assetName collateral name to update data
     * @param _options options to define gas limit
     * @param _payInLzToken Boolean to pay whether in native or LzToken
     */
    function quoteInternal(
        uint32 _dstEid,
        FunctionToDo _functionToDo,
        uint256 _optionsFeesToGetFromOtherChain,
        uint256 _cdsAmountToGetFromOtherChain,
        uint256 _liqAmountToGetFromOtherChain,
        CDSInterface.LiquidationInfo memory _liquidationInfo,
        uint128 _liqIndex,
        USDaOftTransferData memory _oftTransferData,
        CollateralTokenTransferData memory _collateralTokenTransferData,
        IBorrowing.AssetName _assetName,
        bytes memory _options,
        bool _payInLzToken
    ) internal view returns (MessagingFee memory fee) {
        // encoding the message
        bytes memory payload = abi.encode(OAppData(
                _functionToDo,
                CallingFunction.DUMMY,
                _optionsFeesToGetFromOtherChain,
                _cdsAmountToGetFromOtherChain,
                _liqAmountToGetFromOtherChain,
                _liquidationInfo,
                _liqIndex,
                _oftTransferData,
                _collateralTokenTransferData,
                omniChainData,
                _assetName,
                s_collateralData[_assetName]
            )
        );

        // Calling layer zero quote function to get the fee
        fee = _quote(_dstEid, payload, _options, _payInLzToken);
    }

    /**
     * @dev Function which calls quote internal to get fee
     * @param functionToDo fucntion to do in dst chain
     * @param assetName collateral name to update data
     * @param options options to define gas limit
     * @param payInLzToken Boolean to pay whether in native or LzToken
     */
    function quote(
        FunctionToDo functionToDo,
        IBorrowing.AssetName assetName,
        bytes memory options,
        bool payInLzToken
    ) public view returns (MessagingFee memory fee) {
        // Since we need fee for global struct updation only we have passed zero params
        return quoteInternal(
            dstEid,
            functionToDo,
            0,
            0,
            0,
            CDSInterface.LiquidationInfo(0,0,0,0,IBorrowing.AssetName.DUMMY,0),
            0,
            USDaOftTransferData(address(0), 0),
            CollateralTokenTransferData(address(0), 0, 0, 0),
            assetName,
            options,
            payInLzToken
        );
    }

    /**
     * @dev Function which calls send internal to send lz transaction
     * @param functionToDo fucntion to do in dst chain
     * @param assetName collateral name to update data
     * @param fee fee for the transaction
     * @param options options to define gas limit
     * @param refundAddress address to resend fee
     */
    function send(
        FunctionToDo functionToDo,
        IBorrowing.AssetName assetName,
        MessagingFee memory fee,
        bytes memory options,
        address refundAddress
    ) external payable onlyCoreContracts returns (MessagingReceipt memory receipt) {
        // Since we are updation global struct only we have passed zero params
        return sendInternal(
            dstEid,
            functionToDo,
            0,
            0,
            0,
            CDSInterface.LiquidationInfo(0,0,0,0,IBorrowing.AssetName.DUMMY,0),
            0,
            assetName,
            fee,
            options,
            refundAddress
        );
    }

    /**
     * @dev External function which calls _lzsend functions only called by liq contract
     * @param functionToDo fucntion to do in dst chain
     * @param liquidationInfo liq info to store in global
     * @param liqIndex Index of the above liq info to store
     * @param assetName collateral name to update data
     * @param fee fee for the transaction
     * @param options options to define gas limit
     * @param refundAddress address to resend fee
     */
    function sendForLiquidation(
        FunctionToDo functionToDo,
        uint128 liqIndex,
        CDSInterface.LiquidationInfo memory liquidationInfo,
        IBorrowing.AssetName assetName,
        MessagingFee memory fee,
        bytes memory options,
        address refundAddress
    ) external payable onlyCoreContracts returns (MessagingReceipt memory receipt) {
        // Call the sendInternal Function to send oapp msgs
        return sendInternal(
            dstEid,
            functionToDo,
            0,
            0,
            0,
            liquidationInfo,
            liqIndex,
            assetName,
            fee,
            options,
            refundAddress
        );
    }

    /**
     * @dev function to receive data from src
     */
    function _lzReceive(
        Origin calldata /*_origin*/,
        bytes32 /*_guid*/,
        bytes calldata payload,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override {
        // Decoding the message from src
        OAppData memory oappData = abi.decode(payload, (OAppData));

        // Options for oft transfer
        bytes memory _options;
        // Native fee required
        MessagingFee memory _fee;
        //? based on functionToDo, do the lz transactions
        // If needs to transfer USDa only
        if (oappData.functionToDo == FunctionToDo.TOKEN_TRANSFER) {
            // getting options since,the src don't know the dst state
            _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(60000,0);
            // Define SendParam to send OFT
            SendParam memory _sendParam = SendParam(
                dstEid,
                bytes32(uint256(uint160(oappData.oftTransferData.recipient))),
                oappData.oftTransferData.tokensToSend,
                oappData.oftTransferData.tokensToSend,
                _options,
                "0x",
                "0x"
            );
            // Get the fee by calling quote function
            _fee = usda.quoteSend(_sendParam, false);
            // Since we need usda only, we have passed others zero
            treasury.transferFundsToGlobal([0, 0, 0, oappData.oftTransferData.tokensToSend]);
            // Send oft to src chain
            usda.send{value: _fee.nativeFee}(_sendParam, _fee, address(this));
            // If need only collateral or collateral and USDa
        } else if (oappData.functionToDo == FunctionToDo.COLLATERAL_TRANSFER || oappData.functionToDo == FunctionToDo.BOTH_TRANSFER) {
            //Since we need to send ETH with OFt, we can do this by sending single transaction
            _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(280000, 0).addExecutorNativeDropOption(
                    // Pass the ETH amount needed
                    uint128(oappData.collateralTokenTransferData.ethToSend),
                    bytes32(uint256(uint160(oappData.collateralTokenTransferData.recipient)))
                );
            // Define the SendParam to send OFT
            SendParam memory _sendParam = SendParam(
                dstEid,
                bytes32(uint256(uint160(oappData.oftTransferData.recipient))),
                oappData.oftTransferData.tokensToSend,
                oappData.oftTransferData.tokensToSend,
                _options,
                "0x",
                "0x"
            );
            // Quote the native fee
            _fee = usda.quoteSend(_sendParam, false);
            // Get the funds from treasury, since the sender is global variables contract
            treasury.transferFundsToGlobal([
                    oappData.collateralTokenTransferData.ethToSend,
                    oappData.collateralTokenTransferData.weETHToSend,
                    oappData.collateralTokenTransferData.rsETHToSend,
                    oappData.oftTransferData.tokensToSend
                ]
            );
            // Send oft to src chain
            usda.send{value: _fee.nativeFee}(_sendParam, _fee, address(this));
            // Change the options since we dont need to send ETH
            _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(100000, 0);

            // Collateral tokens to send to src chain
            uint256[2] memory tokensToSend = [
                oappData.collateralTokenTransferData.weETHToSend,
                oappData.collateralTokenTransferData.rsETHToSend
            ];
            // Loop through the OFts to send tokens from this to src
            for (uint8 i = 0; i < tokensToSend.length; i++) {
                if (tokensToSend[i] > 0) {
                    _sendParam = SendParam(
                        dstEid,
                        bytes32(uint256(uint160(oappData.collateralTokenTransferData.recipient))),
                        tokensToSend[i],
                        tokensToSend[i],
                        _options,
                        "0x",
                        "0x"
                    );
                    _fee = usda.quoteSend(_sendParam, false);
                    address assetAddress;
                    if (i == 1) {
                        assetAddress = borrowInstance.assetAddress(IBorrowing.AssetName.rsETH);
                    } else {
                        assetAddress = borrowInstance.assetAddress(IBorrowing.AssetName(i + 2));
                    }
                    // Get the Collateal address from borrowing contract
                    IOFT(assetAddress).send{value: _fee.nativeFee}( _sendParam,_fee,address(this));
                }
            }
        }

        // Update the total cds deposited amount with options fees
        cds.updateTotalCdsDepositedAmountWithOptionFees(uint128(oappData.optionsFeesToRemove + oappData.cdsAmountToRemove + oappData.liqAmountToRemove));
        // Update the total cds deposited amount
        cds.updateTotalCdsDepositedAmount(uint128(oappData.cdsAmountToRemove + oappData.liqAmountToRemove));
        // Update the total available liquidation amount in CDS
        cds.updateTotalAvailableLiquidationAmount(oappData.liqAmountToRemove);
        // Update the liquidation info in CDS
        cds.updateLiquidationInfo(oappData.liqIndex, oappData.liquidationInfo);
        // Update the global omnichain data struct
        omniChainData = oappData.message;
        // Update the individual collateral data
        s_collateralData[oappData.assetName] = oappData.collateralData;
    }

    // Receive function to get ETH from treaury and receive ETH from dst chain
    receive() external payable {}
}
