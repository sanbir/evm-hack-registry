// SPDX-License-Identifier: MIT
// Bridge between ethereum and verus

pragma solidity >=0.8.9;
pragma abicoder v2;

import "./VerusObjectsCommon.sol";

library VerusObjects {

    struct blockCreated {
        uint index;
        bool created;
    }

    struct infoDetails {
        uint version;
        string VRSCversion;
        uint blocks;
        uint tiptime;
        string name;
        bool testnet;
    }
    
    struct currencyDetail {
        uint version;
        string name;
        address currencyid;
        address parent;
        address systemid;
        uint8 notarizationprotocol;
        uint8 proofprotocol;
        VerusObjectsCommon.CTransferDestination nativecurrencyid;
        address launchsystemid;
        uint startblock;
        uint endblock;
        uint64 initialsupply;
        uint64 prelaunchcarveout;
        address gatewayid;
        address[] notaries;
        uint minnotariesconfirm;
    }
    
    struct CCurrencyValueMap {
        address currency;
        uint64 amount;
    }

    struct CReserveTransfer {
        uint32 version;
        CCurrencyValueMap currencyvalue;
        uint32 flags;
        address feecurrencyid;
        uint64 fees;
        VerusObjectsCommon.CTransferDestination destination;
        address destcurrencyid;
        address destsystemid;
        address secondreserveid;
    }

    // CReserve Transfer Set is a simplified version of a crosschain export returning only the required info
    
    struct CReserveTransferSet {
        bytes32 exportHash;
        bytes32 prevExportHash;
        uint64 endHeight;
        CReserveTransfer[] transfers;
    }

    struct CReserveTransferSetCalled {
        bytes32 exportHash;
        bytes32 prevExportHash;
        uint64 startHeight;
        uint64 endHeight;
        CReserveTransfer[] transfers;
    }

    struct PackedSend {
        uint256 currencyAndAmount;    //tokenID
        uint256 destinationAndFlags;  //ETH address concatenated with flags
    }

    struct PackedCurrencyLaunch {
        uint256 tokenID;    
        address ERCContract;  //erc address
        address iaddress;
        address parent;
        uint8 flags;
        string name;
    }

    struct ETHPayments {
        address destination;  // the start index of next read. when idx=b.length, we're done
        uint256 amount;   // hold serialized data readonly
    }

    struct CReserveTransferImport {          
        CPtransactionproof partialtransactionproof;     
        bytes serializedTransfers;
    }

    struct CCrossChainExport {
        uint16 version;
        uint16 flags;
        address sourcesystemid;
        bytes32 hashtransfers;                        
        uint64 sourceheightstart;
        uint64 sourceheightend;
        address destinationsystemid;
        address destinationcurrencyid;
        uint32 numinputs;
        CCurrencyValueMap[] totalamounts;
        CCurrencyValueMap[] totalfees;
        CCurrencyValueMap[] totalburned;
        VerusObjectsCommon.CTransferDestination rewardaddress; //reward address
        int32 firstinput;
    }

    struct CMerkleBranch {
        uint8  CMerkleBranchBase;
        uint32 nIndex;
        uint32 nSize;
        uint8 extraHashes;
        bytes32[] branch;
    }

    struct CTXProof {
        uint8 branchType;
        CMerkleBranch proofSequence;
    }

    struct CComponents {
        uint8 elType;
        uint8 elIdx;
        bytes elVchObj;
        CTXProof[] elProof;
    }
    
    struct CPtransactionproof {
        uint8 version;
        uint8 typeC;
        CTXProof[] txproof;
        CComponents[] components;
    }

    struct mappedToken {
        address erc20ContractAddress;
        uint8 flags;
        uint tokenIndex;  //Used for ERC20, ERC721 and ERC1155, total amount of tokens transfered to the bridge
        string name;
        uint256 tokenID; 
    }

    struct setupToken {
        address iaddress;
        address erc20ContractAddress;
        address launchSystemID;
        uint8 flags;
        string name;
        string ticker;
        uint256 tokenID;
    }

    struct upgradeInfo {
        uint8 _vs;
        bytes32 _rs;
        bytes32 _ss;
        address[] contracts;
        uint8 upgradeType;
        bytes32 salt;
        address notarizerID;
        uint32 startHeight;
    }

    struct revokeInfo {
        uint8 _vs;
        bytes32 _rs;
        bytes32 _ss;
        address notaryID;
        bytes32 salt;
    }

    struct pendingUpgradetype {
        address notaryID;
        uint8 upgradeType;
    }

    struct notarizer {
        address main;
        address recovery;
        uint8 state;
    }

    struct lastImportInfo {
        bytes32 hashOfTransfers;
        bytes32 exporttxid;
        uint32 exporttxoutnum;
        uint32 height;
    }

    struct voteState {
        address txid;
        address[] pendingContracts;
        uint32 agree;
        uint32 count;
        uint32 startHeight;
        uint8 nullified;
    }
    struct revokeRecoverInfo{
        uint8 _vs;
        bytes32 _rs;
        bytes32 _ss;
        bytes32 salt;
        address notarizerID;
    }
 }