//SPDX-License-Identifier: UNLICENSED



// Pandora's Blocks is the first innovative designed nodes rewards system built upon the ERC404 token standard

pragma solidity ^0.7.0;

import {ERC404} from "./ERC404.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract PandorasNodes404 is ERC404 {
    string public dataURI;
    string public baseTokenURI;

    constructor(address _owner) ERC404("Pandora's Nodes 404", "BLOCK", 18, 200, _owner) {
        balanceOf[_owner] = totalSupply;
        setWhitelist(_owner, true);
    }

    function setDataURI(string memory _dataURI) public onlyOwner {
        dataURI = _dataURI;
    }

    function setTokenURI(string memory _tokenURI) public onlyOwner {
        baseTokenURI = _tokenURI;
    }

    function setNameSymbol(string memory _name, string memory _symbol) public onlyOwner {
        _setNameSymbol(_name, _symbol);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        if (bytes(baseTokenURI).length > 0) {
            return concatenate(baseTokenURI, Strings.toString(id));
        } else {
            string memory image = concatenate(Strings.toString(id), ".png");

            string memory jsonPreImage = concatenate(
                concatenate(
                    concatenate('{"name": "Pandoras Blocks #', Strings.toString(id)),
                    '","description":"A collection of 200 Pandoras blocks enabled by ERC404, an experimental token standard.","warning":"Only buy this if you know what you are doing. You will likely lose your funds if you do","external_url":"","image":"'
                ),
                concatenate(dataURI, image)
            );
            string memory jsonPostImage = '","attributes":[{"block_type":"item","value":"node"}]}';

            return concatenate("data:application/json;utf8,", concatenate(jsonPreImage, jsonPostImage));
        }
    }

    function concatenate(string memory a, string memory b) public pure returns (string memory) {
        bytes memory bytesA = bytes(a);
        bytes memory bytesB = bytes(b);
        string memory combined = new string(bytesA.length + bytesB.length);
        bytes memory bytesCombined = bytes(combined);
    
        uint k = 0;
        for (uint i = 0; i < bytesA.length; i++) {
            bytesCombined[k++] = bytesA[i];
        }
        for (uint i = 0; i < bytesB.length; i++) {
            bytesCombined[k++] = bytesB[i];
        }
    
        return string(bytesCombined);
    }
}