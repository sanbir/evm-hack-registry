// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IMokeLPDividend.sol";

interface IPancakeRouterLP {
    function WETH() external pure returns (address);
    function factory() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external;
}

interface IPancakePairLP {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

interface IPancakeFactoryLP {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

/**
 * @title MokeLPDividend
 * @dev BNB dividend distribution proportional to LP token holdings.
 *      - Receives BNB from MokeToken tax distribution
 *      - Can also receive MOKE and swap to BNB
 *      - Uses lpToken.totalSupply() for fair per-LP calculation
 *      - LP balances synced via MokeToken._update hook + manual sync + claim-time sync
 */
contract MokeLPDividend is IMokeLPDividend, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public mokeToken;
    IERC20 public lpToken;
    IPancakeRouterLP public router;

    uint256 public totalDividendPerLP;
    mapping(address => uint256) public userLPRecord;
    mapping(address => uint256) public userDividendDebt;
    mapping(address => uint256) public userPendingDividend;

    uint256 public minSwapAmount = 1e18;
    uint256 public minDistributeAmount = 0.001 ether;
    uint256 public swapSlippageBps = 1500;
    uint256 public constant BASIS_POINTS = 10000;

    uint256 public unprocessedBNB;
    bool private _swapping;

    address public mokeTokenContract;

    event DividendDistributed(uint256 bnbAmount, uint256 totalLP, uint256 perLP);
    event DividendClaimed(address indexed user, uint256 amount);
    event UserLPSynced(address indexed user, uint256 oldLP, uint256 newLP);
    event MinSwapAmountSet(uint256 amount);
    event MinDistributeAmountSet(uint256 amount);
    event EmergencyWithdraw(address indexed token, uint256 amount, address indexed to);
    event MokeTokenContractSet(address indexed mokeToken_);
    event RouterSet(address indexed router_);
    event LPTokenSet(address indexed lpToken_);

    constructor(
        address _mokeToken,
        address _lpToken,
        address _router
    ) Ownable(msg.sender) {
        mokeToken = IERC20(_mokeToken);
        mokeTokenContract = _mokeToken;
        lpToken = IERC20(_lpToken);
        router = IPancakeRouterLP(_router);
    }

    // ============ Admin Functions ============

    function setMinSwapAmount(uint256 _amount) external onlyOwner {
        minSwapAmount = _amount;
        emit MinSwapAmountSet(_amount);
    }

    function setMinDistributeAmount(uint256 _amount) external onlyOwner {
        minDistributeAmount = _amount;
        emit MinDistributeAmountSet(_amount);
    }

    function setSwapSlippageBps(uint256 _bps) external onlyOwner {
        require(_bps <= 3000, "Max 30%");
        swapSlippageBps = _bps;
    }

    function setMokeToken(address _mokeToken) external onlyOwner {
        require(_mokeToken != address(0), "Invalid token");
        mokeToken = IERC20(_mokeToken);
    }

    function setMokeTokenContract(address _contract) external onlyOwner {
        require(_contract != address(0), "Invalid address");
        mokeTokenContract = _contract;
        emit MokeTokenContractSet(_contract);
    }

    function setLPToken(address _lpToken) external onlyOwner {
        require(_lpToken != address(0), "Invalid LP token");
        lpToken = IERC20(_lpToken);
        emit LPTokenSet(_lpToken);
    }

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router");
        router = IPancakeRouterLP(_router);
        emit RouterSet(_router);
    }

    // ============ LP Sync ============

    function syncUserLP(address user) external override {
        _syncUserLP(user);
    }

    function batchSyncUserLP(address[] calldata users) external {
        for (uint256 i = 0; i < users.length; i++) {
            _syncUserLP(users[i]);
        }
    }

