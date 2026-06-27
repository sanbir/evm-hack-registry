// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.19;

import "./BEP20.sol";
import "./BEP20Detailed.sol";

contract IntrospectionToken is BEP20, BEP20Detailed {

    bool public airdropOpen = true;
    bool public restoringAirdropOpen = true;
    bool public initialMintHappened = false;
    
    constructor () BEP20Detailed("IntrospectionToken", "IT", 18) {
        _owner = msg.sender;
        addToTotallyUnlockedAddresses(_owner);
        addToTotallyUnlockedAddresses(address(this));
        // _mint(_owner, 1050000 * (10 ** uint256(decimals())));
    }
    
    function setParams(address exchangeAddress, address routerAddress, address _factoryAddress, address referralProgramAddress, address triggerWalletAddress) public onlyOwner returns (bool) {
        require(address(exchange) == address(0), "Params already set");
        exchange = IPankakeSwapExchange(exchangeAddress);
        referralProgram = IReferralProgram(referralProgramAddress);
        router = IPankakeSwapRouter(routerAddress);
        factoryAddress = _factoryAddress;
        addToTotallyUnlockedAddresses(exchangeAddress);
        addToExchangesAddresses(exchangeAddress);
        addContractToAllowed(exchangeAddress);
        _triggerWalletAddress = triggerWalletAddress;
        if(address(this) == exchange.token0()){
            usdtToken = IBEP20(exchange.token1());
        } else {
            usdtToken = IBEP20(exchange.token0());
        }
        return true;
    }

    function airdrop(address to, uint256 amount) public onlyOwner returns (bool){
        require(airdropOpen, "Airdrop already closed");
        _mint(to, amount);
        if(_firstBuyRates[to] == 0){
            _firstBuyRates[to] = getUsdtRate();
        }
        return true;
    }

    function closeAirdrop() public onlyOwner returns (bool){
        require(airdropOpen, "Airdrop already closed");
        airdropOpen = false;
        return true;
    }


    function restoringAirdrop(address to, uint256 amount, uint256 firstBuyRate, uint256 referralUnlock, bool _isActivated, uint256 incomingAmount, uint256 outgoingAmount) public onlyOwner returns (bool){
        require(restoringAirdropOpen, "Airdrop already closed");
        _mint(to, amount);
        _firstBuyRates[to] = firstBuyRate;
        _referralUnlocks[to] = referralUnlock;
        isActivated[to] = _isActivated;
        _totalIncomingTransfersAmounts[to] = incomingAmount;
        _totalOutgoingTransfersAmounts[to] = outgoingAmount;
        return true;
    }

    function closeRestoringAirdrop() public onlyOwner returns (bool){
        require(restoringAirdropOpen, "Airdrop already closed");
        restoringAirdropOpen = false;
        return true;
    }

    
    function burn(uint256 amount) public onlyOwner returns (bool){
        _burn(msg.sender, amount);
        return true;
    }

    function mintOnce(uint256 amount) public onlyOwner returns (bool){
        require(!initialMintHappened, "Initial mint already happened");
        initialMintHappened = true;
        _mint(msg.sender, amount);
        return true;
    }

    function burnOnSmartContractAddress(uint256 amount, address contractAddress) public onlyOwner returns (bool){
        require(isContract(address(contractAddress)), "Address is not a smart contract");
        _burn(contractAddress, amount);
        exchange.sync();
        updateCurrMaxUsdtRateIfNeeded();
        return true;
    }
    
}
