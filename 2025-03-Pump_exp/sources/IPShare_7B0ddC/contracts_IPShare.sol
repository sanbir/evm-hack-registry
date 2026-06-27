// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interface/IIPShare.sol";

// Events
contract IPShareevents {
    event CreateIPshare(
        address indexed subject, 
        uint256 indexed amount, 
        uint256 createFee
    );
    event Trade(
        address indexed trader,
        address indexed subject,
        bool isBuy,
        uint256 shareAmount,
        uint256 ethAmount,
        uint256 protocolEthAmount,
        uint256 subjectEthAmount,
        uint256 supply
    );
    event ValueCaptured(
        address indexed subject,
        address indexed investor,
        uint256 indexed amount
    );
    event Stake(
        address indexed staker,
        address indexed subject,
        bool isStake,
        uint256 indexed amount,
        uint256 stakedAmount
    );
}

// This is a bonding curve share for KOL's content
contract IPShare is Ownable, Pausable, ReentrancyGuard, IPShareevents, IIPShare {
    address private self;

    // donut contract
    address public donut;
    // Subject => user => balance
    mapping(address => mapping(address => uint256)) private _ipshareBalance;
    // Subject => supply
    mapping(address => uint256) private _ipshareSupply;

    // Subject => created
    mapping(address => bool) private _ipshareCreated;

    uint256 minHoldShares = 10 ether;

    // buy and sell c-share will cost operator fee to the author and donut, 
    // the percent is a number from 0 - 10000, ex. 5000 means 50%
    uint256 public subjectFeePercent;
    uint256 public donutFeePercent;
    uint256 public createFee;
    // address that receive donut fee
    address public donutFeeDestination;

    bool public startTrade = false;
    bool public startFM3D = false;

    // ================================ stake =================================
    struct Staker {
        address staker;
        uint256 amount;
        uint256 redeemAmount;
        uint256 unlockTime;
        uint256 debts;
        uint256 profit;
    }

    // max heap for the max stake user: subject => heap
    mapping(address => Staker[]) private stakerMaxHeap;
    // subject => staker => index
    mapping(address => mapping(address => uint256)) private stakerIndex;
    // unlock day
    uint256 constant UNLOCK_PERIOD = 7 days;
    // subject => amount
    mapping(address => uint256) public totalStakedIPshare;
    // subject => acc
    mapping(address => uint256) private ipshareAcc;

    // ================================ Modifiers =================================
    // only Donut can call buy function, donut contract contains fomo 3d game
    modifier onlyDonut() {
        if (startFM3D && donut != msg.sender) {
            revert OnlyDonut();
        }
        _;
    }

    modifier onlyStaker(address subject) {
        uint256 index = stakerIndex[subject][msg.sender];
        if (!(stakerMaxHeap[subject].length > 0 &&
            stakerMaxHeap[subject][index].staker == msg.sender)) {
            revert OnlyStaker();
        }
        _;
    }

    modifier needTradable() {
        if (!startTrade) {
            revert PendingTradeNow();
        }
        _;
    }

    constructor() Ownable(msg.sender) {
        self = address(this);
        // initial the fee as 4.5% 2.5%
        subjectFeePercent = 450;
        donutFeePercent = 250;
        createFee = 0;
        donutFeeDestination = 0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048;
    }

    // 
    function ipshareCreated(address subject) public view override returns (bool) {
        return _ipshareCreated[subject];
    }

    function ipshareBalance(address subject, address holder) public view override returns (uint256) {
        return _ipshareBalance[subject][holder];
    }

    function ipshareSupply(address subject) public view override returns (uint256) {
        return _ipshareSupply[subject];
    }

    // ================================ admin function =================================
    function adminSetDonut(address _donut) public onlyOwner {
        donut = _donut;
    }

    function adminStartTrade() public onlyOwner() {
        startTrade = true;
    }

    function adminStartFM3D() public onlyOwner() {
        if (address(donut) == address(0)) {
            revert DonutNotSet();
        }
        startFM3D = true;
    }

    function adminSetSubjectFeePercent(
        uint256 _subjectFeePercent
    ) public onlyOwner {
        if (_subjectFeePercent >= 1000) {
            revert FeePercentIsTooLarge();
        }
        subjectFeePercent = _subjectFeePercent;
    }

    function adminSetDonutFeePercent(
        uint256 _donutFeePercent
    ) public onlyOwner {
        if (_donutFeePercent >= 1000) {
            revert FeePercentIsTooLarge();
        }
        donutFeePercent = _donutFeePercent;
    }

    function adminSetDonutFeeDestination(
        address _donutFeeDestination
    ) public onlyOwner {
        donutFeeDestination = _donutFeeDestination;
    }

    function adminSetCreateFee(
        uint256 _createFee
    ) public onlyOwner {
        if (_createFee > 0.01 ether) {
            revert TooMuchFee();
        }
        createFee = _createFee;
    }

    function pause() public onlyOwner {
        if (!Pausable(donut).paused()) {
            revert CanntPauseNow();
        }
        _pause();
    }

    function unpause() public onlyOwner {
        if (Pausable(donut).paused()) {
            revert CanntUnpauseNow();
        }
        _unpause();
    }

    // need receive eth from donut and ft contracts
    receive() external payable {
        
    }

    // ================================ create IPShare =================================
    // only ft user can create his c share
    // creation need no fee
    /**
     * @dev only ft user can create his c share
     * creation need no fee
     */
    function createShare(
        address subject
    ) public payable override nonReentrant whenNotPaused {
        if (subject == address(0)) {
            subject = tx.origin;
        }
        // check if ipshare already created
        if (_ipshareCreated[subject]) {
            revert IPShareAlreadyCreated();
        }
        _ipshareCreated[subject] = true;
        uint256 price = getPrice(minHoldShares, 0);
        if (msg.value < price + createFee) {
            revert InsufficientPay();
        }
        
        if (msg.value > price + createFee) {
            (bool success, ) = msg.sender.call{value: msg.value - price - createFee}("");
            if (!success) {
                revert RefundFail();
            }
        }
        (bool success1, ) = donutFeeDestination.call{value: createFee}("");
        if (!success1) {
            revert PayCreateFeeFail();
        }

        uint256 updatedAmount = minHoldShares;
        // the owner can get 10 share free
        _ipshareSupply[subject] = updatedAmount;
        // stake all the initial amount
        _insertStaker(subject, subject, updatedAmount);
        
        _ipshareBalance[subject][subject] = 0;
        totalStakedIPshare[subject] += updatedAmount;

        _updateStake(subject, subject, updatedAmount);

        // create ipshare wont cost fees
        emit CreateIPshare(subject, minHoldShares, createFee);

        emit Stake(subject, subject, true, updatedAmount, updatedAmount);
    }

    // ================================buy and sell=================================
    // every buy and sell operation will cost the operator's c-share as fee to the author
    // The subject addres always equal to the KOL/Author, one subject corresponding a c-share
    function buyShares(
        address subject,
        address buyer
    )
        public
        payable
        override
        onlyDonut
        nonReentrant
        whenNotPaused
        needTradable
        returns (uint256)
    {
        return _buyShares(subject, buyer, msg.value);
    }

    function _buyShares(
        address subject,
        address buyer,
        uint256 value
    ) private returns (uint256) {
        // check subject exist
        if (!_ipshareCreated[subject]) {
            revert IPShareNotExist();
        }
        uint256 supply = _ipshareSupply[subject];
        uint256 buyFunds = value;
        uint256 subjectFee = (buyFunds * subjectFeePercent) / 10000;
        uint256 donutFee = (buyFunds * donutFeePercent) / 10000;

        uint256 ipshareReceived = getBuyAmountByValue(
            supply,
            buyFunds - subjectFee - donutFee
        );

        (bool success1, ) = donutFeeDestination.call{value: donutFee}("");
        (bool success2, ) = subject.call{value: subjectFee}("");
        if (!success1 || !success2) {
            revert CostTradeFeeFail();
        }
        _ipshareBalance[subject][buyer] += ipshareReceived;
        _ipshareSupply[subject] = supply + ipshareReceived;

        emit Trade(
            buyer,
            subject,
            true,
            ipshareReceived,
            buyFunds,
            donutFee,
            subjectFee,
            supply + ipshareReceived
        );
        return ipshareReceived;
    }

    // every one can sell his c-shares
    function sellShares(
        address subject,
        uint256 shareAmount
    ) public override nonReentrant whenNotPaused needTradable {
        uint256 supply = _ipshareSupply[subject];
        uint sellAmount = shareAmount;
        if (_ipshareBalance[subject][msg.sender] < shareAmount) {
            sellAmount = _ipshareBalance[subject][msg.sender];
        }
        uint256 afterSupply = supply - sellAmount;
        if (afterSupply < minHoldShares) {
            revert CanntSellLast10Shares();
        }

        uint256 price = getPrice(afterSupply, sellAmount);
        _ipshareBalance[subject][msg.sender] -= sellAmount;
        _ipshareSupply[subject] -= sellAmount;

        uint256 subjectFee = (price * subjectFeePercent) / 10000;
        uint256 donutFee = (price * donutFeePercent) / 10000;

        (bool success1, ) = donutFeeDestination.call{value: donutFee}("");
        (bool success2, ) = subject.call{value: subjectFee}("");
        (bool success3, ) = msg.sender.call{
            value: price - subjectFee - donutFee
        }("");
        if (!(success1 && success2 && success3)) {
            revert UnableToSendFunds();
        }

        emit Trade(
            msg.sender,
            subject,
            false,
            sellAmount,
            price,
            donutFee,
            subjectFee,
            afterSupply
        );
    }

    // value capture
    function valueCapture(
        address subject
    ) public payable override whenNotPaused {
        // c-share value capture
        // the method receive eth to buy back c-shares and distribute the c-shares to all the c-share stakers
        if (msg.value == 0) {
            revert NoFunds();
        }
        uint256 obtainedAmount = _buyShares(subject, self, msg.value);
        // update acc
        if (totalStakedIPshare[subject] > 0) {
            ipshareAcc[subject] +=
                (obtainedAmount * 1e18) /
                totalStakedIPshare[subject];
        }

        emit ValueCaptured(subject, msg.sender, msg.value);
    }

    // ================================ stake =================================
    // User can stake his c-shares to earn voting rights and dividend rights
    // User can add more stake c-share
    function stake(
        address subject,
        uint256 amount
    ) public nonReentrant whenNotPaused needTradable {
        if (!(amount > 0 && _ipshareBalance[subject][msg.sender] >= amount)) {
            revert InsufficientShares();
        }

        uint256 index = stakerIndex[subject][msg.sender];

        // updated total stake amount
        uint256 updatedAmount = 0;

        if (
            stakerMaxHeap[subject].length == 0 ||
            stakerMaxHeap[subject][index].staker != msg.sender
        ) {
            updatedAmount = amount;
            index = _insertStaker(subject, msg.sender, amount);
        } else if (stakerMaxHeap[subject][index].amount >= 0) {
            updatedAmount = stakerMaxHeap[subject][index].amount + amount;
            stakerMaxHeap[subject][index].profit +=
                (ipshareAcc[subject] * stakerMaxHeap[subject][index].amount) /
                1e18 -
                stakerMaxHeap[subject][index].debts;
        }
        _ipshareBalance[subject][msg.sender] -= amount;
        totalStakedIPshare[subject] += amount;

        // update debtes
        stakerMaxHeap[subject][index].debts =
            (ipshareAcc[subject] * updatedAmount) /
            1e18;

        _updateStake(subject, msg.sender, updatedAmount);

        emit Stake(msg.sender, subject, true, amount, updatedAmount);
    }

    // Staker start unstake his c-shares
    // Everyone can have only one unstaking stuts of one c-share
    // When the staker start unstaked c-shares, the part of c-shares is locked(no voting rights and dividend rights)
    function unstake(
        address subject,
        uint256 amount
    ) public nonReentrant onlyStaker(subject) whenNotPaused needTradable {
        uint256 index = stakerIndex[subject][msg.sender];


        if (stakerMaxHeap[subject][index].redeemAmount != 0) {
            revert InUnstakingPeriodNow();
        }
        
        if (!(amount > 0 && stakerMaxHeap[subject][index].amount >= amount)) {
            revert WrongAmountOrInsufficientStakeAmount();
        }

        // update profits
        stakerMaxHeap[subject][index].profit +=
            (ipshareAcc[subject] * stakerMaxHeap[subject][index].amount) /
            1e18 -
            stakerMaxHeap[subject][index].debts;

        // update stake info
        uint256 updatedAmount = stakerMaxHeap[subject][index].amount - amount;
        stakerMaxHeap[subject][index].redeemAmount = amount;
        stakerMaxHeap[subject][index].unlockTime =
            block.timestamp +
            UNLOCK_PERIOD;
        totalStakedIPshare[subject] -= amount;

        // update debtes
        stakerMaxHeap[subject][index].debts =
            (ipshareAcc[subject] * updatedAmount) /
            1e18;

        _updateStake(subject, msg.sender, updatedAmount);

        emit Stake(msg.sender, subject, false, amount, updatedAmount);
    }

    // Redeem the unstaked c-share
    // The staker can redeem them after 7days after the start unstaking
    function redeem(address subject) public nonReentrant onlyStaker(subject) whenNotPaused {
        uint256 index = stakerIndex[subject][msg.sender];

        if (stakerMaxHeap[subject][index].redeemAmount == 0) {
            revert NoIPShareToRedeem();
        }
        if (stakerMaxHeap[subject][index].unlockTime > block.timestamp) {
            revert IPShareIsInlockingPeriodNow();
        }
        _ipshareBalance[subject][msg.sender] += stakerMaxHeap[subject][index]
            .redeemAmount;
        stakerMaxHeap[subject][index].redeemAmount = 0;
    }

    // claim ipshare profit from captured value
    function claim(address subject) public nonReentrant onlyStaker(subject) whenNotPaused {
        uint256 index = stakerIndex[subject][msg.sender];
        uint256 pendingProfits = getPendingProfits(subject, msg.sender);
        if (pendingProfits == 0) {
            revert NoProfitToClaim();
        }
        _ipshareBalance[subject][msg.sender] += pendingProfits;
        _ipshareBalance[subject][self] -= pendingProfits;
        stakerMaxHeap[subject][index].profit = 0;

        stakerMaxHeap[subject][index].debts =
            (ipshareAcc[subject] * stakerMaxHeap[subject][index].amount) /
            1e18;
    }

    // get stakers' pending profilts from their staking
    function getPendingProfits(
        address subject,
        address staker
    ) public view override returns (uint256) {
        // if (stakerMaxHeap[subject].length == 0) {
        //     return 0;
        // }
        // uint256 index = stakerIndex[subject][staker];
        // Staker memory stakerInfo = stakerMaxHeap[subject][index];

        Staker memory stakerInfo = getStakerInfo(subject, staker);

        uint256 profits = (ipshareAcc[subject] * stakerInfo.amount) /
            1e18 -
            stakerInfo.debts +
            stakerInfo.profit;
        return profits;
    }

    // ================================ Max heap tool =================================
    function getMaxStaker(
        address subject
    ) public view override returns (address, uint256) {
        if (stakerMaxHeap[subject].length == 0) {
            return (address(0), 0);
        }
        return (
            stakerMaxHeap[subject][0].staker,
            stakerMaxHeap[subject][0].amount
        );
    }

    function getStakerInfo(
        address subject,
        address staker
    ) public view returns (Staker memory) {
        if (stakerMaxHeap[subject].length == 0) {
            return Staker(staker, 0, 0, 0, 0, 0);
        }
        Staker memory _staker = stakerMaxHeap[subject][
            stakerIndex[subject][staker]
        ];

        if (_staker.staker == staker) {
            return _staker;
        }
        return Staker(staker, 0, 0, 0, 0, 0);
    }

    function _updateStake(
        address subject,
        address staker,
        uint256 amount
    ) private {
        uint256 heapLength = stakerMaxHeap[subject].length;

        uint256 currentIndex = stakerIndex[subject][staker];
        Staker memory currentStaker = stakerMaxHeap[subject][currentIndex];

        // update stake info
        if (amount > currentStaker.amount) {
            stakerMaxHeap[subject][currentIndex].amount = amount;
            // up
            while (currentIndex > 0) {
                uint256 parentIndex = (currentIndex - 1) / 2;
                if (
                    stakerMaxHeap[subject][currentIndex].amount <=
                    stakerMaxHeap[subject][parentIndex].amount
                ) {
                    break;
                }
                _swapStaker(subject, currentIndex, parentIndex);
                currentIndex = parentIndex;
            }
        } else if (amount < currentStaker.amount) {
            stakerMaxHeap[subject][currentIndex].amount = amount;
            // down
            while (true) {
                uint256 leftChildIndex = 2 * currentIndex + 1;
                uint256 rightChildIndex = 2 * currentIndex + 2;

                uint256 largestIndex = currentIndex;

                if (
                    leftChildIndex < heapLength &&
                    stakerMaxHeap[subject][leftChildIndex].amount >
                    stakerMaxHeap[subject][currentIndex].amount &&
                    (   
                        rightChildIndex >= heapLength ||
                        (stakerMaxHeap[subject][leftChildIndex].amount >
                        stakerMaxHeap[subject][rightChildIndex].amount)
                    )
                ) {
                    largestIndex = leftChildIndex;
                } else if (
                    rightChildIndex < heapLength &&
                    stakerMaxHeap[subject][rightChildIndex].amount >
                    stakerMaxHeap[subject][currentIndex].amount
                ) {
                    largestIndex = rightChildIndex;
                }

                if (largestIndex == currentIndex) {
                    break;
                }
                _swapStaker(subject, largestIndex, currentIndex);
                currentIndex = largestIndex;
            }
        }
    }

    function _insertStaker(
        address subject,
        address staker,
        uint256 amount
    ) private returns (uint256) {
        Staker memory newStaker = Staker(staker, amount, 0, 0, 0, 0);
        stakerMaxHeap[subject].push(newStaker);

        uint256 currentIndex = stakerMaxHeap[subject].length - 1;
        stakerIndex[subject][staker] = currentIndex;

        while (currentIndex > 0) {
            uint256 parentIndex = (currentIndex - 1) / 2;
            if (
                stakerMaxHeap[subject][currentIndex].amount <=
                stakerMaxHeap[subject][parentIndex].amount
            ) {
                break;
            }
            _swapStaker(subject, currentIndex, parentIndex);
            currentIndex = parentIndex;
        }
        return currentIndex;
    }

    function _swapStaker(
        address subject,
        uint256 index1,
        uint256 index2
    ) private {
        // swap the nodes
        Staker memory temp = stakerMaxHeap[subject][index1];
        stakerMaxHeap[subject][index1] = stakerMaxHeap[subject][index2];
        stakerMaxHeap[subject][index2] = temp;

        // update index
        stakerIndex[subject][stakerMaxHeap[subject][index1].staker] = index1;
        stakerIndex[subject][stakerMaxHeap[subject][index2].staker] = index2;
    }

    // ================================ c-share price calculate lib =================================
    /**
     * @dev calculate the eth price when user buy amount ipshares
     * @param supply the current supply of ipshare
     * @param amount the amount user will buy
     * @return price the eth amount as wei will cost
     */
    function getPrice(
        uint256 supply,
        uint256 amount
    ) public pure returns (uint256) {
        uint256 price = (amount *
            (amount ** 2 + 3 * amount * supply + 3 * (supply ** 2)));
        return price / 100000 / 3e36;
    }

    function getBuyPrice(
        address subject,
        uint256 amount
    ) public view override returns (uint256) {
        return getPrice(_ipshareSupply[subject], amount);
    }

    function getSellPrice(
        address subject,
        uint256 amount
    ) public view override returns (uint256) {
        return getPrice((_ipshareSupply[subject] - amount), amount);
    }

    function getBuyPriceAfterFee(
        address subject,
        uint256 amount
    ) public view override returns (uint256) {
        uint256 price = getBuyPrice(subject, amount);
        uint256 donutFee = (price * donutFeePercent) / 10000;
        uint256 subjectFee = (price * subjectFeePercent) / 10000;
        return price + donutFee + subjectFee;
    }

    function getSellPriceAfterFee(
        address subject,
        uint256 amount
    ) public view override returns (uint256) {
        uint256 price = getSellPrice(subject, amount);
        uint256 donutFee = (price * donutFeePercent) / 10000;
        uint256 subjectFee = (price * subjectFeePercent) / 10000;
        return price - donutFee - subjectFee;
    }

    /**
     * Calculate how many ipshare received by payed eth
     */
    function getBuyAmountByValue(
        uint256 supply,
        uint256 ethAmount
    ) public pure override returns (uint256) {
        return floorCbrt(ethAmount * 100000 * 3e36 + supply ** 3) - supply;
    }

    function floorCbrt(uint256 n) internal pure returns (uint256) {
        unchecked {
            uint256 x = 0;
            for (uint256 y = 1 << 255; y > 0; y >>= 3) {
                x <<= 1;
                uint256 z = 3 * x * (x + 1) + 1;
                if (n / y >= z) {
                    n -= y * z;
                    x += 1;
                }
            }
            return x;
        }
    }
}