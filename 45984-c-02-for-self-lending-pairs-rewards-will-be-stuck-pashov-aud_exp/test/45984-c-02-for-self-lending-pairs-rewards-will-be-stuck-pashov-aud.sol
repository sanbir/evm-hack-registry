// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Peapods — AutoCompoundingPodLp self-lending rewards never become fTokens
    (Pashov C-02, finding 45984). SYNTHETIC, cheatcode-free.
    When the reward token is not the pod LP reward token, _tokenToPairedLpToken
    swaps to the lending pair's underlying and returns. It never deposits into
    the pair, so the later fToken swap is caught and the underlying is stuck.
    @> VULN is that return. */

contract ERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
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
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allow");
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

interface ILendingPair {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

contract LendingPair is ILendingPair {
    ERC20 public underlying;
    ERC20 public fToken;

    constructor(ERC20 underlying_, ERC20 fToken_) {
        underlying = underlying_;
        fToken = fToken_;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        underlying.transferFrom(msg.sender, address(this), assets);
        shares = assets;
        fToken.mint(receiver, shares);
    }
}

contract Dex {
    function swap(ERC20 tokenIn, ERC20 tokenOut, address to, uint256 amountIn) external returns (uint256 amountOut) {
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        amountOut = amountIn;
        tokenOut.mint(to, amountOut);
    }
}

contract AutoCompoundingPodLp {
    bool public constant IS_PAIRED_LENDING_PAIR = true;
    ERC20 public rewardToken;
    ERC20 public lpRewardsToken;
    ERC20 public underlying;
    LendingPair public pairedLp;
    Dex public dex;
    ERC20 public podLp;
    address public staker;
    uint256 public compounded;

    constructor(ERC20 rewardToken_, ERC20 lpRewardsToken_, ERC20 underlying_, LendingPair pairedLp_, Dex dex_, ERC20 podLp_, address staker_) {
        rewardToken = rewardToken_;
        lpRewardsToken = lpRewardsToken_;
        underlying = underlying_;
        pairedLp = pairedLp_;
        dex = dex_;
        podLp = podLp_;
        staker = staker_;
    }

    function _swap(ERC20 tokenIn, ERC20 tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        tokenIn.approve(address(dex), amountIn);
        amountOut = dex.swap(tokenIn, tokenOut, address(this), amountIn);
    }

    function _tokenToPairedLpToken(ERC20 token, uint256 amountIn) internal returns (uint256 amountOut) {
        ERC20 swapOutput = underlying;
        if (IS_PAIRED_LENDING_PAIR) {
            swapOutput = ERC20(pairedLp.asset());
        }
        if (address(token) != address(lpRewardsToken)) {
            amountOut = _swap(token, swapOutput, amountIn);
            return amountOut; // @> VULN: self-lending path returns the underlying and never deposits it for fTokens
        }
        amountOut = _swap(token, swapOutput, amountIn);
        swapOutput.approve(address(pairedLp), amountOut);
        amountOut = pairedLp.deposit(amountOut, address(this));
    }

    function _swapPairedToPod(uint256 fTokenAmount) external returns (uint256 podOut) {
        require(msg.sender == address(this), "self");
        ERC20 fToken = pairedLp.fToken();
        require(fToken.balanceOf(address(this)) >= fTokenAmount && fTokenAmount > 0, "no fToken");
        podOut = fTokenAmount;
        podLp.mint(staker, podOut);
        compounded += podOut;
    }

    function processRewards(uint256 amountIn) external {
        uint256 pairedOut = _tokenToPairedLpToken(rewardToken, amountIn);
        try this._swapPairedToPod(pairedOut) returns (uint256 podOut) {
            podOut;
        } catch {
            // the real compounder swallows the failed fToken swap
        }
    }
}

contract AutoCompoundingPodLpFixed {
    ERC20 public rewardToken;
    ERC20 public lpRewardsToken;
    LendingPair public pairedLp;
    Dex public dex;
    ERC20 public podLp;
    address public staker;
    uint256 public compounded;

    constructor(ERC20 rewardToken_, ERC20 lpRewardsToken_, LendingPair pairedLp_, Dex dex_, ERC20 podLp_, address staker_) {
        rewardToken = rewardToken_;
        lpRewardsToken = lpRewardsToken_;
        pairedLp = pairedLp_;
        dex = dex_;
        podLp = podLp_;
        staker = staker_;
    }

    function processRewards(uint256 amountIn) external {
        ERC20 underlying = ERC20(pairedLp.asset());
        rewardToken.approve(address(dex), amountIn);
        uint256 bought = dex.swap(rewardToken, underlying, address(this), amountIn);
        underlying.approve(address(pairedLp), bought);
        uint256 shares = pairedLp.deposit(bought, address(this));
        podLp.mint(staker, shares);
        compounded += shares;
    }
}

contract Exploit {
    ERC20 public rewardToken; // nonce 1
    ERC20 public lpRewardsToken; // nonce 2
    ERC20 public underlying; // nonce 3
    ERC20 public fToken; // nonce 4
    ERC20 public podLp; // nonce 5
    LendingPair public pair; // nonce 6
    Dex public dex; // nonce 7
    AutoCompoundingPodLp public compounder; // nonce 8

    constructor() {
        rewardToken = new ERC20("Reward", "RWD");
        lpRewardsToken = new ERC20("Pod LP Reward", "pLP");
        underlying = new ERC20("Borrow Token", "BORROW");
        fToken = new ERC20("Lending Share", "fBORROW");
        podLp = new ERC20("Pod LP", "POD");
        pair = new LendingPair(underlying, fToken);
        dex = new Dex();
        compounder = new AutoCompoundingPodLp(rewardToken, lpRewardsToken, underlying, pair, dex, podLp, address(this));
        rewardToken.mint(address(compounder), 1000 ether);
    }

    function run() external {
        require(address(rewardToken) != address(lpRewardsToken), "reward token differs from lp reward token");
        require(compounder.IS_PAIRED_LENDING_PAIR(), "self-lending pod");
        uint256 beforeUnderlying = underlying.balanceOf(address(compounder));
        compounder.processRewards(1000 ether);
        uint256 stuck = underlying.balanceOf(address(compounder));
        require(stuck == beforeUnderlying + 1000 ether, "underlying stuck in the compounder");
        require(fToken.balanceOf(address(compounder)) == 0, "no fToken was minted");
        require(podLp.balanceOf(address(this)) == 0, "stakers received no pod LP");
        require(compounder.compounded() == 0, "nothing was compounded");
        require(rewardToken.balanceOf(address(compounder)) == 0, "the reward balance was consumed");
    }
}
