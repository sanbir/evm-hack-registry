// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IHinkalBase} from "./types/IHinkalBase.sol";
import {IHinkalHelper} from "./types/IHinkalHelper.sol";
import {IMerkle} from "./types/IMerkle.sol";
import {Merkle} from "./Merkle.sol";
import {Transferer} from "./Transferer.sol";
import {CircomData, HinkalLogicArgs} from "./types/CircomData.sol";
import {ApprovedUtxo, UTXO, OnChainCommitment} from "./types/UTXO.sol";
import {Dimensions} from "./types/Dimensions.sol";
import {IHinkalInLogic} from "./types/IHinkalInLogic.sol";

///@title Base class for Hinkal Contract
contract HinkalBase is
    IHinkalBase,
    Merkle,
    Transferer,
    AccessControl,
    ReentrancyGuard
{
    mapping(uint256 => bool) public nullifiers;
    mapping(uint256 => address) public externalActionMap;
    IHinkalHelper public hinkalHelper;
    IHinkalInLogic public hinkalInLogic;

    bytes32 public constant HINKAL_HELPER_MANAGER =
        keccak256("HINKAL_HELPER_MANAGER");

    constructor(
        IMerkle.MerkleConstructorArgs memory constructorArgs,
        address _hinkalHelper,
        address _hinkalInLogic,
        address _hinkalHelperManager
    ) Merkle(constructorArgs) {
        hinkalHelper = IHinkalHelper(_hinkalHelper);
        hinkalInLogic = IHinkalInLogic(_hinkalInLogic);
        _setRoleAdmin(HINKAL_HELPER_MANAGER, HINKAL_HELPER_MANAGER);
        _grantRole(HINKAL_HELPER_MANAGER, _hinkalHelperManager);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    receive() external payable {}

    ///@notice set the hinkal helper.
    ///@dev See HinkalHelper contract
    ///@param _hinkalHelper ethereum address of hinkal helper contract
    function setHinkalHelper(
        address _hinkalHelper
    ) external onlyRole(HINKAL_HELPER_MANAGER) {
        hinkalHelper = IHinkalHelper(_hinkalHelper);
    }

    ///@notice set the hinkal logic.
    ///@dev See HinkalInLogic contract
    ///@param _hinkalLogic ethereum address of hinkal logic contract
    function setHinkalLogic(
        address _hinkalLogic
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hinkalInLogic = IHinkalInLogic(_hinkalLogic);
    }

    ///@notice insert user commitments to merkle tree.
    function createCommitment(
        UTXO memory utxo
    ) internal view returns (OnChainCommitment memory) {
        uint256 commitment;
        if (utxo.tokenId > 0) {
            commitment = hash5(
                utxo.amount,
                uint256(uint160(utxo.erc20Address)),
                utxo.stealthAddressStructure.stealthAddress,
                utxo.timeStamp,
                utxo.tokenId
            );
        } else {
            commitment = hash4(
                utxo.amount,
                uint256(uint160(utxo.erc20Address)),
                utxo.stealthAddressStructure.stealthAddress,
                utxo.timeStamp
            );
        }

        OnChainCommitment memory onChainCommitment = OnChainCommitment({
            utxo: utxo,
            commitment: commitment
        });
        return onChainCommitment;
    }

    function insertCommitments(
        uint256[][] memory outCommitments,
        bytes[][] memory encryptedOutputs,
        OnChainCommitment[] memory onChainCommitments,
        bool[] memory onChainCreation
    ) internal {
        // 1) Total Length of Commitments
        uint256 length = 0;
        for (uint256 i = 0; i < outCommitments.length; i++) {
            for (uint256 j = 0; j < outCommitments[i].length; j++) {
                if (onChainCreation[i]) break;
                length += outCommitments[i][j] != 0 ? 1 : 0;
            }
        }
        length += onChainCommitments.length;

        if (length > 0) {
            // 2) Flattening leaves array
            uint256[] memory leaves = new uint256[](length);
            uint256 index = 0;
            for (uint256 i = 0; i < outCommitments.length; i++) {
                for (uint256 j = 0; j < outCommitments[i].length; j++) {
                    if (onChainCreation[i] == true) break;
                    if (outCommitments[i][j] != 0) {
                        leaves[index++] = outCommitments[i][j];
                    }
                }
            }
            for (uint256 i = 0; i < onChainCommitments.length; i++) {
                leaves[index++] = onChainCommitments[i].commitment;
            }

            // 3) Inserting Leaves
            uint256[] memory insertedIndexes = insertMany(leaves);

            // 4) Emitting Commitments/EncryptedOutputs
            index = 0;
            for (uint256 i = 0; i < encryptedOutputs.length; i++) {
                for (uint256 j = 0; j < encryptedOutputs[i].length; j++) {
                    if (onChainCreation[i] == true) break;
                    if (outCommitments[i][j] != 0) {
                        emit NewCommitment(
                            leaves[index],
                            int256(insertedIndexes[index]),
                            encryptedOutputs[i][j]
                        );
                        index++;
                    }
                }
            }
            for (uint256 i = 0; i < onChainCommitments.length; i++) {
                emit NewCommitment(
                    leaves[index],
                    -1 * int256(insertedIndexes[index++]),
                    abi.encode(onChainCommitments[i].utxo)
                );
            }
        }
    }

    function insertNullifiers(
        uint256[][] calldata inputNullifiers,
        bool[] calldata onChainCreation
    ) internal {
        for (uint256 i = 0; i < inputNullifiers.length; i++) {
            for (uint256 j = 0; j < inputNullifiers[i].length; j++) {
                if (onChainCreation[i] == true) break;
                if (inputNullifiers[i][j] != 0) {
                    require(
                        !nullifiers[inputNullifiers[i][j]],
                        "Nullifier cannot be reused"
                    );
                    nullifiers[inputNullifiers[i][j]] = true;
                    emit Nullified(inputNullifiers[i][j]);
                }
            }
        }
    }
}
