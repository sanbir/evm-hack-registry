// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.7.0;
import "../superSwitchToken/superSwitchErc20.sol";
import "../lendingSuperToken.sol";
// lendingAaveErc20 is a combination of super aave ERC20 token and lending pool.
//
// This contract will benefit from mining income and loan interest income.
contract lendingSwitchErc20 is superSwitchErc20,lendingSuperToken {
    using SafeMath for uint256;
    constructor(address multiSignature,address origin0,address origin1,address _aavaToken,address _qiToken,
    address payable _swapHelper,address payable _feePool,uint8 _lendingSwitch,address leverageFactory,uint256 _assetFloor)
        superSwitchErc20(multiSignature,origin0,origin1,_aavaToken,_qiToken,_swapHelper,_feePool,_lendingSwitch) 
        lendingSuperToken(leverageFactory,_assetFloor) {
        setTokenInfo("Lending ","L");
    }
    function getTotalAssets() internal virtual override(superSwitchErc20,superTokenInterface) view returns (uint256){
        return getAvailableBalance().add(totalAssetAmount());
    }

}