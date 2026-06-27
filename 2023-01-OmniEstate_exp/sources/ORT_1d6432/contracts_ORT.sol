// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IORT.sol";
import "./abstracts/crosschain/AnyswapV4ERC20.sol";

contract ORT is IORT, AnyswapV4ERC20 {
    using SafeMath for uint256;
    using Address for address;

    constructor()
    AnyswapV4ERC20('OMNI Real Estate Token', 'ORT', 18, address(0), address(0)) {
        // initial supply on 42M. new tokens can only be minted by creating new farms 
        _mint(_msgSender(), 42 * 10**6 * 10**decimals());
    }

    //== BEP20 function ==
    function getOwner() public override view returns (address) {
        return owner();
    }

    //== Mint and Burn ==
    function mint(uint256 amount) external override onlyMinter returns (bool) {
        _mint(msg.sender, amount);
        return true;
    }

    function burn(uint256 amount) external override returns (bool) {
        _burn(msg.sender, amount);
        return true;
    }
}