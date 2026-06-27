// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./Token.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract ICO is Ownable {

    uint256 public startTime;
    uint256 public endTime;
    uint256 public amountPerStable;
    Token   public token;
    IERC20  public usdtToken;
    IERC20  public busdToken;

    AggregatorV3Interface public priceFeed;

    using SafeMath for uint256;
    event BuyICO(uint256 currency, uint256 amount, uint256 balance, address referrer);

    mapping(address => address) public referrers;

    constructor(
        uint256 _startTime,
        uint256 _endTime,
        uint256 _amountPerStable,
        address _token,
        address _usdtAddress,
        address _busdAddress,
        address _priceFeedAddress){

        startTime       = _startTime;
        endTime         = _endTime;
        amountPerStable = _amountPerStable;

        token     = Token(_token);
        usdtToken = IERC20(_usdtAddress);
        busdToken = IERC20(_busdAddress);
        priceFeed = AggregatorV3Interface(_priceFeedAddress);
    }

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    // Fallback function is called when msg.data is not empty
    fallback() external payable {}

    function setRoundInfo(uint256 _startTime, uint256 _endTime, uint256 _amountPerStable) external onlyOwner {
        require(_startTime > block.timestamp && _startTime < _endTime, "ICO Time Invalid");
        require(_amountPerStable > 0, "Rate Invalid");

        startTime = _startTime;
        endTime   = _endTime;
        amountPerStable = _amountPerStable;
    }

    function setAmountPerStable(uint256 _amountPerStable) external onlyOwner {
        require(_amountPerStable > 0, "Rate Invalid");
        amountPerStable = _amountPerStable;
    }

    function setPriceFeed(address _priceFeedAddress) external onlyOwner {
        require(_priceFeedAddress != address(0), "Price Feed Address Invalid");
        priceFeed = AggregatorV3Interface(_priceFeedAddress);
    }

    function buyByBnb(address _referrer) external payable {
        validate(msg.value);

        uint256 stablePerBnb = uint256(getLatestPrice()); // USDT/ETH
        uint256 amount       = msg.value.mul(10 ** 18).div(stablePerBnb);
        uint256 buyAmount    = amount.mul(amountPerStable);
        require(buyAmount   <= token.balanceOf(address(this)), "Not Enough Token To Buy");

        token.transferLockToken(msg.sender, buyAmount);

        // lv1
        if (_referrer != address (0)) {
            if (referrers[msg.sender] != address (0))
                _referrer = referrers[msg.sender];

            payable(_referrer).transfer(msg.value * 5 / 100);

            // lv2
            address lv2 = referrers[_referrer];
            if (lv2 != address (0)) {
                payable(lv2).transfer(msg.value * 3 / 100);

                // lv3
                address lv3 = referrers[lv2];
                if (lv3 != address (0)) {
                    payable(lv3).transfer(msg.value * 2 / 100);

                    // lv4
                    address lv4 = referrers[lv3];
                    if (lv4 != address (0)) {
                        payable(lv4).transfer(msg.value * 1 / 100);
                    }
                }
            }
        }
    }

    function buyByUsdt(uint256 _amount, address _referrer) external {
        validate(_amount);

        uint256 buyAmount  = _amount.mul(amountPerStable);
        require(buyAmount <= token.balanceOf(address(this)), "Not Enough Token To Buy");

        usdtToken.transferFrom(msg.sender, address(this), _amount);
        token.transferLockToken(msg.sender, buyAmount);

        // lv1
        if (_referrer != address (0)) {
            if (referrers[msg.sender] != address (0))
                _referrer = referrers[msg.sender];

            usdtToken.transfer(_referrer, _amount * 5 / 100);

            // lv2
            address lv2 = referrers[_referrer];
            if (lv2 != address (0)) {
                usdtToken.transfer(lv2, _amount * 3 / 100);

                // lv3
                address lv3 = referrers[lv2];
                if (lv3 != address (0)) {
                    usdtToken.transfer(lv3, _amount * 2 / 100);

                    // lv4
                    address lv4 = referrers[lv3];
                    if (lv4 != address (0)) {
                        usdtToken.transfer(lv4, _amount * 1 / 100);
                    }
                }
            }
        }
    }

    function buyByBusd(uint256 _amount, address _referrer) external {
        validate(_amount);

        uint256 buyAmount  = _amount.mul(amountPerStable);
        require(buyAmount <= token.balanceOf(address(this)), "Not Enough Token To Buy");

        busdToken.transferFrom(msg.sender, address(this), _amount);
        token.transferLockToken(msg.sender, buyAmount);

        // lv1
        if (_referrer != address (0)) {
            if (referrers[msg.sender] != address (0))
                _referrer = referrers[msg.sender];

            busdToken.transfer(_referrer, _amount * 5 / 100);

            // lv2
            address lv2 = referrers[_referrer];
            if (lv2 != address (0)) {
                busdToken.transfer(lv2, _amount * 3 / 100);

                // lv3
                address lv3 = referrers[lv2];
                if (lv3 != address (0)) {
                    busdToken.transfer(lv3, _amount * 2 / 100);

                    // lv4
                    address lv4 = referrers[lv3];
                    if (lv4 != address (0)) {
                        busdToken.transfer(lv4, _amount * 1 / 100);
                    }
                }
            }
        }
    }

    function validate(uint256 _amount) private view {
        require(_amount > 0, "Amount Invalid");
        require(block.timestamp >= startTime, "Not Start Time");
        require(block.timestamp <= endTime, "Time End");
    }

    function getLatestPrice() internal view returns (int256) {
        ( ,int256 answer, , , ) = priceFeed.latestRoundData();
        return answer;
    }

    function withdrawToken() external onlyOwner {
        token.transfer(msg.sender, token.balanceOf(address(this)));
    }

    function withdraw() external onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
        usdtToken.transfer(msg.sender, usdtToken.balanceOf(address(this)));
        busdToken.transfer(msg.sender, busdToken.balanceOf(address(this)));
    }
}
