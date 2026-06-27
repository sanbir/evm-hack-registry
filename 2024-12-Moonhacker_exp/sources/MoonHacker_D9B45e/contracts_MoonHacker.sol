// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IERC20} from "@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import {IPool} from '@aave/core-v3/contracts/interfaces/IPool.sol';

interface IMToken {
    function mint(uint mintAmount) external returns (uint);
    function borrow(uint borrowAmount) external returns (uint);
    function redeem(uint redeemTokens) external returns (uint);
    function redeemUnderlying(uint redeemAmount) external returns (uint);
    function repayBorrow(uint repayAmount) external returns (uint);
    function getAccountSnapshot(address account) external view returns (uint, uint, uint, uint);
    function borrowBalanceCurrent(address account) external returns (uint);

}

interface IWETH {
    function deposit() external payable;
}

interface IERC20Detailed {
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface IComptroller {
    function claimReward() external;
    function claimReward(address holder) external;
    function claimReward(address holder, address[] memory mTokens) external;
}

contract MoonHacker {
    
    event onBatchCallError( bytes data );
    
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    address owner;
    IPool POOL;
    IComptroller COMPTROLLER;

    enum SmartOperation{ SUPPLY, REDEEM }

	modifier onlyOwner {	
		require(msg.sender == owner || (address(this) == msg.sender && tx.origin == owner), "not auth");
		_;
	}

    constructor(address aavePoolAddressProvider, address comptroller) {
        owner = msg.sender;
        POOL = IPool(IPoolAddressesProvider(aavePoolAddressProvider).getPool());
        COMPTROLLER = IComptroller(comptroller);
    }

    function smartSupply(address token, address mToken, uint256 amountToBorrow, uint256 amountToSupply) public onlyOwner() {

        address receiverAddress = address(this);
        bytes memory params = abi.encode(SmartOperation.SUPPLY, mToken, amountToSupply);
        uint16 referralCode = 0;

        POOL.flashLoanSimple(
            receiverAddress,
            token,
            amountToBorrow,
            params,
            referralCode
        );
    }

    function smartRedeem(address token, address mToken) public onlyOwner() {

        //this is needed to accrue interest up to current index and update borrow balance
        IMToken(mToken).borrowBalanceCurrent(address(this));

        (uint err, uint amountToReedem, uint amountToRepay, uint exRateMantissa) = IMToken(mToken).getAccountSnapshot(address(this));


        smartRedeemAmount(token, mToken, amountToReedem, amountToRepay);
    }


    function smartRedeemAmount(address token, address mToken, uint amountToReedem, uint amountToRepay) public onlyOwner() {

        address receiverAddress = address(this);
        bytes memory params = abi.encode(SmartOperation.REDEEM, mToken, amountToReedem);
        uint16 referralCode = 0;


        POOL.flashLoanSimple(
            receiverAddress,
            token,
            amountToRepay,
            params,
            referralCode
        );
    }

    
    function  executeOperation(
        address token,
        uint256 amountBorrowed,
        uint256 premium,
        address initiator,
        bytes calldata params
    )  external returns (bool) {
        
        (SmartOperation operation, address mToken, uint256 amountToSupplyOrReedem) = abi.decode(params, (SmartOperation, address, uint256));
        uint256 totalAmountToRepay = amountBorrowed + premium;

        if (operation == SmartOperation.SUPPLY) {
            //get amount to supply from user
            //IERC20(token).transferFrom(owner, address(this), amountToSupplyOrReedem); ==> removed, we do transfer instead of approve from outside

            //approve total amount to supply 
            uint256 totalSupplyAmount = amountBorrowed + amountToSupplyOrReedem;
            IERC20(token).approve(mToken, totalSupplyAmount);

            //supply total amount
            require(IMToken(mToken).mint(totalSupplyAmount) == 0, "mint failed");

            //borrow amount borrowed from aave plus aave fee
            require(IMToken(mToken).borrow(totalAmountToRepay) == 0, "borrow failed");

            //pay back to aave
            IERC20(token).approve(address(POOL), totalAmountToRepay);

        } else if (operation == SmartOperation.REDEEM) {
            
            //repay
            IERC20(token).approve(mToken, amountBorrowed);
            require(IMToken(mToken).repayBorrow(amountBorrowed) == 0, "repay borrow failed");

            require(IMToken(mToken).redeem(amountToSupplyOrReedem) == 0, "redeem failed");

            //claim rewards
            COMPTROLLER.claimReward(address(this));

        } else {

            revert("invalid op");
        }

        if (strcmp(IERC20Detailed(token).symbol(), "WETH")) {
            //WE received ETH, we need to call 'deposit' now to wrap it into WETH
            IWETH(token).deposit{value: totalAmountToRepay}();
        }

        //pay back to aave
        IERC20(token).approve(address(POOL), totalAmountToRepay);

        return true;
    }


    function strcmp(string memory a, string memory b) internal pure returns(bool){
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }    

    function mint(address mToken, uint mintAmount) external onlyOwner returns (uint) {
        return IMToken(mToken).mint(mintAmount);
    }

    function borrow(address mToken, uint borrowAmount) external onlyOwner returns (uint) {
        return IMToken(mToken).borrow(borrowAmount);
    }

    function redeem(address mToken, uint redeemTokens) external onlyOwner returns (uint) {
       return IMToken(mToken).redeem(redeemTokens);
    }

    function redeemUnderlying(address mToken, uint redeemAmount) external onlyOwner returns (uint) {
       return IMToken(mToken).redeemUnderlying(redeemAmount);
    }

    function repayBorrow(address token, address mToken, uint repayAmount) external onlyOwner returns (uint) {
        IERC20(token).transferFrom(owner, address(this), repayAmount);
        IERC20(token).approve(mToken, repayAmount);
        return IMToken(mToken).repayBorrow(repayAmount);
    }

    function repayBorrowAndReedem(address token, address mToken, uint repayAmount, uint tokensToRedeem) external onlyOwner {
        IERC20(token).transferFrom(owner, address(this), repayAmount);
        IERC20(token).approve(mToken, repayAmount);
        require(IMToken(mToken).repayBorrow(repayAmount) == 0, "repay failed");
        require(IMToken(mToken).redeem(tokensToRedeem) == 0, "redeem failed");
    }
    
    function claimReward() external onlyOwner {
        return COMPTROLLER.claimReward();
    }

    function claimReward(address holder) external onlyOwner {
        return COMPTROLLER.claimReward(holder);
    }

    function claimReward(address holder, address[] memory mTokens) external onlyOwner {
        return COMPTROLLER.claimReward(holder, mTokens);
    }

    function withdrawToken(address _tokenContract, uint256 _amount) external onlyOwner {
        IERC20 tokenContract = IERC20(_tokenContract);
        
        // transfer the token from address of this contract
        // to address of the user (executing the withdrawToken() function)
        tokenContract.transfer(owner, _amount);
    }

    function withdraw() external onlyOwner {
        uint256 amount = address(this).balance;
        require(amount > 0, "Nothing to withdraw; contract balance empty");
        
        (bool sent, ) = owner.call{value: amount}("");
        require(sent, "Failed to send Ether");
    }

    function batch(Call[] memory calls) external onlyOwner {
        for (uint i = 0; i < calls.length; i++) {
			bytes memory data = calls[i].data;
			uint256 value = calls[i].value;
			address to = calls[i].to;//address(this);
			uint gasLeft = gasleft();
			bool success;
			
            assembly {
				//let ptr := mload(0x40)
                success := call(
                    gasLeft,
                    to,
                	value,
                    add(data, 0x20),
                    mload(data),
                    0,//ptr, //output pointer ( pass 'ptr' defined above )
                    0//0x20 //output size
                )
            }
			if (!success) {
				//fire event...
				emit onBatchCallError(data);
			}
        }
    }    

    receive() external payable {}
}
