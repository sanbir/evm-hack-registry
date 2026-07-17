// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.0;

import {HinkalInLogicBase} from "./HinkalInLogicBase.sol";
import {TokenWithAmountAndId, IHinkalInLogic} from "./types/IHinkalInLogic.sol";
import {CircomData} from "./types/CircomData.sol";
import {UTXO} from "./types/UTXO.sol";
import {StealthAddressStructure} from "./types/StealthAddressStructure.sol";
import {IExternalActionV2} from "./types/IExternalActionV2.sol";

// Inherits from HinkalInLogicBase
// Implements Logic Related to External Actions and Proofless Deposits
contract HinkalInLogic is IHinkalInLogic, HinkalInLogicBase {
    ///@notice handle running external actions
    ///@param circomData circom data.
    function handleRunExternalAction(
        CircomData calldata circomData,
        int256[] memory approvalChangesPerToken
    )
        external
        override(HinkalInLogicBase, IHinkalInLogic)
        returns (UTXO[] memory)
    {
        int256[] memory deltaAmountChanges = new int256[](
            circomData.erc20TokenAddresses.length
        );
        for (uint256 i = 0; i < circomData.erc20TokenAddresses.length; i++) {
            deltaAmountChanges[i] = calculateDeltaAmount(
                circomData,
                approvalChangesPerToken,
                i
            );
            if (deltaAmountChanges[i] < 0) {
                transferToken(
                    circomData.erc20TokenAddresses[i],
                    circomData.externalAddress,
                    uint256(-deltaAmountChanges[i]),
                    circomData.tokenIds[i]
                );
            }
        }

        return
            IExternalActionV2(circomData.externalAddress).runAction(
                circomData,
                deltaAmountChanges
            );
    }

    function handleTransfersFromProoflessDeposit(
        TokenWithAmountAndId[] memory uniqueTokens,
        uint256 uniqueCount
    ) internal {
        for (uint256 i = 0; i < uniqueCount; i++) {
            address erc20Address = uniqueTokens[i].erc20Address;
            uint256 amount = uniqueTokens[i].amount;
            uint256 tokenId = uniqueTokens[i].tokenId;

            uint256 balanceBefore = getERC20OrETHBalance(erc20Address);
            if (erc20Address == address(0)) balanceBefore -= msg.value;

            transferTokenFrom(
                erc20Address,
                msg.sender,
                address(this),
                amount,
                tokenId
            );

            uint256 balanceAfter = getERC20OrETHBalance(erc20Address);

            require(
                balanceAfter - balanceBefore == amount,
                "proofless deposit balances must be equal"
            );
        }
    }

    function handleUtxoCreationEach(
        address erc20Address,
        uint256 amount,
        uint256 tokenId,
        StealthAddressStructure calldata stealthAddressStructure
    ) internal view returns (UTXO memory) {
        UTXO memory utxo = UTXO({
            amount: amount,
            erc20Address: erc20Address,
            stealthAddressStructure: stealthAddressStructure,
            tokenId: tokenId,
            timeStamp: block.timestamp
        });

        return utxo;
    }

    function calcTokenChangesForProoflessDeposit(
        address[] calldata erc20Addresses,
        uint256[] calldata amounts,
        uint256[] calldata tokenIds
    )
        internal
        pure
        returns (
            TokenWithAmountAndId[] memory uniqueTokens,
            uint256 uniqueCount
        )
    {
        uniqueTokens = new TokenWithAmountAndId[](erc20Addresses.length);

        for (uint256 i = 0; i < erc20Addresses.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (
                    uniqueTokens[j].erc20Address == erc20Addresses[i] &&
                    uniqueTokens[j].tokenId == tokenIds[i]
                ) {
                    require(
                        tokenIds[i] == 0,
                        "you cannot send two NFTs with the same tokenId"
                    );
                    uniqueTokens[j].amount += amounts[i];
                    found = true;
                    break;
                }
            }
            if (!found) {
                uniqueTokens[uniqueCount] = TokenWithAmountAndId({
                    erc20Address: erc20Addresses[i],
                    amount: amounts[i],
                    tokenId: tokenIds[i]
                });
                uniqueCount++;
            }
        }
    }

    function handleProoflessDeposit(
        address[] calldata erc20Addresses,
        uint256[] calldata amounts,
        uint256[] calldata tokenIds,
        StealthAddressStructure[] calldata stealthAddressStructures
    )
        public
        payable
        override(HinkalInLogicBase, IHinkalInLogic)
        returns (UTXO[] memory utxoArray)
    {
        uint256 addressesLength = erc20Addresses.length;

        require(
            tokenIds.length == addressesLength,
            "tokenIds length must match"
        );

        require(amounts.length == addressesLength, "amounts length must match");

        (
            TokenWithAmountAndId[] memory uniqueTokens,
            uint256 uniqueCount
        ) = calcTokenChangesForProoflessDeposit(
                erc20Addresses,
                amounts,
                tokenIds
            );

        handleTransfersFromProoflessDeposit(uniqueTokens, uniqueCount);

        utxoArray = new UTXO[](addressesLength);
        for (uint256 i = 0; i < addressesLength; i++) {
            utxoArray[i] = handleUtxoCreationEach(
                erc20Addresses[i],
                amounts[i],
                tokenIds[i],
                stealthAddressStructures[i]
            );
        }
    }
}
