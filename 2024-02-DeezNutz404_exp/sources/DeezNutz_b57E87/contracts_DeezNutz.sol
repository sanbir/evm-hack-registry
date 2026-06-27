// SPDX-License-Identifier: MIT
//                            #                                                    
//                            @   ,                                                
//                            @@@@@@@@@.                                           
//                      #@@@   @@@  @@@* @@@@                                      
//                   @@@@@    @@@    @@@   @@@@@@                                  
//                @  @@@     /@@      @@@    @@@  @                                
//                  @@@      @@@@@((@@@@@     @@@   @                              
//              @@@@@@@@@@@@@@@    &@@@@@@@@@@@@@@   (                             
//            @@@@@@@       @@         @@     @@@@@@@@@                            
//                @@       @@@        %@@@      @@  @@@@                           
//               @@@       @@@         @@       @@@    &&                          
//         @     @@@       @@/         @@       @@@     @                          
//               @@@@@@@@@@@@@@@@@@@@@@@@@@@@   @@@     @                          
//         @@@@@@@@@       @@         @@@  *@@@@@@@@@  &@                          
//         @     @@#       @@         @@@      ,@@%@@@@@                           
//         *     @@@       @@        &@@.      @@@     @                           
//               @@@       @@        @@@      @@@     @                            
//                @@@@@@@@@@@@@@@@@@@@@@      @@/    (                             
//           @@@@@@@@@@/   @@@     *@@@@@@@@@@@@@.   *                             
//           @     @@&     @@@      @@@     @@@ @@@@@                              
//            #    @@@     @@@      @@     /@@     @.                              
//            @    @@@     @@@     %@@     @@@     @                               
//            @@@@@@@@&    @@@     @@@     @@.   &@@                               
//           @    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@                              
//          @     @@@     @@@      @@@     @@@     .@                              
//         @     @@@      @@%      @@@     @@@      @@                             
//        @@@,  @@@      @@@        @@      @@@   # *@@                            
//       @ .@@@@@@@@&&  &@@         @@#     #@@@@@@@@@@#                           
//      @     @@@ (@@@@@@@@@@@@@@@@@@@@@@@@@@@@@       @.                          
//    #@     @@@       @@@          @@@      %@@@       @                          
//   /@     @@@        @@@           @@*      &@@@       @                         
//   @@@@@ @@@        @@@            @@@       @@@     @@@&                        
//  @   ,@@@@@@@@@@@* @@@            @@@     /@@@@@@@@@@@@@                        
//  @     @@@   #@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@      #@                        
// /@     @@%        %@@             @@@        @@@       @                        
// %@     @@@        @@@             @@@        @@@      @@                        
//  @@@@@@@@@        @@@             @@*       .@@@  (@@@@@                        
//  @   @@@@@@@@@@@@&@@@            @@@     &@@@@@@@@@@@@@                         
//  @@    @@@   %@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@     ,@                          
//   @@    @@@       @@@           &@@#       @@@,    @@                           
//    @@@@@@@@@      %@@(          @@@       @@@@ @@@@@                            
//      @@@@@@@@@@@@/ @@@ %       @@@&  &@@@@@@@@@@@@                              
//        &  @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@   &@                                
//          @% @@@@.   @@@      .@@@    @@@@@  @                                   
//             .@@@@@&  @@@    @@@@  %@@@@@@@                                      
//                   #@@@@@@@@@@@@@@@@#   
// Deez Nutz $DN

// Website: https://deeznutz.africa/

// Telegram: https://t.me/DeezNutz404

// Twitter: https://twitter.com/DeezNutz_404

// Deez Nutz is the future of finance, memes, and tokenomics, a DN404 fork that adds fractionalized yield tied to cute neochibi peanut NFTs.
   
pragma solidity ^0.8.4;

