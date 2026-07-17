// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.0;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FormUtxosAndCheckSpendingsArgs, IHinkalInLogic} from "./types/IHinkalInLogic.sol";
import {CircomData, UseApprovalUTXOData} from "./types/CircomData.sol";
import {UTXO, ApprovedUtxo} from "./types/UTXO.sol";
import {AddressMemorySet} from "./lib/AddressMemorySet.sol";
import {Transferer} from "./Transferer.sol";
import {InLogicBlacklistedMethodsWithoutData, InLogicBlacklistedMethodsWithData} from "./types/InLogicBlacklistedMethods.sol";
import {DeltaAmountCalculator} from "./DeltaAmountCalculator.sol";
import {StealthAddressStructure} from "./types/StealthAddressStructure.sol";
import {IHinkalInLogic} from "./types/IHinkalInLogic.sol";
import {HinkalInLogicMetadataParser} from "./HinkalInLogicMetadataParser.sol";

// This contract is needed only because evm has restrictions on bytecode size
// Hinkal.sol is delegate calling this contract: it's an extension contract
// Hinkal Base Manages only InHinkal Logic: related to approvals, direct execution, buffering, releasing from buffer, etc.
abstract contract HinkalInLogicBase is
    IHinkalInLogic,
    Transferer,
    DeltaAmountCalculator,
    HinkalInLogicMetadataParser
{
    using SafeERC20 for IERC20;
    using AddressMemorySet for AddressMemorySet.Set;

    mapping(address => ApprovedUtxo[]) public approvedUtxos;
    mapping(address => mapping(address => mapping(uint256 => uint256)))
        public approvalsBuffer; // approvalTarget -> tokenAddress ->  inHinkalAddress -> amount

    function getApprovalsBufferValue(
        address approveTo,
        address tokenAddress,
        uint256 inHinkalAddress
    ) external view returns (uint256) {
        uint amount = approvalsBuffer[approveTo][tokenAddress][inHinkalAddress];
        return amount;
    }

    function getInteractionApprovals(
        address interaction
    ) external view returns (ApprovedUtxo[] memory) {
        return approvedUtxos[interaction];
    }

    function bufferApprovals(
        address[] calldata approvalTargets,
        uint256[][] calldata indexes
    ) external {
        require(
            approvalTargets.length == indexes.length,
            "addresss and indexes length should be the same"
        );

        for (uint256 i = 0; i < approvalTargets.length; i++) {
            ApprovedUtxo[] storage approvedUtxosForAddress = approvedUtxos[
                approvalTargets[i]
            ];

            for (uint256 j = 0; j < indexes[i].length; j++) {
                ApprovedUtxo storage approvedUtxo = approvedUtxosForAddress[
                    indexes[i][j]
                ];

                address tokenAddress = approvedUtxo.tokenAddress;
                uint256 inHinkalAddress = approvedUtxo.inHinkalAddress;
                uint256 amount = approvedUtxo.amount;

                removeApproval(approvedUtxosForAddress, indexes[i][j]);

                // decreasing total approval amount
                approveMore(
                    tokenAddress,
                    approvalTargets[i],
                    -SafeCast.toInt256(amount)
                );

                // update buffer
                uint256 bufferAmount = approvalsBuffer[approvalTargets[i]][
                    tokenAddress
                ][inHinkalAddress];

                approvalsBuffer[approvalTargets[i]][tokenAddress][
                    inHinkalAddress
                ] = bufferAmount + amount;

                emit NewBufferEntry(
                    approvalTargets[i],
                    tokenAddress,
                    amount,
                    inHinkalAddress
                );
            }
        }
    }

    function modifyOrRemoveApprovalUtxo(
        address externalAddress,
        address tokenAddress,
        uint256 inHinkalAddress,
        int256 approvalChange
    ) internal {
        bool foundUtxo = false;
        ApprovedUtxo[] storage approvedUtxosForAddress = approvedUtxos[
            externalAddress
        ];

        for (uint256 i = 0; i < approvedUtxosForAddress.length; i++) {
            ApprovedUtxo storage currentApprovedUtxo = approvedUtxosForAddress[
                i
            ];

            if (
                currentApprovedUtxo.inHinkalAddress != inHinkalAddress ||
                currentApprovedUtxo.tokenAddress != tokenAddress
            ) continue;

            uint256 newAmount = SafeCast.toUint256(
                SafeCast.toInt256(currentApprovedUtxo.amount) + approvalChange
            );

            if (newAmount == 0) {
                removeApproval(approvedUtxosForAddress, i);
            } else {
                currentApprovedUtxo.amount = newAmount;
            }
            foundUtxo = true;
            break;
        }

        require(
            foundUtxo || approvalChange >= 0,
            "if there is no utxo in array, then approval change cannot be negative"
        );

        // if we do not find record we append approvals array
        if (!foundUtxo) {
            ApprovedUtxo memory approvedUtxo = ApprovedUtxo({
                tokenAddress: tokenAddress,
                amount: uint256(approvalChange), // approval change is positive
                inHinkalAddress: inHinkalAddress
            });

            approvedUtxosForAddress.push(approvedUtxo);
        }

        approveMore(tokenAddress, externalAddress, approvalChange);

        emit NewApprovedUtxo(
            externalAddress,
            tokenAddress,
            approvalChange,
            inHinkalAddress
        );
    }

    function handleApprovalUtxos(
        CircomData calldata circomData
    ) public returns (int256[] memory result) {
        result = new int256[](circomData.erc20TokenAddresses.length);
        for (
            uint256 tokenIndex = 0;
            tokenIndex < circomData.erc20TokenAddresses.length;
            tokenIndex++
        ) {
            int256 approvalChangeForToken = 0;
            UseApprovalUTXOData memory useApprovalUTXOData = circomData
                .hinkalLogicArgs
                .useApprovalUtxoData[tokenIndex];
            for (
                uint256 externalAddressIndex = 0;
                externalAddressIndex <
                useApprovalUTXOData.externalApprovalAddresses.length;
                externalAddressIndex++
            ) {
                address externalAddress = useApprovalUTXOData
                    .externalApprovalAddresses[externalAddressIndex];
                int256 currentApprovalChange = useApprovalUTXOData
                    .approvalChanges[externalAddressIndex];

                if (externalAddress == address(0) || currentApprovalChange == 0)
                    continue;

                approvalChangeForToken += currentApprovalChange;

                modifyOrRemoveApprovalUtxo(
                    externalAddress,
                    circomData.erc20TokenAddresses[tokenIndex],
                    useApprovalUTXOData.conversionInHinkalAddress[
                        externalAddressIndex
                    ],
                    currentApprovalChange
                );
            }
            result[tokenIndex] = approvalChangeForToken;
        }
    }

    function inHinkalTransact(
        CircomData calldata circomData,
        int256[] memory approvalChangesPerToken
    ) external payable returns (UTXO[] memory utxoSet) {
        require(
            msg.value == 0,
            "msg.value non allowed for inHinkalTransactions"
        );
        // 1. ONLY APPROVAL CASE: skipped, just send funds to relay
        if (circomData.hinkalLogicArgs.hinkalLogicAction == 1) {
            sendToRelay(
                circomData.relay,
                circomData.feeStructure.flatFee,
                circomData.feeStructure.feeToken
            );

            return utxoSet;
        }

        // 2. RELEASE FROM BUFFER CASE
        if (circomData.hinkalLogicArgs.hinkalLogicAction == 2) {
            releaseFromBuffer(circomData);
        }
        // 3. EXECUTION CASE
        else if (circomData.hinkalLogicArgs.hinkalLogicAction == 3) {
            utxoSet = inHinkalExecutionFlow(circomData);
        } else {
            revert("Unknown HinkalLogicAction");
        }
    }

    /**
     * @notice Executes a user-defined external action after spending any required approvals.
     * @dev Spends user approvals using `spendApprovedUtxos(circomData)`
     * to ensure the user has enough allowance for this operation.
     * @param circomData The CircomData struct containing all parameters required for the approval flow
     * @return UTXO[] The array of newly formed UTXOs.
     */
    function inHinkalExecutionFlow(
        CircomData calldata circomData
    ) internal returns (UTXO[] memory) {
        FormUtxosAndCheckSpendingsArgs memory formUtxosAndCheckSpendingsArgs;

        require(
            msg.value == 0,
            "direct call with positive msg.value not allowed"
        );

        (
            address[] memory unspentTokens,
            uint256 unspentTokensLength
        ) = spendApprovedUtxos(circomData);

        uint256[] memory oldUnspentBalances = calculateBalances(
            unspentTokens,
            unspentTokensLength
        );

        // EXECUTION BLOCK STARTS
        formUtxosAndCheckSpendingsArgs.circomData = circomData;
        formUtxosAndCheckSpendingsArgs.oldBalances = calculateBalances(
            circomData.erc20TokenAddresses
        );

        formUtxosAndCheckSpendingsArgs.oldAllowances = calculateAllowances(
            circomData.erc20TokenAddresses,
            circomData.externalAddress
        );

        erc20SafetyCheck(circomData);

        ParsedInLogicMetadata memory parsedMetadata = parseInLogicMetadata(
            circomData.externalActionMetadata
        );
        // we find if we are spending ethreum to attach it as msg.value
        uint256 ethAmount;
        for (uint256 i = 0; i < circomData.erc20TokenAddresses.length; i++) {
            if (
                circomData.erc20TokenAddresses[i] == address(0) &&
                circomData.onChainCreation[i] == false
            ) {
                if (circomData.amountChanges[i] < 0) {
                    ethAmount = uint256(-circomData.amountChanges[i]);
                    if (
                        circomData.relay != address(0) &&
                        circomData.feeStructure.feeToken == address(0)
                    ) {
                        ethAmount -= circomData.feeStructure.flatFee;
                    }
                }
            }
        }

        (bool success, bytes memory returnData) = address(
            circomData.externalAddress
        ).call{value: ethAmount}(parsedMetadata.externalCallData);

        if (!success) {
            // If there is return data, revert with the error message
            if (returnData.length > 0) {
                assembly {
                    let returnDataSize := mload(returnData)
                    revert(add(32, returnData), returnDataSize)
                }
            } else {
                revert("Hinkal: External call failed");
            }
        }

        // we are sending fees to Relayer
        sendToRelay(
            circomData.relay,
            circomData.feeStructure.flatFee,
            circomData.feeStructure.feeToken
        );

        formUtxosAndCheckSpendingsArgs.newBalances = calculateBalances(
            circomData.erc20TokenAddresses
        );
        formUtxosAndCheckSpendingsArgs.newAllowances = calculateAllowances(
            circomData.erc20TokenAddresses,
            circomData.externalAddress
        );

        uint256[] memory newUnspentBalances = calculateBalances(
            unspentTokens,
            unspentTokensLength
        );

        // EXECUTION BLOCK FINISHES
        UTXO[] memory utxoSet = formUtxosAndCheckSpendings(
            formUtxosAndCheckSpendingsArgs
        );

        // check here instead of in formUtxosAndCheckSpendings, to prevent stack too deep error
        require(
            isArrayEqual(oldUnspentBalances, newUnspentBalances),
            "array's must be equal"
        );

        return utxoSet;
    }

    function releaseFromBuffer(CircomData calldata circomData) internal {
        address[][] memory approvalTargets = abi.decode(
            circomData.externalActionMetadata,
            (address[][])
        );

        uint256 inHinkalAddress = circomData.hinkalLogicArgs.inHinkalAddress;

        require(
            circomData.erc20TokenAddresses.length == approvalTargets.length,
            "releaseFromBuffer check1"
        );

        address feeToken = circomData.feeStructure.feeToken;
        uint256 flatFee = circomData.feeStructure.flatFee;

        sendToRelay(circomData.relay, flatFee, feeToken);

        for (uint256 i = 0; i < circomData.erc20TokenAddresses.length; i++) {
            address erc20address = circomData.erc20TokenAddresses[i];
            uint256 totalBufferAmount = 0;

            for (uint256 j = 0; j < approvalTargets[i].length; j++) {
                uint256 bufferAmount = approvalsBuffer[approvalTargets[i][j]][
                    erc20address
                ][inHinkalAddress];

                require(
                    bufferAmount > 0,
                    "hinkal buffer amount should be more than zero"
                );

                totalBufferAmount += bufferAmount;
                // nullifying buffer
                approvalsBuffer[approvalTargets[i][j]][erc20address][
                    inHinkalAddress
                ] = 0;

                emit BufferReleased(
                    approvalTargets[i][j],
                    erc20address,
                    inHinkalAddress
                );
            }

            require(
                SafeCast.toInt256(totalBufferAmount) ==
                    -circomData.hinkalLogicArgs.executeApprovalChanges[i],
                "total buffer should equal to total disallowance"
            );

            require(
                SafeCast.toInt256(totalBufferAmount) ==
                    (
                        circomData.onChainCreation[i]
                            ? int256(0)
                            : circomData.amountChanges[i]
                    ) +
                        (
                            feeToken == erc20address
                                ? int256(flatFee)
                                : int256(0)
                        ),
                "total buffer amount should be equal to approvalChanges"
            );
        }
    }

    function spendApprovedUtxos(
        CircomData calldata circomData
    ) internal returns (address[] memory, uint256 length) {
        ApprovedUtxo[] storage approvedUtxosForAddress = approvedUtxos[
            circomData.externalAddress
        ];

        bool[] memory userTokenApprovals = new bool[](
            circomData.erc20TokenAddresses.length
        );

        AddressMemorySet.Set memory unspentTokens = AddressMemorySet.init(
            approvedUtxosForAddress.length + 1 // +1 is for circomData.externalAddress
        );

        int256 approvedUtxosLength = int256(approvedUtxosForAddress.length);
        //  erc20Array should include all the tokens in ApprovedUtxo
        //  users are allowed to spend from their approval amounts
        //  if user does not own approval for particular token, his spend approval should be zero
        for (int256 i = 0; i < approvedUtxosLength; i++) {
            uint256 uintI = uint256(i); // the reason: i--
            ApprovedUtxo storage approvedUtxo = approvedUtxosForAddress[uintI];

            bool foundToken = false;
            uint256 tokenLength = circomData.erc20TokenAddresses.length;

            for (uint256 j = 0; j < tokenLength; j++) {
                if (
                    approvedUtxo.tokenAddress ==
                    circomData.erc20TokenAddresses[j]
                ) {
                    foundToken = true;

                    if (
                        approvedUtxo.inHinkalAddress ==
                        circomData.hinkalLogicArgs.inHinkalAddress
                    ) {
                        userTokenApprovals[j] = true;
                        if (
                            circomData.hinkalLogicArgs.executeApprovalChanges[
                                j
                            ] < 0
                        ) {
                            int256 allowanceLeft = SafeCast.toInt256(
                                approvedUtxo.amount
                            ) +
                                circomData
                                    .hinkalLogicArgs
                                    .executeApprovalChanges[j];

                            require(
                                allowanceLeft >= 0,
                                "Hinkal: You should spend exactly the same amount you approved"
                            );
                            approvedUtxo.amount = SafeCast.toUint256(
                                allowanceLeft
                            );

                            if (allowanceLeft == 0) {
                                removeApproval(approvedUtxosForAddress, uintI);
                                i--; // since we put the last element of approvedUtxosForAddress array to i position, we need to repeat once again
                                approvedUtxosLength--;
                            }
                        }
                    }

                    break;
                }
            }
            // all tokens that are presented in approval utxos "tree" should be checked on balance change (to be zero)
            if (!foundToken) unspentTokens.insert(approvedUtxo.tokenAddress);
        }

        // if there is no match both in address and owner, then approvalChanges should be zero
        for (uint256 i = 0; i < userTokenApprovals.length; i++) {
            if (userTokenApprovals[i] == false) {
                require(
                    circomData.hinkalLogicArgs.executeApprovalChanges[i] == 0,
                    "you cannot spend something you do not own"
                );
            }
        }

        if (isERC20(circomData.externalAddress)) {
            bool foundToken = false;
            for (
                uint256 i = 0;
                i < circomData.erc20TokenAddresses.length;
                i++
            ) {
                if (
                    circomData.erc20TokenAddresses[i] ==
                    circomData.externalAddress
                ) {
                    foundToken = true;
                    break;
                }
            }
            if (!foundToken) {
                unspentTokens.insert(circomData.externalAddress);
            }
        }

        // avoid copying to save gas
        return (unspentTokens.inner, unspentTokens.length);
    }

    function calculateBalances(
        address[] memory erc20TokenAddresses,
        uint256 length
    ) internal view returns (uint256[] memory balances) {
        balances = new uint256[](length);

        for (uint64 i; i < length; i++) {
            if (erc20TokenAddresses[i] == address(0)) {
                balances[i] = address(this).balance;
            } else {
                balances[i] = IERC20(erc20TokenAddresses[i]).balanceOf(
                    address(this)
                );
            }
        }
    }

    function calculateBalances(
        address[] memory erc20TokenAddresses
    ) internal view returns (uint256[] memory balances) {
        return
            calculateBalances(erc20TokenAddresses, erc20TokenAddresses.length);
    }

    function calculateAllowances(
        address[] calldata erc20TokenAddresses,
        address approveTo
    ) internal view returns (uint256[] memory allowances) {
        allowances = new uint256[](erc20TokenAddresses.length);

        for (uint64 i; i < erc20TokenAddresses.length; i++) {
            if (erc20TokenAddresses[i] == address(0)) {
                allowances[i] = 0;
            } else {
                allowances[i] = IERC20(erc20TokenAddresses[i]).allowance(
                    address(this),
                    approveTo
                );
            }
        }
    }

    function isERC20(address contractAddress) internal view returns (bool) {
        // we can't use try/catch here because if address is an EOA it will revert no matter what
        (bool success, bytes memory result) = contractAddress.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );

        // note: just success check isn't enought, for some reason true is returned for EOAs.
        return success && result.length == 32;
    }

    function erc20SafetyCheck(CircomData calldata circomData) internal view {
        if (!isERC20(circomData.externalAddress)) return;

        bytes4 selector = bytes4(circomData.externalActionMetadata);

        bytes4[12] memory blacklistedArrays = [
            InLogicBlacklistedMethodsWithoutData.increaseAllowance.selector,
            InLogicBlacklistedMethodsWithoutData.decreaseAllowance.selector,
            InLogicBlacklistedMethodsWithoutData.approve.selector,
            InLogicBlacklistedMethodsWithoutData.mint.selector,
            InLogicBlacklistedMethodsWithoutData.burn.selector,
            InLogicBlacklistedMethodsWithoutData.transferFrom.selector,
            InLogicBlacklistedMethodsWithoutData.authorizeOperator.selector,
            InLogicBlacklistedMethodsWithoutData.revokeOperator.selector,
            InLogicBlacklistedMethodsWithoutData.approveAndCall.selector,
            InLogicBlacklistedMethodsWithoutData.transferFromAndCall.selector,
            InLogicBlacklistedMethodsWithData.approveAndCall.selector,
            InLogicBlacklistedMethodsWithData.transferFromAndCall.selector
        ];

        for (uint256 i = 0; i < blacklistedArrays.length; i++) {
            require(selector != blacklistedArrays[i], "blacklisted selector");
        }
    }

    function isArrayEqual(
        uint256[] memory a,
        uint256[] memory b
    ) internal pure returns (bool) {
        if (a.length != b.length) return false;

        for (uint256 i = 0; i < a.length; i++) if (a[i] != b[i]) return false;

        return true;
    }

    function formUtxosAndCheckSpendings(
        FormUtxosAndCheckSpendingsArgs memory args
    ) internal returns (UTXO[] memory utxoSet) {
        utxoSet = countPositiveTokens(
            args.circomData.erc20TokenAddresses,
            args.oldBalances,
            args.newBalances
        );

        uint256 counter = 0;

        for (
            uint256 i = 0;
            i < args.circomData.erc20TokenAddresses.length;
            i++
        ) {
            address tokenAddress = args.circomData.erc20TokenAddresses[i];
            int256 balanceDif = SafeCast.toInt256(args.newBalances[i]) -
                SafeCast.toInt256(args.oldBalances[i]);

            int256 allowanceDif = SafeCast.toInt256(args.newAllowances[i]) -
                SafeCast.toInt256(args.oldAllowances[i]);
            if (balanceDif > 0) {
                utxoSet[counter++] = UTXO({
                    amount: uint256(balanceDif),
                    erc20Address: tokenAddress,
                    stealthAddressStructure: args
                        .circomData
                        .stealthAddressStructure,
                    timeStamp: args.circomData.timeStamp,
                    tokenId: 0
                });
            } else if (balanceDif < 0) {
                if (tokenAddress != address(0)) {
                    int256 relayFeeForToken = args
                        .circomData
                        .feeStructure
                        .feeToken == tokenAddress
                        ? SafeCast.toInt256(
                            args.circomData.feeStructure.flatFee
                        )
                        : int256(0);
                    require(
                        balanceDif + relayFeeForToken == allowanceDif,
                        "balance and allowance Dif mismatch"
                    );
                }
            }

            // CODE BELOW: if we spent more allowance than we have: we restore it
            int256 approvalChange = args
                .circomData
                .hinkalLogicArgs
                .executeApprovalChanges[i];

            //  int256 allowanceDif = int256(newAllowances[i]) -  int256(oldAllowances[i]);
            int256 excessApprovalSpend = allowanceDif - approvalChange;

            // e.g. total allowanceDif = -2, individual approvalChange = -1; diff = -1
            // in this case actual approval spend will be 2 > 1 = own approve spend

            if (excessApprovalSpend != 0) {
                // if we spent more approval than our own approval, we need to restore difference
                // we bring change in actual approval to match change in individual approval
                approveMore(
                    tokenAddress,
                    args.circomData.externalAddress,
                    -excessApprovalSpend
                );
                // this gurantees that total approval = sum of individual approvals
            }

            emit NewApprovedUtxo(
                args.circomData.externalAddress,
                tokenAddress,
                approvalChange,
                args.circomData.hinkalLogicArgs.inHinkalAddress
            );
        }
    }

    function countPositiveTokens(
        address[] memory erc20TokenAddresses,
        uint256[] memory oldBalances,
        uint256[] memory newBalances
    ) internal pure returns (UTXO[] memory utxoSet) {
        uint256 positiveTokens = 0;

        for (uint64 i = 0; i < erc20TokenAddresses.length; i++) {
            int256 balanceDif = SafeCast.toInt256(newBalances[i]) -
                SafeCast.toInt256(oldBalances[i]);

            if (balanceDif > 0) {
                positiveTokens++;
            }
        }

        utxoSet = new UTXO[](positiveTokens);
    }

    function approveMore(
        address externalAddress,
        address approveTo,
        int256 additionalApprove
    ) internal {
        uint256 aggregateAllowance = IERC20(externalAddress).allowance(
            address(this),
            approveTo
        );

        uint256 newApprove = additionalApprove > 0
            ? (aggregateAllowance + uint256(additionalApprove))
            : (aggregateAllowance - uint256(-additionalApprove));

        // next constraint will not be triggered, but logic should be obvious
        require(newApprove >= 0, "Hinkal: allowance was already spent");

        IERC20(externalAddress).forceApprove(approveTo, newApprove);
    }

    function removeApproval(
        ApprovedUtxo[] storage approvedUtxosForAddress,
        uint256 index
    ) internal {
        uint256 approvalLength = approvedUtxosForAddress.length;

        require(index < approvalLength, "removeApproval index is out of range");

        if (index != approvalLength - 1) {
            approvedUtxosForAddress[index] = approvedUtxosForAddress[
                approvalLength - 1
            ];
        }

        delete approvedUtxosForAddress[approvalLength - 1];
        approvedUtxosForAddress.pop();
    }

    function handleRunExternalAction(
        CircomData calldata circomData,
        int256[] memory approvalChangesPerToken
    ) external virtual returns (UTXO[] memory);

    function handleProoflessDeposit(
        address[] calldata erc20Addresses,
        uint256[] calldata amounts,
        uint256[] calldata tokenIds,
        StealthAddressStructure[] calldata stealthAddressStructures
    ) public payable virtual returns (UTXO[] memory utxoArray);
}
