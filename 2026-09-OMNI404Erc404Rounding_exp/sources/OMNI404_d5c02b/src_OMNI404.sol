//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {O404} from "./O404.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

//    ...........................................................................
// ,xKXK0KXKd, .oXNNK:  ,ONXXx..kNNXd. .kNk' .xNK:    .oKNNd.  ;kKK00X0d.     ;OXNK;
// ;0NKl...lKN0,.dNNXNk..oXXNNx..kNNNXd..kNO' .kNK:   ;k0OKNx. ,0N0:..oXNd.  .oK00NK:
// .oNNx.   .xNNo.oNKkKKc:0XO0Nx..kN0x0Xd:kNO' .kNK: .lKO::0Nx. cXNx.  ,0N0' ,kKd,dNK:
// lXNk.   .kNXl.dN0ldN0OXklONx..kNO;:0XOKNO' .kNK:.dXKd:oKNOc.cXNk.  ;KNO,:0NOcckNXd,
// .xNXxc;ckXXx..dN0;;0NNXc,ONx..kNO' :0NNNO' .kNX:'okxxk0NNKk;'xNXd;ckNKl.;xkxxkKNN0o.
// .:dO000Od:.  cOd'.lOOo..oOl..oOd.  ;xOOo. .oOx,      ;xOl.  .cxO00Od;       .oOx;
//    ...........................................................................

contract OMNI404 is O404 {
    string public baseURI;

    constructor(uint256 _initialSupplyERC20, address _lzEndpoint, address _delegate)
        O404("OMNI404", "O404", 50, _lzEndpoint, _delegate)
    {
        // Do not mint the ERC721s to the initial owner, as it's a waste of gas.
        _setWhitelist(_delegate, true);
        _mintERC20(_delegate, _initialSupplyERC20);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        string memory image = string.concat(Strings.toString(id), ".JPG");

        string memory jsonPreImage = string.concat(
            string.concat(
                string.concat('{"name": "OMNI404 #', Strings.toString(id)),
                '","description":"The frontier of permissionless assets.","external_url":"https://twitter.com/omnichain404","image":"'
            ),
            string.concat(baseURI, image)
        );
        string memory jsonPostImage = string.concat('"}');

        return string.concat("data:application/json;utf8,", string.concat(jsonPreImage, jsonPostImage));
    }

    function setBaseURI(string memory _baseURI) public onlyOwner {
        baseURI = _baseURI;
    }

    function setWhitelist(address account_, bool value_) external onlyOwner {
        _setWhitelist(account_, value_);
    }
}
