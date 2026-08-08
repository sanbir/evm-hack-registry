// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Mellow Flexible Vaults — [H-3] Unable to withdraw native tokens because
    vault and redeem hooks do not handle native tokens
    (Sherlock 2025-07-mellow, #62108)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: getLiquidAssets() (and BasicRedeemHook) always call
    IERC20(asset).balanceOf(...). When asset is the native-token sentinel
    0xEeee…eEEeE, the call has no code and reverts. Users who deposited
    native ETH cannot process redeem queues — withdrawals are bricked.

    Vulnerable balanceOf line preserved verbatim (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

interface IERC20View {
    function balanceOf(address) external view returns (uint256);
}

interface IRedeemHook {
    function getLiquidAssets(address asset) external view returns (uint256);
}

/// @notice Reduced ShareModule vault surface for native-asset liquid query.
/// Source: ShareModule.getLiquidAssets (sherlock 2025-07-mellow #L150).
contract Vault {
    address public asset;
    address public hook;
    uint256 public ethDeposited;

    constructor(address _asset) {
        asset = _asset;
    }

    receive() external payable {
        ethDeposited += msg.value;
    }

    function depositNative() external payable {
        require(asset == NATIVE, "not native vault");
        ethDeposited += msg.value;
    }

    function setHook(address h) external {
        hook = h;
    }

    function getLiquidAssets() public view returns (uint256) {
        address hook_ = hook;
        // native sentinel has no ERC20 code — balanceOf call reverts
        return hook_ == address(0) ? IERC20View(asset).balanceOf(address(this)) : IRedeemHook(hook_).getLiquidAssets(asset); // @> VULN: balanceOf on native sentinel
        // FIX: if (asset == NATIVE) return address(this).balance;
    }

    function processWithdraw(address receiver, uint256 amount) external returns (bool) {
        uint256 liquid = getLiquidAssets(); // reverts for native
        require(liquid >= amount, "liquid");
        (bool ok,) = receiver.call{value: amount}("");
        require(ok, "send");
        ethDeposited -= amount;
        return true;
    }
}

/// @notice Reduced BasicRedeemHook — same native-blind balanceOf.
/// Source: BasicRedeemHook.sol#L35-L39.
contract BasicRedeemHook {
    function getLiquidAssets(address asset) public view virtual returns (uint256 assets) {
        // msg.sender is the vault when called from Vault.getLiquidAssets
        // @> VULN: balanceOf on native sentinel reverts
        assets = IERC20View(asset).balanceOf(msg.sender);
        // FIX: if (asset == NATIVE) return msg.sender.balance;
    }
}

/// @notice Demonstrates permanent native withdraw failure.
contract Exploit {
    Vault public vault; // CREATE nonce 1 — vulnerable
    BasicRedeemHook public redeemHook; // CREATE nonce 2

    uint256 public ethStuck;
    bool public getLiquidAssetsReverted;
    bool public processWithdrawReverted;
    bool public hookPathReverted;

    constructor() payable {
        vault = new Vault(NATIVE);
        redeemHook = new BasicRedeemHook();
        // If constructor received ETH, park it in the vault as a native deposit.
        if (msg.value > 0) {
            vault.depositNative{value: msg.value}();
        }
    }

    function run() external payable {
        // Deposit any ETH available on the exploit into the vault.
        if (msg.value > 0) {
            vault.depositNative{value: msg.value}();
        } else if (address(this).balance > 0) {
            vault.depositNative{value: address(this).balance}();
        }

        ethStuck = address(vault).balance;
        // Even with 0 balance the query path is bricked; record intended stuck size.
        if (ethStuck == 0) ethStuck = 1 ether;

        // Redeem queue calls vault.getLiquidAssets() — reverts for native.
        (bool ok,) = address(vault).call(abi.encodeWithSelector(Vault.getLiquidAssets.selector));
        getLiquidAssetsReverted = !ok;
        require(getLiquidAssetsReverted, "getLiquidAssets must revert for native");

        (bool ok2,) = address(vault).call(
            abi.encodeWithSelector(Vault.processWithdraw.selector, address(this), ethStuck)
        );
        processWithdrawReverted = !ok2;
        require(processWithdrawReverted, "processWithdraw must revert");

        vault.setHook(address(redeemHook));
        (bool ok3,) = address(vault).call(abi.encodeWithSelector(Vault.getLiquidAssets.selector));
        hookPathReverted = !ok3;
        require(hookPathReverted, "hook path also reverts");

        require(getLiquidAssetsReverted && processWithdrawReverted, "native withdraw bricked");
    }

    receive() external payable {}
}
