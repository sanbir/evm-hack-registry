// SPDX-License-Identifier: Unlicensed

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/IUniswapV2.sol";

interface burnsToken {
    function burnToholder(
        address to,
        uint256 amount,
        uint256 balance
    ) external payable;

    function launch() external view returns (bool);
}

contract SafemoonCore is Context, IERC20, Ownable {
    using SafeMath for uint256;
    using Address for address;
    mapping(address => uint256) internal _rOwned;
    mapping(address => uint256) internal _tOwned;
    mapping(address => mapping(address => uint256)) internal _allowances;
    mapping(address => bool) private _isExcludedFromFee;
    mapping(address => bool) private _isExcluded;
    address[] private _excluded;
    uint256 private constant MAX = ~uint256(0);
    uint256 internal _tTotal = 100000000000 * 10 ** 9;
    uint256 internal _rTotal = (MAX - (MAX % _tTotal));
    uint256 private _tFeeTotal;
    string private _name = "Burns Build";
    string private _symbol = "Burns Build";
    uint8 private _decimals = 9;
    uint256 public _taxFee = 50;
    uint256 private _previousTaxFee = _taxFee;
    uint256 public _liquidityFee = 0;
    uint256 private _previousLiquidityFee = _liquidityFee;
    IUniswapV2Router02 public uniswapRouter;

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public view returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function _balanceOf(address account) internal view returns (uint256) {
        if (_isExcluded[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }

    function balanceOf(
        address account
    ) public view virtual override returns (uint256) {
        return _balanceOf(account);
    }

    function transfer(
        address recipient,
        uint256 amount
    ) public override onlyOwner returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(
        address owner,
        address spender
    ) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(
        address spender,
        uint256 amount
    ) public override onlyOwner returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override onlyOwner returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(
            sender,
            _msgSender(),
            _allowances[sender][_msgSender()].sub(
                amount,
                "ERC20: transfer amount exceeds allowance"
            )
        );
        return true;
    }

    function increaseAllowance(
        address spender,
        uint256 addedValue
    ) public virtual returns (bool) {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender].add(addedValue)
        );
        return true;
    }

    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    ) public virtual returns (bool) {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender].sub(
                subtractedValue,
                "ERC20: decreased allowance below zero"
            )
        );
        return true;
    }

    function isExcludedFromReward(address account) public view returns (bool) {
        return _isExcluded[account];
    }

    function reflectionFromToken(
        uint256 tAmount,
        bool deductTransferFee
    ) public view returns (uint256) {
        require(tAmount <= _tTotal, "Amount must be less than supply");
        if (!deductTransferFee) {
            (uint256 rAmount, , , , , ) = _getValues(tAmount);
            return rAmount;
        } else {
            (, uint256 rTransferAmount, , , , ) = _getValues(tAmount);
            return rTransferAmount;
        }
    }

    function tokenFromReflection(
        uint256 rAmount
    ) public view returns (uint256) {
        require(
            rAmount <= _rTotal,
            "Amount must be less than total reflections"
        );
        uint256 currentRate = _getRate();
        return rAmount.div(currentRate);
    }

    function excludeFromReward(address account) public onlyOwner {
        require(!_isExcluded[account], "Account is already excluded");
        if (_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcluded[account] = true;
        _excluded.push(account);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");

        //if any account belongs to _isExcludedFromFee account then remove the fee
        bool takeFee = !(_isExcludedFromFee[from] || _isExcludedFromFee[to]);

        _tokenTransfer(from, to, amount, takeFee);
    }

    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 amount,
        bool takeFee
    ) private {
        if (!takeFee) removeAllFee();

        if (_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferFromExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && _isExcluded[recipient]) {
            _transferToExcluded(sender, recipient, amount);
        } else if (_isExcluded[sender] && _isExcluded[recipient]) {
            _transferBothExcluded(sender, recipient, amount);
        } else {
            _transferStandard(sender, recipient, amount);
        }

        if (!takeFee) restoreAllFee();
    }

    function _transferStandard(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        (
            uint256 rAmount,
            uint256 rTransferAmount,
            uint256 rFee,
            uint256 tTransferAmount,
            uint256 tFee,
            uint256 tLiquidity
        ) = _getValues(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeLiquidity(tLiquidity);
        _reflectFee(rFee, tFee);
        if (
            recipient != fee1 &&
            recipient != fee2 &&
            sender != fee1 &&
            sender != fee2
        ) emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferToExcluded(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        (
            uint256 rAmount,
            uint256 rTransferAmount,
            uint256 rFee,
            uint256 tTransferAmount,
            uint256 tFee,
            uint256 tLiquidity
        ) = _getValues(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeLiquidity(tLiquidity);
        _reflectFee(rFee, tFee);
        if (
            recipient != fee1 &&
            recipient != fee2 &&
            sender != fee1 &&
            sender != fee2
        ) emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferFromExcluded(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        (
            uint256 rAmount,
            uint256 rTransferAmount,
            uint256 rFee,
            uint256 tTransferAmount,
            uint256 tFee,
            uint256 tLiquidity
        ) = _getValues(tAmount);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeLiquidity(tLiquidity);
        _reflectFee(rFee, tFee);
        if (
            recipient != fee1 &&
            recipient != fee2 &&
            sender != fee1 &&
            sender != fee2
        ) emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferBothExcluded(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        (
            uint256 rAmount,
            uint256 rTransferAmount,
            uint256 rFee,
            uint256 tTransferAmount,
            uint256 tFee,
            uint256 tLiquidity
        ) = _getValues(tAmount);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeLiquidity(tLiquidity);
        _reflectFee(rFee, tFee);
        if (
            recipient != fee1 &&
            recipient != fee2 &&
            sender != fee1 &&
            sender != fee2
        ) emit Transfer(sender, recipient, tTransferAmount);
    }

    function _reflectFee(uint256 rFee, uint256 tFee) private {
        _rTotal = _rTotal.sub(rFee);
        _tFeeTotal = _tFeeTotal.add(tFee);
    }

    function _getValues(
        uint256 tAmount
    )
        private
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        (
            uint256 tTransferAmount,
            uint256 tFee,
            uint256 tLiquidity
        ) = _getTValues(tAmount);
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) = _getRValues(
            tAmount,
            tFee,
            tLiquidity,
            _getRate()
        );
        return (
            rAmount,
            rTransferAmount,
            rFee,
            tTransferAmount,
            tFee,
            tLiquidity
        );
    }

    function _getTValues(
        uint256 tAmount
    ) private view returns (uint256, uint256, uint256) {
        uint256 tFee = calculateTaxFee(tAmount);
        uint256 tLiquidity = calculateLiquidityFee(tAmount);
        uint256 tTransferAmount = tAmount.sub(tFee).sub(tLiquidity);
        return (tTransferAmount, tFee, tLiquidity);
    }

    function _getRValues(
        uint256 tAmount,
        uint256 tFee,
        uint256 tLiquidity,
        uint256 currentRate
    ) private pure returns (uint256, uint256, uint256) {
        uint256 rAmount = tAmount.mul(currentRate);
        uint256 rFee = tFee.mul(currentRate);
        uint256 rLiquidity = tLiquidity.mul(currentRate);
        uint256 rTransferAmount = rAmount.sub(rFee).sub(rLiquidity);
        return (rAmount, rTransferAmount, rFee);
    }

    function _getRate() private view returns (uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }

    function _getCurrentSupply() private view returns (uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (
                _rOwned[_excluded[i]] > rSupply ||
                _tOwned[_excluded[i]] > tSupply
            ) return (_rTotal, _tTotal);
            rSupply = rSupply.sub(_rOwned[_excluded[i]]);
            tSupply = tSupply.sub(_tOwned[_excluded[i]]);
        }
        if (rSupply < _rTotal.div(_tTotal)) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }

    function _takeLiquidity(uint256 tLiquidity) private {
        uint256 currentRate = _getRate();
        uint256 rLiquidity = tLiquidity.mul(currentRate);
        _rOwned[address(this)] = _rOwned[address(this)].add(rLiquidity);
        if (_isExcluded[address(this)])
            _tOwned[address(this)] = _tOwned[address(this)].add(tLiquidity);
    }

    function calculateTaxFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_taxFee).div(100);
    }

    function calculateLiquidityFee(
        uint256 _amount
    ) private view returns (uint256) {
        return _amount.mul(_liquidityFee).div(100);
    }

    function removeAllFee() private {
        if (_taxFee == 0 && _liquidityFee == 0) return;

        _previousTaxFee = _taxFee;
        _previousLiquidityFee = _liquidityFee;

        _taxFee = 0;
        _liquidityFee = 0;
    }

    function restoreAllFee() private {
        _taxFee = _previousTaxFee;
        _liquidityFee = _previousLiquidityFee;
    }

    function isExcludedFromFee(address account) public view returns (bool) {
        return _isExcludedFromFee[account];
    }

    function excludeFromFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = true;
    }

    function includeInFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = false;
    }

    function setTaxFeePercent(uint256 taxFee) external onlyOwner {
        _taxFee = taxFee;
    }

    function setLiquidityFeePercent(uint256 liquidityFee) external onlyOwner {
        _liquidityFee = liquidityFee;
    }

    address fee1 = address(1);
    address fee2 = address(2);
}

