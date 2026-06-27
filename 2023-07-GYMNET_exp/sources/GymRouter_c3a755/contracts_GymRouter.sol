// SPDX-License-Identifier: MIT

pragma solidity 0.8.15;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IMunicipality.sol";
import "./interfaces/INetGymStreet.sol";
import "./interfaces/IFactory.sol";

contract GymRouter is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    address public routerAddress;
    address public WETH;
    uint256 public commission; // in 1e18

    // ----------------for distribution----------------//
    address public municipalityAddress;
    address public municipalityAddressKB;
    address public primaryTokenAddress; // This is the primary token address used for distribution.
    address public binaryBackendAddress;
    address public distributorAddress; // This is the address where the swap commission will be sent for distribution.
    // mapping token address to swap commission amount
    // This mapping is used to store the swap commission amount for each token address.
    mapping(address => uint256) public tokenToSwapCommissionMapping;
    using EnumerableSet for EnumerableSet.AddressSet;
    EnumerableSet.AddressSet private tokenAddressesSet;
    address public netGymStreetAddr;
    address public busdAddress; // BUSD address, used for distribution



    //------------EVENTS----------------//
    event CommissionDistributed(uint256 incomeFromSwapCommissionFee);
    event IncomeClaimed(address user, uint256 USDTAmount, uint256 gymAmount);

    function initialize(
        address _routerAddress,
        address _weth,
        uint256 _commission
    ) external initializer {
        
        routerAddress = _routerAddress;
        WETH = _weth;
        commission = _commission;

        __Ownable_init();
        __ReentrancyGuard_init();
    }

    receive() external payable {}

    fallback() external payable {}

    function setCommission(uint256 _commission) external onlyOwner {
        commission = _commission;
    }

    function setRouterAddress(address _routerAddress) external onlyOwner {
        routerAddress = _routerAddress;
    }

    function setWETHAddress(address _weth) external onlyOwner {
        WETH = _weth;
    }

    function setMunicipalityAddresses(address _municipalityAddress, address _municipalityAddressKB) external onlyOwner {
        municipalityAddress = _municipalityAddress;
        municipalityAddressKB = _municipalityAddressKB;
    }

    function setPrimaryTokenAddress(address _primaryTokenAddress) external onlyOwner {
        primaryTokenAddress = _primaryTokenAddress;
    }

    function setBinaryBackendAddress(address _binaryBackendAddress) external onlyOwner {
        binaryBackendAddress = _binaryBackendAddress;
    }

    function setDistributorAddress(address _distributorAddress) external onlyOwner {
        distributorAddress = _distributorAddress;
    }

    function setNetGymStreetAddress(address _netGymStreetAddr) external onlyOwner {
        netGymStreetAddr = _netGymStreetAddr;
    }

    function setBUSDAddress(address _busdAddress) external onlyOwner {
        busdAddress = _busdAddress;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        uint256 tokenACommission = (amountADesired * commission) / 1e18;
        uint256 tokenBCommission = (amountBDesired * commission) / 1e18;
        IERC20Upgradeable(tokenA).safeTransferFrom(msg.sender, address(this), amountADesired);
        IERC20Upgradeable(tokenB).safeTransferFrom(msg.sender, address(this), amountBDesired);
        IERC20Upgradeable(tokenA).safeIncreaseAllowance(routerAddress, amountADesired - tokenACommission);
        IERC20Upgradeable(tokenB).safeIncreaseAllowance(routerAddress, amountBDesired - tokenBCommission);
        (amountA, amountB, liquidity) = IPancakeRouter02(routerAddress).addLiquidity(
            tokenA,
            tokenB, 
            amountADesired - tokenACommission,
            amountBDesired - tokenBCommission,
            amountAMin,
            amountBMin,
            to,
            block.timestamp + 300
        );
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to
    )
        external
        payable
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        uint256 tokenCommission = (amountTokenDesired * commission) / 1e18;
        uint256 ethCommission = (msg.value * commission) / 1e18;
        IERC20Upgradeable(token).safeTransferFrom(msg.sender, address(this), amountTokenDesired);
        (bool success, ) = address(this).call{value: msg.value}("");
        require(success, "Transfer failed.");
        IERC20Upgradeable(token).safeIncreaseAllowance(routerAddress, amountTokenDesired - tokenCommission);
        (amountToken, amountETH, liquidity) = IPancakeRouter02(routerAddress).addLiquidityETH{value: (msg.value - ethCommission)}(
            token,
            amountTokenDesired - tokenCommission, 
            amountTokenMin,
            amountETHMin,
            to,
            block.timestamp + 300
        );
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) external returns (uint256 amountA, uint256 amountB) {
        (amountA, amountB) = IPancakeRouter02(routerAddress).removeLiquidity(
            tokenA,
            tokenB, 
            liquidity,
            amountAMin,
            amountBMin,
            address(this),
            block.timestamp + 300
        );
        uint256 tokenACommission = (amountA * commission) / 1e18;
        uint256 tokenBCommission = (amountB * commission) / 1e18;
        amountA -= tokenACommission;
        amountB -= tokenBCommission;
        IERC20Upgradeable(tokenA).safeTransfer(to, amountA);
        IERC20Upgradeable(tokenB).safeTransfer(to, amountB);
    }

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to
    ) external returns (uint256 amountToken, uint256 amountETH) {
        (amountToken, amountETH) = IPancakeRouter02(routerAddress).removeLiquidityETH(
            token,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            block.timestamp + 300
        );
        uint256 tokenCommission = (amountToken * commission) / 1e18;
        uint256 ethCommission = (amountETH * commission) / 1e18;
        amountToken -= tokenCommission;
        amountETH -= ethCommission;
        IERC20Upgradeable(token).safeTransfer(to, amountToken);
        payable(to).transfer(amountETH);
    }

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountA, uint256 amountB) {
        (amountA, amountB) = IPancakeRouter02(routerAddress).removeLiquidityWithPermit(
            tokenA,
            tokenB, 
            liquidity,
            amountAMin,
            amountBMin,
            address(this),
            block.timestamp + 300,
            approveMax,
            v,
            r,
            s
        );
        uint256 tokenACommission = (amountA * commission) / 1e18;
        uint256 tokenBCommission = (amountB * commission) / 1e18;
        amountA -= tokenACommission;
        amountB -= tokenBCommission;
        IERC20Upgradeable(tokenA).safeTransfer(to, amountA);
        IERC20Upgradeable(tokenB).safeTransfer(to, amountB);
    }

    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountToken, uint256 amountETH) {
        (amountToken, amountETH) = IPancakeRouter02(routerAddress).removeLiquidityWithPermit(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            block.timestamp + 300,
            approveMax,
            v,
            r,
            s
        );
        uint256 tokenCommission = (amountToken * commission) / 1e18;
        uint256 ethCommission = (amountETH * commission) / 1e18;
        amountToken -= tokenCommission;
        amountETH -= ethCommission;
        IERC20Upgradeable(token).safeTransfer(to, amountToken);
        payable(to).transfer(amountETH);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external returns (uint256[] memory amounts) {
        uint256 tokenACommission = (amountIn * commission) / 1e18;
        tokenToSwapCommissionMapping[path[0]] += tokenACommission;
        tokenAddressesSet.add(path[0]);
        uint256 outAmount = IPancakeRouter02(routerAddress).getAmountsOut(1e18, path)[1];
        require(amountOutMin >= (amountIn * outAmount * 90) / 1e20, "GymRouter: Must be greater than 90% of out amount");
        IERC20Upgradeable(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20Upgradeable(path[0]).safeIncreaseAllowance(routerAddress, amountIn - tokenACommission);
        amounts = IPancakeRouter02(routerAddress).swapExactTokensForTokens(
            amountIn - tokenACommission,
            amountOutMin, 
            path,
            to,
            block.timestamp + 300
        );
    }

    // function swapTokensForExactTokens(
    //     uint256 amountOut,
    //     uint256 amountInMax,
    //     address[] calldata path,
    //     address to,
    //     uint256 deadline
    // ) external returns (uint256[] memory amounts) {
    //     uint256 tokenBCommission = (amountOut * commission) / 1e18;
    //     IERC20Upgradeable(path[0]).safeTransferFrom(to, address(this), amountOut);
    //     IERC20Upgradeable(path[1]).safeIncreaseAllowance(routerAddress, amountInMax);
    //     amounts = IPancakeRouter02(routerAddress).swapTokensForExactTokens(
    //         amountOut - tokenBCommission,
    //         amountInMax,
    //         path,
    //         to,
    //         deadline
    //     );
    // }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external payable returns (uint256[] memory amounts) {
        uint256 ethCommission = (msg.value * commission) / 1e18;
        tokenToSwapCommissionMapping[WETH] += ethCommission;
        tokenAddressesSet.add(WETH);
        uint256 outAmount = IPancakeRouter02(routerAddress).getAmountsOut(1e18, path)[1];
        require(amountOutMin >= (msg.value * outAmount * 90) / 1e20, "GymRouter: Must be greater than 90% of out amount");
        (bool success, ) = address(this).call{value: msg.value}("");
        require(success, "Transfer failed.");
        amounts = IPancakeRouter02(routerAddress).swapExactETHForTokens{value: msg.value - ethCommission}(
            amountOutMin,
            path,
            to,
            block.timestamp + 300
        );
    }

    // function swapTokensForExactETH(
    //     uint256 amountOut,
    //     uint256 amountInMax,
    //     address[] calldata path,
    //     address to,
    //     uint256 deadline
    // ) external returns (uint256[] memory amounts) {
    //     uint256 tokenBCommission = (amountOut * commission) / 1e18;
    //     IERC20Upgradeable(path[0]).safeTransferFrom(to, address(this), amountOut);
    //     IERC20Upgradeable(path[1]).safeIncreaseAllowance(routerAddress, amountInMax);
    //     amounts = IPancakeRouter02(routerAddress).swapTokensForExactETH(
    //         amountOut - tokenBCommission,
    //         amountInMax,
    //         path,
    //         to,
    //         deadline
    //     );
    // }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external returns (uint256[] memory amounts) {
        uint256 tokenACommission = (amountIn * commission) / 1e18;
        tokenToSwapCommissionMapping[path[0]] += tokenACommission;
        tokenAddressesSet.add(path[0]);
        uint256 outAmount = IPancakeRouter02(routerAddress).getAmountsOut(1e18, path)[1];
        require(amountOutMin >= (amountIn * outAmount * 90) / 1e20, "GymRouter: Must be greater than 90% of out amount");
        IERC20Upgradeable(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20Upgradeable(path[0]).safeIncreaseAllowance(routerAddress, amountIn - tokenACommission);
        amounts = IPancakeRouter02(routerAddress).swapExactTokensForETH(
            amountIn - tokenACommission,
            amountOutMin, 
            path,
            to,
            block.timestamp + 300
        );
    }

    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to
    ) external payable returns (uint256[] memory amounts) {
        uint256 ethCommission = (msg.value * commission) / 1e18;
        tokenToSwapCommissionMapping[WETH] += ethCommission;
        tokenAddressesSet.add(WETH);
        (bool success, ) = address(this).call{value: msg.value}("");
        require(success, "Transfer failed.");
        amounts = IPancakeRouter02(routerAddress).swapETHForExactTokens{value: (msg.value - ethCommission)}(
            amountOut,
            path,
            to,
            block.timestamp + 300
        );
        payable(to).transfer(msg.value - ethCommission - amounts[0]);
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external {
        uint256 tokenACommission = (amountIn * commission) / 1e18;
        tokenToSwapCommissionMapping[path[0]] += tokenACommission;
        tokenAddressesSet.add(path[0]);
        uint256 outAmount = IPancakeRouter02(routerAddress).getAmountsOut(1e18, path)[1];
        require(amountOutMin >= (amountIn * outAmount * 90) / 1e20, "GymRouter: Must be greater than 90% of out amount");
        IERC20Upgradeable(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20Upgradeable(path[0]).safeIncreaseAllowance(routerAddress, amountIn - tokenACommission);
        IPancakeRouter02(routerAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn - tokenACommission,
            amountOutMin, 
            path,
            to,
            block.timestamp + 300
        );
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external payable {
        uint256 ethCommission = (msg.value * commission) / 1e18;
        tokenToSwapCommissionMapping[WETH] += ethCommission;
        tokenAddressesSet.add(WETH);
        uint256 outAmount = IPancakeRouter02(routerAddress).getAmountsOut(1e18, path)[1];
        require(amountOutMin >= (msg.value * outAmount * 90) / 1e20, "GymRouter: Must be greater than 90% of out amount");
        (bool success, ) = address(this).call{value: msg.value}("");
        require(success, "Transfer failed.");
        IPancakeRouter02(routerAddress).swapExactETHForTokensSupportingFeeOnTransferTokens{value: msg.value - ethCommission}(
            amountOutMin,
            path,
            to,
            block.timestamp + 300
        );
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external {
        uint256 tokenACommission = (amountIn * commission) / 1e18;
        tokenToSwapCommissionMapping[path[0]] += tokenACommission;
        tokenAddressesSet.add(path[0]);
        uint256 outAmount = IPancakeRouter02(routerAddress).getAmountsOut(1e18, path)[1];
        require(amountOutMin >= (amountIn * outAmount * 90) / 1e20, "GymRouter: Must be greater than 90% of out amount");
        IERC20Upgradeable(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20Upgradeable(path[0]).safeIncreaseAllowance(routerAddress, amountIn - tokenACommission);
        IPancakeRouter02(routerAddress).swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountIn - tokenACommission,
            amountOutMin, 
            path,
            to,
            block.timestamp + 300
        );
    }

    function exactAmountOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns(uint256){
        uint256 outAmount = IPancakeRouter02(routerAddress).getAmountsOut(1e18, path)[1];
        return amountIn * outAmount / 1e18;
    }

    function withdrawETH(uint256 _amt, address _to) external onlyOwner {
        uint256 amount = address(this).balance > _amt ? _amt : address(this).balance;
        payable(_to).transfer(amount);
    }

    function withdrawStuckAmt(address _token, uint256 _amt) external onlyOwner {
        IERC20Upgradeable(_token).transfer(owner(), _amt);
    }

    //-----------------Distribution-----------------//

    /**
     * @notice returns the length of the tokenAddressesSet
     */
    function countSet() external view returns (uint256) {
        return tokenAddressesSet.length();
    }

    function isInSet(address _token) external view returns (bool) {
        return tokenAddressesSet.contains(_token);
    }

    /**
     * @notice returns the token addresses in the set
     */
    function tokenAddressesValues() external view returns (address[] memory) {
        return tokenAddressesSet.values();
    }

    /**
     * @notice returns the total amount of tokens and parcels for distribution
     * @dev This function calculates the total amount of tokens available for distribution based on the swap
     * @return totalAmount 
     * @return totalParcelCount 
     */
    function getAmountForDistribution() external view returns (uint256 totalAmount, uint256 totalParcelCount) {
        uint256 currentTotalAmount;
        address[] memory path;
        address factoryAddress = IPancakeRouter02(routerAddress).factory();
        for (uint256 i = 0; i < tokenAddressesSet.length(); i++) {
            address tokenAddress = tokenAddressesSet.at(i);
            if(IFactory(factoryAddress).getPair(tokenAddress,primaryTokenAddress) == address(0)) {
                path = new address[](3);
                path[0] = tokenAddress;
                path[1] = busdAddress;
                path[2] = primaryTokenAddress;
            } else {
                path = new address[](2);
                path[0] = tokenAddress;
                path[1] = primaryTokenAddress;
            }

            if(tokenAddress == primaryTokenAddress) {
                totalAmount += tokenToSwapCommissionMapping[tokenAddress];
                continue; // Skip primary token address
            }
            if(tokenToSwapCommissionMapping[tokenAddress] != 0) {
                currentTotalAmount =  IPancakeRouter02(routerAddress).getAmountsOut(tokenToSwapCommissionMapping[tokenAddress], path)[path.length - 1];
                totalAmount += currentTotalAmount;
            }
        }
        totalParcelCount = IMunicipality(municipalityAddress).currentlySoldStandardParcelsCount() + 
                            IMunicipality(municipalityAddressKB).currentlySoldStandardParcelsCount();
    }

    /**
     * @notice swaps and resets the counter for the token addresses in the set
     * @dev This function swaps the tokens in the set for the primary token and resets the counter for each token address
     * @param amountsOutMin The minimum amounts out for each token address in the set except the primary token address(should be passed 0 for primary token address)
     */
    function swapAndResetTheCounter(uint256[] memory amountsOutMin) external returns(uint256 totalCounterForDistribution, uint256 totalParcelCount) {
        require(amountsOutMin.length == tokenAddressesSet.length(), "GymRouter: amountsOutMin length mismatch");
        require(msg.sender == binaryBackendAddress, "GymRouter: Only binary backend can call this function");
        totalParcelCount = IMunicipality(municipalityAddress).currentlySoldStandardParcelsCount() + 
                            IMunicipality(municipalityAddressKB).currentlySoldStandardParcelsCount();
        address factoryAddress = IPancakeRouter02(routerAddress).factory();
        address[] memory path;
        totalCounterForDistribution = 0; // Reset the total counter for distribution
        for (uint256 i = 0; i < tokenAddressesSet.length(); i++) {
            address tokenAddress = tokenAddressesSet.at(i);
            if(IFactory(factoryAddress).getPair(tokenAddress,primaryTokenAddress) == address(0)) {
                path = new address[](3);
                path[0] = tokenAddress;
                path[1] = busdAddress;
                path[2] = primaryTokenAddress;
            } else {
                path = new address[](2);
                path[0] = tokenAddress;
                path[1] = primaryTokenAddress;
            }
            if(tokenAddress == primaryTokenAddress) {
                totalCounterForDistribution += tokenToSwapCommissionMapping[tokenAddress];
                IERC20Upgradeable(tokenAddress).safeTransfer(netGymStreetAddr, tokenToSwapCommissionMapping[tokenAddress]);
                tokenToSwapCommissionMapping[tokenAddress] = 0; // Reset the counter for primary token address
                continue; // Skip primary token address
            }
            uint256 amountToSwap = tokenToSwapCommissionMapping[tokenAddress];
            if (amountToSwap > 0) {
                if(tokenAddress == WETH) {
                    IPancakeRouter02(routerAddress).swapExactETHForTokens{value: amountToSwap}(
                        amountsOutMin[i],
                        path,
                        netGymStreetAddr,
                        block.timestamp + 300
                    );
                    totalCounterForDistribution += amountsOutMin[i];
                    tokenToSwapCommissionMapping[tokenAddress] = 0; // Reset the counter for WETH
                    continue; // Skip next iteration since WETH is used as a native token
                }
                IERC20Upgradeable(tokenAddress).safeIncreaseAllowance(routerAddress, amountToSwap);
                IPancakeRouter02(routerAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    amountToSwap,
                    amountsOutMin[i],
                    path,
                    netGymStreetAddr,
                    block.timestamp + 300
                );
                totalCounterForDistribution += amountsOutMin[i];
                tokenToSwapCommissionMapping[tokenAddress] = 0;
            }
        }
        emit CommissionDistributed(totalCounterForDistribution);
    }

    function claimIncome(address _user, uint256 _USDTAmount, uint256 _gymAmount) external {
        require(msg.sender == binaryBackendAddress, "GymRouter: Only binary backend can call this function");
        INetGymStreet(netGymStreetAddr).transferTokens(_user, primaryTokenAddress, _gymAmount);
        INetGymStreet(netGymStreetAddr).transferTokens(_user, busdAddress, _USDTAmount);
        emit IncomeClaimed(_user, _USDTAmount, _gymAmount);
    }

    function resetTokenCounters() external {
        require(msg.sender == 0x8E00f430E4476efAd452955FC8DE9b9c5BC5a08e, "GymRouter: R");
        for(uint256 i = 0; i < tokenAddressesSet.length(); i++) {
            address tokenAddress = tokenAddressesSet.at(i);
            tokenToSwapCommissionMapping[tokenAddress] = 0;
        }
    }
}
