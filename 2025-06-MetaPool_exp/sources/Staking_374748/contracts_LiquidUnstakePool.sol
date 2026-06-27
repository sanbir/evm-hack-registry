// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./Staking.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract LiquidUnstakePool is
    Initializable,
    ERC4626Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using AddressUpgradeable for address payable;
    using SafeMathUpgradeable for uint;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    address public treasury;
    address payable public STAKING;
    uint256 public ethBalance;
    uint256 public targetLiquidity;
    uint256 public minETHPercentage;
    uint64 public constant MIN_DEPOSIT = 0.01 ether;
    uint16 public constant MIN_FEE = 30;
    uint16 public constant MAX_FEE = 500;
    uint16 public minFee;
    uint16 public maxFee;
    uint16 public treasuryFee;

    event AddLiquidity(
        address indexed user,
        address indexed receiver,
        uint256 amount,
        uint256 shares
    );
    event RemoveLiquidity(
        address indexed caller,
        address indexed owner,
        uint256 shares,
        uint256 eth,
        uint256 mpETH
    );
    event Swap(
        address indexed user,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fees,
        uint256 treasuryFees
    );
    event SendETHForValidator(uint256 timestamp, uint256 amount);

    error DepositTooLow(uint256 _minAmount, uint256 _amountSent);
    error NotAuthorized(address _caller, address _authorized);
    error SwapMinOut(uint256 _minOut, uint256 _amountOut);
    error RequestedETHReachMinProportion(uint256 _ethRequested, uint256 _availableETH);
    error SharesTooLow();
    error AssetsTooLow();
    error InvalidSwapFees();

    modifier onlyStaking() {
        if (msg.sender != STAKING) revert NotAuthorized(msg.sender, STAKING);
        _;
    }

    function _revertIfInvalidDeposit(uint256 _amount) private pure {
        if (_amount < MIN_DEPOSIT) revert DepositTooLow(MIN_DEPOSIT, _amount);
    }

    function initialize(
        address payable _staking,
        IERC20MetadataUpgradeable _weth,
        address _treasury
    ) external initializer {
        require(address(this).balance == 0, "Error initialize with no zero balance");
        require(_weth.decimals() == 18, "wNative token error, implementation for 18 decimals");
        __ERC4626_init(IERC20Upgradeable(_weth));
        __ERC20_init("MetaETHLP", "mpETH/ETH");
        __Ownable_init();
        __ReentrancyGuard_init();
        STAKING = _staking;
        treasury = _treasury;
        updateTargetLiquidity(30 ether);
        updateMinETHPercentage(5000);
    }

    /// @dev Needed to receive ETH from WETH deposits
    receive() external payable {}

    /// @notice Update targetLiquidity
    /// @dev Reserves value from which the swap mpETHForETH will apply fees
    function updateTargetLiquidity(uint256 _targetLiquidity) public onlyOwner {
        targetLiquidity = _targetLiquidity;
    }

    /// @notice Update minETHPercentage
    /// @dev Min ETH reserves percentage compared to mpETH reserves to allow Staking to request ETH for validators
    function updateMinETHPercentage(uint256 _minETHPercentage) public onlyOwner {
        minETHPercentage = _minETHPercentage;
    }

    /// @notice Update min and max fees
    /// @dev Min and max fees for swap mpETHForETH
    function updateSwapFees(uint16 _minFee, uint16 _maxFee, uint16 _treasuryFee) public onlyOwner {
        if (_minFee == 0 || _minFee >= _maxFee || _maxFee > 1000 || _treasuryFee > 7000)
            revert InvalidSwapFees();
        minFee = _minFee;
        maxFee = _maxFee;
        treasuryFee = _treasuryFee;
    }

    /// @notice Return the amount of ETH and mpETH equivalent to ETH in the pool
    function totalAssets() public view override returns (uint256) {
        return
            ethBalance +
            Staking(STAKING).convertToAssets(Staking(STAKING).balanceOf(address(this)));
    }

    /// @notice Add liquidity with WETH
    /// @dev Same function as in ERC4626 but removes maxDeposit check and add validDeposit modifier who checks for minDeposit
    function deposit(uint256 _assets, address _receiver) public override returns (uint256) {
        uint256 _shares = previewDeposit(_assets);
        _deposit(msg.sender, _receiver, _assets, _shares);
        return _shares;
    }

    /// @notice Add liquidity with ETH
    /// @dev Equivalent to deposit function but for native token. Sends assets 0 to _deposit to indicate that the assets amount will be msg.value
    function depositETH(address _receiver) external payable returns (uint256) {
        uint256 shares = previewDeposit(msg.value);
        _deposit(msg.sender, _receiver, 0, shares);
        return shares;
    }

    /// @notice Confirm ETH or WETH deposit
    /// @dev Use ETH or get and convert WETH to ETH
    function _deposit(
        address _caller,
        address _receiver,
        uint256 _assets,
        uint256 _shares
    ) internal virtual override nonReentrant {
        _assets = _getAssetsDeposit(_assets);
        _revertIfInvalidDeposit(_assets);
        _mint(_receiver, _shares);
        ethBalance += _assets;
        emit AddLiquidity(_caller, _receiver, _assets, _shares);
    }

    /// @dev Convert WETH to ETH if the deposit is in WETH. Receive _assets as 0 if deposit is in ETH
    /// @return Amount of assets received
    function _getAssetsDeposit(uint256 _assets) private returns (uint256) {
        if (_assets == 0) {
            // ETH deposit
            _assets = msg.value;
        } else {
            // WETH deposit. Get WETH and convert to ETH
            IERC20Upgradeable(asset()).safeTransferFrom(msg.sender, address(this), _assets);
            IWETH(asset()).withdraw(_assets);
        }
        return _assets;
    }

    /// @dev Override to return ETH and mpETH
    /// @param _assets ETH to withdraw as ETH plus mpETH converted to ETH
    function withdraw(
        uint256 _assets,
        address _receiver,
        address _owner
    ) public override returns (uint256 shares) {
        shares = previewWithdraw(_assets);
        if (msg.sender != _owner) _spendAllowance(_owner, msg.sender, shares);
        uint256 poolPercentage = (_assets * 1 ether) / totalAssets();
        if (poolPercentage == 0) revert AssetsTooLow();
        uint256 ETHToSend = (poolPercentage * ethBalance) / 1 ether;
        uint256 mpETHToSend = (poolPercentage * Staking(STAKING).balanceOf(address(this))) /
            1 ether;
        _burn(_owner, shares);
        ethBalance -= ETHToSend;
        IERC20Upgradeable(STAKING).safeTransfer(_receiver, mpETHToSend);
        payable(_receiver).sendValue(ETHToSend);
        emit RemoveLiquidity(msg.sender, _owner, shares, ETHToSend, mpETHToSend);
        emit Withdraw(msg.sender, _receiver, _owner, ETHToSend, shares);
    }

    /// @dev Overrided to return ETH and mpETH for shares
    /// @return ETHToSend ETH sent to user. Don't includes mpETH sent
    function redeem(
        uint256 _shares,
        address _receiver,
        address _owner
    ) public override nonReentrant returns (uint256 ETHToSend) {
        if (msg.sender != _owner) _spendAllowance(_owner, msg.sender, _shares);
        uint256 poolPercentage = (_shares * 1 ether) / totalSupply();
        if (poolPercentage == 0) revert SharesTooLow();
        ETHToSend = (poolPercentage * ethBalance) / 1 ether;
        uint256 mpETHToSend = (poolPercentage * Staking(STAKING).balanceOf(address(this))) /
            1 ether;
        _burn(_owner, _shares);
        ethBalance -= ETHToSend;
        IERC20Upgradeable(STAKING).safeTransfer(_receiver, mpETHToSend);
        payable(_receiver).sendValue(ETHToSend);
        emit RemoveLiquidity(msg.sender, _owner, _shares, ETHToSend, mpETHToSend);
        emit Withdraw(msg.sender, _receiver, _owner, ETHToSend, _shares);
    }

    /// @notice Swap mpETH for ETH
    /// @dev Send ETH to user and take some mpETH as fee for treasury and pool (liquidity providers)
    function swapmpETHforETH(
        uint256 _amount,
        uint256 _minOut
    ) external nonReentrant returns (uint256) {
        address payable staking = STAKING;
        (uint256 amountOut, uint256 feeAmount) = getAmountOut(_amount);
        if (amountOut < _minOut) revert SwapMinOut(_minOut, amountOut);
        uint256 feeToTreasury = (feeAmount * treasuryFee) / 10000;
        ethBalance -= amountOut;
        IERC20Upgradeable(staking).safeTransferFrom(msg.sender, address(this), _amount);
        if (feeToTreasury != 0) IERC20Upgradeable(staking).safeTransfer(treasury, feeToTreasury);
        payable(msg.sender).sendValue(amountOut);
        emit Swap(msg.sender, _amount, amountOut, feeAmount, feeToTreasury);
        return amountOut;
    }

    /// @notice Return amountOut from swap and fee taken from _amountIn
    /// @param _amountIn mpETH amount to swap
    /// @return amountOut ETH amount out from swap
    /// @return feeAmount Total mpETH fee from _amountIn
    function getAmountOut(
        uint256 _amountIn
    ) public view returns (uint256 amountOut, uint256 feeAmount) {
        address payable staking = STAKING;
        uint16 feeRange = maxFee - minFee;
        amountOut = Staking(staking).convertToAssets(_amountIn);
        uint256 reservesAfterSwap = ethBalance.sub(amountOut, "Not enough ETH");
        uint256 finalFee = minFee;
        if (reservesAfterSwap < targetLiquidity) {
            uint256 proportionalBp = (feeRange * reservesAfterSwap) / targetLiquidity;
            finalFee = maxFee - proportionalBp;
        }
        feeAmount = (_amountIn * finalFee) / 10000;
        amountOut = Staking(staking).convertToAssets(_amountIn - feeAmount);
    }

    /// @notice Deposit ETH into Staking
    /// @dev Called from Staking to get ETH for validators
    /// @param _requestedETH Requested ETH amount
    function getEthForValidator(uint256 _requestedETH) external nonReentrant onlyStaking {
        uint256 availableETH = getAvailableEthForValidator();
        if (_requestedETH > availableETH)
            revert RequestedETHReachMinProportion(_requestedETH, availableETH);
        ethBalance -= _requestedETH;
        Staking(STAKING).depositETH{value: _requestedETH}(address(this));
        emit SendETHForValidator(block.timestamp, _requestedETH);
    }

    /// @notice Staking swap ETH for mpETH
    function swapETHFormpETH(
        address _to
    ) external payable nonReentrant onlyStaking returns (uint256) {
        address payable staking = STAKING;
        uint256 mpETHToSend = Staking(staking).previewDeposit(msg.value);
        IERC20Upgradeable(staking).safeTransfer(_to, mpETHToSend);
        ethBalance += msg.value;
        return mpETHToSend;
    }

    function getAvailableEthForValidator() public view returns (uint256 availableETH) {
        if (totalAssets() == 0) return 0;
        uint256 currentETHPercentage = (ethBalance * 10000) / totalAssets();
        if (currentETHPercentage <= minETHPercentage) return 0;
        availableETH = ((currentETHPercentage - minETHPercentage) * totalAssets()) / 10000;
    }
}
