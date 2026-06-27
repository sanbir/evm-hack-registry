// SPDX-License-Identifier: MIT
// Bridge between ethereum and verus

pragma solidity >=0.8.9;
pragma abicoder v2;   
import "../Libraries/VerusObjects.sol";
import "../Libraries/VerusObjectsNotarization.sol";
import "../Libraries/VerusConstants.sol";

contract VerusSerializer {

    uint constant ETH_ADDRESS_SIZE_BYTES = 20;
    uint32 constant CCC_PREFIX_TO_OPTIONS = 3 + 4; // already starts on the byte so 3 first
    uint32 constant VERUS_ID_LENGTH = 20;
    uint32 constant CCC_NATIVE_OFFSET = 4 + 4 + 1;
    uint32 constant CCC_TOKENID_OFFSET = 32;
    uint32 constant ETH_SEND_GATEWAY_AND_AUX_DEST = 20 + 20 + 8 + 4 + 20;
    uint32 constant TRANSFER_GATEWAYSKIP = 48; // skip gatewayID (20), gatewayCode (20), fees (8)
    uint8 constant FLAG_MASK = 192; // 11000000

    function initialize() external {
        
    }

    function readCompactSizeLE(bytes memory incoming, uint32 offset) public pure returns(VerusObjectsCommon.UintReader memory) {

        uint8 oneByte;
        assembly {
            oneByte := mload(add(incoming, offset))
        }
        offset++;
        if (oneByte < 253)
        {
            return VerusObjectsCommon.UintReader(offset, oneByte);
        }
        else if (oneByte == 253)
        {
            offset++;
            uint16 twoByte;
            assembly {
                twoByte := mload(add(incoming, offset))
            }
 
            return VerusObjectsCommon.UintReader(offset + 1, ((twoByte << 8) & 0xffff)  | twoByte >> 8);
        }
        else if (oneByte == 254)
        {
            offset += 3;
            uint32 fourByte;
            assembly {
                fourByte := mload(add(incoming, offset))
            }
            return VerusObjectsCommon.UintReader(offset + 3, serializeUint32(fourByte));
        }
        else
        {
            offset += 7;
            uint64 eightByte;
            assembly {
                eightByte := mload(add(incoming, offset))
            }
            return VerusObjectsCommon.UintReader(offset + 1, serializeUint64(eightByte));
        }
    }

    function writeVarInt(uint64 incoming) public pure returns(bytes memory) {
        bytes1 inProgress;
        bytes memory output;
        uint len = 0;
        while(true){
            inProgress = bytes1(uint8(incoming & 0x7f) | (len!=0 ? 0x80:0x00));
            output = abi.encodePacked(inProgress,output);
            if(incoming <= 0x7f) break;
            incoming = (incoming >> 7) -1;
            len++;
        }
        return output;
    }
   
    function writeCompactSize(uint newNumber) public pure returns(bytes memory) {
        bytes memory output;
        if (newNumber < uint8(253))
        {   
            output = abi.encodePacked(uint8(newNumber));
        }
        else if (newNumber <= 0xFFFF)
        {   
            output = abi.encodePacked(uint8(253),uint8(newNumber & 0xff),uint8(newNumber >> 8));
        }
        else if (newNumber <= 0xFFFFFFFF)
        {   
            output = abi.encodePacked(uint8(254),uint8(newNumber & 0xff),uint8(newNumber >> 8),uint8(newNumber >> 16),uint8(newNumber >> 24));
        }
        else 
        {   
            output = abi.encodePacked(uint8(254),uint8(newNumber & 0xff),uint8(newNumber >> 8),uint8(newNumber >> 16),uint8(newNumber >> 24),uint8(newNumber >> 32),uint8(newNumber >> 40),uint8(newNumber >> 48),uint8(newNumber >> 56));
        }
        return output;
    }
 
    //serialize functions

    function serializeUint16(uint16 number) public pure returns(uint16){
        number = (number << 8) | (number >> 8) ;
        return number;
    }
    
    function serializeUint32(uint32 number) public pure returns(uint32){
        // swap bytes
        number = ((number & 0xFF00FF00) >> 8) | ((number & 0x00FF00FF) << 8);
        number = (number >> 16) | (number << 16);
        return number;
    }

    function serializeInt16(int16 number) public pure returns(int16){
        number = (number << 8) | (number >> 8) ;
        return number;
    }
    
    function serializeInt32(int32 inval) public pure returns(uint32){
        uint32 number = uint32(inval);
        number = ((number & 0xFF00FF00) >> 8) | ((number & 0x00FF00FF) << 8);
        number = (number >> 16) | (number << 16);
        return number;
    }
    
    function serializeInt64(int64 number) public pure returns(uint64){
        
        uint64 v = uint64(number);
        v = ((v & 0xFF00FF00FF00FF00) >> 8) |
        ((v & 0x00FF00FF00FF00FF) << 8);

        // swap 2-byte long pairs
        v = ((v & 0xFFFF0000FFFF0000) >> 16) |
            ((v & 0x0000FFFF0000FFFF) << 16);

        // swap 4-byte long pairs
        v = (v >> 32) | (v << 32);
        return v;
    }

    function serializeUint64(uint64 v) public pure returns(uint64){
        
        v = ((v & 0xFF00FF00FF00FF00) >> 8) |
        ((v & 0x00FF00FF00FF00FF) << 8);

        // swap 2-byte long pairs
        v = ((v & 0xFFFF0000FFFF0000) >> 16) |
            ((v & 0x0000FFFF0000FFFF) << 16);

        // swap 4-byte long pairs
        v = (v >> 32) | (v << 32);
        return v;
    }

    function serializeInt32Array(int32[] memory numbers) public pure returns(bytes memory){
        bytes memory be;
        be = writeCompactSize((numbers.length));
        for(uint i = 0;i < numbers.length; i++){
            be = abi.encodePacked(be, serializeInt32(numbers[i]));
        }
        return be;
    }

    function serializeInt64Array(int64[] memory numbers) public pure returns(bytes memory){
        bytes memory be;
        be = writeCompactSize((numbers.length));
        for(uint i = 0;i < numbers.length; i++){
            be = abi.encodePacked(be, serializeInt64(numbers[i]));
        }
        return be;
    }

    function serializeUint160Array(uint160[] memory numbers) public pure returns(bytes memory){
        bytes memory be;
        be = writeCompactSize((numbers.length));
        for(uint i = 0;i < numbers.length; i++){
            be = abi.encodePacked(be,abi.encodePacked(numbers[i]));
        }
        return be;
    }

    function serializeCTransferDestination(VerusObjectsCommon.CTransferDestination memory ctd) public pure returns(bytes memory){

        uint256 destinationSize;

        if ((ctd.destinationtype & VerusConstants.DEST_REGISTERCURRENCY) == VerusConstants.DEST_REGISTERCURRENCY) {

            destinationSize = ctd.destinationaddress.length;

        } else {

            destinationSize = ETH_ADDRESS_SIZE_BYTES;
        }

        return abi.encodePacked(ctd.destinationtype, writeCompactSize(destinationSize),ctd.destinationaddress);
    }    

    function serializeCCurrencyValueMap(VerusObjects.CCurrencyValueMap memory _ccvm) public pure returns(bytes memory){
         return abi.encodePacked(_ccvm.currency, serializeUint64(_ccvm.amount));
    }
    
    function serializeCCurrencyValueMaps(VerusObjects.CCurrencyValueMap[] memory _ccvms) public pure returns(bytes memory){
        bytes memory inProgress;
        inProgress = writeVarInt(uint64(_ccvms.length));
        for(uint i=0; i < _ccvms.length; i++){
            inProgress = abi.encodePacked(inProgress,serializeCCurrencyValueMap(_ccvms[i]));
        }
        return inProgress;
    }

    function serializeCReserveTransfer(VerusObjects.CReserveTransfer memory ct) public pure returns(bytes memory){
        
        bytes memory output =  abi.encodePacked(
            writeVarInt(ct.version),
            ct.currencyvalue.currency, 
            writeVarInt(uint64(ct.currencyvalue.amount)), //special interpretation of a ccurrencyvalue
            writeVarInt(ct.flags),
            ct.feecurrencyid,
            writeVarInt(uint64(ct.fees)),
            serializeCTransferDestination(ct.destination),
            ct.destcurrencyid
           );
           
        if((ct.flags & VerusConstants.RESERVE_TO_RESERVE )>0) output = abi.encodePacked(output, ct.secondreserveid);           
         //see if it has a cross_system flag
        if((ct.flags & VerusConstants.CROSS_SYSTEM)>0) output = abi.encodePacked(output, ct.destsystemid);
        
        return output;
    }
    
    function serializeCReserveTransfers(VerusObjects.CReserveTransfer[] memory _bts, bool includeSize) public pure returns(bytes memory){
        bytes memory inProgress;
        
        if (includeSize) inProgress = writeCompactSize(_bts.length);
        
        for(uint i=0; i < _bts.length; i++){
            inProgress = abi.encodePacked(inProgress,serializeCReserveTransfer(_bts[i]));
        }
        return inProgress;
    }
    
    function serializeCCrossChainExport(VerusObjects.CCrossChainExport memory _ccce) public pure returns(bytes memory){
        bytes memory part1 = abi.encodePacked(
            serializeUint16(_ccce.version),
            serializeUint16(_ccce.flags),
            _ccce.sourcesystemid,
            _ccce.hashtransfers,
            _ccce.destinationsystemid,
            _ccce.destinationcurrencyid);
        bytes memory part2 = abi.encodePacked(
            bytes2(0x0000), //Ctransferdesination is 00 type and 00 length for exporter
            serializeInt32(_ccce.firstinput),
            serializeUint32(_ccce.numinputs),
            writeVarInt(_ccce.sourceheightstart),
            writeVarInt(_ccce.sourceheightend),
            serializeCCurrencyValueMaps(_ccce.totalfees),
            serializeCCurrencyValueMaps(_ccce.totalamounts),
            serializeCCurrencyValueMaps(_ccce.totalburned),
            bytes1(0x00)); // Reservetransfers 
            
        return abi.encodePacked(part1,part2);

    }

    function flipArray(bytes memory incoming) public pure returns(bytes memory){
        uint256 len;
        len = incoming.length;
        bytes memory output = new bytes(len);
        uint256 pos = 0;
        while(pos < len){
            output[pos] = incoming[len - pos - 1];
            pos++;
        }
        return output;
    }

    function currencyParser(bytes memory input, uint256 offset) public pure
                    returns (VerusObjects.PackedCurrencyLaunch memory returnCurrency)
    {
        uint32 nextOffset;
        uint32 tempUint32;
        address parent;
        address nativeCurrencyID;
        uint256 nftID;
        uint8 NativeCurrencyType;
        uint8 NativeCurrencyTypeNoFlags;
        uint32 options;

        nextOffset = CCC_PREFIX_TO_OPTIONS + uint32(offset);

        assembly {
            options := mload(add(input, nextOffset))
            nextOffset := add(nextOffset, VERUS_ID_LENGTH)
            parent := mload(add(input, nextOffset))
            nextOffset := add(nextOffset, 1)  // one byte move forwards to read string length
            tempUint32 := and(mload(add(input, nextOffset)), 0x000000ff) // string length MAX 64 so will always be a byte
        }

        options = serializeUint32(options);  //reverse endian
        returnCurrency.parent = parent;
        bytes memory tempname = new bytes(tempUint32);

        for (uint32 i = 0; i < tempUint32; i++) { 
            tempname[i] = input[i + nextOffset];
        }
        
        returnCurrency.name = string(tempname);
        nextOffset += tempUint32;
        assembly {
            nextOffset := add(nextOffset, VERUS_ID_LENGTH) // move to read launchsystemID
            nextOffset := add(nextOffset, VERUS_ID_LENGTH) // move to read systemID
            nextOffset := add(nextOffset, CCC_NATIVE_OFFSET) // move to read the native currency type
            NativeCurrencyType := mload(add(input, nextOffset)) 
        }

        NativeCurrencyTypeNoFlags = NativeCurrencyType & ~FLAG_MASK; //remove flags
       
        if (NativeCurrencyTypeNoFlags == VerusConstants.DEST_ETHNFT) {
            assembly {
                nextOffset := add(add(nextOffset, VERUS_ID_LENGTH), 1) //skip vector length 
                nativeCurrencyID := mload(add(input, nextOffset))
                nextOffset := add(nextOffset, CCC_TOKENID_OFFSET)
                nftID := mload(add(input, nextOffset))
            }   

            if (NativeCurrencyType == VerusConstants.DEST_ETHNFT) { //if there is no auxdest then it is an ERC721
                returnCurrency.flags |= uint8(VerusConstants.MAPPING_ERC721_NFT_DEFINITION); 
            } else {
                returnCurrency.flags |= uint8(VerusConstants.MAPPING_ERC1155_NFT_DEFINITION);
            }
            returnCurrency.flags |= uint8(VerusConstants.MAPPING_ETHEREUM_OWNED);
            returnCurrency.tokenID = nftID;
        }
        else if (NativeCurrencyTypeNoFlags == VerusConstants.DEST_ETH) {
            
            assembly {
                nextOffset := add(add(nextOffset, VERUS_ID_LENGTH), 1) //skip vector length 
                nativeCurrencyID := mload(add(input, nextOffset))
            }

            if (NativeCurrencyType == VerusConstants.DEST_ETH) {  //if there is no auxdest then it is an ERC20
                returnCurrency.flags |= uint8(VerusConstants.MAPPING_ERC20_DEFINITION);
            } else {
                returnCurrency.flags |= uint8(VerusConstants.MAPPING_ERC1155_ERC_DEFINITION);
            }
            returnCurrency.flags |= uint8(VerusConstants.MAPPING_ETHEREUM_OWNED);
        }
        else if (options & VerusConstants.OPTION_NFT_TOKEN == VerusConstants.OPTION_NFT_TOKEN) { //minted NFT from verus
        
            returnCurrency.flags |= uint8(VerusConstants.MAPPING_ERC721_NFT_DEFINITION);
            returnCurrency.flags |= uint8(VerusConstants.MAPPING_VERUS_OWNED);
            nativeCurrencyID = address(0); //The Verus NFT contract is not known by this contract so it will be set when the NFT is minted.
        }
        else { // Verus owned ERC20, ERC20 contract not known yet.
        
            returnCurrency.flags |= uint8(VerusConstants.MAPPING_ERC20_DEFINITION);
            returnCurrency.flags |= uint8(VerusConstants.MAPPING_VERUS_OWNED);
        }

        returnCurrency.ERCContract = nativeCurrencyID;
        
        if (NativeCurrencyType & VerusConstants.FLAG_DEST_AUX == VerusConstants.FLAG_DEST_AUX) {

            assembly {
                nextOffset := add(nextOffset, 1) //move to vector length 
            }

            uint256 TokenId;

            TokenId = readAuxDestPK(input, nextOffset);

            if (NativeCurrencyTypeNoFlags == VerusConstants.DEST_ETH) {
                returnCurrency.tokenID = TokenId;
            }
            else if (NativeCurrencyTypeNoFlags == VerusConstants.DEST_ETHNFT &&
                TokenId != nftID) {
                // if the NFT ID does not match the auxdest NFT ID then the currency is invalid
                returnCurrency.flags = uint8(VerusConstants.MAPPING_INVALID);
                return returnCurrency;
            }
        } 
        return returnCurrency;
    }

    function deserializeTransfers(bytes memory tempSerialized, uint8 numberOfTransfers) public pure
        returns (VerusObjects.PackedSend[] memory tempTransfers, VerusObjects.PackedCurrencyLaunch[] memory launchTxs, uint32 counter, uint176[] memory refundAddresses)
    { 
        // return value counter is a packed 32bit number first bytes is number of transfers, 3rd byte number of ETH sends 4th byte number of currencey launches
              
        tempTransfers = new VerusObjects.PackedSend[](numberOfTransfers); 
        refundAddresses = new uint176[](numberOfTransfers);
        launchTxs = new VerusObjects.PackedCurrencyLaunch[](3); //max to Currency launches
        address tempaddress;
        uint64 temporaryRegister1;
        uint8 destinationType;
        uint256 nextOffset = 1;
        uint176 refundAddress;
        uint64 flags;

        while (nextOffset <= tempSerialized.length) {
            
            assembly {
                destinationType := mload(add(tempSerialized, nextOffset)) // Read one byte at the given offset
                if iszero(eq(and(destinationType,0xff), 1)) {
                    revert(0, 0) // Revert the transaction if version is not equal to 1
                }
                nextOffset := add(nextOffset, VERUS_ID_LENGTH)
                tempaddress := mload(add(tempSerialized, nextOffset)) // skip version 0x01 (1 byte) and read currency being sent
            }

            (temporaryRegister1, nextOffset)  = readVarint(tempSerialized, nextOffset);  // read varint (amount) returns next idx position
            (flags, nextOffset) = readVarint(tempSerialized, nextOffset);

            tempTransfers[uint8(counter)].currencyAndAmount = uint256(temporaryRegister1) << VerusConstants.UINT160_BITS_SIZE; //shift amount and pack
            tempTransfers[uint8(counter)].currencyAndAmount |= uint256(uint160(tempaddress));

            nextOffset += VERUS_ID_LENGTH; //skip feecurrency id always vETH, variint already 1 byte in so 19

            (temporaryRegister1, nextOffset) = readVarint(tempSerialized, nextOffset); //fees read into 'temporaryRegister1' but not used
            
            // Store Fees temporarily in the tokenID field
            launchTxs[2].tokenID += temporaryRegister1;
            assembly {
                nextOffset := add(nextOffset, 1) //move to read the destination type
                destinationType := mload(add(tempSerialized, nextOffset))
                nextOffset := add(nextOffset, 1) //move to read destination vector length compactint
            }

            // get the length of the destination and move the offset to the start of the destination address

            (temporaryRegister1, nextOffset) = readCompactSizeLE2(tempSerialized, nextOffset);    

            // if destination an ERC Send (ETH, ERC20, ERC721, ERC1155)
            if (destinationType & VerusConstants.DEST_ETH == VerusConstants.DEST_ETH) {

                assembly {
                    tempaddress := mload(sub(add(add(tempSerialized, nextOffset), VERUS_ID_LENGTH), 1)) //skip back one byte to read address
                }
                tempTransfers[uint8(counter)].destinationAndFlags = uint256(uint160(tempaddress));
            }
            else if (destinationType & VerusConstants.DEST_REGISTERCURRENCY == VerusConstants.DEST_REGISTERCURRENCY || 
                     destinationType & VerusConstants.DEST_ETHNFT == VerusConstants.DEST_ETHNFT) { 
                
                launchTxs[(counter >> 24 & 0xff)] = currencyParser(tempSerialized, nextOffset);

                if (launchTxs[(counter >> 24 & 0xff)].flags != 0) {
                    // if the currency is valid then set the iaddress to the currencyID and increment the counter.
                    launchTxs[(counter >> 24 & 0xff)].iaddress = address(uint160(tempTransfers[uint8(counter)].currencyAndAmount));
                    counter += 0x1000000; //This is the Launch currency counter packed into the 4th byte
                }
            }

            assembly {
                nextOffset := add(nextOffset, temporaryRegister1) //move to end of destination address + one byte ahead.
            }

            // If FLAG_DEST_GATEWAY is set then skip the gateway fields as well.
            if (destinationType & VerusConstants.FLAG_DEST_GATEWAY == VerusConstants.FLAG_DEST_GATEWAY)
            {
                assembly {
                    nextOffset := add(nextOffset, TRANSFER_GATEWAYSKIP) //move to vector length 
                }
            }

            if (destinationType & VerusConstants.FLAG_DEST_AUX == VerusConstants.FLAG_DEST_AUX) {

                (temporaryRegister1, nextOffset) = readCompactSizeLE2(tempSerialized, nextOffset);    // get the length of the auxDest

                // NOTE: This uses the last aux address as the refund address. Check with Verus this is intended.

                for (uint i = temporaryRegister1; i > 0; i--) {
                    (temporaryRegister1, nextOffset) = readCompactSizeLE2(tempSerialized, nextOffset);    // get the length of the auxDest sub array
                    assembly {
                        refundAddress := mload(sub(add(add(tempSerialized, nextOffset), temporaryRegister1), 1)) //skip type +1 byte to read address
                    }
                    refundAddresses[uint8(counter)] = refundAddress;

                    // Note: this moves to one byte past the data ready to read the next byte. 
                    nextOffset += temporaryRegister1;
                }
            }

            counter++;

            assembly {
                nextOffset := add(nextOffset, VERUS_ID_LENGTH) //move to read destCurrencyID
            }

            if (flags & VerusConstants.RESERVE_TO_RESERVE == VerusConstants.RESERVE_TO_RESERVE)
            {
                assembly {
                    nextOffset := add(nextOffset, VERUS_ID_LENGTH) //move to read secondReserveID
                }
            }

            if (flags & VerusConstants.CROSS_SYSTEM == VerusConstants.CROSS_SYSTEM )
            {
                assembly {
                    nextOffset := add(nextOffset, VERUS_ID_LENGTH) //move to read destSystemID
                }
            }

        }

        return (tempTransfers, launchTxs, counter, refundAddresses);

    }
        
    function readVarint(bytes memory buf, uint idx) public pure returns (uint64 v, uint retidx) {
        uint8 b;
    
        assembly {
            let end := add(idx, 10)
            let i := idx
            retidx := add(idx, 1)
            for {} lt(i, end) {} {
                b := mload(add(buf, retidx))
                i := add(i, 1)
                v := or(shl(7, v), and(b, 0x7f))
                if iszero(eq(and(b, 0x80), 0x80)) {
                    break
                }
                v := add(v, 1)
                retidx := add(retidx, 1)
            }
        }

    }

   // NOTE: This function always leaves the serializer a byte after the data, ready to read the next byte.

   function readCompactSizeLE2(bytes memory incoming, uint256 offset) public pure returns(uint64 v, uint retidx) {

        uint8 oneByte;
        assembly {
            oneByte := mload(add(incoming, offset))
        }
        offset++;
        if (oneByte < 253)
        {
            return (uint64(oneByte), offset);
        }
        else if (oneByte == 253)
        {
            offset++;
            uint16 twoByte;
            assembly {
                twoByte := mload(add(incoming, offset))
            }
            return (((twoByte << 8) & 0xffff)  | twoByte >> 8, offset + 1);
        }
        else if (oneByte == 254)
        {
            offset += 3;
            uint32 fourByte;
            assembly {
                fourByte := mload(add(incoming, offset))
            }
            return (serializeUint32(fourByte), offset + 3);
        }
        else
        {
            offset += 7;
            uint64 eightByte;
            assembly {
                eightByte := mload(add(incoming, offset))
            }
            return (serializeUint64(eightByte), offset + 7);
        }
    }

    function deserializeTransfer(bytes memory serialized) public view returns (VerusObjects.CReserveTransfer memory transfer){ 

        uint256 nextOffset;
        address tempaddress;
        uint64 tempReg1;
        uint8 tempuint8;
                    
        assembly {
            nextOffset := add(nextOffset, 1) //move to read the version type
            tempuint8 := mload(add(serialized, nextOffset)) // read the version type
            nextOffset := add(nextOffset, VERUS_ID_LENGTH) //move to read the currencyID
            tempaddress := mload(add(serialized, nextOffset)) // read the version currencyID
    
        }
        transfer.version = tempuint8;

        transfer.currencyvalue.currency = tempaddress;
    
        (tempReg1, nextOffset)  = readVarint(serialized, nextOffset);  // read varint (nValue) returns next idx position

        transfer.currencyvalue.amount = tempReg1;  //copy the value

        (tempReg1, nextOffset) = readVarint(serialized, nextOffset); //read the flags

        transfer.flags = uint32(tempReg1);  //copy the flags

        assembly {
            nextOffset := add(nextOffset, VERUS_ID_LENGTH) //move to read the destination type, note already 1 byte in so only move 19
            tempaddress := mload(add(serialized, nextOffset)) // read the feecurrencyid
          
        }
        transfer.feecurrencyid = tempaddress; //copy the feecurrency

        (transfer.fees, nextOffset) = readVarint(serialized, nextOffset); //read the fees and copy into structure

        assembly {
            nextOffset := add(nextOffset, 1)
            tempuint8 := mload(add(serialized, nextOffset))  // already at destination type location so read byte
        }
        transfer.destination.destinationtype = tempuint8; //copy destination type 

        if (tempuint8 == (VerusConstants.DEST_ETH + VerusConstants.FLAG_DEST_GATEWAY + VerusConstants.FLAG_DEST_AUX) || 
            tempuint8 == VerusConstants.DEST_ID ||
            tempuint8 == VerusConstants.DEST_PKH) {
            
            assembly {
            nextOffset := add(nextOffset, 1)  // skip vector length
            nextOffset := add(nextOffset, VERUS_ID_LENGTH) //move to read the destinationaddress, note already at vector length. 
            tempaddress := mload(add(serialized, nextOffset))  // read desitination address note always 20 bytes.
            }

        } else {revert();} // note only 3 types allowed at the moment

        bytes memory tempBouncebacktype;

        if (tempuint8 == (VerusConstants.DEST_ETH + VerusConstants.FLAG_DEST_GATEWAY + VerusConstants.FLAG_DEST_AUX)) {

            tempBouncebacktype = this.slice(serialized, nextOffset, nextOffset + ETH_SEND_GATEWAY_AND_AUX_DEST);
            assembly {
                nextOffset := add(nextOffset, ETH_SEND_GATEWAY_AND_AUX_DEST)  // skip vector length
            }
        }

        transfer.destination.destinationaddress = abi.encodePacked(tempaddress, tempBouncebacktype);

        assembly {
            nextOffset := add(nextOffset, VERUS_ID_LENGTH) //move to read the destinationcurrency address
            tempaddress := mload(add(serialized, nextOffset)) // read the destinationcurrency address
        }

        transfer.destcurrencyid = tempaddress;

        if (transfer.flags & VerusConstants.RESERVE_TO_RESERVE == VerusConstants.RESERVE_TO_RESERVE) {
        
            assembly {
                nextOffset := add(nextOffset, VERUS_ID_LENGTH) //move to read the secondreserveid
                tempaddress := mload(add(serialized, nextOffset)) // read the secondreserveid
            }

            transfer.secondreserveid = tempaddress;
        }
        
        return transfer;
    }

     function slice (bytes calldata data, uint256 start, uint256 end) public pure returns (bytes memory) {

        return data[start:end];
       
    }

        function _toLower(bytes memory bStr) internal pure returns (string memory) {

        bytes memory bLower = new bytes(bStr.length);
        for (uint i = 0; i < bStr.length; i++) {
            // Uppercase character...
            if ((uint8(bStr[i]) >= 65) && (uint8(bStr[i]) <= 90)) {
                // So we add 32 to make it lowercase
                bLower[i] = bytes1(uint8(bStr[i]) + 32);
            } else {
                bLower[i] = bStr[i];
            }
        }
        return string(bLower);
    }


    function sha256d(string memory _string) internal pure returns(bytes32){
        return sha256(abi.encodePacked(sha256(abi.encodePacked(_string))));
    }

    function checkIAddress(VerusObjects.PackedCurrencyLaunch memory _tx) public pure{

        address calculated;

        calculated = address(ripemd160(abi.encodePacked(sha256(abi.encodePacked(sha256d(string(abi.encodePacked(_tx.parent,sha256d(_toLower(bytes(_tx.name)))))))))));

        require(calculated == _tx.iaddress, "Iaddress does not match");
    }

    function readAuxDestPK(bytes memory input, uint256 nextOffset) internal pure returns(uint256) { 

        uint64 temporaryRegister1;
        uint256 tokenID;
        (temporaryRegister1, nextOffset) = readCompactSizeLE2(input, nextOffset);    // get the length of the auxDest

        if (temporaryRegister1 == 1) {
            (temporaryRegister1, nextOffset) = readCompactSizeLE2(input, nextOffset);    // get the length of the auxDest sub array, this will be a CReserveDestination
            if (uint8(input[nextOffset - 1]) == VerusConstants.DEST_PK && uint8(input[nextOffset]) == 0x21 //check for PKH and 33 bytes
                && uint8(input[nextOffset + 1]) == VerusConstants.DEST_PKH) {

                assembly {
                    nextOffset := add(nextOffset, 1) //move to vector length
                    nextOffset := add(nextOffset, 1) //move to PKtype
                    nextOffset := add(nextOffset, CCC_TOKENID_OFFSET) //move to TokenId address
                    tokenID := mload(add(input, nextOffset)) 
                }
            return tokenID;
            }  
        }
        return tokenID;
    }
}