    function _syncUserLP(address user) internal {
        uint256 currentLP = lpToken.balanceOf(user);
        uint256 recordedLP = userLPRecord[user];

        if (recordedLP > 0) {
            uint256 accumulated = recordedLP * totalDividendPerLP / 1e18;
            uint256 debt = userDividendDebt[user];
            if (accumulated > debt) {
                userPendingDividend[user] += accumulated - debt;
            }
        }

        if (currentLP != recordedLP) {
            emit UserLPSynced(user, recordedLP, currentLP);
        }

        userLPRecord[user] = currentLP;
        userDividendDebt[user] = currentLP * totalDividendPerLP / 1e18;
    }

    // ============ Core Functions ============

    function distributeDividend() external payable override nonReentrant whenNotPaused {
        uint256 mokeBalance = mokeToken.balanceOf(address(this));

        uint256 bnbAmount;
        if (mokeBalance >= minSwapAmount) {
            bnbAmount = _swapMOKEForBNB(mokeBalance);
        }
        bnbAmount += unprocessedBNB + msg.value;
        unprocessedBNB = 0;

        if (bnbAmount < minDistributeAmount) {
            unprocessedBNB = bnbAmount;
            return;
        }

        uint256 totalLP = lpToken.totalSupply();
        if (totalLP == 0) {
            unprocessedBNB = bnbAmount;
            return;
        }

        uint256 perLP = bnbAmount * 1e18 / totalLP;
        totalDividendPerLP += perLP;

        emit DividendDistributed(bnbAmount, totalLP, perLP);
    }

    function claimDividend() external override nonReentrant whenNotPaused {
        _syncUserLP(msg.sender);

        uint256 pending = userPendingDividend[msg.sender];
        require(pending > 0, "No dividend");

        userPendingDividend[msg.sender] = 0;

        (bool sent,) = payable(msg.sender).call{value: pending}("");
        require(sent, "Transfer failed");

        emit DividendClaimed(msg.sender, pending);
    }

    function getPendingDividend(address user) external view override returns (uint256) {
        uint256 currentLP = lpToken.balanceOf(user);
        uint256 accumulated = currentLP * totalDividendPerLP / 1e18;
        uint256 debt = userDividendDebt[user];
        return userPendingDividend[user] + (accumulated > debt ? accumulated - debt : 0);
    }

    // ============ Swap ============

    function _swapMOKEForBNB(uint256 mokeAmount) internal returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(mokeToken);
        path[1] = router.WETH();

        uint256 minOut = _getMinOutput(mokeAmount, path[0], path[1]);
        mokeToken.forceApprove(address(router), mokeAmount);

        _swapping = true;
        uint256 before = address(this).balance;
        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            mokeAmount, minOut, path, address(this), block.timestamp + 300
        ) {
            uint256 received = address(this).balance - before;
            _swapping = false;
            return received;
        } catch {
            _swapping = false;
            return 0;
        }
    }

    function _getMinOutput(uint256 amountIn, address tokenIn, address tokenOut) internal view returns (uint256) {
        address factory = router.factory();
        address pair = IPancakeFactoryLP(factory).getPair(tokenIn, tokenOut);
        if (pair == address(0)) return 0;
        try IPancakePairLP(pair).getReserves() returns (uint112 r0, uint112 r1, uint32) {
            address t0 = IPancakePairLP(pair).token0();
            uint256 reserveIn;
            uint256 reserveOut;
            if (t0 == tokenIn) { reserveIn = r0; reserveOut = r1; }
            else { reserveIn = r1; reserveOut = r0; }
            if (reserveIn == 0 || reserveOut == 0) return 0;
            uint256 amountInWithFee = amountIn * 997;
            uint256 expectedOut = amountInWithFee * reserveOut / (reserveIn * 1000 + amountInWithFee);
            return expectedOut * (BASIS_POINTS - swapSlippageBps) / BASIS_POINTS;
        } catch {
            return 0;
        }
    }

    // ============ Emergency / Pausable ============

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            (bool sent,) = payable(owner()).call{value: amount}("");
            require(sent, "BNB transfer failed");
        } else {
            IERC20(token).safeTransfer(owner(), amount);
        }
        emit EmergencyWithdraw(token, amount, owner());
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    receive() external payable {
        if (!_swapping) {
            unprocessedBNB += msg.value;
        }
    }
}
