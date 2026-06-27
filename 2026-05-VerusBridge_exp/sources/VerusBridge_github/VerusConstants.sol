// SPDX-License-Identifier: MIT
// Bridge between ethereum and verus

pragma solidity >=0.8.9;
pragma abicoder v2;

// Developers notes for datatypes used:
// uint176 types are used to store CTransferDestiantions as we are limited to a type (1byte) + vector length (1byte) + 20 bytes address.
// These are used to allow the contract to process up to 50 transactions per CCE.  When a currency import enters the contract through a transaction
// The destination is a bytes array.


library VerusConstants {

    uint256 constant public transactionFee = 3000000000000000; //0.003 ETH 18 decimals
    uint256 constant public upgradeFee = 1000000000000000; //0.001 ETH 18 decimals WEI  TODO: increase for MAINNET
    uint64 constant public verusTransactionFee = 2000000; //0.02 VRSC 8 decimals
    uint64 constant public verusvETHTransactionFee = 300000; //0.003 vETH 8 decimals
    uint64 constant public verusvETHReturnFee = 1000000; //0.01 vETH 8 decimals
    uint64 constant public verusBridgeLaunchFeeShare = 500000000000;
    uint256 constant NOTARY_CLAIM_TX_GAS_COST = 310000; // gas required to run the notary fee claim function.
    uint256 constant GAS_BASE_COST_FOR_NOTARYS = 1100000; // 2 x submit imports 450k x 2 + base cost of submitimports.25k + 120K
    uint256 constant GAS_BASE_COST_FOR_REFUND_PAYOUTS = 20000; 
    uint32 constant VALID = 1;
    uint32 constant CONVERT = 2;
    uint32 constant CROSS_SYSTEM = 0x40; 
    uint8 constant FLAG_SUPPLEMENTAL = 8;
    uint32 constant BURN_CHANGE_PRICE = 0x80;              
    uint32 constant IMPORT_TO_SOURCE = 0x200;          
    uint32 constant RESERVE_TO_RESERVE = 0x400; 
    uint32 constant CURRENCY_EXPORT = 0x2000;
    uint8 constant NFT_POSITION = 0;
    bytes32 constant VDXF_SYSTEM_NOTARIZATION_NOTARYFEEPOOL = 0x00000000000000000000000039aDf7BA6E5c91eeef476Bb4aC9417549ba0d51a;
    bytes32 constant VDXF_SYSTEM_DAI_HOLDINGS =               0x000000000000000000000000334711b41Cf095C9D44d1a209f34bf3559eA7640;
    address constant VDXF_ETH_DAI_VRSC_LAST_RESERVES = address(0x1b83EBE56D691b909cFb0dFc291E5A0EDAAfc64C);
    bytes32 constant VDXFID_DAI_DSR_SUPPLY =    0x00000000000000000000000084206E821f7bB4c6F390299c1367600F608c28C8;
    bytes32 constant SUBMIT_IMPORTS_LAST_TXID = 0x00000000000000000000000037256eef64a0bf17344bcb0cbfcde4bea6746347;
    bytes32 constant VDXFID_DAI_BURNBACK_TIME_THRESHOLD = 0x0000000000000000000000007d6505549c434ef651d799ede5f0d3f698464fcf;
    // controls.control key — halt flags stored in storageGlobal
    bytes32 constant VDXF_CONTROLS_CONTROL_KEY = 0x000000000000000000000000b024b1e290c833d9c5703ef6184a7c84e7ddd335;
    uint8 constant HALT_NOTARIZATIONS  = 1;  // bit 0: stops setLatestData
    uint8 constant HALT_SUBMIT_IMPORTS = 2;  // bit 1: stops _createImports
    uint8 constant HALT_SEND_TRANSFERS = 4;  // bit 2: stops sendTransfer/sendTransferDirect
    uint176 constant VDXFID_VETH_BURN_ADDRESS = 0x0214B26820ee0C9b1276Aac834Cf457026a575dfCe84;
    uint256 constant DAI_BURNBACK_THRESHOLD = 1000000000000000000000; //1000 DAI 18 decimals
    uint256 constant DAI_BURNBACK_TRANSACTION_GAS_AMOUNT = 594722;
    uint256 constant DAI_BURNBACK_MAX_FEE_THRESHOLD = 40000000000;   //400 DAI in verus 8 decimals
    uint256 constant SECONDS_IN_DAY = 86400;
    uint256 constant REFUND_FEE_REIMBURSE_GAS_AMOUNT = 1000000;  //1,000,000 GAS
    uint256 constant CLAIM_NOTARY_FEE_THRESHOLD = 0.75 ether;
    uint8 constant MINIMUM_TRANSACTIONS_FOR_REFUNDS = 8;
    uint8 constant MINIMUM_TRANSACTIONS_FOR_REFUNDS_HALF = 4;

    uint32 constant INVALID_FLAGS = 0xffffffff - (VALID + CONVERT + RESERVE_TO_RESERVE + IMPORT_TO_SOURCE);

    uint8 constant DEST_PK = 1;
    uint8 constant DEST_PKH = 2;
    uint8 constant DEST_ID = 4;
    uint8 constant DEST_REGISTERCURRENCY = 6;
    uint8 constant DEST_ETH = 9;
    uint8 constant DEST_ETHNFT = 10;
    uint8 constant FLAG_DEST_AUX = 64;
    uint8 constant FLAG_DEST_GATEWAY = 128;
    uint8 constant FLAG_DEST_GATEWAY_LENGTH = 48;
    uint8 constant CURRENT_VERSION = 1;

    // deploy & launch Token flags These must match the constants in deploycontracts.js
    uint32 constant MAPPING_INVALID = 0;
    uint32 constant MAPPING_ETHEREUM_OWNED = 1;
    uint32 constant MAPPING_VERUS_OWNED = 2;
    uint32 constant MAPPING_PARTOF_BRIDGEVETH = 4;
    uint32 constant MAPPING_ISBRIDGE_CURRENCY = 8;
    uint32 constant MAPPING_ERC1155_NFT_DEFINITION = 16;
    uint32 constant MAPPING_ERC20_DEFINITION = 32;
    uint32 constant MAPPING_ERC1155_ERC_DEFINITION = 64;
    uint32 constant MAPPING_ERC721_NFT_DEFINITION = 128;
    
    // send flags
    uint32 constant TOKEN_ERC_SEND = 16;   
    uint32 constant TOKEN_ETH_SEND = 64;


    uint32 constant AUX_DEST_PREFIX = 0x01160214;

    uint32 constant TICKER_LENGTH_MAX = 4;
    uint8 constant DESTINATION_PLUS_GATEWAY = 68;

    //notary flags
    uint8 constant NOTARY_VALID = 1;
    uint8 constant NOTARY_REVOKED = 2;

    //notarizationflags
    uint32 constant FLAG_CONTRACT_UPGRADE = 0x200;

    //cCurrencydefintion constants
    uint32 constant OPTION_NFT_TOKEN = 0x800;

    uint constant SATS_TO_WEI_STD = 10000000000;
    uint8 constant NUMBER_OF_CONTRACTS = 11;
    uint64 constant MIN_VRSC_FEE = 4000000; //0.04 VRSC 8 decimals
    uint64 constant MAX_VERUS_TRANSFER = 1000000000000000000; //10,000,000,000.00000000
    uint constant VERUS_IMPORT_FEE = 2000000; //This is 0.02 VRSC 8 decimals
    uint constant VERUS_IMPORT_FEE_X2 = 4000000; //This is 2 x the fee 0.02 VRSC 8 decimals
    enum ContractType {
        TokenManager,
        VerusSerializer,
        VerusProof,
        VerusCrossChainExport,
        VerusNotarizer,
        CreateExport,
        VerusNotaryTools,
        ExportManager,
        SubmitImports,
        NotarizationSerializer,
        UpgradeManager
    } 

    uint8 constant UINT160_SIZE = 20;
    uint8 constant UINT64_SIZE = 8;
    uint8 constant UINT160_BITS_SIZE = 160;
    uint8 constant UINT176_BITS_SIZE = 176;
    uint8 constant NOTARIZER_INDEX_AND_FLAGS_OFFSET = 184;
    uint8 constant NOTARIZATION_VOUT_NUM_INDEX = 192;
    uint8 constant NOTARIZATION_VALID_BIT_SHIFT = 7;

    //Global Generic Variable types

    uint8 constant GLOBAL_TYPE_NOTARY_VALID_HIGH_BIT = 0x80;
    uint8 constant GLOBAL_TYPE_NOTARY_MASK = 0x7f;
    uint8 constant VOTE_LENGTH = 50;
    uint8 constant DEFAULT_INDEX_VALUE = 200;
    uint256 constant MAX_UINT256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
}

//TODO: extra constants to add 176, 92 etc..
//NOTE: Check constants with Mike