import "./DN404Reflect.sol";
import "./DN404Mirror.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract DeezNutz is DN404Reflect, Ownable {
    string private _name;
    string private _symbol;
    string private baseTokenURI;
    bool private isHidden;
    bool private tradingEnabled;
    address private uniswapV2Router;

    constructor(address uniswapV2Router_) Ownable(tx.origin) {
        _name = "DeezNutz";
        _symbol = "DN";
        isHidden = true;
        uniswapV2Router = uniswapV2Router_;
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                          METADATA                          */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function setTokenURI(string memory _tokenURI) public onlyOwner {
        baseTokenURI = _tokenURI;
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        if (!_exists(id)) revert TokenDoesNotExist();
        if (isHidden) return baseTokenURI;
        return string.concat(baseTokenURI, Strings.toString(id), ".json");
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                         TRANSFERS                          */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/
    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (!tradingEnabled) {
            require(msg.sender == owner(), "Trading is not enabled");
        }
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (!tradingEnabled) {
            require(
                msg.sender == owner() || (msg.sender == uniswapV2Router && from == owner()),
                "Trading is not enabled"
            );
        }
        DN404Storage storage $ = _getDN404Storage();
        uint256 allowed = $.allowance[from][msg.sender];

        if (allowed != type(uint256).max) {
            if (amount > allowed) revert InsufficientAllowance();
            unchecked {
                $.allowance[from][msg.sender] = allowed - amount;
            }
        }

        _transfer(from, to, amount);

        return true;
    }

    function _transferFromNFT(
        address from,
        address to,
        uint256 id,
        address msgSender
    ) internal override {
        if (!tradingEnabled) {
            require(msg.sender == owner(), "Trading is not enabled");
        }
        DN404Reflect._transferFromNFT(from, to, id, msgSender);
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                      ADMIN FUNCTIONS                       */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    function initialize(
        uint96 totalSupply_,
        address owner_,
        uint256 wad,
        address mirror
    ) public onlyOwner() {
        _initializeDN404Reflect(
            totalSupply_,
            owner_,
            mirror,
            wad
        );
    }

    function reveal(string memory uri) public onlyOwner {
        baseTokenURI = uri;
        isHidden = false;
    }

    ///@dev exclude account from earning reflections
    function excludeAccount(address account) external onlyOwner {
        DN404Storage storage $ = _getDN404Storage();
        require(!$.functionsRenounced, "Function is renounced");
        AddressData storage accountAddressData = _addressData(account);

        require(!accountAddressData.isExcluded, "Account is already excluded");
        if (accountAddressData.rOwned > 0) {
            accountAddressData.tOwned = tokenFromReflection(
                accountAddressData.rOwned
            );
        }
        accountAddressData.isExcluded = true;
        $.excluded.push(account);
    }

    ///@dev include account to earn reflections
    function includeAccount(address account) external onlyOwner {
        DN404Storage storage $ = _getDN404Storage();
        AddressData storage accountAddressData = _addressData(account);

        require(!accountAddressData.isExcluded, "Account is already excluded");
        for (uint256 i = 0; i < $.excluded.length; i++) {
            if ($.excluded[i] == account) {
                $.excluded[i] = $.excluded[$.excluded.length - 1];
                accountAddressData.tOwned = 0;
                accountAddressData.isExcluded = false;
                $.excluded.pop();
                break;
            }
        }
    }

    /// @dev function to set reflections fee, cannot be invoked once ownership is renounced, 1-1000 for 1 decimal of precision
    // i.e. 50 = 5%, 25 = 2.5%, 1 = 0.1%
    function setTaxFee(uint256 fee) external onlyOwner {
        DN404Storage storage $ = _getDN404Storage();
        require(!$.functionsRenounced, "Function is renounced");
        require(fee <= 50, "Reflections fee must be 5% or less");
        $.taxFee = fee;
    }

    function getTaxFee() external returns (uint256) {
        return _getDN404Storage().taxFee;
    }

    /// @dev renounce setTaxFee and excludeAccount WARNING: CANNOT BE UNDONE
    function renounceFunctions() external onlyOwner {
        _getDN404Storage().functionsRenounced = true;
    }

    function enableTrading() external onlyOwner {
        tradingEnabled = true;
    }
}
