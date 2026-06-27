// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Nonces.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interface/IPump.sol";
import "./Token.sol";
import "./interface/IIPShare.sol";
import "./interface/IBondingCurve.sol";
import './UniswapV2/FullMath.sol';
import './solady/src/utils/FixedPointMathLib.sol';
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import "hardhat/console.sol";

contract Pump is Ownable, Nonces, IPump, ReentrancyGuard, IBondingCurve {
    address private ipshare;
    uint256 public createFee = 0.01 ether;
    uint256 private claimFee = 0.001 ether;
    uint256 private divisor = 10000;
    uint256 private secondPerDay = 86400;
    address private feeReceiver = 0x06Deb72b2e156Ddd383651aC3d2dAb5892d9c048;
    address private claimSigner = 0x78C2aF38330C5b41Ae7946A313e43cDCEEaf8611;
    uint256[2] private feeRatio = [100, 100];  // 0: to tiptag; 1: to salesman
    address private WETH = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;  // bsc
    address private uniswapV2Factory 
        = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;  // bsc
    address private uniswapV2Router 
        = 0x10ED43C718714eb63d5aA57B78B54704E256024E;  // bsc   

    mapping(address => bool) public createdTokens;
    mapping(string => bool) public createdTicks;

    // social distribution
    uint256 private constant claimAmountPerSecond = 11.574074 ether;
    mapping(address => uint256) private lastClaimTime;
    mapping(address => mapping(uint256 => bool)) public claimedOrder;
    mapping(address => uint256) public pendingClaimSocialRewards;
    mapping(address => uint256) public totalClaimedSocialRewards;
    uint256 public totalTokens;

    constructor(
        address _ipshare
    ) Ownable(msg.sender) {
        ipshare = _ipshare;
    }

    receive() external payable {}

    // admin function
    function adminChangeIPShare(address _ipshare) public onlyOwner {
        emit IPShareChanged(ipshare, _ipshare);
        ipshare = _ipshare;
    }

    function adminChangeCreateFee(uint256 _createFee) public onlyOwner {
        if (_createFee > 1 ether) {
            revert TooMuchFee();
        }
        emit CreateFeeChanged(createFee, _createFee);
        createFee = _createFee;
    }

    function adminChangeFeeRatio(uint256[2] calldata ratios) public onlyOwner {
        if (ratios[0] > 9000 || ratios[1] > 9000) {
            revert TooMuchFee();
        }
        feeRatio = ratios;
        emit FeeRatiosChanged(ratios[0], ratios[1]);
    }

    function adminChangeClaimSigner(address signer) public onlyOwner {
        emit ClaimSignerChanged(claimSigner, signer);
        claimSigner = signer;
    }

    function adminChangeFeeAddress(address _feeReceiver) public onlyOwner {
        emit FeeAddressChanged(feeReceiver, _feeReceiver);
        feeReceiver = _feeReceiver;
    }

    function getIPShare() public override view returns (address) {
        return ipshare;
    }

    function getFeeReceiver() public override view returns (address) {
        return feeReceiver;
    }

    function getFeeRatio() public override view returns (uint256[2] memory) {
        return feeRatio;
    }
    function getClaimFee() public override view returns (uint256) {
        return claimFee;
    }

    function getClaimSigner() public override view returns (address) {
        return claimSigner;
    }

    function getUniswapV2Factory() public override view returns (address) {
        return uniswapV2Factory;
    }

    function getUniswapV2Router() public override view returns (address) {
        return uniswapV2Router;
    }

    function getWETH() public override view returns (address) {
        return WETH;
    }

    function createToken(string calldata tick)
        public payable override nonReentrant returns (address) {
        if (createdTicks[tick]) {
            revert TickHasBeenCreated();
        }
        
        createdTicks[tick] = true;

        // check user created ipshare
        address creator = tx.origin;
        
        if (!IIPShare(ipshare).ipshareCreated(creator)) {
            // create ipshare
            IIPShare(ipshare).createShare(creator);
        }

        // cost fee
        if (createFee != 0 && msg.value < createFee) {
            revert InsufficientCreateFee();
        }
        (bool success, ) = feeReceiver.call{value: createFee}("");
        if (!success) {
            revert InsufficientCreateFee();
        }

        Token token = new Token();
        address instance  = address(token);

        emit NewToken(tick, instance, creator);
        
        token.initialize(
            address(this),
            creator,
            tick
        );

        // before dawn of today
        lastClaimTime[instance] = block.timestamp - (block.timestamp % secondPerDay) - 1;

        if (msg.value > createFee) {
            (bool success1, ) = instance.call{
                value: msg.value - createFee
            }(abi.encodeWithSignature("buyToken(uint256,address,uint16,address)", 0, creator, 0, creator));
            if (!success1) {
                revert PreMineTokenFail();
            }
            uint256 leftValue = address(this).balance;
            if (leftValue > 0) {
                (bool success2, ) = msg.sender.call{value: leftValue}("");
                if (!success2) {
                    revert RefundFail();
                }
            }
        }
        createdTokens[instance] = true;
        totalTokens += 1;
        // console.log(instance);
        return instance;
    }

     /********************************** social distribution ********************************/
    function calculateReward(uint256 from, uint256 to) public pure returns (uint256 rewards) {
        if (from >= to) return 0;
        return (to - from) * claimAmountPerSecond;
    }

    // set distributed rewards can be claimed by user
    function claimPendingSocialRewards(address token) public {
        // calculate rewards
        uint256 rewards = calculateReward(lastClaimTime[token], block.timestamp);
        if (rewards > 0) {
            pendingClaimSocialRewards[token] += rewards;
            lastClaimTime[token] = block.timestamp;
            emit ClaimDistributedReward(token, block.timestamp, rewards);
        }
    }

    function userClaim(address token, uint256 orderId, uint256 amount, bytes calldata signature) public payable {
        if (!IToken(token).listed()) {
            revert TokenNotListed();
        }
        if (claimedOrder[token][orderId]) {
            revert ClaimOrderExist();
        }
        if (signature.length != 65) {
            revert InvalidSignature();
        }
        if (!createdTokens[token]) {
            revert TokenNotCreated();
        }

        if (msg.value < claimFee) {
            revert CostFeeFail();
        } else {
            (bool success, ) = feeReceiver.call{value: claimFee}("");
            if (!success) {
                revert CostFeeFail();
            }
        }

        bytes32 data = keccak256(abi.encodePacked(token, orderId, msg.sender, amount));
        if (!_check(data, signature)) {
            revert InvalidSignature();
        }

        if (pendingClaimSocialRewards[token] < amount) {
            claimPendingSocialRewards(token);
        }

        if (pendingClaimSocialRewards[token] < amount) {
            revert InvalidClaimAmount();
        }

        pendingClaimSocialRewards[token] -= amount;
        totalClaimedSocialRewards[token] += amount;

        claimedOrder[token][orderId] = true;

        IERC20(token).transfer(msg.sender, amount);

        emit UserClaimReward(token, orderId, msg.sender, amount);
    }

    function _check(bytes32 data, bytes calldata sign) internal view returns (bool) {
        bytes32 r = abi.decode(sign[:32], (bytes32));
        bytes32 s = abi.decode(sign[32:64], (bytes32));
        uint8 v = uint8(sign[64]);
        if (v < 27) {
            if (v == 0 || v == 1) v += 27;
        }
        bytes memory profix = "\x19Ethereum Signed Message:\n32";
        bytes32 info = keccak256(abi.encodePacked(profix, data));
        address addr = ecrecover(info, v, r, s);
        return addr == claimSigner;
    }

    /********************************** bonding curve ********************************/
    
     /**
     * calculate the eth price when user buy amount tokens
     */
    function getPrice(uint256 supply, uint256 amount) public pure override returns (uint256) {
        uint256 a = 6_500_000_000;
        uint256 b = 2.5175516438e26;
        uint256 x = FixedPointMathLib.mulWad(a, b);
        uint256 e1 = uint256(FixedPointMathLib.expWad(int256((supply + amount) * 1e18 / b)));
        uint256 e2 = uint256(FixedPointMathLib.expWad(int256((supply) * 1e18 / b)));
        return FixedPointMathLib.mulWad(e1 - e2, x);
    }
    
    function getSellPrice(uint256 supply, uint256 amount) public pure override returns (uint256) {
        return getPrice(supply - amount, amount);
    }

    function getBuyPriceAfterFee(uint256 supply, uint256 amount) public view override returns (uint256) {
        uint256 price = getPrice(supply, amount);
        return ((price * divisor) / (divisor - feeRatio[0] - feeRatio[1]));
    }

    function getSellPriceAfterFee(uint256 supply, uint256 amount) public view override returns (uint256) {
        uint256 price = getSellPrice(supply, amount);
        return (price * (divisor - feeRatio[0] - feeRatio[1])) / divisor;
    }

    function getBuyAmountByValue(uint256 bondingCurveSupply, uint256 ethAmount) public pure override returns (uint256) {
        uint256 a = 6_500_000_000;
        uint256 b = 2.5175516438e26;
        // b * ln(ethAmount / (a*b) + exp(bondingCurveSupply/b)) - bondingCurveSupply;
        uint256 ab = FixedPointMathLib.mulWad(a, b);
        uint256 sab = FixedPointMathLib.divWad(ethAmount, ab);
        uint256 e = uint256(FixedPointMathLib.expWad(int256(bondingCurveSupply * 1e18 / b)));
        uint256 ln = uint256(FixedPointMathLib.lnWad(int256(sab + e)));
        return FixedPointMathLib.mulWad(b, ln) - bondingCurveSupply;
    }
}
