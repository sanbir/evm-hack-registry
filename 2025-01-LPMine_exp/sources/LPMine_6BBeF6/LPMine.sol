// SPDX-License-Identifier: MIT
    pragma solidity ^0.8.0;

    interface IERC20 {
        function totalSupply() external view returns (uint256);
        function balanceOf(address account) external view returns (uint256);
        function transfer(address recipient, uint256 amount) external returns (bool);
        function symbol() external view returns(string memory);
        function allowance(address owner, address spender)
        external
        view
        returns (uint256);

        function approve(address spender, uint256 amount) external returns (bool);

        function transferFrom(
            address sender,
            address recipient,
            uint256 amount
        ) external returns (bool);

        event Transfer(address indexed from, address indexed to, uint256 value);

        event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value);
    }

    contract Ownable {
        address internal _owner;

        event OwnershipTransferred(
            address indexed previousOwner,
            address indexed newOwner
        );

        constructor() {
            address msgSender = _msgSender();
            _owner = msgSender;
            emit OwnershipTransferred(address(0), msgSender);
        }

        function _msgSender() internal view returns(address) {
            return msg.sender;
        }
        function owner() public view returns (address) {
            return _owner;
        }

        modifier onlyOwner() {
            require(_owner == _msgSender(), "Ownable: caller is not the owner");
            _;
        }

        function renounceOwnership() public virtual onlyOwner {
            emit OwnershipTransferred(_owner, address(0));
            _owner = address(0);
        }

        function transferOwnership(address newOwner) public virtual onlyOwner {
            require(
                newOwner != address(0),
                "Ownable: new owner is the zero address"
            );
            emit OwnershipTransferred(_owner, newOwner);
            _owner = newOwner;
        }
    }


    library SafeMath {
        function add(uint256 a, uint256 b) internal pure returns (uint256) {
            uint256 c = a + b;
            require(c >= a, "SafeMath: addition overflow");

            return c;
        }

        function sub(uint256 a, uint256 b) internal pure returns (uint256) {
            return sub(a, b, "SafeMath: subtraction overflow");
        }

        function sub(
            uint256 a,
            uint256 b,
            string memory errorMessage
        ) internal pure returns (uint256) {
            require(b <= a, errorMessage);
            uint256 c = a - b;

            return c;
        }

        function mul(uint256 a, uint256 b) internal pure returns (uint256) {
            
            
            
            if (a == 0) {
                return 0;
            }

            uint256 c = a * b;
            require(c / a == b, "SafeMath: multiplication overflow");

            return c;
        }

        function div(uint256 a, uint256 b) internal pure returns (uint256) {
            return div(a, b, "SafeMath: division by zero");
        }

        function div(
            uint256 a,
            uint256 b,
            string memory errorMessage
        ) internal pure returns (uint256) {
            require(b > 0, errorMessage);
            uint256 c = a / b;
            
            return c;
        }
    }
    interface IUniswapV2Pair {
        function balanceOf(address owner) external view returns (uint256);
        function token0() external view returns (address);
        function token1() external view returns (address);
    }

    interface IUniswapV2Router01 {
        function factory() external pure returns (address);

        function swapExactTokensForTokens(
            uint amountIn,
            uint amountOutMin,
            address[] calldata path,
            address to,
            uint deadline
        ) external returns (uint[] memory amounts);

        function addLiquidity(
            address tokenA,
            address tokenB,
            uint256 amountADesired,
            uint256 amountBDesired,
            uint256 amountAMin,
            uint256 amountBMin,
            address to,
            uint256 deadline
        )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

        function removeLiquidity(
            address tokenA,
            address tokenB,
            uint liquidity,
            uint amountAMin,
            uint amountBMin,
            address to,
            uint deadline
        ) external returns (uint amountA, uint amountB);
       
        function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
    }

    interface IUniswapV2Router02 is IUniswapV2Router01 {
        
        function swapExactTokensForTokensSupportingFeeOnTransferTokens(
            uint256 amountIn,
            uint256 amountOutMin,
            address[] calldata path,
            address to,
            uint256 deadline
        ) external;
    }

    interface IUniswapV2Factory {
        function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
    }

    contract TokenDistributor {
        address public _owner;
        address public _admin;
        constructor (address admin) {
            _owner = msg.sender;
            _admin = admin;
        }
        
        function claimToken(address token, uint256 amount, address to) external  {
            require(msg.sender == _admin || msg.sender == _owner);
            IERC20(token).transfer(to, amount);
        }
    }


    contract LPMine is Ownable {
        using SafeMath for uint256;
        address private immutable usdtAddress;

        IUniswapV2Router02 private immutable uniswapV2Router;
        TokenDistributor public immutable rewardPool;
        
        
        uint256 public monthFee = 5;
        uint256 public removeFee = 1;

        uint256 private wtoOpenBuy = 1741080220;
        
        uint256 public tokenIds = 0;
        uint256 private wtoTokenId = 1;
        uint256 private coarTokenId = 2;
        struct Token {
            address tokenAddress; 
            address pair; 
            string name; 
            string logo; 
            bool sort; 
        }

        mapping(uint256 => Token) public tokens;
        address public wtoFeeAccount;
        address public coarFeeAccount;
        struct PledgeInfo{ 
            uint256 wtoLpAmount; 
            uint256 coarLpAmount; 
            uint256 depositTime; 
            uint256 wtoLpBackTime;
            uint256 coarLpBackTime; 
            uint256 wtoRewardTime;
            uint256 coarRewardTime;
        }

        mapping(address => PledgeInfo) public userPledge;

        bool public mustBind;
        struct Invite {
            uint256 num;
            uint256 wtoAmount;
            uint256 coarAmount;
        }
        mapping(address => Invite) public inviteInfos;

        mapping(address => address) public inviteBind;  
        uint256[] public levelFee;

        event InviteBind(address indexed newUser,address indexed oldUser);
        
        event AddLP(address indexed account,address tokenAddress,uint256 lpAmount,uint time);
        
        event RemoveLP(address indexed account,uint time);
        
        event ReceiveRewird(address indexed account,address tokenAddress ,uint256 amount,uint256 time);

        constructor(address[] memory _wallets) {
            uniswapV2Router = IUniswapV2Router02(_wallets[0]);
            usdtAddress = _wallets[1];
            rewardPool = new TokenDistributor(_msgSender());
            IERC20(usdtAddress).approve(_wallets[0],~uint256(0));
        }
        
        receive() external payable {
        }
        
        function partakeAddLp(uint256 _tokenId,uint256 _tokenAmount, uint256 _usdtAmount,address _oldUser) public {    
            if(mustBind) {
                require(isBind(_oldUser),"oldUser not bind parent");
            }
            if(!isBind(_msgSender())) {
                newBind(_msgSender(),_oldUser);
            }
            IERC20 _usdt = IERC20(usdtAddress);
            _usdt.transferFrom(_msgSender(),address(this),_usdtAmount);
            Token memory _token = tokens[_tokenId];
            address _tokenAddress = _token.tokenAddress;
            IERC20 _tokenContract = IERC20(_token.tokenAddress);
            _tokenContract.transferFrom(_msgSender(),address(this),_tokenAmount);
            
            (uint256 _addTokenAmount,uint256 _addUsdtAmount,uint256 _liquidity) = addLiquidityUseUsdt(_tokenAddress,usdtAddress,_tokenAmount,_usdtAmount);
            
            backToken(_tokenAddress,_tokenAmount,_addTokenAmount);
            
            backToken(usdtAddress,_usdtAmount,_addUsdtAmount);
            
            (uint256 _wtoAmount,uint256 _coarAmount) = getCanClaimed(_msgSender());
            if(_wtoAmount > 0){
                rewardPool.claimToken(tokens[wtoTokenId].tokenAddress,_wtoAmount,_msgSender());
                rewardParent(wtoTokenId,tokens[wtoTokenId].tokenAddress,_wtoAmount,_msgSender());
            }
            if(_coarAmount > 0){
                rewardPool.claimToken(tokens[coarTokenId].tokenAddress,_coarAmount,_msgSender());
                rewardParent(coarTokenId,tokens[coarTokenId].tokenAddress,_coarAmount,_msgSender());
            }
            
            PledgeInfo storage _pledge = userPledge[_msgSender()];
            if(_tokenId == wtoTokenId){
                _pledge.wtoLpAmount += _liquidity;   
                _pledge.wtoLpBackTime = wtoOpenBuy;
                _pledge.wtoRewardTime = block.timestamp;
            }
            if(_tokenId == coarTokenId){
                _pledge.coarLpAmount += _liquidity;
                _pledge.coarRewardTime = block.timestamp;
            }
            _pledge.depositTime = block.timestamp;

            emit AddLP(_msgSender(), _tokenAddress, _liquidity, block.timestamp);
        }

        function newBind(address _new,address _old) internal {
            inviteBind[_new] = _old;
            address[] memory _parents = getParents(_new);
            for(uint256 _i = 0;_i < _parents.length;_i++){
                if(_parents[_i] == address(0)) break;
                Invite storage _parent = inviteInfos[_parents[_i]];
                _parent.num += 1;
            }
            emit InviteBind(_new,_old);
        }
        function getParents(address _user) internal view returns(address[] memory){
            address[] memory _parents = new address[](6);
            _parents[0] = inviteBind[_user];
            for(uint256 i = 1;i < _parents.length;i++){
                _parents[i] = inviteBind[_parents[i - 1]];
            }
            return _parents;
        }


        function backToken(address _contract,uint256 _inAmount,uint256 _outAmount) private {
            if(_inAmount > _outAmount) {
                uint256 _backAmount = _inAmount.sub(_outAmount);
                IERC20(_contract).transfer(_msgSender(),_backAmount);
            }
        } 
        function addLiquidityUseUsdt(address _path0,address _path1,uint256 _tokenAmount,uint256 _usdtAmount) private returns(uint256,uint256,uint256) {
            (uint256 path0Amount,uint256 path1Amount,uint256 liquidity) = uniswapV2Router.addLiquidity(
                _path0,
                _path1,
                _tokenAmount,
                _usdtAmount,
                0,
                0,
                address(this),
                block.timestamp + 10
            );
            return (path0Amount,path1Amount,liquidity);
        }

        function isBind(address _user) public view returns(bool) {
            return inviteBind[_user] != address(0) || _user == owner();
        }
        
        function takeLp(uint256 _tokenId) public {
            Token memory _token = tokens[_tokenId];
            PledgeInfo storage _pledge = userPledge[_msgSender()];
            address _pair = _token.pair;
            uint256 _lpAmount;
            address _feeAccount;
            if(_tokenId == wtoTokenId){
                require(_pledge.wtoLpAmount > 0,"wto no lp");
                _lpAmount = _pledge.wtoLpAmount;
                _feeAccount = wtoFeeAccount;
                _pledge.wtoLpAmount = 0;
                _pledge.wtoLpBackTime = 0;
            }
            if(_tokenId == coarTokenId){
                require(_pledge.coarLpAmount > 0,"coar no Lp");
                _lpAmount = _pledge.coarLpAmount;
                _feeAccount = coarFeeAccount;
                _pledge.coarLpAmount = 0;
            }
            (uint256 _amountA, uint256 _amountB) =  removeLiquidity(_pair,_token.tokenAddress,usdtAddress,_lpAmount, address(this));
        
            (address _token0, address _token1) = getTokenSort(_pair,_token.sort);
            
            uint256 _amountAFee = calculateFee(_amountA,removeFee);
            IERC20(_token0).transfer(_feeAccount,_amountAFee);
            _amountA = _amountA.sub(_amountAFee);
            IERC20(_token0).transfer(_msgSender(),_amountA);
            
            uint256 _amountBFee = calculateFee(_amountB,removeFee);
            IERC20(_token1).transfer(_feeAccount,_amountBFee);
            _amountB = _amountB.sub(_amountBFee);
            IERC20(_token1).transfer(_msgSender(),_amountB);

            emit RemoveLP(_msgSender(), block.timestamp);
        }
        function removeLiquidity(address _pair,address _tokenAddress,address _usdtAddress, uint256 _liquidity,address _to) private returns (uint,uint){
            IERC20(_pair).approve(address(uniswapV2Router),_liquidity);
            return uniswapV2Router.removeLiquidity(_tokenAddress, _usdtAddress, _liquidity, 0, 0, _to, block.timestamp + 10);
        }
        
        function getTokenSort(address _pair,bool _sort) internal view returns (address _token0, address _token1) {
            _token0 = IUniswapV2Pair(_pair).token0();
            _token1 = IUniswapV2Pair(_pair).token1();
            if(_sort){
                address _temp = _token0;
                _token0 = _token1;
                _token1 = _temp;
            }
        }

        function extractReward(uint256 _tokenId) external {
            Token memory _token = tokens[_tokenId];
            (uint256 _wtoAmount,uint256 _coarAmount) = getCanClaimed(_msgSender());
            PledgeInfo storage _pledge = userPledge[_msgSender()];
            uint256 _canReward;
            if(_tokenId == wtoTokenId){
                _canReward = _wtoAmount;
                _pledge.wtoRewardTime = block.timestamp;
            }
            if(_tokenId == coarTokenId){
                _canReward = _coarAmount;
                _pledge.coarRewardTime = block.timestamp;
            }
            rewardPool.claimToken(_token.tokenAddress,_canReward,_msgSender());           
            rewardParent(_tokenId,_token.tokenAddress,_canReward,_msgSender());
            emit ReceiveRewird(_msgSender(),_token.tokenAddress,_canReward,block.timestamp);
        }

        
        function rewardParent(uint256 _tokenId, address _tokenAddress,uint256 _canReward,address _user) private {
            address[] memory _parents = getParents(_user);
            for(uint256 i = 0;i < _parents.length;i++){
                if(_parents[i] == address(0)) break;
                if(levelFee[i] == uint256(0)) break;
                uint256 _reward = calculateFee(_canReward,levelFee[i]);
                rewardPool.claimToken(_tokenAddress,_reward,_parents[i]);
                Invite storage _parent = inviteInfos[_parents[i]];
                _tokenId == wtoTokenId ? _parent.wtoAmount += _reward : _parent.coarAmount += _reward;
            }
        }

        
        function getCanClaimed(address _user) public view returns(uint256 _wtoAmount,uint256 _coarAmount) {
            PledgeInfo memory _pledge = userPledge[_user];
            Token memory _wtoToken = tokens[wtoTokenId];
            Token memory _coarToken = tokens[coarTokenId];
            if(_pledge.wtoLpAmount > 0) {
                (uint256 _removeUsdt,) = getRemoveTokens(_wtoToken.pair,usdtAddress,_wtoToken.tokenAddress,_pledge.wtoLpAmount);
                uint256 _valueU = _removeUsdt.mul(2);
                uint256 _rewardTime = block.timestamp.sub(_pledge.wtoRewardTime);
                (uint256 _secondWtoAmount,uint256 _secondCoarAmount) = getEachReward(_valueU,monthFee,_wtoToken.tokenAddress,_coarToken.tokenAddress,usdtAddress);
                _wtoAmount += _rewardTime.mul(_secondWtoAmount);
                _coarAmount += _rewardTime.mul(_secondCoarAmount);
            }

            if(_pledge.coarLpAmount > 0){
                (uint256 _removeUsdt,) = getRemoveTokens(_coarToken.pair,usdtAddress,_coarToken.tokenAddress,_pledge.coarLpAmount);
                uint256 _valueU = _removeUsdt.mul(2);
                
                uint256 _rewardTime = block.timestamp.sub(_pledge.coarRewardTime);
                (uint256 _secondWtoAmount,uint256 _secondCoarAmount) = getEachReward(_valueU,monthFee,_wtoToken.tokenAddress,_coarToken.tokenAddress,usdtAddress);
                _wtoAmount += _rewardTime.mul(_secondWtoAmount);
                _coarAmount += _rewardTime.mul(_secondCoarAmount);
            }     
        }

        
        function getEachReward(uint256 _valueU,uint256 _monthFee,address _wtoAddress,address _coarAddress,address _usdtAddress) public view returns(uint256,uint256){     
            uint256 _monthFeeAmount = calculateFee(_valueU,_monthFee);
            (,uint256 _outWtoAmount) = getAmountOut(_usdtAddress,_wtoAddress,_monthFeeAmount);
            (,uint256 _outCoarAmount) = getAmountOut(_usdtAddress,_coarAddress,_monthFeeAmount);
            uint256 _secondWtoAmount = _outWtoAmount / 30 days;
            uint256 _secondCoarAmount = _outCoarAmount / 30 days;
            return (_secondWtoAmount,_secondCoarAmount);
        }

        function getRemoveTokens(address _pair,address _usdtAddress,address _tokenAddress,uint256 _liquidity) private view returns(uint256 _removeUsdt,uint256 _removeToken){
            uint _usdtAmount = IERC20(_usdtAddress).balanceOf(_pair);
            uint _tokenAmount = IERC20(_tokenAddress).balanceOf(_pair);
            uint _totalSupply = IERC20(_pair).totalSupply();
            _removeUsdt = _liquidity.mul(_usdtAmount) / _totalSupply; 
            _removeToken = _liquidity.mul(_tokenAmount) / _totalSupply;
        }

        function getAmountOut(address _token0,address _token1,uint256 _amountIn) internal view returns(address[] memory,uint256) {
            address[] memory _path = new address[](2);
            _path[0] = _token0;
            _path[1] = _token1;
            if(IUniswapV2Factory(uniswapV2Router.factory()).getPair(_token0,_token1) == address(0)) return(_path,0);
            
            uint256[] memory _amountOut = uniswapV2Router.getAmountsOut(_amountIn,_path);
            uint256 _out = _amountOut[1];
            return(_path,_out);
        }  


        function addToken(address _tokenAddress,string memory _logo,bool _sort) public onlyOwner {
            IERC20 _ierc20 = IERC20(_tokenAddress);
            Token memory _tokenInfo = Token({
                tokenAddress:_tokenAddress,
                pair:IUniswapV2Factory(uniswapV2Router.factory()).getPair(usdtAddress,_tokenAddress),
                name:_ierc20.symbol(),
                logo:_logo,
                sort:_sort
            });
            tokens[++tokenIds] = _tokenInfo;
            _ierc20.approve(address(uniswapV2Router),~uint256(0));
        }

        function updateToken(uint256 _tokenId,address _tokenAddress,string memory _logo,bool _sort) public onlyOwner {
            IERC20 _ierc20 = IERC20(_tokenAddress);
            Token storage _tokenInfo = tokens[_tokenId]; 
            _tokenInfo.tokenAddress=_tokenAddress;
            _tokenInfo.pair = IUniswapV2Factory(uniswapV2Router.factory()).getPair(usdtAddress,_tokenAddress);
            _tokenInfo.name = _ierc20.symbol();
            _tokenInfo.logo = _logo;
            _tokenInfo.sort = _sort;
            _ierc20.approve(address(uniswapV2Router),~uint256(0));
        }
        function setTokenSort(uint256 _tokenId,bool _sort) external onlyOwner {
            Token storage _tokenInfo = tokens[_tokenId]; 
            _tokenInfo.sort = _sort;
        }
        function calculateFee(uint256 _amount,uint256 _fee) internal pure returns(uint256){
            return _amount.mul(_fee).div(10**2);
        }

        function claimToken(address token, uint256 amount, address to) external onlyOwner {
            IERC20(token).transfer(to, amount);
        }
        
        function setFee(uint256 _monthFee,uint256 _removeFee) public onlyOwner {
            monthFee = _monthFee;
            removeFee = _removeFee;
        }

        function setAccount(address _wto,address _coar) public onlyOwner {
            wtoFeeAccount = _wto;
            coarFeeAccount = _coar;
        }

        function addLevel(uint256[] memory _fee) public onlyOwner {
            for(uint256 i = 0;i < _fee.length;i++){
                levelFee.push(_fee[i]);
            }
        }

        function updateLevel(uint256[] memory _fee) public onlyOwner {
            for(uint256 i = 0;i < _fee.length;i++){
                levelFee[i] = _fee[i];
            }
        }

        function setBind(address[] memory _users,address[] memory _parents) external onlyOwner{
            for(uint256 i = 0;i < _users.length;i++){
                inviteBind[_users[i]] = _parents[i];
            }
        }

        function setPledgeData(address _user,PledgeInfo memory _data) external onlyOwner {
            PledgeInfo storage _pledge = userPledge[_user];
            _pledge.wtoLpAmount = _data.wtoLpAmount; 
            _pledge.coarLpAmount = _data.coarLpAmount;
            _pledge.depositTime = _data.depositTime;
            _pledge.wtoLpBackTime = _data.wtoLpBackTime;
            _pledge.coarLpBackTime = _data.coarLpBackTime;
            _pledge.wtoRewardTime = _data.wtoRewardTime;
            _pledge.coarRewardTime = _data.coarRewardTime;
        }

        function setInviteData(address _user,Invite memory _data) external onlyOwner {
            Invite storage _parent = inviteInfos[_user];
            _parent.num = _data.num;
            _parent.wtoAmount = _data.wtoAmount;
            _parent.coarAmount = _data.coarAmount;
        }
    
        function setMustBind(bool _val) public onlyOwner {
            mustBind = _val;
        }

        
}