// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Peapods — H-3 (Sherlock 2025-01, issue 175)
    With LEAVE_AS_PAIRED_LP_TOKEN set, depositFromPairedLpToken forwards the
    paired token into _depositRewards. That function reverts with "R" when
    totalShares == 0 and the token is not rewardsToken. debond calls this path
    and can never finish, so bonded tokens stay in the pod.
*/

interface IERC20 {
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        require(token.transfer(to, amount), "transfer");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        require(token.transferFrom(from, to, amount), "transferFrom");
    }
}

library FixedPoint96 {
    uint256 internal constant Q96 = 2 ** 96;
}

contract Fees {
    function DEN() external pure returns (uint256) {
        return 1000;
    }

    function yieldAdmin() external pure returns (uint256) {
        return 0;
    }

    function yieldBurn() external pure returns (uint256) {
        return 0;
    }
}

contract FeeRouter {
    Fees public immutable protocolFee;

    constructor() {
        protocolFee = new Fees();
    }

    function protocolFees() external view returns (Fees) {
        return protocolFee;
    }
}

contract DexAdapter {
    function getV3Pool(address, address, uint24) external pure returns (address) {
        return address(0);
    }

    function getV3Pool(address, address, int24) external pure returns (address) {
        return address(0);
    }
}

contract Twap {
    function sqrtPriceX96FromPoolAndInterval(address) external pure returns (uint160) {
        return 0;
    }

    function priceX96FromSqrtPriceX96(uint160) external pure returns (uint256) {
        return 0;
    }
}

