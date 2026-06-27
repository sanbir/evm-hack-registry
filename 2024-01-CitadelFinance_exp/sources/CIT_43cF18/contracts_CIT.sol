//  _____  _  _              _        _ 
// /  __ \(_)| |            | |      | |
// | /  \/ _ | |_  __ _   __| |  ___ | |
// | |    | || __|/ _` | / _` | / _ \| |
// | \__/\| || |_| (_| || (_| ||  __/| |
//  \____/|_| \__|\__,_| \__,_| \___||_|
                                     
// TG: https://t.me/Citadel_Finance
// Twitter: https://twitter.com/Citadel_Finance
// Website: https://www.citadelfinance.xyz/home
// Documentation: https://t.co/jdlEwHQLD3

// SPDX-License-Identifier: MIT

pragma solidity >=0.8.20;

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

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "./interfaces/ICamelotRouter.sol";
import "./interfaces/ICamelotFactory.sol";

contract CIT is Context, ERC20, Ownable {
    //----------------------VARIABLES----------------------//

    using SafeMath for uint256;

    mapping(address => bool) private _isExcludedFromFee;

    address public treasury;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; //0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    address public bCIT;
    address public CITStaking;
    address public CITRedeem;

    uint256 private _initialBuyTax = 40;
    uint256 private _initialSellTax = 40;
    uint256 public _finalBuyTax = 2;
    uint256 public _finalSellTax = 15;

    uint256 private _blockAtLaunch;
    uint256 private _blockRemoveLimits = 4; 

    uint8 private constant _decimals = 18;
    uint256 private _tTotal = 100_000 * 10 ** _decimals;
    uint256 private _maxWalletSize = (_tTotal * 50) / 10000; // 0.5% of total supply
    uint256 private _maxLittleWalletSize = (_tTotal * 20) / 10000; // 0.2% of total supply
    uint256 private swapThreshold = (_tTotal * 50) / 10000; // 0.5% of total supply

    ICamelotRouter private router;
    address public pair;
    bool private initialized = false;
    bool public tradingOpen = false;
    bool private inSwap = false;
    bool private swapEnabled = false;

    modifier lockTheSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }

    //----------------------CONSTRUCTOR----------------------//

    constructor(
        address initialOwner,
        address _treasury,
        address _bCIT,
        address _CITStaking,
        address _CITRedeem
    ) ERC20("Citadel", "CIT") Ownable(initialOwner) {
        router = ICamelotRouter(0xc873fEcbd354f5A56E00E710B90EF4201db2448d); // Camelot Arbitrum One 0xc873fEcbd354f5A56E00E710B90EF4201db2448d

        treasury = _treasury;
        bCIT = _bCIT;
        CITStaking = _CITStaking;
        CITRedeem = _CITRedeem;

        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[address(this)] = true;
        _isExcludedFromFee[_treasury] = true;
        _isExcludedFromFee[_bCIT] = true;
        _isExcludedFromFee[_CITStaking] = true;

        _mint(msg.sender, _tTotal);

        emit Transfer(address(0), _msgSender(), _tTotal);
    }

    function initializePair() external onlyOwner {
        require(!initialized, "Already initialized");
        pair = ICamelotFactory(0x6EcCab422D763aC031210895C81787E87B43A652) // 0x6EcCab422D763aC031210895C81787E87B43A652
            .createPair(address(this), WETH);
        initialized = true;
    }

    function setPair(address _pair) external onlyOwner {
        pair = _pair;
    }

    function setIsInitialized(bool _initialized) external onlyOwner {
        initialized = _initialized;
    }

    function rescueTokens(address token, uint256 amount) external onlyOwner {
        require(token != address(this), "Can't withdraw this token");
        IERC20(token).transfer(msg.sender, amount);
    }

    function rescueETH(uint256 amount) external onlyOwner {
        bool tmpSuccess;
            (tmpSuccess, ) = payable(msg.sender).call{
                value: amount,
                gas: 5000000
            }("");
    }

    // Launch limits functions

    /** @dev Remove wallet cap.
     * @notice Can only be called by the current owner.
     */
    function removeLimits() external onlyOwner {
        _maxWalletSize = 1_000_000 * 10 ** _decimals;
    }

    /** @dev Enable trading.
     * @notice Can only be called by the current owner.
     * @notice Can only be called once.
     */
    function openTrading() external onlyOwner {
        require(!tradingOpen, "trading is already open");
        swapEnabled = true;
        tradingOpen = true;
        _blockAtLaunch = block.number;
    }

    // Transfer functions

    function transfer(
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        require(initialized || msg.sender == owner(), "Not yet initialized");
        if (msg.sender == pair) {
            return update(msg.sender, recipient, amount);
        } else {
            return _basicTransfer(msg.sender, recipient, amount);
        }
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(sender, spender, amount);
        update(sender, recipient, amount);

        return true;
    }

    function update(
        address sender,
        address recipient,
        uint256 amount
    ) internal returns (bool) {
        require(
            _isExcludedFromFee[sender] ||
                _isExcludedFromFee[recipient] ||
                tradingOpen,
            "Not authorized to trade yet"
        );

        uint256 blockSinceLaunch = block.number - _blockAtLaunch;
        uint256 _limit = _maxWalletSize;

        // Checks max transaction limit
        if (sender != owner() && recipient != owner() && recipient != DEAD) {
            if (recipient != pair) {
                if (blockSinceLaunch <= _blockRemoveLimits) {
                    _limit = _maxLittleWalletSize;
                } else if (
                    blockSinceLaunch > _blockRemoveLimits && _blockAtLaunch != 0
                ) {
                    _limit = _maxWalletSize;
                }
                require(
                    _isExcludedFromFee[recipient] ||
                        (balanceOf(recipient) + amount <= _limit),
                    "Transfer amount exceeds the MaxWallet size."
                );
            }
        }

        //shouldSwapBack
        if (shouldSwapBack() && recipient == pair) {
            swapBack();
        }

        //Check if should Take Fee
        uint256 amountReceived = (!shouldTakeFee(sender) ||
            !shouldTakeFee(recipient))
            ? amount
            : takeFee(sender, recipient, amount);

        _transfer(sender, recipient, amountReceived);

        return true;
    }

    function _basicTransfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal returns (bool) {
        _transfer(sender, recipient, amount);
        return true;
    }

    function shouldTakeFee(address sender) internal view returns (bool) {
        return !_isExcludedFromFee[sender];
    }

    function takeFee(
        address sender,
        address recipient,
        uint256 amount
    ) internal returns (uint256) {
        uint256 feeAmount = 0;
        uint256 blockSinceLaunch = block.number - _blockAtLaunch;
        uint256 tax;

        if (blockSinceLaunch >= _blockRemoveLimits) {
            if (sender == pair && recipient != pair) {
                tax = _finalBuyTax;
            } else if (sender != pair && recipient == pair) {
                tax = _finalSellTax;
            }
        } else {
            if (sender == pair && recipient != pair) {
                tax = _initialBuyTax;
            } else if (sender != pair && recipient == pair) {
                tax = _initialSellTax;
            }
        }

        feeAmount = (amount * tax) / 100;

        if (feeAmount > 0) {
            _transfer(sender, address(this), feeAmount);
        }

        return amount - feeAmount;
    }

    function shouldSwapBack() internal view returns (bool) {
        return
            msg.sender != pair &&
            !inSwap &&
            swapEnabled &&
            balanceOf(address(this)) >= swapThreshold;
    }

    function swapBack() internal lockTheSwap {
        uint256 amountToSwap = swapThreshold;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();
        _approve(address(this), address(router), amountToSwap);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            path,
            address(this),
            address(0),
            block.timestamp + 5
        );

        uint256 amountETHDev = address(this).balance;

        if (amountETHDev > 0) {
            bool tmpSuccess;
            (tmpSuccess, ) = payable(treasury).call{
                value: amountETHDev,
                gas: 5000000
            }("");
        }
    }

    // Threshold management functions

    /** @dev Set a new threshold to trigger swapBack.
     * @notice Can only be called by the current owner.
     */
    function setSwapThreshold(uint256 newTax) external onlyOwner {
        swapThreshold = newTax;
    }

    // Minting function for bonding convertion

    function mint(address to, uint256 value) external {
        require(
            msg.sender == bCIT || msg.sender == CITStaking,
            "Not authorized"
        );
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        require(msg.sender == CITRedeem, "Not authorized");
        _burn(from, value);
    }

    // Internal functions

    receive() external payable {}

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return (a > b) ? b : a;
    }

    function isContract(address account) private view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }
}
