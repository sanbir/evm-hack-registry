// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Errors as CoreErrors} from "@makina-core/libraries/Errors.sol";

library Errors {
    error AlreadyClaimed();
    error AlreadyFinalized();
    error CooldownExpired();
    error CooldownOngoing();
    error FinalizationDelayPending();
    error FutureRequest();
    error GreaterThanCurrentWatermark();
    error InvalidDepositorImplemId();
    error InvalidFeeManagerImplemId();
    error InvalidFeeSplit();
    error InvalidMachinePeriphery();
    error InvalidRedeemerImplemId();
    error InvalidSecurityModule();
    error MachineAlreadySet();
    error MachineNotSet();
    error MaxBpsValueExceeded();
    error MaxFeeRateValueExceeded();
    error MaxSlashableExceeded();
    error NotDepositor();
    error NotEnoughAssets();
    error NotFeeManager();
    error NotFinalized();
    error NotImplemented();
    error NotRedeemer();
    error NotSecurityModule();
    error SecurityModuleAlreadySet();
    error SlashingSettlementOngoing();
    error ZeroMachineAddress();
    error ZeroRequestId();
    error ZeroShares();
}
