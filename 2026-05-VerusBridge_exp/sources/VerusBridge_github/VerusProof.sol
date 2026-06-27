// SPDX-License-Identifier: MIT
// Bridge between ethereum and verus

pragma solidity >=0.4.22;
pragma abicoder v2;
import "../Libraries/VerusObjects.sol";
import "./VerusBlake2b.sol";
import {VerusSerializer} from "../VerusBridge/VerusSerializer.sol";
import "../Libraries/VerusObjectsCommon.sol";
import "../VerusNotarizer/VerusNotarizer.sol";
import "./VerusMMR.sol";
import "../Storage/StorageMaster.sol";

contract VerusProof is VerusStorage  {
    
    address immutable VETH;
    address immutable BRIDGE;
    address immutable VERUS;
    uint constant FORKS_DATA_OFFSET_FOR_HEIGHT = 224;
    uint constant FORKS_PROPOSER_SLOT = 2;

    constructor(address vETH, address Bridge, address Verus){

        VETH = vETH;
        BRIDGE = Bridge;
        VERUS = Verus;
    }

    using VerusBlake2b for bytes;
    
    // these constants should be able to reference each other, as many are relative, but Solidity does not
    // allow referencing them and still considering the result a constant. For any changes to these constants,
    // which are designed to ensure smart transaction provability, care must be take to ensure that OUTPUT_SCRIPT_OFFSET
    // is present and substituted for all equivalent values (currently (32 + 8))
    uint8 constant CCE_EVAL_EXPORT = 0xc;
    uint32 constant CCE_COPTP_HEADERSIZE = 4 + 1;   // skips: 1(PUSHDATA len) + 2(version) + 2(flags) = 5, ready to read flags
    uint32 constant CCE_COPTP_EVALOFFSET = 2;
    uint32 constant CCE_SOURCE_SYSTEM_OFFSET = 24;
    uint32 constant CCE_HASH_TRANSFERS_DELTA = 32;
    uint32 constant CCE_DEST_SYSTEM_DELTA = 20;
    uint32 constant CCE_DEST_CURRENCY_DELTA = 20;
    uint32 constant CCE_SOURCE_SYSTEM_DELTA = 20;  // advance past flags(2) to sourceSystemID... no: flags read inline, then +20 for sourceID

    uint32 constant OUTPUT_SCRIPT_OFFSET = (8 + 1);                 // start of prevector serialization for output script
    uint32 constant SCRIPT_OP_CHECKCRYPTOCONDITION = 0xcc;
    uint32 constant SCRIPT_OP_PUSHDATA1 = 0x4c;
    uint32 constant SCRIPT_OP_PUSHDATA2 = 0x4d;
    uint32 constant TYPE_TX_OUTPUT = 4;
    uint32 constant SIZEOF_UINT64 = 8;
    uint8 constant FLAG_FRACTIONAL = 1;
    uint8 constant FLAG_REFUNDING = 4;
    uint8 constant FLAG_LAUNCHCONFIRMED = 0x10;
    uint8 constant FLAG_LAUNCHCOMPLETEMARKER = 0x20;
    uint8 constant AUX_DEST_ETH_VEC_LENGTH = 22;
    uint8 constant TX_HEADER = 1;
    uint8 constant NUM_TX_PROOFS = 3;

    bytes16 constant _SYMBOLS = "0123456789abcdef";

    function checkProof(bytes32 hashToProve, VerusObjects.CTXProof[] memory _branches) public view returns(bytes32){
        //loop through the branches from bottom to top
        bytes32 hashInProgress = hashToProve;

        require(_branches.length > 0);
        
        for(uint i = 0; i < _branches.length; i++){
            hashInProgress = checkBranch(hashInProgress,_branches[i].proofSequence);
        }
        return hashInProgress;
    }

    function checkBranch(bytes32 _hashToCheck,VerusObjects.CMerkleBranch memory _branch) public view returns(bytes32){
        
        require(_branch.branch.length > 0,"Branch must be longer than 0");
        uint branchLength = _branch.branch.length;
        bytes32 hashInProgress = _hashToCheck;
        bytes memory joined;
        //hashInProgress = blake2b.bytesToBytes32(abi.encodePacked(_hashToCheck));

        uint hashIndex = VerusMMR.GetMMRProofIndex(_branch.nIndex, _branch.nSize, _branch.extraHashes);
        
       for(uint i = 0;i < branchLength; i++){
            if(hashIndex & 1 > 0){
                require(_branch.branch[i] != _hashToCheck,"Value can be equal to node but never on the right");
                //join the two arrays and pass to blake2b
                joined = abi.encodePacked(_branch.branch[i],hashInProgress);
            } else {
                joined = abi.encodePacked(hashInProgress,_branch.branch[i]);
            }
            hashInProgress = joined.createHash();
            hashIndex >>= 1;
        }

        return hashInProgress;

    }
    
    function checkExportAndTransfers(VerusObjects.CReserveTransferImport memory _import, bytes32 hashedTransfers) public view returns (uint128, uint176) {

        // the first component of the import partial transaction proof is the transaction header, for each version of
        // transaction header, we have a specific offset for the hash of transfers. if we change this, we must
        // deprecate and deploy new contracts

        if(_import.partialtransactionproof.components[0].elType != TX_HEADER){
            return (uint64(0), uint128(0));
        }

        for (uint i = 1; i < _import.partialtransactionproof.components.length; i++)
        {
            if (_import.partialtransactionproof.components[i].elType != TYPE_TX_OUTPUT)
                continue;
            
            bytes memory firstObj = _import.partialtransactionproof.components[i].elVchObj; // we should have a first entry that is the txout with the export

            // ensure this is an export to VETH and pull the hash for reserve transfers
            // to ensure a valid export.
            // the eval code for the main COptCCParams must be EVAL_CROSSCHAIN_EXPORT, and the destination system
            // must match VETH

            uint32 nextOffset;
            uint8 var1;
            uint8 opCode2;
            uint32 nIndex; 
            nIndex = _import.partialtransactionproof.components[i].elProof[0].proofSequence.nIndex;

            VerusObjectsCommon.UintReader memory readerLen;

            readerLen = VerusSerializer(contracts[uint(VerusConstants.ContractType.VerusSerializer)]).readCompactSizeLE(firstObj, OUTPUT_SCRIPT_OFFSET);    // get the length of the output script
            readerLen = VerusSerializer(contracts[uint(VerusConstants.ContractType.VerusSerializer)]).readCompactSizeLE(firstObj, readerLen.offset);        // then length of first master push

            // must be push less than 75 bytes, as that is an op code encoded similarly to a vector.
            // all we do here is ensure that is the case and skip master
            if (readerLen.value == 0 || readerLen.value > 0x4b)
            {
                return (uint64(0), uint128(0));
            }

            nextOffset = uint32(readerLen.offset + readerLen.value);        // add the length of the push of master to point to cc opcode

            assembly {
                var1 := mload(add(firstObj, nextOffset))         // this should be OP_CHECKCRYPTOCONDITION
                nextOffset := add(nextOffset, 1)                    // and after that...
                opCode2 := mload(add(firstObj, nextOffset))         // should be OP_PUSHDATA1 or OP_PUSHDATA2
                nextOffset := add(nextOffset, 1)                    // point to the length of the pushed data after CC instruction
            }

            if (var1 != SCRIPT_OP_CHECKCRYPTOCONDITION ||
                (opCode2 != SCRIPT_OP_PUSHDATA1 && opCode2 != SCRIPT_OP_PUSHDATA2))
            {
                return (uint64(0), uint128(0));
            }

            if (opCode2 == SCRIPT_OP_PUSHDATA1)
            {
                assembly {
                    nextOffset := add(nextOffset, 1)
                }
            }
            else
            {
                assembly {
                    nextOffset := add(nextOffset, 2)
                }

            }

            // COptCCParams are serialized as pushes in a script, first the header, then the keys, then the data
            // skip right to the serialized export and then to the source system

            nextOffset += CCE_COPTP_EVALOFFSET;
            assembly {
                var1 := mload(add(firstObj, nextOffset))
            }

            if (var1 != CCE_EVAL_EXPORT)
            {
                return (uint64(0), uint128(0));
            }

            nextOffset += CCE_SOURCE_SYSTEM_OFFSET;

            assembly {
                opCode2 := mload(add(firstObj, nextOffset))         // should be OP_PUSHDATA1 or OP_PUSHDATA2
            }

            
            if (opCode2 == SCRIPT_OP_PUSHDATA2)
            {
                    nextOffset += 1; // one extra byte taken for varint
            } 
            nextOffset += CCE_COPTP_HEADERSIZE;

            // nVersion is last two bytes of header, but we don't currently use it for anything, so just read and move on
            // validate source and destination values as well and set reward address
            return (checkCCEValues(firstObj, nextOffset, hashedTransfers, nIndex));
        
        }
        return (uint128(0), uint176(0));
    }

    function checkCCEValues(bytes memory firstObj, uint32 nextOffset, bytes32 hashedTransfers, uint32 nIndex) public view returns(uint128 tmpPacked, uint176 exporter)
    {
        bytes32 hashReserveTransfers;
        address systemSourceID;
        address destSystemID;
        uint32 tempRegister;
        uint8 tmpuint8;
        uint128 packedRegister;
        
        assembly {
            let flags := and(mload(add(firstObj, nextOffset)), 0x0800)  // flags LE uint16: byte0=0x08 lands at bits 15-8 in mload word, byte1=0x00 at bits 7-0; mask 0x0800 checks FLAG_SUPPLEMENTAL
            if gt(flags, 0) {
                revert(0, 0)  
            }
            nextOffset := add(nextOffset, CCE_SOURCE_SYSTEM_DELTA)
            systemSourceID := mload(add(firstObj, nextOffset))       // source system ID, which should match expected source (VRSC/VRSCTEST)
            nextOffset := add(nextOffset, CCE_HASH_TRANSFERS_DELTA)
            hashReserveTransfers := mload(add(firstObj, nextOffset)) // get hash of reserve transfers from partial transaction proof
            nextOffset := add(nextOffset, CCE_DEST_SYSTEM_DELTA)
            destSystemID := mload(add(firstObj, nextOffset))         // destination system, which should be vETH
            nextOffset := add(nextOffset, CCE_DEST_CURRENCY_DELTA)   // goto destcurrencyid
            nextOffset := add(nextOffset, 1)                         // goto exporter type  
            tmpuint8 := mload(add(firstObj, nextOffset))             // read exporter type
            nextOffset := add(nextOffset, 1)                         // goto exporter destination length
            let lengthOfExporter := and(mload(add(firstObj, nextOffset)), 0xff)  
            if gt(lengthOfExporter, 0) {
                nextOffset := add(nextOffset, lengthOfExporter)  // goto exporter destination
                exporter := mload(add(firstObj, nextOffset))     // read exporter destination
            }
        }

        if(tmpuint8 & VerusConstants.FLAG_DEST_GATEWAY == VerusConstants.FLAG_DEST_GATEWAY)
        {
            nextOffset += VerusConstants.FLAG_DEST_GATEWAY_LENGTH;  // skip past gateway ID to get to auxdest vector length
        }

        if (tmpuint8 & VerusConstants.FLAG_DEST_AUX == VerusConstants.FLAG_DEST_AUX)
        {
            nextOffset += 1;  // goto auxdest parent vec length position
            (nextOffset, exporter) = readAuxDest(firstObj, nextOffset, exporter); //NOTE: If Auxdest present use address
            nextOffset -= 1;  // NOTE: Next Varint call takes array pos not array pos +1
        }

        assembly {
            nextOffset := add(nextOffset, 8)                               // move to read num inputs
            tempRegister := mload(add(firstObj, nextOffset))                // number of numInputs                 
        }

        (packedRegister, nextOffset)  = readVarint(firstObj, nextOffset);   // put startheight at [0] 32bit chunk
        tempRegister = serializeUint32(tempRegister);                          // reverse endian of no. transfers
        packedRegister  |= (uint128(tempRegister) << 96) ;                     // put number of transfers at [3] 32-bit chunk     
        
        (tempRegister, nextOffset)  = readVarint(firstObj, nextOffset); 
        packedRegister  |= (uint128(tempRegister) << 32) ;                   // put endheight at [1] 32 bit chunk
        packedRegister  |= (uint128(nIndex) << 64) ;                        // put nindex at [2] 32 bit chunk
        assembly {
            nextOffset := add(nextOffset, 1)                                // move to next byte for mapsize
            tmpuint8 := mload(add(firstObj, nextOffset)) 
        }

        if (tmpuint8 == 1) 
        {
            assembly {
                nextOffset := add(add(nextOffset, CCE_DEST_CURRENCY_DELTA), 8)  // move 20 + 8 bytes for (address + 64bit)
            }

        }

        if (!(hashedTransfers == hashReserveTransfers &&
                systemSourceID == VERUS &&
                destSystemID == VETH)) {

            revert("CCE information does not checkout");
        }

        tmpPacked = packedRegister;
        return (tmpPacked, exporter); 

    }

    function readAuxDest (bytes memory firstObj, uint32 nextOffset, uint176 exporter) public view returns (uint32, uint176)
    {
                                                  
            VerusObjectsCommon.UintReader memory readerLen;
            readerLen = VerusSerializer(contracts[uint(VerusConstants.ContractType.VerusSerializer)]).readCompactSizeLE(firstObj, nextOffset);    // get the length of the auxDest
            nextOffset = readerLen.offset;
            uint arraySize = readerLen.value;
            
            for (uint i = 0; i < arraySize; i++)
            {
                    readerLen = VerusSerializer(contracts[uint(VerusConstants.ContractType.VerusSerializer)]).readCompactSizeLE(firstObj, nextOffset);    // get the length of the auxDest sub array
                    if (readerLen.value == AUX_DEST_ETH_VEC_LENGTH)
                    {
                         assembly {
                            exporter := mload(add(add(firstObj, nextOffset),AUX_DEST_ETH_VEC_LENGTH))
                         }
                    }

                    nextOffset = (readerLen.offset + uint32(readerLen.value));
            }
            return (nextOffset, exporter);
    }

    // roll through each proveComponents
    function proveComponents(VerusObjects.CReserveTransferImport memory _import) public view returns(bytes32 txRoot){
     
        bytes32 hashInProgress;
        bytes32 testHash;
  
        hashInProgress = _import.partialtransactionproof.components[0].elVchObj.createHash();
        if (_import.partialtransactionproof.components[0].elType == TX_HEADER )
        {
            txRoot = checkProof(hashInProgress, _import.partialtransactionproof.components[0].elProof);           
        }
        
        for (uint i = 1; i < _import.partialtransactionproof.components.length; i++) {

            hashInProgress = _import.partialtransactionproof.components[i].elVchObj.createHash();
            testHash = checkProof(hashInProgress, _import.partialtransactionproof.components[i].elProof);
        
            if (txRoot != testHash) 
            {
                txRoot = bytes32(0);
                break;
            }
        }

        return txRoot;
    }
    
    function proveImports(bytes calldata dataIn ) external view returns(uint128, uint176){
        
        (VerusObjects.CReserveTransferImport memory _import, bytes32 hashOfTransfers) = abi.decode(dataIn, (VerusObjects.CReserveTransferImport, bytes32));
        bytes32 confirmedStateRoot;
        bytes32 retStateRoot;
        uint176 exporter;
        uint128 heightsAndTXNum;

        (heightsAndTXNum, exporter) = checkExportAndTransfers(_import, hashOfTransfers);
        
        bytes32 txRoot = proveComponents(_import);

        if(txRoot == bytes32(0))
        { 
            revert("Components do not validate"); 
        }
        
        require(_import.partialtransactionproof.txproof.length == NUM_TX_PROOFS);

        retStateRoot = checkProof(txRoot, _import.partialtransactionproof.txproof);
        confirmedStateRoot = getLastConfirmedVRSCStateRoot();

        if (retStateRoot == bytes32(0) || retStateRoot != confirmedStateRoot) {

            revert("Stateroot does not match");
        }
        //truncate to only return heights as, contract will revert if issue with proofs.
        return (heightsAndTXNum, exporter);
 
    }

    function getLastConfirmedVRSCStateRoot() public view returns (bytes32) {

        bytes storage tempArray = bestForks[0];
        if (tempArray.length == 0)
        {
            return bytes32(0);
        }

        bytes32 stateRoot;
        uint32 height;
        bytes32 slot;

        assembly {
                    mstore(add(slot, 32),tempArray.slot)
                    height := shr(FORKS_DATA_OFFSET_FOR_HEIGHT, sload(add(keccak256(add(slot, 32), 32), FORKS_PROPOSER_SLOT)))
        }
        tempArray = proofs[bytes32(uint256(height))];

        assembly {
                mstore(add(slot, 32),tempArray.slot)
                stateRoot := sload(add(keccak256(add(slot, 32), 32), 0))
        }

        return stateRoot;
    }

    function readVarint(bytes memory buf, uint idx) public pure returns (uint32 v, uint32 retidx) {
        uint8 b;
    
        assembly {  ///assemmbly  2267 GAS
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

    function getTokenList(uint256 start, uint256 end) external returns(VerusObjects.setupToken[] memory ) {

        uint tokenListLength;
        tokenListLength = tokenList.length;
        VerusObjects.mappedToken memory recordedToken;
        uint i;
        uint endPoint;

        endPoint = tokenListLength - 1;
        if (start >= 0 && start < tokenListLength)
        {
            i = start;
        }

        if (end > i && end < tokenListLength)
        {
            endPoint = end;
        }
        VerusObjects.setupToken[] memory temp = new VerusObjects.setupToken[]((endPoint - i) + 1);

        uint j;
        for(; i <= endPoint; i++) {

            address iAddress;
            iAddress = tokenList[i];
            recordedToken = verusToERC20mapping[iAddress];
            temp[j].iaddress = iAddress;
            temp[j].flags = recordedToken.flags;

            if (iAddress == VETH)
            {
                temp[j].erc20ContractAddress = address(0);
                temp[j].name = recordedToken.name;
                temp[j].ticker = "ETH";
            }
            else if(recordedToken.flags & VerusConstants.MAPPING_ERC20_DEFINITION == VerusConstants.MAPPING_ERC20_DEFINITION )
            {
                temp[j].erc20ContractAddress = recordedToken.erc20ContractAddress;
                bytes memory tempName;
                tempName = bytes(recordedToken.name);
                if (tempName[1] == "." && tempName[2] == "." && tempName[3] == ".") {

                    temp[j].name = string(abi.encodePacked("[", toHexString(uint160(recordedToken.erc20ContractAddress), 20), "]", slice(tempName, 5, tempName.length - 5)));

                } else {
                    temp[j].name = recordedToken.name;
                }
                (bool success, bytes memory retval) = recordedToken.erc20ContractAddress.call(abi.encodeWithSignature("symbol()"));

                if (success && retval.length > 0x40) {
                    temp[j].ticker = abi.decode(retval, (string));
                } else if (retval.length == 0x20) {
                    temp[j].ticker = string(slice(retval, 0, (retval[3] == 0 ? 3 : 4)));
                } else {
                    temp[j].ticker = string(slice(bytes(temp[j].name), 3, 4));
                }
            }
            else if(recordedToken.flags & VerusConstants.MAPPING_ERC721_NFT_DEFINITION == VerusConstants.MAPPING_ERC721_NFT_DEFINITION
                        || recordedToken.flags & VerusConstants.MAPPING_ERC1155_NFT_DEFINITION == VerusConstants.MAPPING_ERC1155_NFT_DEFINITION
                        || recordedToken.flags & VerusConstants.MAPPING_ERC1155_ERC_DEFINITION == VerusConstants.MAPPING_ERC1155_ERC_DEFINITION)
            {
                temp[j].erc20ContractAddress = recordedToken.erc20ContractAddress;
                temp[j].name = recordedToken.name;
                temp[j].tokenID = recordedToken.tokenID;
            }
            j++;
        }

        return temp;
    }

    function serializeUint32(uint32 number) public pure returns(uint32){
        // swap bytes
        number = ((number & 0xFF00FF00) >> 8) | ((number & 0x00FF00FF) << 8);
        number = (number >> 16) | (number << 16);
        return number;
    }

    function toHexString(uint160 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = _SYMBOLS[value & 0xf];
            value >>= 4;
        }
        require(value == 0, "Strings: hex length insufficient");
        return string(buffer);
    }

function slice(
        bytes memory _bytes,
        uint256 _start,
        uint256 _length
    )
        internal
        pure
        returns (bytes memory)
    {
        require(_length + 31 >= _length, "slice_overflow");
        require(_bytes.length >= _start + _length, "slice_outOfBounds");

        bytes memory tempBytes;
        assembly {
            switch iszero(_length)
            case 0 {
                tempBytes := mload(0x40)
                let lengthmod := and(_length, 31)
                let mc := add(add(tempBytes, lengthmod), mul(0x20, iszero(lengthmod)))
                let end := add(mc, _length)

                for {
                    let cc := add(add(add(_bytes, lengthmod), mul(0x20, iszero(lengthmod))), _start)
                } lt(mc, end) {
                    mc := add(mc, 0x20)
                    cc := add(cc, 0x20)
                } {
                    mstore(mc, mload(cc))
                }
                mstore(tempBytes, _length)
                mstore(0x40, and(add(mc, 31), not(31)))
            }
            default {
                tempBytes := mload(0x40)
                mstore(tempBytes, 0)
                mstore(0x40, add(tempBytes, 0x20))
            }
        }
        return tempBytes;
    }
    
}


