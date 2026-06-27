// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./interfaces.sol";
import "./pancakeSwap.sol";
import "./LpIncentive.sol";

contract RLToken is ERC20, ITokenInterface, Ownable {
    using SafeMath for uint256;
    using Address for address;

    uint internal constant PRICE_DECIMAL = 1e9;
    uint internal constant FACTOR_18 = 1e18;
    // for test
    //    uint internal constant Day1 = 10 * 60;// 10 min
    //for mainnet
    uint internal constant Day1 = 1 * 24 * 60 * 60;// 1 day

    address public usdt;
    IPancakeSwapV2Pair public pancakeSwapV2Pair;
    IPancakeSwapV2Router02 public pancakeSwapV2Router;
    address public slideReceiver;
    mapping(address => bool) public isCommunityAddress;//300
    mapping(address => uint) public lastMintReward;
    uint public mintInterval;
    address public govIDO;
    uint public mintedAmt;
    ILpIncentive public incentive;


    struct BoughtInfo {
        uint boughtAmt;
        uint averagePrice;
    }

    mapping(address => address) public father;
    mapping(address => BoughtInfo) public bought;
    mapping(address => uint) public mintAwardTimes;


    event UpdateSlideReceiver(address old, address newAddress);
    event MintAward(address indexed to, uint balance, uint award, uint price);
    event BuyToken(address indexed user, uint amount, uint price, uint averagePrice);
    event SellToken(address indexed user, uint amount, uint price, uint averagePrice);

    constructor(address _slideReceiver,
        address _usdt, address router) ERC20("RL Token", "RL") {
        _mint(msg.sender, 1e7 * 10 ** 18);
        pancakeSwapV2Router = IPancakeSwapV2Router02(router);
        address pair = IPancakeSwapV2Factory(pancakeSwapV2Router.factory())
        .createPair(address(this), _usdt);
        usdt = _usdt;
        pancakeSwapV2Pair = IPancakeSwapV2Pair(pair);
        slideReceiver = _slideReceiver;
        isCommunityAddress[_slideReceiver] = true;
        isCommunityAddress[msg.sender] = true;
        mintInterval = Day1;
    }

    function setMintInterval(uint newMintInterval) public onlyOwner {
        mintInterval = newMintInterval;
    }

    function setIncentive(ILpIncentive _incentive) public onlyOwner {
        incentive = _incentive;
    }

    function setGovIDO(address newGovIDO) public onlyOwner {
        govIDO = newGovIDO;
    }

    function addCommunityAddress(address[] calldata user) public onlyOwner {
        for (uint i = 0; i < user.length; i++) {
            isCommunityAddress[user[i]] = true;
        }
    }

    function deleteCommunityAddress(address[] calldata user) public onlyOwner {
        for (uint i = 0; i < user.length; i++) {
            isCommunityAddress[user[i]] = false;
        }
    }

    function updateSlideReceiver(address newSlideReceiver) onlyOwner public {
        address old = slideReceiver;
        slideReceiver = newSlideReceiver;
        emit UpdateSlideReceiver(old, newSlideReceiver);
    }

    function burn(uint256 amount) public override {
        _burn(msg.sender, amount);
    }

    function getFather(address user) external override view returns (address) {
        return father[user];
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        if (to != address(pancakeSwapV2Pair) && to != address(pancakeSwapV2Router)) {
            incentive.distributeAirdrop(to);
        }
        if (msg.sender != address(pancakeSwapV2Pair) && msg.sender != address(pancakeSwapV2Router)) {
            incentive.distributeAirdrop(msg.sender);
        }
        if (govIDO != address(0) && msg.sender == address(pancakeSwapV2Pair)) {
            if (IKBKGovIDO(govIDO).isPriSaler(to)) {
                IKBKGovIDO(govIDO).releasePriSale(to);
            }
        }
        address from = _msgSender();
        if (from != address(0) && father[to] == address(0) && from != address(pancakeSwapV2Pair)
            && !isCommunityAddress[to] && !from.isContract() && !to.isContract()) {
            father[to] = from;
        }
        if (from != address(pancakeSwapV2Pair)) {
            if (!isCommunityAddress[from] && !isCommunityAddress[to]) {
                uint burnAmt = amount / 100;
                amount -= burnAmt;
                _burn(from, burnAmt);
            }
        }
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        if (from != address(pancakeSwapV2Pair) && from != address(pancakeSwapV2Router)) {
            incentive.distributeAirdrop(from);
        }
        if (to != address(pancakeSwapV2Pair) && to != address(pancakeSwapV2Router)) {
            incentive.distributeAirdrop(to);
        }
        if (msg.sender != address(pancakeSwapV2Pair) && msg.sender != address(pancakeSwapV2Router)) {
            incentive.distributeAirdrop(msg.sender);
        }
        require(allowance(from, msg.sender) >= amount, "insufficient allowance");
        if (govIDO != address(0)) {
            if (IKBKGovIDO(govIDO).isPriSaler(from)) {
                IKBKGovIDO(govIDO).releasePriSale(from);
            }
            if (IKBKGovIDO(govIDO).isPriSaler(to)) {
                IKBKGovIDO(govIDO).releasePriSale(to);
            }
        }
        //sell
        if (to == address(pancakeSwapV2Pair) && msg.sender == address(pancakeSwapV2Router)) {
            if (!isCommunityAddress[from]) {
                uint burnAmt = amount / 100;
                _burn(from, burnAmt);
                uint slideAmt = amount * 2 / 100;
                _transfer(from, slideReceiver, slideAmt);
                amount -= (burnAmt + slideAmt);
            }
        } else {
            if (!isCommunityAddress[from] && !isCommunityAddress[to]) {
                uint burnAmt = amount / 100;
                amount -= burnAmt;
                _burn(from, burnAmt);
            }
        }
        return super.transferFrom(from, to, amount);
    }

    function getCurPrice() public view returns (uint) {
        (uint112 reserve0, uint112 reserve1,) = pancakeSwapV2Pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) {
            return 0;
        }
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = usdt;
        uint[] memory amounts = pancakeSwapV2Router.getAmountsOut(FACTOR_18, path);
        if (amounts[0] == 0) {
            return 0;
        }
        return amounts[1] * PRICE_DECIMAL / amounts[0];
    }
}
