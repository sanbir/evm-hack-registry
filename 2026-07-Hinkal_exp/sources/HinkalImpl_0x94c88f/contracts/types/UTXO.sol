// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.0;

import {StealthAddressStructure} from "./StealthAddressStructure.sol";

struct UTXO {
    uint256 amount;
    address erc20Address;
    StealthAddressStructure stealthAddressStructure;
    uint256 timeStamp;
    uint256 tokenId;
}

struct ApprovedUtxo {
    address tokenAddress;
    uint256 amount;
    uint256 inHinkalAddress;
}

struct OnChainCommitment {
    UTXO utxo;
    uint256 commitment;
}
