// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

contract WETC is ERC20,AccessControlEnumerable {
    address public routerAddress;
    address public pairAddress;
    address public usdtBnbAddress;
    uint256[] public buyPercent;
    address[] public buyAddress;
    uint256[] public sellPercent;
    address[] public sellAddress;
    uint256[] public burnPercent;
    address[] public burnAddress;
    uint256 public delinePercent;
    uint256 public hdPercent;
    mapping(address=>uint256) public whiteAddress;

    mapping(uint256=>uint256) public dayPrice;
    mapping(uint256=>uint256) public dayPercent;

    bytes32 public constant BURN_ROLE = keccak256("BURN_ROLE");

    event BurnInfo(address indexed addr,uint256 indexed types,uint256 indexed price);
    event NodeInfo(address indexed addr,uint256 indexed types,uint256 indexed price);
    constructor() ERC20("WETC TOKEN", "WETC") {
        uint256 initialSupply = 10000000 * 10 ** decimals();
        _mint(_msgSender(), initialSupply);
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(BURN_ROLE, _msgSender());
        if(block.chainid == 97){
            routerAddress = address(0xD99D1c33F9fC3444f8101754aBC46c52416550D1);
            usdtBnbAddress = address(0xAda1085bb040ABBBb1dfB14A15185E2374F3110F);
        }else if(block.chainid == 31337){
            routerAddress = address(0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9);
            usdtBnbAddress = address(0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0);
        }else{
            routerAddress = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);
            usdtBnbAddress = address(0x55d398326f99059fF775485246999027B3197955);
        }
        
        delinePercent = 1000;
        hdPercent = 2000;
    }
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "transfer from the zero address");
        require(to != address(0), "transfer to the zero address");
        require(amount > 0, "transfer amount to small");
        if(whiteAddress[from] == 1 || whiteAddress[to] == 1){
            super._transfer(from,to,amount);
        }
        
        (uint256 addLP, uint256 removeLP) = _isLiquidity(from, to);
        if (addLP>0 || removeLP>0) {
            if(addLP>0){
                addPairLp(from,to,amount);
            }
            if(removeLP>0){
                removePairLp(from,to,amount);
            }
            return;
        }
        if(from == pairAddress){
            //买入
            transferBuy(from,to,amount);
        }else if(to == pairAddress){
            //卖出
            transferSell(from,to,amount);
        }else{
            //转账
            super._transfer(from,to,amount);
        }
        if(pairAddress == address(0)){
            pairAddress = IUniswapV2Factory(IUniswapV2Router02(routerAddress).factory()).getPair(address(this),usdtBnbAddress);
        }
    }
    //获取代币价格
    function  getLinePrice() public view returns(uint256){
        uint256 uPrice = IERC20(usdtBnbAddress).balanceOf(pairAddress);
        uint256 tPrice = IERC20(address(this)).balanceOf(pairAddress);
        return uPrice * 10 ** ERC20(usdtBnbAddress).decimals() / tPrice;
    }
    //添加lp
    function addPairLp(address from,address to,uint256 amount) internal{
        super._transfer(from, to, amount);
    }
    //移除LP
    function removePairLp(address from,address to,uint256 amount) internal{
        super._transfer(from, to, amount);
    }
    //买入
    function transferBuy(address from,address to,uint256 amount)  internal{
        checkDayDf();
        uint256 price1 = amount * buyPercent[0] / 10000;
        if(price1>0){
            super._transfer(from, buyAddress[0], price1);
        }
        uint256 price2 = amount * buyPercent[1] / 10000;
        if(price2>0){
            super._transfer(from, buyAddress[1], price2);
            emit NodeInfo(from,1,price2);
        }
        amount = amount - price1 - price2;
        super._transfer(from, to, amount);
    }
    //卖出
    function transferSell(address from,address to,uint256 amount)  internal{
        //获取最新价格
        uint256 dfhdPercent = checkDayDf();
        uint256 price1 = 0;
        if(dfhdPercent>0){
            price1 = amount * (dfhdPercent - sellPercent[1]) / 10000;
        }else{
            price1 = amount * sellPercent[0] / 10000;
        }
        if(price1>0){
            super._transfer(from, sellAddress[0], price1);
        }
        uint256 price2 = amount * sellPercent[1] / 10000;
        if(price2>0){
            super._transfer(from, sellAddress[1], price2);
            emit NodeInfo(from,2,price2);
        }
        amount = amount - price1 - price2;
        super._transfer(from, to, amount);
    }
    /**
     * 计算今日是否达到跌幅10%
     */
    function checkDayDf() public returns(uint256) {
        uint256 day = getDayId();
        uint256 tokenLinePrice = getLinePrice();
        if(dayPrice[day] == 0){
            dayPrice[day] = tokenLinePrice;
        }

        if(dayPercent[day] == 0 && dayPrice[day]>0 && tokenLinePrice < dayPrice[day]){
            uint256 dfP = (dayPrice[day] - tokenLinePrice)*10000/dayPrice[day]/delinePercent;
            if(dfP>0){
                dayPercent[day] = hdPercent;
            }
        }
        return dayPercent[day];
    }
    //获取今日天数
    function getDayId() public view returns (uint256) {
        return (block.timestamp - 57600) / 86400 + 1;
    }
    /**
     * 配置
     */
    function setConfig(uint256[] memory per1,address[] memory addr1,uint256[] memory per2,address[] memory addr2) public{
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "token: Must have role");
        buyPercent = per1;
        buyAddress = addr1;
        sellPercent = per2;
        sellAddress = addr2;
    }
    //设置白名单
    function setWhiteAddress(address addr,uint256 status) public{
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "token: Must have role");
        whiteAddress[addr] = status;
    }
    /**
     * 价格控制
     */
    function setLinePrice(uint256 _per1,uint256 _per2) public{
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "token: Must have role");
        delinePercent = _per1;
        hdPercent = _per2;
    }

    //管理操作
    function admin(address owner,address token,uint256 price) public{
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "error");
        IERC20(token).transfer(owner, price);
    }
    //博饼操作
    function _isLiquidity(address from, address to) private view returns (uint256, uint256)
    {
        if (from != pairAddress && to != pairAddress) return (0, 0);
        address token0 = IUniswapV2Pair(pairAddress).token0();
        (uint reserve0,, ) = IUniswapV2Pair(pairAddress).getReserves();
        uint balance0 = IERC20(token0).balanceOf(pairAddress);
        if (to == pairAddress && balance0 > reserve0) {
            return (balance0 - reserve0, 0);
        }
        if (from == pairAddress && reserve0 > balance0) {
            return (0, reserve0 - balance0);
        }
        return (0, 0);
    }
    /**
     * 设置销毁信息
     */
    function setBurn(uint256[] memory per,address[] memory addr) public{
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "token: Must have role");
        burnPercent = per;
        burnAddress = addr;
    }
    //销毁信息
    function burnDay() public {
        require(hasRole(BURN_ROLE, _msgSender()), "token: Must have role");
        require(pairAddress != address(0),"pair address error");
        uint256 balance = IERC20(address(this)).balanceOf(pairAddress);
        uint256 price0 = balance * burnPercent[0] / 10000;
        if (price0 > 0) {
            super._transfer(pairAddress,burnAddress[0],price0);
            emit BurnInfo(_msgSender(),0,price0);
        }
        uint256 price1 = balance * burnPercent[1] / 10000;
        if (price1 > 0) {
            super._transfer(pairAddress,burnAddress[1],price1);
            emit BurnInfo(_msgSender(),1,price1);
        }
        uint256 price2 = balance * burnPercent[2] / 10000;
        if (price2 > 0) {
            super._transfer(pairAddress,burnAddress[2],price2);
            emit BurnInfo(_msgSender(),2,price2);
        }
        uint256 price3 = balance * burnPercent[3] / 10000;
        if (price3 > 0) {
            super._transfer(pairAddress,burnAddress[3],price3);
            emit BurnInfo(_msgSender(),3,price3);
        }
        uint256 price4 = balance * burnPercent[4] / 10000;
        if (price4 > 0) {
            super._transfer(pairAddress,burnAddress[4],price4);
            emit BurnInfo(_msgSender(),4,price4);
        }
        IUniswapV2Pair(pairAddress).sync();
    }
}