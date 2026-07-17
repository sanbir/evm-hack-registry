// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {Address, HinkalBase, IMerkle, ApprovedUtxo, Dimensions, CircomData, UTXO, IHinkalInLogic, OnChainCommitment} from "./HinkalBase.sol";

import {VerifierFacade} from "./VerifierFacade.sol";
import {IHinkal} from "./types/IHinkal.sol";
import {IExternalActionV2} from "./types/IExternalActionV2.sol";
import {IPreTransactHook, ITransactHook} from "./types/ITransactHook.sol";
import {DeltaAmountCalculator} from "./DeltaAmountCalculator.sol";
import {StealthAddressStructure} from "./types/StealthAddressStructure.sol";

///@title Hinkal Contract
///@notice Entrypoint for all Hinkal Transactions.
contract Hinkal is IHinkal, VerifierFacade, HinkalBase, DeltaAmountCalculator {
    using Address for address;

    constructor(
        IMerkle.MerkleConstructorArgs memory constructorArgs,
        address _hinkalHelper,
        address _hinkalInLogic,
        address _hinkalHelperManager
    )
        HinkalBase(
            constructorArgs,
            _hinkalHelper,
            _hinkalInLogic,
            _hinkalHelperManager
        )
    {}

    function registerExternalAction(
        uint256 externalActionId,
        address externalActionAddress
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        externalActionMap[externalActionId] = externalActionAddress;
        emit ExternalActionRegistered(externalActionAddress);
    }

    function transact(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        Dimensions calldata dimensions,
        CircomData calldata circomData
    ) public payable nonReentrant {
        {
            uint256[] memory inputForCircom = hinkalHelper.performHinkalChecks(
                circomData,
                dimensions,
                msg.sender
            );

            require(
                verifyProof(
                    a,
                    b,
                    c,
                    inputForCircom,
                    buildVerifierId(dimensions, circomData.externalActionId)
                ),
                "Invalid Proof"
            );
            // Root Hash Validation
            require(
                rootHashExists(circomData.rootHashHinkal),
                "Hinkal Root Hash is Incorrect"
            );
        }
        hinkalHelper.performSideEffects(circomData);

        {
            // function variables to store commitments created on-chain
            UTXO[] memory utxoSet;
            if (circomData.hookData.preHookContract != address(0)) {
                IPreTransactHook transactHook = IPreTransactHook(
                    circomData.hookData.preHookContract
                );
                transactHook.preTransact(circomData);
            }

            uint256[] memory oldBalances = getBalancesForArray(
                circomData.erc20TokenAddresses,
                circomData.tokenIds
            );

            int256[] memory approvalChangesPerToken = new int256[](
                circomData.erc20TokenAddresses.length
            );

            if (circomData.hinkalLogicArgs.doPreTxApproval) {
                approvalChangesPerToken = _handleApprovalUtxos(circomData);
            }

            uint256 hinkalLogicAction = circomData
                .hinkalLogicArgs
                .hinkalLogicAction;

            if (hinkalLogicAction > 0) {
                utxoSet = _inHinkalTransact(
                    circomData,
                    approvalChangesPerToken
                );
            } else if (
                hinkalLogicAction == 0 && circomData.externalActionId == 0
            ) {
                _internalTransact(circomData, approvalChangesPerToken);
            } else if (
                hinkalLogicAction == 0 && circomData.externalActionId != 0
            ) {
                utxoSet = _internalRunExternalAction(
                    circomData,
                    approvalChangesPerToken
                );
            }

            uint256[] memory newBalances = getBalancesForArray(
                circomData.erc20TokenAddresses,
                circomData.tokenIds
            );

            OnChainCommitment[]
                memory onChainCommitments = new OnChainCommitment[](
                    utxoSet.length
                );
            uint256 onChainCommitmentCounter = 0;
            for (uint64 i; i < circomData.erc20TokenAddresses.length; i++) {
                int256 balanceDif;

                if (circomData.erc20TokenAddresses[i] == address(0)) {
                    balanceDif =
                        int256(newBalances[i]) +
                        int256(msg.value) -
                        int256(oldBalances[i]);
                } else {
                    balanceDif =
                        int256(newBalances[i]) -
                        int256(oldBalances[i]);
                }
                // balance inequality to check that minimum amount of token is received/given
                require(
                    balanceDif >= circomData.slippageValues[i],
                    "slippage param is violated"
                );

                uint256 utxoAmount = 0;
                for (uint j = 0; j < utxoSet.length; j++) {
                    if (
                        utxoSet[j].erc20Address ==
                        circomData.erc20TokenAddresses[i]
                    ) {
                        utxoAmount += utxoSet[j].amount;
                        onChainCommitments[
                            onChainCommitmentCounter++
                        ] = createCommitment(utxoSet[j]);
                    }
                }
                // balance equation to check: CHANGE IN BALANCE SHOULD EQUAL TO
                // 1) change in off-chain utxos
                // 2) change in on-chain utxos
                // 3) approved utxos change
                require(
                    balanceDif ==
                        (
                            circomData.onChainCreation[i]
                                ? int256(0)
                                : circomData.amountChanges[i]
                        ) +
                            int256(utxoAmount) +
                            approvalChangesPerToken[i] +
                            circomData.hinkalLogicArgs.executeApprovalChanges[
                                i
                            ],
                    "Balance Diff Should be equal to sum of onchain and offchain created commitments"
                );
            }

            if (circomData.hookData.hookContract != address(0)) {
                ITransactHook transactHook = ITransactHook(
                    circomData.hookData.hookContract
                );
                transactHook.afterTransact(circomData);
            }

            insertNullifiers(
                circomData.inputNullifiers,
                circomData.onChainCreation
            );

            insertCommitments(
                circomData.outCommitments,
                circomData.encryptedOutputs,
                onChainCommitments,
                circomData.onChainCreation
            );
        }
    }

    function prooflessDeposit(
        address[] calldata erc20Addresses,
        uint256[] calldata amounts,
        uint256[] calldata tokenIds,
        StealthAddressStructure[] calldata stealthAddressStructures
    ) public payable nonReentrant {
        hinkalHelper.performProoflessDepositChecks(
            erc20Addresses,
            amounts,
            tokenIds,
            stealthAddressStructures
        );

        bytes memory returnData = address(hinkalInLogic).functionDelegateCall(
            abi.encodeWithSelector(
                hinkalInLogic.handleProoflessDeposit.selector,
                erc20Addresses,
                amounts,
                tokenIds,
                stealthAddressStructures
            )
        );

        UTXO[] memory utxoSet = abi.decode(returnData, (UTXO[]));
        uint256 length = utxoSet.length;

        OnChainCommitment[] memory commitmentArray = new OnChainCommitment[](
            length
        );

        for (uint256 i = 0; i < length; i++) {
            commitmentArray[i] = createCommitment(utxoSet[i]);
        }

        insertCommitments(
            new uint256[][](0),
            new bytes[][](0),
            commitmentArray,
            new bool[](0)
        );
    }

    ///@notice privates inHinkal function for transaction
    ///@param circomData circom dara
    function _inHinkalTransact(
        CircomData calldata circomData,
        int256[] memory approvalChangesPerToken
    ) private returns (UTXO[] memory) {
        bytes memory data = abi.encodeWithSelector(
            hinkalInLogic.inHinkalTransact.selector,
            circomData,
            approvalChangesPerToken
        );
        bytes memory returnData = address(hinkalInLogic).functionDelegateCall(
            data
        );

        UTXO[] memory utxoSet = abi.decode(returnData, (UTXO[]));
        return utxoSet;
    }

    ///@notice private internal function for transaction
    ///@param circomData circom dara
    function _internalTransact(
        CircomData calldata circomData,
        int256[] memory approvalChangesPerToken
    ) private {
        bool hasPaidToRelay = false;
        for (uint64 i = 0; i < circomData.erc20TokenAddresses.length; i++) {
            int256 deltaAmountChange = calculateDeltaAmount(
                circomData,
                approvalChangesPerToken,
                i
            );

            if (deltaAmountChange > 0) {
                require(
                    circomData.externalAddress == msg.sender,
                    "Deposit should come from the sender"
                );
                transferTokenFrom(
                    circomData.erc20TokenAddresses[i],
                    circomData.externalAddress,
                    address(this),
                    uint256(circomData.amountChanges[i]),
                    circomData.tokenIds[i]
                );
            } else {
                uint256 sumAbs = uint256(-deltaAmountChange);
                uint256 relayFee = 0;
                if (
                    circomData.relay != address(0) &&
                    circomData.feeStructure.feeToken ==
                    circomData.erc20TokenAddresses[i]
                ) {
                    relayFee = hinkalHelper.calculateRelayFee(
                        sumAbs,
                        circomData.feeStructure.flatFee,
                        circomData.feeStructure.variableRate
                    );
                    require(
                        relayFee <= sumAbs,
                        "Relay Fee is over withdraw amount"
                    );
                    if (circomData.tokenIds[i] == 0) {
                        transferERC20TokenOrETH(
                            circomData.erc20TokenAddresses[i],
                            circomData.relay,
                            relayFee
                        );
                    }
                    hasPaidToRelay = true;
                }
                transferToken(
                    circomData.erc20TokenAddresses[i],
                    circomData.externalAddress,
                    sumAbs - relayFee,
                    circomData.tokenIds[i]
                );
            }
        }
        require(
            circomData.relay == address(0) || hasPaidToRelay,
            "relay not paid"
        );
    }

    ///@notice internal function to use Hinkal with external contracts.
    ///@param circomData circom data.
    function _internalRunExternalAction(
        CircomData calldata circomData,
        int256[] memory approvalChangesPerToken
    ) internal returns (UTXO[] memory) {
        require(
            externalActionMap[circomData.externalActionId] ==
                circomData.externalAddress &&
                circomData.externalAddress != address(0),
            "Unknown externalAddress"
        );

        bytes memory inputData = abi.encodeWithSelector(
            hinkalInLogic.handleRunExternalAction.selector,
            circomData,
            approvalChangesPerToken
        );

        bytes memory data = address(hinkalInLogic).functionDelegateCall(
            inputData
        );

        return abi.decode(data, (UTXO[]));
    }

    function _handleApprovalUtxos(
        CircomData calldata circomData
    ) internal returns (int256[] memory approvalsChangesPerToken) {
        bytes memory inputData = abi.encodeWithSelector(
            hinkalInLogic.handleApprovalUtxos.selector,
            circomData
        );

        bytes memory data = address(hinkalInLogic).functionDelegateCall(
            inputData
        );

        approvalsChangesPerToken = abi.decode(data, (int256[]));
    }

    // this is not a view function. Front-end needs to use ethers.callStatic
    function getInteractionApprovals(
        address interaction
    ) external returns (ApprovedUtxo[] memory approvedUtxos) {
        bytes memory inputData = abi.encodeWithSelector(
            hinkalInLogic.getInteractionApprovals.selector,
            interaction
        );
        bytes memory data = address(hinkalInLogic).functionDelegateCall(
            inputData
        );
        approvedUtxos = abi.decode(data, (ApprovedUtxo[]));
    }

    function bufferApprovals(
        address[] calldata approvalTargets,
        uint256[][] calldata indexes
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes memory data = abi.encodeWithSelector(
            hinkalInLogic.bufferApprovals.selector,
            approvalTargets,
            indexes
        );
        address(hinkalInLogic).functionDelegateCall(data);
    }

    function getBufferEntry(
        address approveTo,
        address tokenAddress,
        uint256 inHinkalAddress
    ) external returns (uint256) {
        bytes memory data = abi.encodeWithSelector(
            hinkalInLogic.getApprovalsBufferValue.selector,
            approveTo,
            tokenAddress,
            inHinkalAddress
        );

        bytes memory returnData = address(hinkalInLogic).functionDelegateCall(
            data
        );

        uint256 amount = abi.decode(returnData, (uint256));

        return amount;
    }
}
