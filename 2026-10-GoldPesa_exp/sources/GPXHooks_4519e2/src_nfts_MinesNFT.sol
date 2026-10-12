// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "./NFTUtils.sol";
import {MinesNFTReader} from "./MinesNFTReader.sol";

/**
 * @notice Token URI generator for GoldPesa Mines NFTs.
 * @dev This contract constructs a dynamic token URI by:
 *  - Reading SVG data from deployed contracts.
 *  - Injecting dynamic values at pre-defined byte offsets.
 *  - Concatenating the chunks into a complete SVG image.
 *  - Embedding the SVG and metadata (name, ID, address) into a base64-encoded JSON.
 * 
 * Allowing on-chain, customizable, and dynamic metadata generation per token.
 */
contract MinesNFT {
    using NFTUtils for uint256;
    using NFTUtils for address;

    MinesNFTReader public reader;

    constructor(
        MinesNFTReader _reader
    ) {
        reader = _reader;
    }

    /**
     * @dev Constructs the token URI for the NFT.
     * @param _tokenId The ID of the NFT.
     * @param _currentLevel The current level of the NFT
     * @param _gpxValue The GPX value of the NFT in USDC
     * @return string A base64 encoded JSON string representing the NFT metadata.
     */
    function constructTokenURI(
        uint256 _tokenId,
        int8 _currentLevel,
        uint256 _gpxValue
    ) external view returns (string memory) {
        string memory tokId = _tokenId.uintToString(false, 0);
        bytes memory curLevel = abi.encodePacked(_currentLevel < 0 ? '-' : '', NFTUtils.uintToString(_currentLevel >= 0 ? uint256(int256(_currentLevel)) : uint256(int256(-_currentLevel)), false, 0));
        string memory levelstr = string(curLevel);
        string memory gpxValue = string.concat('$', NFTUtils.uintToString(_gpxValue / 1e2, true, 4));

        // Generate SVG using BlobReader
        bytes memory svgBytes = reader.read(
            tokId,
            levelstr,
            gpxValue,
            levelstr
        );
        string memory svgBase64 = Base64.encode(svgBytes);

        string memory title = string.concat(
            "GoldPesa Mines - NFT #",
            tokId,
            " - Level ",
            levelstr
        );
        string memory description = string.concat(
            "Official GoldPesa Mines NFT.\\n",
            "NFT ID: ",
            tokId,
            "\\n",
            "Level: ",
            levelstr,
            "\\n",
            "GPX Value: ",
            gpxValue,
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
