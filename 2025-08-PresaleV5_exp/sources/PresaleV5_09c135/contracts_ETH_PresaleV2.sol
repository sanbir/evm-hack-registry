//SPDX-License-Identifier: MIT
//               _    _____                                        _
// __      _____| |__|___ / _ __   __ _ _   _ _ __ ___   ___ _ __ | |_ ___
// \ \ /\ / / _ \ '_ \ |_ \| '_ \ / _` | | | | '_ ` _ \ / _ \ '_ \| __/ __|
//  \ V  V /  __/ |_) |__) | |_) | (_| | |_| | | | | | |  __/ | | | |_\__ \
//   \_/\_/ \___|_.__/____/| .__/ \__,_|\__, |_| |_| |_|\___|_| |_|\__|___/
//                         |_|          |___/
//
pragma solidity 0.8.9;
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

interface Aggregator {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface StakingManager {
    function depositByPresale(address _user, uint256 _amount) external;
}

interface IPoolV3 {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

contract PresaleV5 is
    Initializable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable
{
    uint256 public totalTokensSold;
    uint256 public startTime;
    uint256 public endTime;
    uint256 public claimStart;
    address public saleToken;
    uint256 public baseDecimals;
    uint256 public maxTokensToBuy;
    uint256 public currentStep;
    uint256 public checkPoint;
    uint256 public usdRaised;
    uint256 public timeConstant;
    uint256 public totalBoughtAndStaked;
    uint256[][3] public rounds;
    uint256[] public prevCheckpoints;
    uint256[] public remainingTokensTracker;
    uint256[] public percentages;
    address[] public wallets;
    address public paymentWallet;
    address public admin;
    bool public dynamicTimeFlag;
    bool public whitelistClaimOnly;
    bool public stakeingWhitelistStatus;

    IERC20Upgradeable public USDTInterface;
    Aggregator public aggregatorInterface;
    mapping(address => uint256) public userDeposits;
    mapping(address => bool) public hasClaimed;
    mapping(address => bool) public isBlacklisted;
    mapping(address => bool) public isWhitelisted;
    mapping(address => bool) public wertWhitelisted;

    StakingManager public stakingManagerInterface;

    IERC20Upgradeable public USDCInterface;

    bool public dynamicSaleState;
    uint256 public maxTokensToSell;
    uint256 public directTotalTokensSold;
    address public V3Pool;
    uint256 public percent;

    event SaleTimeSet(uint256 _start, uint256 _end, uint256 timestamp);
    event SaleTimeUpdated(
        bytes32 indexed key,
        uint256 prevValue,
        uint256 newValue,
        uint256 timestamp
    );
    event TokensBought(
        address indexed user,
        uint256 indexed tokensBought,
        address indexed purchaseToken,
        uint256 amountPaid,
        uint256 usdEq,
        uint256 timestamp
    );
    event TokensAdded(
        address indexed token,
        uint256 noOfTokens,
        uint256 timestamp
    );
    event TokensClaimed(
        address indexed user,
        uint256 amount,
        uint256 timestamp
    );
    event ClaimStartUpdated(
        uint256 prevValue,
        uint256 newValue,
        uint256 timestamp
    );
    event MaxTokensUpdated(
        uint256 prevValue,
        uint256 newValue,
        uint256 timestamp
    );
    event TokensBoughtAndStaked(
        address indexed user,
        uint256 indexed tokensBought,
        address indexed purchaseToken,
        uint256 amountPaid,
        uint256 usdEq,
        uint256 timestamp
    );
    event TokensClaimedAndStaked(
        address indexed user,
        uint256 amount,
        uint256 timestamp
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /**
     * @dev To pause the presale
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev To unpause the presale
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    function fetchPrice(uint256 amountOut) public view returns (uint256) {
        if (dynamicSaleState) {
            uint256 price = getV3Price(amountOut);

            require(price != 0, "Price fetch failed");

            return price + ((price * percent) / 100);
        } else {
            return (amountOut * rounds[1][currentStep]) / getLatestPrice();
        }
    }

    function getV3Price(uint256 _amountOut) public view returns (uint256) {
        if (V3Pool == address(0)) return 0;

        (uint160 sqrtPriceX96, , , , , , ) = IPoolV3(V3Pool).slot0();

        uint256 price = ((sqrtPriceX96) / (2 ** 96)) ** 2;

        return ((_amountOut) / (price));
    }

    function calculatePrice(uint256 _amount) public view returns (uint256) {
        return
            (fetchPrice(_amount * baseDecimals) * getLatestPrice()) /
            baseDecimals;
    }

    /**
     * @dev To get latest ETH price in 10**18 format
     */
    function getLatestPrice() public view returns (uint256) {
        (, int256 price, , , ) = aggregatorInterface.latestRoundData();
        price = (price * (10 ** 10));
        return uint256(price);
    }

    function setSplits(
        address[] memory _wallets,
        uint256[] memory _percentages
    ) public onlyOwner {
        require(_wallets.length == _percentages.length, "Mismatched arrays");
        delete wallets;
        delete percentages;
        uint256 totalPercentage = 0;

        for (uint256 i = 0; i < _wallets.length; i++) {
            require(_percentages[i] > 0, "Percentage must be greater than 0");
            totalPercentage += _percentages[i];
            wallets.push(_wallets[i]);
            percentages.push(_percentages[i]);
        }

        require(totalPercentage == 100, "Total percentage must equal 100");
    }

    modifier checkSaleState(uint256 amount) {
        require(
            block.timestamp >= startTime && block.timestamp <= endTime,
            "Invalid time for buying"
        );
        require(amount > 0, "Invalid sale amount");
        _;
    }

    /**
     * @dev To buy into a presale using USDT
     * @param amount No of tokens to buy
     */
    function buyWithUSDT(
        uint256 amount,
        bool
    ) external checkSaleState(amount) whenNotPaused returns (bool) {
        require(dynamicSaleState, "Dynamic sale not active");
        require(
            amount <= maxTokensToSell - directTotalTokensSold,
            "Amount exceeds max tokens to be sold"
        );
        directTotalTokensSold += amount;

        uint256 usdPrice = calculatePrice(amount);
        uint256 price = usdPrice / (10 ** 12);

        IERC20Upgradeable(saleToken).transfer(
            _msgSender(),
            amount * baseDecimals
        );

        emit TokensBought(
            _msgSender(),
            amount,
            address(USDTInterface),
            price,
            usdPrice,
            block.timestamp
        );

        uint256 ourAllowance = USDTInterface.allowance(
            _msgSender(),
            address(this)
        );
        require(price <= ourAllowance, "Make sure to add enough allowance");
        splitUSDTValue(price);

        return true;
    }

    /**
     * @dev To buy into a presale using USDT
     * @param amount No of tokens to buy
     */
    function buyWithUSDT(
        uint256 amount
    ) external checkSaleState(amount) whenNotPaused returns (bool) {
        require(dynamicSaleState, "Dynamic sale not active");
        require(
            amount <= maxTokensToSell - directTotalTokensSold,
            "Amount exceeds max tokens to be sold"
        );
        directTotalTokensSold += amount;

        uint256 usdPrice = calculatePrice(amount);
        uint256 price = usdPrice / (10 ** 12);

        IERC20Upgradeable(saleToken).transfer(
            _msgSender(),
            amount * baseDecimals
        );

        emit TokensBought(
            _msgSender(),
            amount,
            address(USDTInterface),
            price,
            usdPrice,
            block.timestamp
        );

        uint256 ourAllowance = USDTInterface.allowance(
            _msgSender(),
            address(this)
        );
        require(price <= ourAllowance, "Make sure to add enough allowance");
        splitUSDTValue(price);

        return true;
    }

    /**
     * @dev To buy into a presale using USDC
     * @param amount No of tokens to buy
     */
    function buyWithUSDC(
        uint256 amount,
        bool
    ) external checkSaleState(amount) whenNotPaused returns (bool) {
        require(dynamicSaleState, "Dynamic sale not active");
        require(
            amount <= maxTokensToSell - directTotalTokensSold,
            "Amount exceeds max tokens to be sold"
        );
        directTotalTokensSold += amount;

        uint256 usdPrice = calculatePrice(amount);
        uint256 price = usdPrice / (10 ** 12);

        IERC20Upgradeable(saleToken).transfer(
            _msgSender(),
            amount * baseDecimals
        );

        emit TokensBought(
            _msgSender(),
            amount,
            address(USDCInterface),
            price,
            usdPrice,
            block.timestamp
        );

        uint256 ourAllowance = USDCInterface.allowance(
            _msgSender(),
            address(this)
        );
        require(price <= ourAllowance, "Make sure to add enough allowance");
        splitUSDCValue(price);

        return true;
    }

    /**
     * @dev To buy into a presale using USDC
     * @param amount No of tokens to buy
     */
    function buyWithUSDC(
        uint256 amount
    ) external checkSaleState(amount) whenNotPaused returns (bool) {
        require(dynamicSaleState, "Dynamic sale not active");
        require(
            amount <= maxTokensToSell - directTotalTokensSold,
            "Amount exceeds max tokens to be sold"
        );
        directTotalTokensSold += amount;

        uint256 usdPrice = calculatePrice(amount);
        uint256 price = usdPrice / (10 ** 12);

        IERC20Upgradeable(saleToken).transfer(
            _msgSender(),
            amount * baseDecimals
        );

        emit TokensBought(
            _msgSender(),
            amount,
            address(USDCInterface),
            price,
            usdPrice,
            block.timestamp
        );

        uint256 ourAllowance = USDCInterface.allowance(
            _msgSender(),
            address(this)
        );
        require(price <= ourAllowance, "Make sure to add enough allowance");
        splitUSDCValue(price);

        return true;
    }

    /**
     * @dev To buy into a presale using ETH
     * @param amount No of tokens to buy
     */
    function buyWithEth(
        uint256 amount,
        bool
    )
        external
        payable
        checkSaleState(amount)
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        require(dynamicSaleState, "Dynamic sale not active");
        require(
            amount <= maxTokensToSell - directTotalTokensSold,
            "Amount exceeds max tokens to be sold"
        );
        directTotalTokensSold += amount;

        uint256 ethAmount = fetchPrice(amount * baseDecimals);
        require(msg.value >= ethAmount, "Less payment");
        uint256 excess = msg.value - ethAmount;

        uint256 usdPrice = calculatePrice(amount);

        IERC20Upgradeable(saleToken).transfer(
            _msgSender(),
            amount * baseDecimals
        );

        emit TokensBought(
            _msgSender(),
            amount,
            address(0),
            ethAmount,
            usdPrice,
            block.timestamp
        );

        splitETHValue(ethAmount);
        if (excess > 0) sendValue(payable(_msgSender()), excess);
        return true;
    }

    /**
     * @dev To buy into a presale using ETH
     * @param amount No of tokens to buy
     */
    function buyWithEth(
        uint256 amount
    )
        external
        payable
        checkSaleState(amount)
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        require(dynamicSaleState, "Dynamic sale not active");
        require(
            amount <= maxTokensToSell - directTotalTokensSold,
            "Amount exceeds max tokens to be sold"
        );
        directTotalTokensSold += amount;

        uint256 ethAmount = fetchPrice(amount * baseDecimals);
        require(msg.value >= ethAmount, "Less payment");
        uint256 excess = msg.value - ethAmount;

        uint256 usdPrice = calculatePrice(amount);

        IERC20Upgradeable(saleToken).transfer(
            _msgSender(),
            amount * baseDecimals
        );

        emit TokensBought(
            _msgSender(),
            amount,
            address(0),
            ethAmount,
            usdPrice,
            block.timestamp
        );

        splitETHValue(ethAmount);
        if (excess > 0) sendValue(payable(_msgSender()), excess);
        return true;
    }

