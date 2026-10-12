// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import {NFTUtils} from "./NFTUtils.sol";
import {GPVaultNFTReader} from "./GPVaultNFTReader.sol";

/**
 * @notice Token URI generator for GoldPesa Vault NFTs.
 * @dev This contract constructs a dynamic token URI by:
 *  - Reading SVG data from deployed contracts.
 *  - Injecting dynamic values at pre-defined byte offsets.
 *  - Concatenating the chunks into a complete SVG image.
 *  - Embedding the SVG and metadata (name, ID, address) into a base64-encoded JSON.
 * 
 * Allowing on-chain, customizable, and dynamic metadata generation per token.
 */
contract GPVaultNFT {
    using NFTUtils for uint256;
    using NFTUtils for address;

    GPVaultNFTReader public reader;

    constructor(
        GPVaultNFTReader _reader
    ) {
        reader = _reader;
    }
    
    /**
     * @dev Constructs the token URI for the NFT.
     * @param nftID The ID of the NFT
     * @param gpoStaked The amount of GPO staked
     * @param startDate The staking start date
     * @param gpoBalance The current GPO balance
     * @param gpxBalance The current GPX balance
     * @return string A base64 encoded JSON string representing the NFT metadata.
     */
    function constructTokenURI(
        uint256 nftID,
        uint256 gpoStaked,
        uint256 startDate,
        uint256 gpoBalance,
        uint256 gpxBalance
    ) external view returns (string memory) {
        string memory nftIDStr = NFTUtils.uintToString(nftID, false, 0);
        string memory gpoStakedStr = NFTUtils.uintToString(gpoStaked / 1e16, true, 2);
        string memory startDateStr = NFTUtils.timestampToDate(startDate);
        string memory gpoBalanceStr = NFTUtils.uintToString(gpoBalance / 1e14, true, 4);
        string memory gpxBalanceStr = NFTUtils.uintToString(gpxBalance / 1e14, true, 4);

        // Get SVG data from blob reader
        bytes memory svgBytes = reader.read(
            nftIDStr,
            gpoStakedStr,
            startDateStr,
            gpoBalanceStr,
            gpxBalanceStr
        );
        string memory svgBase64 = Base64.encode(svgBytes);

        string memory title = string.concat("GoldPesa Vault NFT #", nftIDStr);
        string memory description = string.concat(
            "Official GoldPesa Vault NFT.\\n",
            "NFT ID: ",
            nftIDStr,
            "\\n",
            "GPO staked: ",
            gpoStakedStr,
            "\\n",
            "Start Date: ",
            startDateStr,
            "\\n",
            "GPO Balance: ",
            gpoBalanceStr,
            "\\n",
            "GPX Balance: ",
            gpxBalanceStr,
            "\\n",
            unicode"⚠️ DISCLAIMER: Verify contract address before transactions."
        );

        return
            string.concat(
                "data:application/json;base64,",
                Base64.encode(
                    bytes(
                        abi.encodePacked(
                            '{"name":"',
                            title,
                            '","description":"',
                            description,
                            '","image":"data:image/svg+xml;base64,',
                            svgBase64,
                            '"}'
                        )
                    )
                )
            );
    }
}
