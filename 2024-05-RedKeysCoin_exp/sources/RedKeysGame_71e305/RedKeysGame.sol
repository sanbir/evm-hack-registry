// SPDX-License-Identifier: MIT
// RedKeys.io Game

pragma solidity 0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function burn(uint256 amount) external;
}

abstract contract Ownable {
    address private _owner;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    constructor() {
        _transferOwnership(msg.sender);
    }

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    function _checkOwner() internal view virtual {
        require(owner() == msg.sender, "Ownable: caller is not the owner");
    }

    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        _transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        _status = _ENTERED;
    }

    function _nonReentrantAfter() private {
        _status = _NOT_ENTERED;
    }

    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == _ENTERED;
    }
}

contract RedKeysGame is Ownable, ReentrancyGuard {
    event GameTokenChanged(address token);
    event Game(uint256 indexed _id);
    event RatioChanged(uint16 ratio, uint16 benefit);
    event MarketingFeePayed(uint256 amount);
    event MarketWalletChanged(address account);
    event MarketFeeChanged(uint256 ratio);

    uint256 constant MIN_AMOUNT = 10 ** 5; //     10 token
    uint256 constant MAX_AMOUNT = 10 ** 9; // 100_000 token
    uint256 constant DIVIDER = 10_000;

    IERC20 public immutable redKeysToken;
    uint256 public counter;
    uint256 public totalEarnings;

    address private marketingWallet;
    uint256 private marketingFeeRatio = 100; // %1
    uint256 private marketingFeeTotal;

    struct Bet {
        uint256 id;
        uint256 amount;
        uint256 timestamp;
        address player;
        uint16 choice;
        uint16 result;
        uint16 ratio;
        uint16 benefit;
    }

    mapping(uint256 => Bet) private bets;

    mapping(address => uint256) public earnings;
    mapping(address => uint256) public usersLastGameId;
    mapping(uint16 => uint16) public ratios;

    constructor(address marketingWallet_, address redKeysToken_) {
        redKeysToken = IERC20(redKeysToken_);
        marketingWallet = marketingWallet_;

        setRatio(2, 3);
        setRatio(3, 5);
        setRatio(5, 7);
        setRatio(7, 11);
        setRatio(11, 13);
        setRatio(13, 17);
        setRatio(17, 19);
        setRatio(19, 23);
        setRatio(1000, 1000);
    }

    function changeRatio(uint16 ratio, uint16 benefit) external onlyOwner {
        require(ratio >= 2 && ratio <= MAX_AMOUNT, "Not in range");
        require(benefit >= 2 && benefit <= MAX_AMOUNT, "Not in range");

        setRatio(ratio, benefit);
        emit RatioChanged(ratio, benefit);
    }

    function setRatio(uint16 ratio, uint16 benefit) internal {
        require(ratio >= 2 && ratio <= MAX_AMOUNT, "Not in range");
        require(benefit >= 2 && benefit <= MAX_AMOUNT, "Not in range");

        ratios[ratio] = benefit;
        emit RatioChanged(ratio, benefit);
    }

    function getById(uint id) public view returns (Bet memory) {
        return bets[id];
    }

    function playGame(
        uint16 choice,
        uint16 ratio,
        uint256 amount
    ) external nonReentrant {
        // read once
        uint16 benefit = ratios[ratio];

        require(choice < 2, "Wrong Choice");
        require(benefit > 0, "Wrong Ratio");
        require(amount >= MIN_AMOUNT && amount <= MAX_AMOUNT, "Not in Range");

        redKeysToken.transferFrom(msg.sender, address(this), amount);

        counter++;
        marketingFeeTotal += (amount * marketingFeeRatio) / DIVIDER;

        uint16 _betResult = uint16(randomNumber()) % ratio;

        bets[counter] = Bet(
            counter,
            amount,
            block.timestamp,
            msg.sender,
            choice,
            _betResult,
            ratio,
            benefit
        );

        if (choice == _betResult) {
            uint256 earned = amount * benefit;
            redKeysToken.transfer(msg.sender, earned);

            // update states
            earnings[msg.sender] += earned;
            totalEarnings += earned;
        } else {
            redKeysToken.burn(amount / ratio);
        }

        usersLastGameId[msg.sender] = counter;
        emit Game(counter);
    }

    function randomNumber() internal view returns (uint256) {
        uint256 seed = uint256(
            keccak256(
                abi.encodePacked(
                    counter +
                        block.timestamp +
                        block.prevrandao +
                        ((
                            uint256(keccak256(abi.encodePacked(block.coinbase)))
                        ) / (block.timestamp)) +
                        block.gaslimit +
                        ((uint256(keccak256(abi.encodePacked(msg.sender)))) /
                            (block.timestamp)) +
                        block.number
                )
            )
        );

        return (seed - ((seed / 1000) * 1000));
    }

    function changeMarketingWallet(address account) external {
        require(msg.sender == marketingWallet, "Not Allowed");
        require(account != address(0), "Address Zero");

        marketingWallet = account;
        emit MarketWalletChanged(account);
    }

    function changeMarketingFeeRatio(uint256 ratio) external {
        require(msg.sender == marketingWallet, "Not Allowed");

        marketingFeeRatio = ratio;
        emit MarketFeeChanged(ratio);
    }

    function removeMarketingFees() external {
        require(msg.sender == marketingWallet, "Not Allowed");

        redKeysToken.transfer(marketingWallet, marketingFeeTotal);
        marketingFeeTotal = 0;
        emit MarketingFeePayed(marketingFeeTotal);
    }
}