    /**
     * @dev To buy ETH directly from wert .*wert contract address should be whitelisted if wertBuyRestrictionStatus is set true
     * @param _user address of the user
     * @param _amount No of ETH to buy
     */
    function buyWithETHWert(
        address _user,
        uint256 _amount,
        bool
    )
        external
        payable
        checkSaleState(_amount)
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        require(
            wertWhitelisted[_msgSender()],
            "User not whitelisted for this tx"
        );

        require(dynamicSaleState, "Dynamic sale not active");
        require(
            _amount <= maxTokensToSell - directTotalTokensSold,
            "Amount exceeds max tokens to be sold"
        );
        directTotalTokensSold += _amount;
        uint256 usdPrice = calculatePrice(_amount);

        uint256 ethAmount = fetchPrice(_amount * baseDecimals);
        require(msg.value >= ethAmount, "Less payment");
        uint256 excess = msg.value - ethAmount;

        IERC20Upgradeable(saleToken).transfer(_user, _amount * baseDecimals);

        emit TokensBought(
            _user,
            _amount,
            address(0),
            ethAmount,
            usdPrice,
            block.timestamp
        );

        splitETHValue(ethAmount);
        if (excess > 0) sendValue(payable(_user), excess);
        return true;
    }

    /**
     * @dev To buy ETH directly from wert .*wert contract address should be whitelisted if wertBuyRestrictionStatus is set true
     * @param _user address of the user
     * @param _amount No of ETH to buy
     */
    function buyWithETHWert(
        address _user,
        uint256 _amount
    )
        external
        payable
        checkSaleState(_amount)
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        require(
            wertWhitelisted[_msgSender()],
            "User not whitelisted for this tx"
        );

