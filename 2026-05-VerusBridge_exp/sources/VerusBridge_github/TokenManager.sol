// SPDX-License-Identifier: MIT
// Bridge between ethereum and verus

pragma solidity >=0.8.9;
pragma abicoder v2;

import "./Token.sol";
import "../Libraries/VerusConstants.sol";
import "../Libraries/VerusObjects.sol";
import {VerusSerializer} from "../VerusBridge/VerusSerializer.sol";
import "../VerusBridge/CreateExports.sol";
import "../VerusBridge/UpgradeManager.sol";
import "../VerusBridge/SubmitImports.sol";
import "../Libraries/VerusObjectsCommon.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "../Storage/StorageMaster.sol";
import "./VerusCrossChainExport.sol";


contract TokenManager is VerusStorage {

    address immutable VETH;
    address immutable VERUS;
    address immutable DAIERC20ADDRESS;

    uint8 constant SEND_FAILED = 1;
    uint8 constant SEND_SUCCESS = 2;
    uint8 constant SEND_SUCCESS_ERC1155 = 3;
    uint8 constant SEND_SUCCESS_ERC721 = 4;
    uint8 constant SEND_SUCCESS_ERC20_MINTED = 5;
    uint8 constant SEND_SUCCESS_ETH = 6;

    bytes4 constant ERC20_SEND_SELECTOR = ERC20.transfer.selector ;
    bytes4 constant ERC20_MINT_SELECTOR = Token.mint.selector ;
    bytes4 constant ERC721_SEND_SELECTOR = IERC721.transferFrom.selector;
    bytes4 constant ERC1155_SEND_SELECTOR = IERC1155.safeTransferFrom.selector;

    constructor(address vETH, address, address Verus, address DaiERC20Address){

        VETH = vETH;
        VERUS = Verus;
        DAIERC20ADDRESS = DaiERC20Address;
    }

    function initialize() external {

    } 

    function launchToken(VerusObjects.PackedCurrencyLaunch[] memory _tx) private {
        
        for (uint j = 0; j < _tx.length; j++)
        {
            // If the iaddress is already mapped or the iaddress is null skip token register
            if (verusToERC20mapping[_tx[j].iaddress].flags > 0 || _tx[j].iaddress == address(0))
                continue;

            VerusSerializer(contracts[uint(VerusConstants.ContractType.VerusSerializer)]).checkIAddress(_tx[j]); 

            string memory outputName;

            // Only adjust the name of the token if it is a Ethereum owned token and it not a ERC1155 NFT
            if (_tx[j].flags & 
                (VerusConstants.MAPPING_ETHEREUM_OWNED | VerusConstants.MAPPING_ERC1155_ERC_DEFINITION | VerusConstants.MAPPING_ERC1155_NFT_DEFINITION) 
                    == VerusConstants.MAPPING_ETHEREUM_OWNED)
            {
               (bool success, bytes memory result) = _tx[j].ERCContract.call{gas:30000}(abi.encodeWithSignature("name()"));
                if (success) {
                    outputName = abi.decode(result, (string));
                } else {
                    outputName = "...";
                }

                outputName = string(abi.encodePacked("[", outputName, "] as "));
            }

            outputName = string(abi.encodePacked(outputName, _tx[j].name));

            if (_tx[j].parent != VERUS)
            {
                outputName = string(abi.encodePacked(outputName, ".", verusToERC20mapping[_tx[j].parent].name));
            }
            recordToken(_tx[j].iaddress, _tx[j].ERCContract, outputName, _tx[j].name, uint8(_tx[j].flags), _tx[j].tokenID);
        }
    }

    function recordToken(
        address _iaddress,
        address ethContractAddress,
        string memory name,
        string memory ticker,
        uint8 flags,
        uint256 tokenID
    ) public { 

        address ERCContract;

        if (flags & VerusConstants.MAPPING_VERUS_OWNED == VerusConstants.MAPPING_VERUS_OWNED) 
        {
            if (flags & VerusConstants.MAPPING_ERC20_DEFINITION == VerusConstants.MAPPING_ERC20_DEFINITION) 
            {
                Token t = new Token(name, ticker); 
                ERCContract = address(t); 
            }
            else if (flags & VerusConstants.MAPPING_ERC721_NFT_DEFINITION == VerusConstants.MAPPING_ERC721_NFT_DEFINITION)
            {
                ERCContract = verusToERC20mapping[tokenList[VerusConstants.NFT_POSITION]].erc20ContractAddress;
                tokenID = uint256(uint160(_iaddress)); //tokenID is the i address
            }
        }
        else 
        {
            ERCContract = ethContractAddress;
        }

        tokenList.push(_iaddress);
        // TokenIndex is used for accounting of ERC20, ERC721, ERC1155 so allways start at 0.
        verusToERC20mapping[_iaddress] = VerusObjects.mappedToken(ERCContract, flags, 0, name, tokenID);
 
    }

    function processTransactions(bytes calldata serializedTransfers, uint256 numberOfTransfers) 
                external returns (bytes memory refundsData, uint256 fees, uint176[] memory refundAddresses)
    {

        VerusObjects.PackedSend[] memory transfers;
        VerusObjects.PackedCurrencyLaunch[] memory launchTxs;

        uint32 counter;
        (transfers, launchTxs, counter, refundAddresses) = VerusSerializer(contracts[uint(VerusConstants.ContractType.VerusSerializer)])
            .deserializeTransfers(serializedTransfers, uint8(numberOfTransfers));
        
        // Only two currency launches are allowed per CCE, so use a third one to store fees, as function is to large.
        fees = uint64(launchTxs[2].tokenID);
        refundsData = importTransactions(transfers, refundAddresses);
        // 32bit counter is split into two 16bit values, the first 16bits is the number of transactions, the second 16bits is the number of currency launches
        if (uint8(counter >> 24) > 0) {
            launchToken(launchTxs);
        }

        //return and refund any failed transactions
        return (refundsData, fees, refundAddresses);
    }

    function importTransactions(VerusObjects.PackedSend[] memory trans, uint176[] memory refundAddresses) private returns (bytes memory refundsData){
      
        VerusObjects.mappedToken memory tempToken;
        
        for(uint256 i = 0; i < trans.length; i++)
        {
            uint64 sendAmount;
            address destinationAddress;
            address currencyiAddress;
            uint32 result;

            sendAmount = uint64(trans[i].currencyAndAmount >> VerusConstants.UINT160_BITS_SIZE);
            destinationAddress  = address(uint160(trans[i].destinationAndFlags));
            tempToken = verusToERC20mapping[address(uint160(trans[i].currencyAndAmount))];
            currencyiAddress = address(uint160(trans[i].currencyAndAmount));
            
            if (currencyiAddress == VETH) 
            {
                // NOTE: Send limits gas so cannot pay to contract addresses with fallback functions.
                (bool success, ) = destinationAddress.call{value: (sendAmount * VerusConstants.SATS_TO_WEI_STD), gas: 100000}("");
                result = success ? SEND_SUCCESS_ETH : SEND_FAILED;            
            }   
            else if (tempToken.flags & VerusConstants.MAPPING_ERC721_NFT_DEFINITION == VerusConstants.MAPPING_ERC721_NFT_DEFINITION &&
                     tempToken.flags & VerusConstants.MAPPING_VERUS_OWNED == VerusConstants.MAPPING_VERUS_OWNED)
            {
                VerusNft t = VerusNft(tempToken.erc20ContractAddress);
                t.mint(currencyiAddress, tempToken.name, destinationAddress);
                // Do nothing after minted.
                result = 0;
            }
            else if (tempToken.flags & VerusConstants.MAPPING_ERC20_DEFINITION == VerusConstants.MAPPING_ERC20_DEFINITION)
            {
                // if the ERC20 type is verus owned then mint the currency to the destination address, else transfer the currency to the destination address.
                result = uint32((tempToken.flags & VerusConstants.MAPPING_VERUS_OWNED == VerusConstants.MAPPING_VERUS_OWNED) 
                                                   ? uint32(ERC20_MINT_SELECTOR) : uint32(ERC20_SEND_SELECTOR));
            } 
            else if (tempToken.flags & VerusConstants.MAPPING_ERC721_NFT_DEFINITION == VerusConstants.MAPPING_ERC721_NFT_DEFINITION) 
            {             
                result = uint32(ERC721_SEND_SELECTOR);

            } else if (tempToken.flags & VerusConstants.MAPPING_ERC1155_NFT_DEFINITION == VerusConstants.MAPPING_ERC1155_NFT_DEFINITION ||
                        tempToken.flags & VerusConstants.MAPPING_ERC1155_ERC_DEFINITION == VerusConstants.MAPPING_ERC1155_ERC_DEFINITION) 
            {
                result = uint32(ERC1155_SEND_SELECTOR);
            }            

            // if result is a sector then use it to make the call in the sendCurrencyToETHAddress function, else call is already made.
            if(result > SEND_SUCCESS_ETH) {
                result = sendCurrencyToETHAddress(tempToken.erc20ContractAddress, destinationAddress, sendAmount, result, tempToken.tokenID); 
            }

            if (result == SEND_FAILED && sendAmount > 0) {
                refundsData = abi.encodePacked(refundsData, refundAddresses[i], sendAmount, currencyiAddress);
            } 
            else if (result == SEND_SUCCESS) {
                // TokenIndex used for ERC20, ERC721 & ERC1155 Acounting so decrement holdings if successful
                verusToERC20mapping[currencyiAddress].tokenIndex -= sendAmount;
            }
        } 
    }

    // Returns true if successful transfer
    function sendCurrencyToETHAddress(address tokenERCAddress, address destinationAddress, uint256 sendAmount, uint32 selector, uint256 TokenId ) private returns (uint8){
    
        bytes memory data;
        uint256 amount;
        bool success;
        if (selector == uint32(ERC20_MINT_SELECTOR) || selector == uint32(ERC20_SEND_SELECTOR)) {
            (success, data) = tokenERCAddress.call{gas: 30000}(abi.encodeWithSelector(ERC20.decimals.selector)); 
            if(!success) {
                return SEND_FAILED;
            }
            amount = convertFromVerusNumber(sendAmount, abi.decode(data, (uint8)));
        }

        if(tokenERCAddress == DAIERC20ADDRESS) {
            address crossChainExportAddress = contracts[uint(VerusConstants.ContractType.VerusCrossChainExport)];
            (success,) = crossChainExportAddress.delegatecall(abi.encodeWithSelector(VerusCrossChainExport.exit.selector, destinationAddress, amount));
            return success ? SEND_SUCCESS : SEND_FAILED;
        }
        else if(selector == uint32(ERC20_MINT_SELECTOR) || selector == uint32(ERC20_SEND_SELECTOR)) {

            data = abi.encodeWithSelector(bytes4(selector), destinationAddress, amount);

        }
        else if(selector == uint32(ERC721_SEND_SELECTOR)) {

            data = abi.encodeWithSelector(bytes4(selector), address(this), destinationAddress, TokenId);

        }
        else if(selector == uint32(ERC1155_SEND_SELECTOR)) {

            data = abi.encodeWithSelector(bytes4(selector), address(this), destinationAddress, TokenId, sendAmount, "");

        } 
        (success, data) = tokenERCAddress.call{gas: 100000}(data);

        if (!success || (data.length >= 32 && abi.decode(data, (uint256)) == 0)) {
            return SEND_FAILED;
        }
        return selector == uint32(ERC20_MINT_SELECTOR) ? SEND_SUCCESS_ERC20_MINTED : SEND_SUCCESS;
    }

    function convertFromVerusNumber(uint256 a, uint8 decimals) internal pure returns (uint256 c) {

        if(decimals > 8 ) {
            uint8 power = decimals - 8;// number of decimals in verus
            c = a * (10 ** power);
        }else if(decimals < 8){
            uint8 power = 8 - decimals;// number of decimals in verus
            c = a / (10 ** power);
        } else {
            c = a;
        }
    
        return c;
    }
}