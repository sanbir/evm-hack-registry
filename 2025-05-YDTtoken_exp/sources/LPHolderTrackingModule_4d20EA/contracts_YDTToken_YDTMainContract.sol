// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
// 引入各个子合约
import "./DeflationModule.sol";
import "./TaxModule.sol";
import "./ReferralModule.sol";
import "./LiquidityModule.sol";
import "./LPHolderTrackingModule.sol";
import "./LiquidityRemovalModule.sol";
interface IUniswapV2Factory {
    function createPair(address tokenA,address tokenB) external returns (address);
}

contract YDTMainContract is ERC20, Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    // 基础信息
    uint256 private constant TOTAL_SUPPLY = 21000000 * (10 ** 6);
    uint8 private constant DECIMALS = 6;
    mapping(address => bool) public whitelist; // 白名单地址

    // 地址配置
    address public addressA;
    address public addressB;
    address public addressC;
    address public addressD;
    address public addressM;
    address public USDT;
    address public pancakePair;
    IUniswapV2Router02 public pancakeRouter;

    // 子合约实例
    DeflationModule public deflationModule;
    TaxModule public taxModule;
    ReferralModule public referralModule;
    LiquidityModule public liquidityModule;
    LPHolderTrackingModule public lpTrackingModule;
    LiquidityRemovalModule public liquidityRemovalModule;

    event Burned(address indexed account, uint256 amount);
    event AddressUpdated(
        string addressType,
        address oldAddress,
        address newAddress
    );
    event TokenRescued(address indexed tokenAddress, address indexed to, uint256 amount);
    event TokenRescuedFromSubContract(
        address indexed subContract,
        address indexed tokenAddress,
        address indexed to,
        uint256 amount
    );
    event RescueOperationFailed(
        uint256 indexed operationIndex,
        address indexed subContract,
        address indexed tokenAddress,
        string reason
    );
    constructor(
        address _router,
        address _usdt,
        address _addressA,
        address _addressB,
        address _addressC,
        address _addressD,
        address _addressM
    ) ERC20("Yellow Duck Token", "YDT") {
        _mint(msg.sender, TOTAL_SUPPLY);
        // 设置相关地址
        USDT = _usdt;
        addressA = _addressA;
        addressB = _addressB;
        addressC = _addressC;
        addressD = _addressD;
        addressM = _addressM;
        pancakeRouter = IUniswapV2Router02(_router);
        // 创建交易对
        pancakePair = IUniswapV2Factory(pancakeRouter.factory()).createPair(
            address(this),
            _usdt
        );
        // 实例化子合约
        deflationModule = new DeflationModule(address(this));
        lpTrackingModule = new LPHolderTrackingModule(address(this), addressM);
        taxModule = new TaxModule(address(this));
        referralModule = new ReferralModule(address(this));
        liquidityModule = new LiquidityModule(address(this));
        liquidityRemovalModule = new LiquidityRemovalModule(address(this));

        // 授权税收模块可以转移本合约的代币
        _approve(address(this), address(taxModule), type(uint256).max);
        _approve(pancakePair, address(deflationModule), type(uint256).max);
        _approve(address(this), address(liquidityModule), type(uint256).max);
    }

    // 修改各个地址的函数
    function setAddressA(address _newAddress) external onlyOwner {
        require(_newAddress != address(0), "Cannot set to zero address");
        address oldAddress = addressA;
        addressA = _newAddress;
        emit AddressUpdated("AddressA", oldAddress, _newAddress);
    }
    function setAddressB(address _newAddress) external onlyOwner {
        require(_newAddress != address(0), "Cannot set to zero address");
        address oldAddress = addressB;
        addressB = _newAddress;
        emit AddressUpdated("AddressB", oldAddress, _newAddress);
    }
    function setAddressC(address _newAddress) external onlyOwner {
        require(_newAddress != address(0), "Cannot set to zero address");
        address oldAddress = addressC;
        addressC = _newAddress;
        emit AddressUpdated("AddressC", oldAddress, _newAddress);
    }
    function setAddressD(address _newAddress) external onlyOwner {
        require(_newAddress != address(0), "Cannot set to zero address");
        address oldAddress = addressD;
        addressD = _newAddress;
        emit AddressUpdated("AddressD", oldAddress, _newAddress);
    }

    function setAddressM(address _newAddress) external onlyOwner {
        require(_newAddress != address(0), "Cannot set to zero address");
        address oldAddress = addressM;
        addressM = _newAddress;
        // 更新LP跟踪模块中的M地址
        lpTrackingModule.updateExcludedAddress(oldAddress, _newAddress);
        emit AddressUpdated("AddressM", oldAddress, _newAddress);
    }
    function setUSDT(address _newUSDT) external onlyOwner {
        require(_newUSDT != address(0), "Cannot set to zero address");
        address oldUSDT = USDT;
        USDT = _newUSDT;
        emit AddressUpdated("USDT", oldUSDT, _newUSDT);
    }
    function setRouter(address _newRouter) external onlyOwner {
        require(_newRouter != address(0), "Cannot set to zero address");
        address oldRouter = address(pancakeRouter);
        pancakeRouter = IUniswapV2Router02(_newRouter);
        emit AddressUpdated("Router", oldRouter, _newRouter);
    }
    // 提供公共访问器，供子合约获取上下文信息
    function getAddressA() public view returns (address) {
        return addressA;
    }
    function getAddressB() external view returns (address) {
        return addressB;
    }
    function getAddressC() external view returns (address) {
        return addressC;
    }
    function getAddressD() external view returns (address) {
        return addressD;
    }
    function getAddressM() external view returns (address) {
        return addressM;
    }
    function getUSDT() external view returns (address) {
        return USDT;
    }
    function getPancakePair() external view returns (address) {
        return pancakePair;
    }
    function getPancakeRouter() external view returns (IUniswapV2Router02) {
        return pancakeRouter;
    }
    function getTaxModule() external view returns (TaxModule) {
        return taxModule;
    }
    function getReferralModule() external view returns (ReferralModule) {
        return referralModule;
    }
    function getLiquidityModule() external view returns (LiquidityModule) {
        return liquidityModule;
    }
    function getDeflationModule() external view returns (DeflationModule) {
        return deflationModule;
    }
    function getLiquidityRemovalModule()
        external
        view
        returns (LiquidityRemovalModule)
    {
        return liquidityRemovalModule;
    }
    function getLPTrackingModule()
        external
        view
        returns (LPHolderTrackingModule)
    {
        return lpTrackingModule;
    }
    function getDecimals() external pure returns (uint256) {
        return DECIMALS;
    }
    function getTotalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    // 转账函数，调用交易税模块处理交易税
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override nonReentrant {
        if(msg.sender==owner()){
            super._transfer(sender, recipient, amount);
            return;
        }
        // 先处理推荐模块
        try referralModule.handleTransfer(sender, recipient, amount) {
            // 推荐模块调用成功
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("Referral failed: ", reason)));
        }

        // 再处理税收模块
        try taxModule.handleTransferTax(sender, recipient, amount) returns (
            uint256 amountAfterTax
        ) {
            // 税收模块调用成功
            amount = amountAfterTax;
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("Tax transfer failed: ", reason)));
        }

        if (amount > 0 && balanceOf(sender) >= amount) {
            super._transfer(sender, recipient, amount);
            console.log("transfer success",sender,recipient,amount);
        }

        try
            lpTrackingModule.handleTransferLpTracking(sender, recipient, amount)
        {} catch Error(string memory reason) {
            revert(string(abi.encodePacked("LpTracking failed: ", reason)));
        }
    }

    // 代理转账方法，允许子模块绕过税收和推荐处理
    function proxyTransfer(
        address sender,
        address recipient,
        uint256 amount,
        address callerModule // 调用方模块地址（需为子合约）
    ) external {
        // 校验调用者必须为子合约
        require(
            address(taxModule) == callerModule ||
                address(referralModule) == callerModule ||
                address(deflationModule) == callerModule ||
                address(liquidityModule) == callerModule ||
                address(lpTrackingModule) == callerModule,
            "Only sub-modules allowed"
        );

        // 直接调用父类转账（跳过子模块逻辑）
        super._transfer(sender, recipient, amount);
    }

    // 销毁接口
    function burnTokens(address account, uint256 amount) external {
        require(
            msg.sender == owner() || msg.sender == address(deflationModule),
            "Unauthorized"
        );
        require(balanceOf(account) >= amount, "Insufficient balance");

        _burn(account, amount);
        emit Burned(account, amount);
    }

    // 添加流动性函数（从用户接收USDT，并调用LiquidityModule）
    function addLiquidityThroughTransit(address recipient,uint256 usdtAmount) external onlyOwner(){
        IERC20 usdtToken = IERC20(USDT);
        address mainAddress=address(this);
        require(usdtToken.balanceOf(mainAddress)>=usdtAmount,'Insufficient balance');
 
        require(usdtToken.transfer(address(liquidityModule),usdtAmount),'Insufficient allowance');
        // 将USDT从用户转移到LiquidityModule合约

        // 调用LiquidityModule的addLiquidityThroughTransit函数
        liquidityModule.addLiquidityThroughTransit(recipient, usdtAmount);
   
    }

    function decimals() public view virtual override returns (uint8) {
        return DECIMALS;
    }
    /**
     * @dev 设置流动性移除模块地址
     */
    function setLiquidityRemovalModule(
        address _liquidityRemovalModule
    ) external onlyOwner {
        require(_liquidityRemovalModule != address(0), "YDT: Zero address");
        liquidityRemovalModule = LiquidityRemovalModule(
            _liquidityRemovalModule
        );
    }

    function removeLiquidityThroughTransit(address recipient,uint256 lpAmount) external onlyOwner(){
        require(address(liquidityRemovalModule) != address(0),"LiquidityRemovalModule not set");
        // 获取LP代币地址
        IERC20 lpToken =IERC20(pancakePair) ;
        address mainAddress=address(this);
        //检测是否授权，没有则抛出异常，用require
        require(lpToken.balanceOf(mainAddress)>=lpAmount,'Insufficient balance');
        require(lpToken.transfer(address(liquidityRemovalModule),lpAmount),'Insufficient allowance');
      
        // 调用流动性移除模块的函数
        liquidityRemovalModule.removeLiquidityForUser(recipient, lpAmount);
    }

    function applyDeflation() external {
        deflationModule.applyDeflation();
    }

    function rescueToken(address tokenAddress, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "001");
        require(amount > 0, "002");
        
        if (tokenAddress == address(this)) {
            // 如果是本合约代币，使用transfer函数
            _transfer(address(this), to, amount);
        } else {
            // 对于其他ERC20代币，使用transfer函数
            IERC20 token = IERC20(tokenAddress);
            uint256 balance = token.balanceOf(address(this));
            require(balance >= amount, "003");
            
            token.transfer(to, amount);
        }
        
        // 触发事件
        emit TokenRescued(tokenAddress, to, amount);
    }

    /**
     * @dev 管理员专用：从任意子合约提取任意代币
     * @param subContractAddress 子合约地址
     * @param tokenAddress 要提取的代币地址（address(0)表示ETH）
     * @param to 代币接收地址
     * @param amount 提取金额
     */
    function rescueTokenFromSubContract(
        address subContractAddress,
        address tokenAddress,
        address to,
        uint256 amount
    ) external onlyOwner {
        require(subContractAddress != address(0), "YDT: Sub-contract address cannot be zero");
        require(to != address(0), "YDT: Recipient address cannot be zero");
        require(amount > 0, "YDT: Amount must be greater than zero");
        
        // 验证是否是有效的子合约
        require(
            subContractAddress == address(deflationModule) ||
            subContractAddress == address(taxModule) ||
            subContractAddress == address(referralModule) ||
            subContractAddress == address(liquidityModule) ||
            subContractAddress == address(lpTrackingModule) ||
            subContractAddress == address(liquidityRemovalModule),
            "YDT: Invalid sub-contract address"
        );
        
        if (tokenAddress == address(0)) {
            // 提取ETH
            uint256 contractBalance = subContractAddress.balance;
            require(contractBalance >= amount, "YDT: Insufficient ETH balance in sub-contract");
            
            // 使用call方式从子合约提取ETH
            (bool success, ) = subContractAddress.call(
                abi.encodeWithSignature("withdrawETH(address,uint256)", to, amount)
            );
            require(success, "YDT: ETH withdrawal failed");
        } else {
            // 提取ERC20代币
            IERC20 token = IERC20(tokenAddress);
            uint256 contractBalance = token.balanceOf(subContractAddress);
            require(contractBalance >= amount, "YDT: Insufficient token balance in sub-contract");
            
            // 使用call方式从子合约提取代币
            (bool success, ) = subContractAddress.call(
                abi.encodeWithSignature("withdrawToken(address,address,uint256)", tokenAddress, to, amount)
            );
            require(success, "YDT: Token withdrawal failed");
        }
        
        // 触发事件
        emit TokenRescuedFromSubContract(subContractAddress, tokenAddress, to, amount);
    }
 

    function isWhitelisted(address account) external view returns (bool) {
        return whitelist[account];
    }

  // 添加或移除白名单地址
    function addToWhitelist(address account, bool value) external onlyOwner {
            whitelist[account] = true; 
    }

}