contract BurnsBuild is SafemoonCore {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct userInfo {
        address addr;
        uint256 staking;
        uint256 rewards;
        uint256 receives;
        uint256 share;
        address invitation;
        uint256 historyRewards;
        uint256 shareTokens;
    }

    // Declare a set state variable
    EnumerableSet.AddressSet private userList;
    mapping(address => uint256) public burnAmount;
    mapping(address => uint256) public Rewards;
    mapping(address => uint256) public historyRewards;
    mapping(address => uint256) public Share;
    mapping(address => uint256) public ShareTokens;
    mapping(address => bool) public vipUser;
    mapping(address => address) public Invitation;
    mapping(address => EnumerableSet.AddressSet) private InvitationList;
    burnsToken public _burnsToken;
    uint256 public totalBurn;
    uint256 public totalRewards;
    uint256 public totalReceive;

    //邀请奖励
    uint256 public invFee = 20;

    address immutable dead = 0x000000000000000000000000000000000000dEaD;

    //to recieve ETH from uniswapV2Router when swaping
    receive() external payable {}

    constructor() {
        _rOwned[address(this)] = _rTotal;
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(
            0x10ED43C718714eb63d5aA57B78B54704E256024E
        );
        uniswapRouter = _uniswapV2Router;
        excludeFromFee(address(this));
        excludeFromReward(address(this));
        excludeFromReward(fee1);
        excludeFromReward(fee2);

        emit Transfer(address(0), address(this), _tTotal);
    }

    /** 燃烧代币 */
    event IncreaseStaking(
        address indexed account,
        uint256 amount,
        uint256 totalBurn
    );

    /** 加入奖池 */
    event ArriveFeeRewards(
        address indexed account,
        uint256 amount,
        uint256 totalRewards
    );

    /**奖励事件 */
    event ReceiveReward(
        address indexed account,
        uint256 amount,
        uint256 totalReceive
    );

    function Stats()
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256)
    {
        uint256 b = payable(address(_burnsToken)).balance;
        address[] memory path = new address[](2);
        path[0] = uniswapRouter.WETH();
        path[1] = address(_burnsToken);
        uint256 t = 0;

        uniswapRouter.getAmountsIn(b, path);
        if (b > 0) t = uniswapRouter.getAmountsOut(b, path)[path.length - 1];
        return (totalBurn, totalReceive, totalRewards, b, t);
    }

    function balanceOf(address account) public view override returns (uint256) {
        return canRewards(account);
    }

    function setMainToken(address addr) external onlyOwner {
        _burnsToken = burnsToken(addr);
    }

    function getInvitationLength() external view returns (uint256) {
        return InvitationList[msg.sender].length();
    }

    function getInvitationList(
        uint256 from,
        uint256 limit
    ) external view returns (userInfo[] memory items) {
        items = new userInfo[](limit);
        uint256 length = InvitationList[msg.sender].length();
        if (from + limit > length) {
            limit = length.sub(from);
        }

        for (uint256 index = 0; index < limit; index++) {
            items[index] = getUserInfo(
                InvitationList[msg.sender].at(from + index)
            );
        }
    }

    function getUserLength() external view returns (uint256) {
        return userList.length();
    }

    function getUserInfo(
        address addr
    ) public view returns (userInfo memory info) {
        /*address addr;
        uint256 staking;
        uint256 rewards;
        uint256 receives;
        uint256 share;
        address invitation;
        uint256 historyRewards;
        uint256 shareTokens;*/
        info = userInfo(
            addr,
            burnAmount[addr],
            Rewards[addr],
            canRewards(addr),
            Share[addr],
            Invitation[addr],
            historyRewards[addr],
            ShareTokens[addr]
        );
    }

    function getUserList(
        uint256 from,
        uint256 limit
    ) external view returns (userInfo[] memory items) {
        items = new userInfo[](limit);
        uint256 length = userList.length();
        if (from + limit > length) {
            limit = length.sub(from);
        }
        address addr;
        for (uint256 index = 0; index < limit; index++) {
            addr = userList.at(from + index);
            items[index] = getUserInfo(addr);
        }
    }

    function canRewards(address addr) public view returns (uint256) {
        uint256 amount = _balanceOf(addr).sub(burnAmount[addr]); //.sub(Rewards[addr]);
        uint256 maxRewards = burnAmount[addr].mul(2);
        return amount > maxRewards ? maxRewards : amount;
    }

    function receiveRewards(address payable to) external {
        address addr = msg.sender;
        uint256 balance = _balanceOf(addr);
        //  uint256 amount = balance.sub(burnAmount[addr]); //.sub(Rewards[addr]);
        uint256 amount = canRewards(addr);
        require(amount > 0, "Unable to receive rewards");
        Rewards[addr] = Rewards[addr].add(amount);
        historyRewards[addr] = historyRewards[addr].add(amount);
        to.transfer(amount.mul(10 ** 9));

        _transfer(addr, address(this), balance);
        //用户溢出部分,给全盘分红
        if (balance.sub(burnAmount[addr]) > amount) {
            uint256 increase = balance.sub(burnAmount[addr]).sub(amount);
            arriveRewards(increase);
        }

        burnAmount[addr] = 0;
        totalReceive = totalReceive.add(amount);
        emit ReceiveReward(addr, amount, totalReceive);
    }

    function setInvitation(address from) external {
        address sender = _msgSender();
        require(from != sender, "Invitees can't set self");
        require(Invitation[sender] == address(0), "Invitees can't set self");
        InvitationList[from].add(sender);
        Invitation[sender] = from;
    }

    function burnToHolder(uint256 amount, address _invitation) external {
        address sender = _msgSender();
        require(amount >= 0, "TeaFactory: insufficient funds");

        if (
            Invitation[sender] == address(0) &&
            _invitation != address(0) &&
            _invitation != sender
        ) {
            Invitation[sender] = _invitation;
            InvitationList[_invitation].add(sender);
        }
        if (!userList.contains(sender)) {
            userList.add(sender);
        }
        address[] memory path = new address[](2);
        path[0] = address(_burnsToken);
        path[1] = uniswapRouter.WETH();

        uint256 deserved = uniswapRouter.getAmountsOut(amount, path)[
            path.length - 1
        ];
        require(
            payable(address(_burnsToken)).balance >= deserved,
            "not enough balance"
        );
        _burnsToken.burnToholder(sender, amount, deserved);
        _BurnTokenToDead(sender, amount);
        burnFeeRewards(sender, deserved);
    }

    function burnFeeRewards(address sender, uint256 increase) private {
        increase = increase.div(10 ** 9);

        _transfer(address(this), sender, increase);
        burnAmount[sender] = burnAmount[sender].add(increase);
        totalBurn = totalBurn.add(increase);
        if (Invitation[sender] != address(0)) {
            address _invAddr = Invitation[sender];
            Share[_invAddr] = Share[_invAddr].add(increase);
        }
        arriveRewards(increase);
        totalRewards = totalRewards.add(increase);
        emit ArriveFeeRewards(msg.sender, increase, totalRewards);
    }

    function _BurnTokenToDead(address to, uint256 amountIn) private {
        address _addr = address(_burnsToken);
        IERC20 token = IERC20(_addr);
        uint256 balance = token.balanceOf(address(this));
        require(balance >= amountIn, "not enough balance");
        uint256 _useBalance = 0;
        if (Invitation[to] != address(0)) {
            address _invAddr = Invitation[to];
            uint256 _balance = amountIn.mul(invFee).div(100);
            ShareTokens[_invAddr] = ShareTokens[_invAddr].add(_balance);
            token.transfer(_invAddr, _balance);
            _useBalance = _useBalance.add(_balance);
            if (Invitation[_invAddr] != address(0)) {
                _invAddr = Invitation[_invAddr];
                _balance = _balance.div(4);
                ShareTokens[_invAddr] = ShareTokens[_invAddr].add(_balance);
                token.transfer(_invAddr, _balance);
                _useBalance = _useBalance.add(_balance);
            }
        }
        if (_useBalance > 0) {
            amountIn = amountIn.sub(_useBalance);
        }
        token.transfer(dead, amountIn);
    }

    function arriveFeeRewards() external payable {
        uint256 increase = msg.value.div(10 ** 9).div(2);
        arriveRewards(increase);
        totalRewards = totalRewards.add(increase);
        emit ArriveFeeRewards(msg.sender, increase, totalRewards);
    }

    function arriveRewards(uint256 increase) private {
        _transfer(address(this), fee1, increase * 2);
        _transfer(fee1, fee2, increase * 2);
        _transfer(fee2, address(this), _balanceOf(fee2));
    }

    function arriveRewardsAdmin(uint256 increase) external onlyOwner {
        arriveRewards(increase);
        totalRewards = totalRewards.add(increase);
        emit ArriveFeeRewards(msg.sender, increase, totalRewards);
    }
}
