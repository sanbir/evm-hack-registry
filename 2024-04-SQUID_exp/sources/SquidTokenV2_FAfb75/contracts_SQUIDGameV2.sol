// SQUID Game (SQUID) is originally a meme coin on Binance Smart Chain.
// Proxy Contract:  https://bscscan.com/token/0x87230146E138d3F296a9a77e497A2A83012e9Bc5

// Why is the original SQUID token(BSC address above) migrating on the BNB Smart Chain (BSC) to this new OFTV2(LayerZero-powered) contract?
// The migration of the SQUID token to a new, more secure smart contract on the BNB Smart Chain (BSC)
// is essential for addressing the security risks associated with the current proxy contract.
// This strategic move aims to eliminate vulnerabilities, prevent potential manipulations,
// and ensure alignment with the highest standards of token security.

// SQUID V2 will be an omnichain fungible token (OFT) that conforms to the OFT standard, which enables tokens to work seamlessly across multiple blockchains.
// This means that SQUID V2 holders can access various decentralized exchanges (DEXes), lending platforms,
// and other DeFi services on different chains without needing bridges or wrappers.
// SQUID V2 will leverage LayerZero’s modular security framework,
// which allows developers to choose from different decentralized verifier networks (DVNs) to verify cross-chain messages.
// This ensures that SQUID V2 transactions are secure, reliable, and cost-efficient.

// Website: https://www.squidgametoken.vip/
// or its alias domain name: https://SQUIDGameHolders.Club

// Twitter: https://twitter.com/SQUIDCryptoCoin
// Telegram: https://t.me/squidcrypt
// CMC: https://coinmarketcap.com/currencies/squid-game/

/*
    A Proclamation from the SQUID Game Visionary

    "In the grand arena of life, we decree that victory belongs not to the few, but to all who dare to dream. 
    In unity, we stand, a formidable legion against the tempests of chance and challenge. Together, we embark 
    on a quest not just for glory, but for the fulfillment of every aspiration that beats in our hearts. 
    Let this be our collective crusade, where every stride forward is a testament to our indomitable spirit.
    
    Join us, brave souls, in a boundless journey where every individual's triumph is a beacon of our shared resilience. 
    Here, within the SQUID Game realm, we forge not just a game, but a destiny where every participant is an architect 
    of their fate. Together, we are invincible, bound by a common purpose and propelled by our shared dreams.

    Let this be our vow: to unite, to conquer, and to emerge not just as players, but as pioneers of our collective future.
    For in the heart of SQUID Game, every dream has the power to transcend reality. Together, we rise!"
*/

// Message from the SQUID Frontman
/*
Everyone should be the winner!
Let's stand together and aim to achieve our dreams and aspirations despite all odds!
Let's unite! We are strong together!
*/
// https://SQUIDGameHolders.Club/docs/messagefromsquidfrontman2/
// https://www.squidgametoken.vip/docs/messagefromsquidfrontman2/

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFT.sol";

contract SquidTokenV2 is OFT {
    uint256 public constant MAX_SUPPLY = 800_000_000 * 10 ** 18; // 800 million SQUID

    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate
    ) OFT(_name, _symbol, _lzEndpoint, _delegate) Ownable(_delegate) {
        // Only mint on BSC Mainnet (chainid 56) or BSC Testnet (chainid 97)
        if (block.chainid == 56 || block.chainid == 97) {
            _mint(_msgSender(), MAX_SUPPLY);
        }
    }

    // Override the _update function to include the MAX_SUPPLY check
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0)) {
            require(totalSupply() + value <= MAX_SUPPLY, "Minting exceeds MAX_SUPPLY");
        }
        super._update(from, to, value);
    }
}
