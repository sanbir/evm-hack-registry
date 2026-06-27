//  _____  _  _              _        _  ______           _                        
// /  __ \(_)| |            | |      | | | ___ \         | |                       
// | /  \/ _ | |_  __ _   __| |  ___ | | | |_/ / ___   __| |  ___   ___  _ __ ___  
// | |    | || __|/ _` | / _` | / _ \| | |    / / _ \ / _` | / _ \ / _ \| '_ ` _ \ 
// | \__/\| || |_| (_| || (_| ||  __/| | | |\ \|  __/| (_| ||  __/|  __/| | | | | |
//  \____/|_| \__|\__,_| \__,_| \___||_| \_| \_|\___| \__,_| \___| \___||_| |_| |_|

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/ICIT.sol";
import "./interfaces/IBCIT.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/ICITStaking.sol";
import "./interfaces/ICamelotRouter.sol";

contract CitadelRedeem is Ownable, ReentrancyGuard {

    //----------------------VARIABLES----------------------//

    ICIT public CIT;
    IBCIT public bCIT;
    IERC20 public USDC;
    IERC20 public WETH;
    ITreasury public treasury;
    ICITStaking public CITStaking;
    ICamelotRouter public camelotRouter;

    address private CITStakingAddy;

    uint256 public maxRedeemableFixed = 0;
    uint256 public maxRedeemableVariable = 0;

    mapping(address => uint256) private totalbCITRedeemedByUser;

    //----------------------CONSTRUCTOR----------------------//

    constructor(address initialOwner, address _treasury, address _bCIT) Ownable(initialOwner) {
        treasury = ITreasury(_treasury);
        bCIT = IBCIT(_bCIT);
        USDC = IERC20(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8); // 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8
        WETH = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1); // 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1
        camelotRouter = ICamelotRouter(0xc873fEcbd354f5A56E00E710B90EF4201db2448d); // Camelot Arbitrum One 0xc873fEcbd354f5A56E00E710B90EF4201db2448d
    }

    //----------------------SETTERS----------------------//

    function setbCIT(address _bCIT) public onlyOwner {
        bCIT = IBCIT(_bCIT);
    }

    function setCIT(address _CIT) public onlyOwner {
        CIT = ICIT(_CIT);
    }

    function setTreasury(address _treasury) public onlyOwner {
        treasury = ITreasury(_treasury);
    }

    function setCITStaking(address _CITStaking) public onlyOwner {
        CITStaking = ICITStaking(_CITStaking);
        CITStakingAddy = _CITStaking;
    }

    function setMaxRedeemableFixed(uint256 _maxRedeemableFixed) public onlyOwner {
        maxRedeemableFixed += _maxRedeemableFixed;
    }

    function setMaxRedeemableVariable(uint256 _maxRedeemableVariable) public onlyOwner {
        maxRedeemableVariable += _maxRedeemableVariable;
    }

    //----------------------USERS FUNCTIONS----------------------//

    /**
     * 
     * @param underlying the id of the underlying to be distributed - 0 for USDC, 1 for ETH
     * @param token the id of the token to be distributed - 0 for CIT, 1 for bCIT
     * @param amount the amount of CIT to be redeemed
     * @param rate the rate, either fixed or variable - 0 for variable, 1 for fixed
     */
    function redeem(uint256 underlying, uint256 token, uint256 amount, uint8 rate) public nonReentrant {
        require(underlying == 0 || underlying == 1, "Invalid underlying");
        require(token == 0 || token == 1, "Invalid token");
        require(rate == 0 || rate == 1, "Invalid rate");
        require(amount > 0, "Amount must be greater than 0");

        uint256 amountAvailable = CITStaking.redeemCalculator(msg.sender)[token][rate];
        require(amountAvailable > 0, "Nothing to redeem");

        uint256 amountInUnderlying;
        address tokenAddy = underlying == 0 ? address(USDC) : address(WETH);
        // Variable rate
        if (rate == 0) {
            require(amount <= amountAvailable, "Not enough CIT or bCIT to redeem");
            require(amount <= maxRedeemableVariable, "Amount too high");
            maxRedeemableVariable -= amount;
            address[] memory path = new address[](3);

            path[0] = address(CIT); // 1e18
            path[1] = address(WETH);
            path[2] = address(USDC); // 1e6

            uint[] memory a = camelotRouter.getAmountsOut(amount, path);

            if (underlying == 0) {
                amountInUnderlying = a[2]; // result in 6 decimal
            } else {
                amountInUnderlying = a[1]; // result in 18 decimal
            }
        } 
        // Fixed rate
        else {
            uint256 _amount = CITStaking.getCITInUSDAllFixedRates(msg.sender, amount);
            require(amount <= amountAvailable, "Not enough CIT or bCIT to redeem");
            require(amount <= maxRedeemableFixed, "Amount too high");
            maxRedeemableFixed -= amount;
            if (underlying == 1) {
                address[] memory path = new address[](2);

                path[0] = address(USDC); // 1e6
                path[1] = address(WETH); // 1e18

                uint[] memory a = camelotRouter.getAmountsOut(_amount / 1e12, path); // result in 18 decimal

                amountInUnderlying = a[1];
            } else {
                amountInUnderlying = _amount / 1e12; // 1e6 is the decimals of USDC, so 18 - 12 = 6
            }
        }

        if (token == 0) {
            CIT.burn(CITStakingAddy, amount);
            CITStaking.removeStaking(msg.sender, address(CIT), rate, amount);
        } else if (token == 1) {
            totalbCITRedeemedByUser[msg.sender] += amount;
            bCIT.burn(CITStakingAddy, amount);
            CITStaking.removeStaking(msg.sender, address(bCIT), rate, amount);
        }

        treasury.distributeRedeem(tokenAddy, amountInUnderlying, msg.sender);
    }

    //----------------------CALCULATORS----------------------//

    function getTreasuryBalanceETHinUSDC() private view returns (uint256) {
        uint256 amount = address(treasury).balance + WETH.balanceOf(address(treasury));
        address[] memory path = new address[](2);

        path[0] = address(WETH);
        path[1] = address(USDC);

        uint[] memory a = camelotRouter.getAmountsOut(amount, path); // result in 6 decimal

        return a[1];
    }

    function getTotalTreasuryBalance() public view returns (uint256) {
        return USDC.balanceOf(address(treasury)) + getTreasuryBalanceETHinUSDC();
    }

    //---------------------- GETTERS ----------------------//

    function getTotalbCITRedeemedByUser(address user) public view returns (uint256) {
        return totalbCITRedeemedByUser[user];
    }
}