contract ERC20Mini {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract TokenRewards {
    using SafeERC20 for IERC20;

    uint256 constant PRECISION = 10 ** 27;

    address public INDEX_FUND;
    address public PAIRED_LP_TOKEN;
    bool public LEAVE_AS_PAIRED_LP_TOKEN;
    FeeRouter public PROTOCOL_FEE_ROUTER;
    DexAdapter public DEX_ADAPTER;
    Twap public V3_TWAP_UTILS;
    address public rewardsToken;
    uint256 public totalShares;
    mapping(address => uint256) public rewardsDeposited;
    mapping(address => uint256) public rewardsDistributed;
    mapping(address => uint256) internal _rewardsPerShare;
    mapping(address => bool) internal _depositedRewardsToken;
    address[] internal _allRewardsTokens;
    address public admin;
    bool public immutable burnWhenNoStakers;

    constructor(address paired, address reward, address indexFund, bool leave, bool _burnWhenNoStakers) {
        PAIRED_LP_TOKEN = paired;
        rewardsToken = reward;
        INDEX_FUND = indexFund;
        LEAVE_AS_PAIRED_LP_TOKEN = leave;
        burnWhenNoStakers = _burnWhenNoStakers;
        PROTOCOL_FEE_ROUTER = new FeeRouter();
        DEX_ADAPTER = new DexAdapter();
        V3_TWAP_UTILS = new Twap();
        admin = msg.sender;
    }

    function _msgSender() internal view returns (address) {
        return msg.sender;
    }

    function depositFromPairedLpToken(uint256 _amountTknDepositing) public {
        require(PAIRED_LP_TOKEN != rewardsToken, "R");
        if (_amountTknDepositing > 0) {
            IERC20(PAIRED_LP_TOKEN).safeTransferFrom(_msgSender(), address(this), _amountTknDepositing);
        }
        uint256 _unclaimedPairedLpTkns = rewardsDeposited[PAIRED_LP_TOKEN] - rewardsDistributed[PAIRED_LP_TOKEN];
        uint256 _amountTkn = IERC20(PAIRED_LP_TOKEN).balanceOf(address(this)) - _unclaimedPairedLpTkns;
        require(_amountTkn > 0, "A");
        uint256 _adminAmt = _getAdminFeeFromAmount(_amountTkn);
        _amountTkn -= _adminAmt;

        if (LEAVE_AS_PAIRED_LP_TOKEN) {
            (, uint256 _yieldBurnFee) = _getYieldFees();
            uint256 _burnAmount = (_amountTkn * _yieldBurnFee) / PROTOCOL_FEE_ROUTER.protocolFees().DEN();
            _adminAmt += _burnAmount;
            _amountTkn -= _burnAmount;
            if (_adminAmt > 0) {
                _processAdminFee(_adminAmt);
            }
            _depositRewards(PAIRED_LP_TOKEN, _amountTkn);
            return;
        }

        (address _token0, address _token1) =
            PAIRED_LP_TOKEN < rewardsToken ? (PAIRED_LP_TOKEN, rewardsToken) : (rewardsToken, PAIRED_LP_TOKEN);
        address _pool;
        try DEX_ADAPTER.getV3Pool(_token0, _token1, uint24(10000)) returns (address __pool) {
            _pool = __pool;
        } catch {
            _pool = DEX_ADAPTER.getV3Pool(_token0, _token1, int24(200));
        }
        uint160 _rewardsSqrtPriceX96 = V3_TWAP_UTILS.sqrtPriceX96FromPoolAndInterval(_pool);
        uint256 _rewardsPriceX96 = V3_TWAP_UTILS.priceX96FromSqrtPriceX96(_rewardsSqrtPriceX96);
        uint256 _amountOut = _token0 == PAIRED_LP_TOKEN
            ? (_rewardsPriceX96 * _amountTkn) / FixedPoint96.Q96
            : (_amountTkn * FixedPoint96.Q96) / _rewardsPriceX96;
        _swapForRewards(_amountTkn, _amountOut, _adminAmt);
    }

    function _depositRewards(address _token, uint256 _amountTotal) internal {
        if (_amountTotal == 0) {
            return;
        }
        if (!_depositedRewardsToken[_token]) {
            _depositedRewardsToken[_token] = true;
            _allRewardsTokens.push(_token);
        }
        if (totalShares == 0) {
            if (!burnWhenNoStakers) {
                // @> VULN: paired-lp fees revert while nobody is staked, so debond cannot finish
                require(_token == rewardsToken, "R");
            }
            if (_token == rewardsToken) {
                _burnRewards(_amountTotal);
            } else {
                IERC20(_token).safeTransfer(address(0xdead), _amountTotal);
            }
            return;
        }
        rewardsDeposited[_token] += _amountTotal;
        _rewardsPerShare[_token] += (PRECISION * _amountTotal) / totalShares;
    }

    function _burnRewards(uint256 amount) internal {
        IERC20(rewardsToken).safeTransfer(address(0xdead), amount);
    }

    function _getAdminFeeFromAmount(uint256 amount) internal view returns (uint256) {
        (uint256 adminFee,) = _getYieldFees();
        if (adminFee == 0) return 0;
        return (amount * adminFee) / PROTOCOL_FEE_ROUTER.protocolFees().DEN();
    }

    function _getYieldFees() internal view returns (uint256 adminFee, uint256 burnFee) {
        Fees fees = PROTOCOL_FEE_ROUTER.protocolFees();
        adminFee = fees.yieldAdmin();
        burnFee = fees.yieldBurn();
    }

    function _processAdminFee(uint256 amount) internal {
        IERC20(PAIRED_LP_TOKEN).safeTransfer(admin, amount);
    }

    function _swapForRewards(uint256, uint256, uint256) internal pure {}
}

contract Pod {
    ERC20Mini public immutable peas;
    ERC20Mini public immutable paired;
    ERC20Mini public immutable pool;
    TokenRewards public immutable rewards;
    mapping(address => uint256) public bonded;

    constructor(ERC20Mini _peas, ERC20Mini _paired, ERC20Mini _pool, TokenRewards _rewards) {
        peas = _peas;
        paired = _paired;
        pool = _pool;
        rewards = _rewards;
    }

    function bond(uint256 amount) external {
        require(peas.transferFrom(msg.sender, address(this), amount), "bond");
        bonded[msg.sender] += amount;
    }

    function debond(uint256 amount) external {
        require(bonded[msg.sender] >= amount, "bond");
        _processPreSwapFeesAndSwap();
        bonded[msg.sender] -= amount;
        require(peas.transfer(msg.sender, amount), "return");
    }

    function _processPreSwapFeesAndSwap() internal {
        if (!rewards.LEAVE_AS_PAIRED_LP_TOKEN()) return;
        if (address(paired) == rewards.rewardsToken()) return;
        if (paired.balanceOf(address(pool)) == 0) return;
        uint256 fees = paired.balanceOf(address(this));
        if (fees == 0) return;
        paired.approve(address(rewards), fees);
        rewards.depositFromPairedLpToken(fees);
    }
}

contract Exploit {
    ERC20Mini public peas;
    ERC20Mini public paired;
    ERC20Mini public reward;
    ERC20Mini public pool;
    TokenRewards public rewards;
    Pod public pod;
    bool public debondReverted;
    uint256 public locked;

    constructor() {
        peas = new ERC20Mini("PEAS");
        paired = new ERC20Mini("DAI");
        reward = new ERC20Mini("RWD");
        pool = new ERC20Mini("LP");
        rewards = new TokenRewards(address(paired), address(reward), address(this), true, false);
        pod = new Pod(peas, paired, pool, rewards);
    }

    function run() external {
        peas.mint(address(this), 100 ether);
        peas.approve(address(pod), 100 ether);
        pod.bond(100 ether);
        paired.mint(address(pool), 1 ether);
        paired.mint(address(pod), 10 ether);
        uint256 bondedBefore = pod.bonded(address(this));
        (bool ok,) = address(pod).call(abi.encodeWithSignature("debond(uint256)", 100 ether));
        debondReverted = !ok;
        locked = peas.balanceOf(address(pod));
        require(bondedBefore == 100 ether, "bonded");
        require(rewards.totalShares() == 0, "stakers");
        require(debondReverted, "debond");
        require(locked == 100 ether, "locked");
        require(pod.bonded(address(this)) == 100 ether, "still");
        require(peas.balanceOf(address(this)) == 0, "user");
    }
}
