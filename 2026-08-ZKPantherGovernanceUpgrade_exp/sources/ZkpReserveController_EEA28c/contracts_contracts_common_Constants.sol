// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright 2021-25 Panther Protocol Foundation
// slither-disable-next-line solc-version
pragma solidity ^0.8.4;

// Constants

uint256 constant IN_PRP_UTXOs = 1;
uint256 constant IN_UTXOs = 2 + IN_PRP_UTXOs;

uint256 constant OUT_PRP_UTXOs = 1;
uint256 constant OUT_UTXOs = 2 + OUT_PRP_UTXOs;
uint256 constant OUT_MAX_UTXOs = OUT_UTXOs;
// Number of UTXOs given as a reward for an "advanced" stake
uint256 constant OUT_RWRD_UTXOs = 2;

// For overflow protection and circuits optimization
// (must be less than the FIELD_SIZE)
uint256 constant MAX_EXT_AMOUNT = 2 ** 96;
uint256 constant MAX_IN_CIRCUIT_AMOUNT = 2 ** 64;
uint256 constant MAX_TIMESTAMP = 2 ** 32;
uint256 constant MAX_ZASSET_ID = 2 ** 160;

// Maximum amount for PRP
uint256 constant MAX_PRP_AMOUNT = (2 ** 64) - 1;

// Token types
// (not `enum` to let protocol extensions use bits, if needed)
uint8 constant ERC20_TOKEN_TYPE = 0x00;
uint8 constant ERC721_TOKEN_TYPE = 0x10;
uint8 constant ERC1155_TOKEN_TYPE = 0x11;
uint8 constant NATIVE_TOKEN_TYPE = 0xFF;

// ZAsset statuses
// (not `enum` to let protocol extensions use bits, if needed)
uint8 constant zASSET_ENABLED = 0x01;
uint8 constant zASSET_DISABLED = 0x02;
uint8 constant zASSET_UNKNOWN = 0x00;

// UTXO data (opening values - encrypted and public) formats
uint8 constant UTXO_DATA_TYPE5 = 0x00; // for zero UTXO (no data to provide)
uint8 constant UTXO_DATA_TYPE1 = 0x01; // for UTXO w/ zero tokenId
uint8 constant UTXO_DATA_TYPE3 = 0x02; // for UTXO w/ non-zero tokenId

// Grant Types
// bytes4(keccak256('panther-onboarding-grantor'))
bytes4 constant GT_ONBOARDING = 0x93b212ae;
// The "prp grant type" for the "release and bridge" ZKPs
// bytes4(keccak256("panther-zkp-release"))
bytes4 constant GT_ZKP_RELEASE = 0x53a1eb85;
// The "prp grant type" for the "distributing" ZKPs
// bytes4(keccak256("panther-zkp-distribute"))
bytes4 constant GT_ZKP_DISTRIBUTE = 0xd48cb9c0;
// The "prp grant type" for the "distributing" ZKPs
// bytes4(keccak256("panther-fee-exchange"))
bytes4 constant GT_FEE_EXCHANGE = 0x1d91a712;
// The "prp grant type" for the refilling the PayMaster's EntryPoint deposit
// bytes4(keccak256('panther-paymaster-refund-grantor'))
bytes4 constant GT_PAYMASTER_REFUND = 0x3002a002;

// The default value that should be used
uint64 constant DEFAULT_GRANT_TYPE_PRP_REWARDS = 0;

// Number of 32-bit words of the CiphertextMsg for UTXO_DATA_TYPE1
// (ephemeral key (packed) - 32 bytes, encrypted `random` - 32 bytes)
uint256 constant CIPHERTEXT1_WORDS = 2;

// Number of 32-bit words in the (uncompressed) spending PubKey
uint256 constant PUBKEY_WORDS = 2;
// Number of elements in `pathElements`
uint256 constant PATH_ELEMENTS_NUM = 16;

// @dev Unusable on public network address, which is useful for simulations
//  in forked test env, e.g. for bypassing SNARK proof verification like this:
// `require(isValidProof || tx.origin == DEAD_CODE_ADDRESS)`
address constant DEAD_CODE_ADDRESS = address(uint160(0xDEADC0DE));

address constant NATIVE_TOKEN = address(0);

// 100% expressed in 1/100th of 1% ("pips")
uint256 constant HUNDRED_PERCENT = 100 * 100;

// Prtocol token decimals
uint256 constant PROTOCOL_TOKEN_DECIMALS = 1e18;