        require(dynamicSaleState, "Dynamic sale not active");
        require(
            _amount <= maxTokensToSell - directTotalTokensSold,
            "Amount exceeds max tokens to be sold"
        );
        directTotalTokensSold += _amount;
        uint256 usdPrice = calculatePrice(_amount);

        uint256 ethAmount = fetchPrice(_amount * baseDecimals);
        require(msg.value >= ethAmount, "Less payment");
        uint256 excess = msg.value - ethAmount;

        IERC20Upgradeable(saleToken).transfer(_user, _amount * baseDecimals);

        emit TokensBought(
            _user,
            _amount,
            address(0),
            ethAmount,
            usdPrice,
            block.timestamp
        );

        splitETHValue(ethAmount);
        if (excess > 0) sendValue(payable(_user), excess);
        return true;
    }

    /**
     * @dev Helper funtion to get ETH price for given amount
     * @param amount No of tokens to buy
     */
    function ethBuyHelper(
        uint256 amount
    ) external view returns (uint256 ethAmount) {
        uint256 usdPrice = calculatePrice(amount);
        ethAmount = (usdPrice * baseDecimals) / getLatestPrice();
    }

    /**
     * @dev Helper funtion to get USDT price for given amount
     * @param amount No of tokens to buy
     */
    function usdtBuyHelper(
        uint256 amount
    ) external view returns (uint256 usdPrice) {
        usdPrice = calculatePrice(amount);
        usdPrice = usdPrice / (10 ** 12);
    }

    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Low balance");
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "ETH Payment failed");
    }

    function splitETHValue(uint256 _amount) internal {
        if (wallets.length == 0) {
            require(paymentWallet != address(0), "Payment wallet not set");
            sendValue(payable(paymentWallet), _amount);
        } else {
            uint256 tempCalc;
            for (uint256 i = 0; i < wallets.length; i++) {
                uint256 amountToTransfer = (_amount * percentages[i]) / 100;
                sendValue(payable(wallets[i]), amountToTransfer);
                tempCalc += amountToTransfer;
            }
            if ((_amount - tempCalc) > 0) {
                sendValue(
                    payable(wallets[wallets.length - 1]),
                    _amount - tempCalc
                );
            }
        }
    }

    function splitUSDTValue(uint256 _amount) internal {
        if (wallets.length == 0) {
            require(paymentWallet != address(0), "Payment wallet not set");
            (bool success, ) = address(USDTInterface).call(
                abi.encodeWithSignature(
                    "transferFrom(address,address,uint256)",
                    _msgSender(),
                    paymentWallet,
                    _amount
                )
            );
            require(success, "Token payment failed");
        } else {
            uint256 tempCalc;
            for (uint256 i = 0; i < wallets.length; i++) {
                uint256 amountToTransfer = (_amount * percentages[i]) / 100;
                (bool success, ) = address(USDTInterface).call(
                    abi.encodeWithSignature(
                        "transferFrom(address,address,uint256)",
                        _msgSender(),
                        wallets[i],
                        amountToTransfer
                    )
                );
                require(success, "Token payment failed");
                tempCalc += amountToTransfer;
            }
            if ((_amount - tempCalc) > 0) {
                (bool success, ) = address(USDTInterface).call(
                    abi.encodeWithSignature(
                        "transferFrom(address,address,uint256)",
                        _msgSender(),
                        wallets[wallets.length - 1],
                        _amount - tempCalc
                    )
                );
                require(success, "Token payment failed");
            }
        }
    }

    function splitUSDCValue(uint256 _amount) internal {
        if (wallets.length == 0) {
            require(paymentWallet != address(0), "Payment wallet not set");
            (bool success, ) = address(USDCInterface).call(
                abi.encodeWithSignature(
                    "transferFrom(address,address,uint256)",
                    _msgSender(),
                    paymentWallet,
                    _amount
                )
            );
            require(success, "Token payment failed");
        } else {
            uint256 tempCalc;
            for (uint256 i = 0; i < wallets.length; i++) {
                uint256 amountToTransfer = (_amount * percentages[i]) / 100;
                (bool success, ) = address(USDCInterface).call(
                    abi.encodeWithSignature(
                        "transferFrom(address,address,uint256)",
                        _msgSender(),
                        wallets[i],
                        amountToTransfer
                    )
                );
                require(success, "Token payment failed");
                tempCalc += amountToTransfer;
            }
            if ((_amount - tempCalc) > 0) {
                (bool success, ) = address(USDCInterface).call(
                    abi.encodeWithSignature(
                        "transferFrom(address,address,uint256)",
                        _msgSender(),
                        wallets[wallets.length - 1],
                        _amount - tempCalc
                    )
                );
                require(success, "Token payment failed");
            }
        }
    }

    /**
     * @dev to initialize staking manager with new addredd
     * @param _stakingManagerAddress address of the staking smartcontract
     */
    function setStakingManager(
        address _stakingManagerAddress
    ) external onlyOwner {
        require(
            _stakingManagerAddress != address(0),
            "staking manager cannot be inatialized with zero address"
        );
        stakingManagerInterface = StakingManager(_stakingManagerAddress);
        IERC20Upgradeable(saleToken).approve(
            _stakingManagerAddress,
            type(uint256).max
        );
    }

    /**
     * @dev To claim tokens after claiming starts
     */
    function claim() external whenNotPaused returns (bool) {
        require(saleToken != address(0), "Sale token not added");
        require(!isBlacklisted[_msgSender()], "This Address is Blacklisted");
        if (whitelistClaimOnly) {
            require(
                isWhitelisted[_msgSender()],
                "User not whitelisted for claim"
            );
        }
        require(block.timestamp >= claimStart, "Claim has not started yet");
        require(!hasClaimed[_msgSender()], "Already claimed");
        hasClaimed[_msgSender()] = true;
        uint256 amount = userDeposits[_msgSender()];
        require(amount > 0, "Nothing to claim");
        delete userDeposits[_msgSender()];
        bool success = IERC20Upgradeable(saleToken).transfer(
            _msgSender(),
            amount
        );
        require(success, "Token transfer failed");
        emit TokensClaimed(_msgSender(), amount, block.timestamp);
        return true;
    }

    function claimAndStake() external whenNotPaused returns (bool) {
        require(saleToken != address(0), "Sale token not added");
        require(!isBlacklisted[_msgSender()], "This Address is Blacklisted");
        if (stakeingWhitelistStatus) {
            require(
                isWhitelisted[_msgSender()],
                "User not whitelisted for stake"
            );
        }
        uint256 amount = userDeposits[_msgSender()];
        require(amount > 0, "Nothing to stake");
        stakingManagerInterface.depositByPresale(_msgSender(), amount);
        delete userDeposits[_msgSender()];
        emit TokensClaimedAndStaked(_msgSender(), amount, block.timestamp);
        return true;
    }

    function changeMaxTokensToBuy(uint256 _maxTokensToBuy) external onlyOwner {
        require(_maxTokensToBuy > 0, "Zero max tokens to buy value");
        uint256 prevValue = maxTokensToBuy;
        maxTokensToBuy = _maxTokensToBuy;
        emit MaxTokensUpdated(prevValue, _maxTokensToBuy, block.timestamp);
    }

    function changeRoundsData(uint256[][3] memory _rounds) external onlyOwner {
        rounds = _rounds;
    }

    /**
     * @dev To add users to blacklist which restricts blacklisted users from claiming
     * @param _usersToBlacklist addresses of the users
     */
    function blacklistUsers(
        address[] calldata _usersToBlacklist
    ) external onlyOwner {
        for (uint256 i = 0; i < _usersToBlacklist.length; i++) {
            isBlacklisted[_usersToBlacklist[i]] = true;
        }
    }

    /**
     * @dev To remove users from blacklist which restricts blacklisted users from claiming
     * @param _userToRemoveFromBlacklist addresses of the users
     */
    function removeFromBlacklist(
        address[] calldata _userToRemoveFromBlacklist
    ) external onlyOwner {
        for (uint256 i = 0; i < _userToRemoveFromBlacklist.length; i++) {
            isBlacklisted[_userToRemoveFromBlacklist[i]] = false;
        }
    }

    /**
     * @dev To set payment wallet address
     * @param _newPaymentWallet new payment wallet address
     */
    function changePaymentWallet(address _newPaymentWallet) external onlyOwner {
        require(_newPaymentWallet != address(0), "address cannot be zero");
        paymentWallet = _newPaymentWallet;
    }

    /**
     * @dev To manage time gap between two rounds
     */
    function manageTimeDiff() internal {
        for (uint256 i; i < rounds[2].length - currentStep; i++) {
            rounds[2][currentStep + i] = block.timestamp + i * timeConstant;
        }
    }

    /**
     * @dev To set time constant for manageTimeDiff()
     * @param _timeConstant time in <days>*24*60*60 format
     */
    function setTimeConstant(uint256 _timeConstant) external onlyOwner {
        timeConstant = _timeConstant;
    }

    /**
     * @dev To get array of round details at once
     * @param _no array index
     */
    function roundDetails(
        uint256 _no
    ) external view returns (uint256[] memory) {
        return rounds[_no];
    }

    /**
     * @dev to update userDeposits for purchases made on BSC
     * @param _users array of users
     * @param _userDeposits array of userDeposits associated with users
     */
    function updateFromBSC(
        address[] calldata _users,
        uint256[] calldata _userDeposits
    ) external onlyOwner {
        require(_users.length == _userDeposits.length, "Length mismatch");
        for (uint256 i = 0; i < _users.length; i++) {
            userDeposits[_users[i]] += _userDeposits[i];
        }
    }

    /**
     * @dev To increment the rounds from backend
     */
    function incrementCurrentStep() external {
        require(
            msg.sender == admin || msg.sender == owner(),
            "caller not admin or owner"
        );
        prevCheckpoints.push(checkPoint);
        if (dynamicTimeFlag) {
            manageTimeDiff();
        }
        if (checkPoint < rounds[0][currentStep]) {
            if (currentStep == 0) {
                remainingTokensTracker.push(
                    rounds[0][currentStep] - totalTokensSold
                );
            } else {
                remainingTokensTracker.push(
                    rounds[0][currentStep] - checkPoint
                );
            }
            checkPoint = rounds[0][currentStep];
        }
        currentStep++;
    }

    /**
     * @dev To set admin
     * @param _admin new admin wallet address
     */
    function setAdmin(address _admin) external onlyOwner {
        admin = _admin;
    }

    /**
     * @dev To change details of the round
     * @param _step round for which you want to change the details
     * @param _checkpoint token tracker amount
     */
    function setCurrentStep(
        uint256 _step,
        uint256 _checkpoint
    ) external onlyOwner {
        currentStep = _step;
        checkPoint = _checkpoint;
    }

    /**
     * @dev To set time shift functionality on/off
     * @param _dynamicTimeFlag bool value
     */
    function setDynamicTimeFlag(bool _dynamicTimeFlag) external onlyOwner {
        dynamicTimeFlag = _dynamicTimeFlag;
    }

    /**
     * @dev     Function to return remainingTokenTracker Array
     */
    function trackRemainingTokens() external view returns (uint256[] memory) {
        return remainingTokensTracker;
    }

    /**
     * @dev     To update remainingTokensTracker Array
     * @param   _unsoldTokens  input parameters in uint256 array format
     */
    function setRemainingTokensArray(uint256[] memory _unsoldTokens) public {
        require(
            msg.sender == admin || msg.sender == owner(),
            "caller not admin or owner"
        );
        require(_unsoldTokens.length != 0, "cannot update invalid values");
        delete remainingTokensTracker;
        for (uint256 i; i < _unsoldTokens.length; i++) {
            remainingTokensTracker.push(_unsoldTokens[i]);
        }
    }

    function setDynamicSaleState(
        bool _state,
        address _v3Pool
    ) external onlyOwner {
        dynamicSaleState = _state;
        V3Pool = _v3Pool;
    }

    function setMaxTokensToSell(uint256 _maxTokensToSell) external onlyOwner {
        maxTokensToSell = _maxTokensToSell;
    }

    function setPercent(uint256 _percent) external onlyOwner {
        percent = _percent;
    }
}
